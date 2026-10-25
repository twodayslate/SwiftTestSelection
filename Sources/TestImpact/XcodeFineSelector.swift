// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

public enum XcodeFineSelector {
    public static func select(current: XcodeTestGraph, previous: XcodeTestGraph?, changes: [FileChange], baseRevision: String, additionalFallbacks: [String] = []) -> ImpactReport {
        let inventory = Set(current.tests)
        let uiTargets = Set(current.targets.filter(\.isUITest).map(\.name))
        let uiTests = inventory.filter { uiTargets.contains(target(of: $0)) }
        var selected = Set<String>()
        var explanations: [TestExplanation] = []
        var diagnostics: [SelectionDiagnostic] = []
        var fullReasons: [String] = []
        var ignored = Set<String>()
        var headMappingIndex: MappingIndex?
        var boundaryDecisions: [RuntimeBoundaryDecision] = []
        func include(_ tests: Set<String>, kind: String, reason: String, revision: String, path: [String] = []) {
            for test in tests.intersection(inventory).sorted() {
                selected.insert(test)
                explanations.append(TestExplanation(test: test, reason: reason, revision: revision, path: path, kind: kind))
            }
        }
        func fallback(_ code: String, _ message: String, tests: Set<String> = inventory) {
            let affected = tests.intersection(inventory)
            diagnostics.append(SelectionDiagnostic(code: code, message: message, tests: affected.sorted()))
            include(affected, kind: "fallback", reason: message, revision: "base/head")
            if affected == inventory { fullReasons.append(message) }
        }
        let oldUnits = Dictionary(grouping: previous?.sources.values.flatMap(\.units) ?? [], by: \.key)
        let newUnits = Dictionary(grouping: current.sources.values.flatMap(\.units), by: \.key)
        let oldUnitsByFile = Dictionary(grouping: oldUnits.values.flatMap { $0 }, by: { $0.region.path })
        let newUnitsByFile = Dictionary(grouping: newUnits.values.flatMap { $0 }, by: { $0.region.path })
        var oldChanged: [SourceUnit] = []
        var newChanged: [SourceUnit] = []
        for key in Set(oldUnits.keys).union(newUnits.keys) {
            let old = oldUnits[key] ?? [], new = newUnits[key] ?? []
            if old.map(\.fingerprint).sorted() != new.map(\.fingerprint).sorted() {
                oldChanged += old; newChanged += new
            }
        }
        // Only compare definitions owned by the source module. Imported SIL can
        // be emitted by several compiler invocations, with different attribution
        // and serialized implementation details in each copy.
        if let previous, let before = previous.dependencies, let after = current.dependencies {
            func edgeGroups(_ snapshot: XcodeTestGraph, _ graph: DependencyGraph) -> [String: [FunctionNode]] {
                var ownership: [String: Set<String>] = [:]
                for target in snapshot.targets {
                    if let module = snapshot.modules[target.name] {
                        ownership[module, default: []].formUnion(target.sourceFiles)
                    }
                }
                return Dictionary(grouping: graph.functions.values.filter { node in
                    node.regions.contains { ownership[node.module]?.contains($0.path) == true }
                }, by: { $0.module + "." + $0.name })
            }
            let oldEdges = edgeGroups(previous, before), newEdges = edgeGroups(current, after)
            // Mangled IDs preserve overload identity and are independent of the
            // importing module. Only pair renamed IDs by semantic name when both
            // sides have one owned definition (e.g. a private function file move).
            let sharedIDs = Set(before.functions.keys).intersection(after.functions.keys)
            var movedIDs: [String: String] = [:]
            for key in Set(oldEdges.keys).intersection(newEdges.keys) {
                if let old = oldEdges[key], let new = newEdges[key], old.count == 1, new.count == 1,
                   !sharedIDs.contains(old[0].id), !sharedIDs.contains(new[0].id) {
                    movedIDs[old[0].id] = key; movedIDs[new[0].id] = key
                }
            }
            func signatures(_ nodes: [FunctionNode]) -> [String] {
                nodes.map { node in node.dependencies.map { id in
                    movedIDs[id].map { "definition:" + $0 } ?? "symbol:" + id
                }.sorted().joined(separator: "\n") }.sorted()
            }
            for key in Set(oldEdges.keys).intersection(newEdges.keys) {
                if signatures(oldEdges[key]!) != signatures(newEdges[key]!) {
                    for (nodes, units, isOld) in [(oldEdges[key]!, oldUnitsByFile, true), (newEdges[key]!, newUnitsByFile, false)] {
                        let candidates = Set(nodes.flatMap(\.regions).map(\.path)).flatMap { units[$0] ?? [] }
                        let enclosing = candidates.filter { unit in unit.kind == "function" && nodes.contains { node in node.regions.contains { $0.path == unit.region.path && $0.startLine >= unit.region.startLine && $0.startLine <= unit.region.endLine } } }
                        if isOld { oldChanged += enclosing } else { newChanged += enclosing }
                    }
                }
            }
        }
        oldChanged = Dictionary(grouping: oldChanged, by: { $0.key + $0.region.path }).values.compactMap(\.first)
        newChanged = Dictionary(grouping: newChanged, by: { $0.key + $0.region.path }).values.compactMap(\.first)
        let semanticPaths = Set((oldChanged + newChanged).map { $0.region.path })
        let knownPaths = Set((current.targets + (previous?.targets ?? [])).flatMap(\.sourceFiles))
        let analyzedPaths = Set((Array(current.sources.keys) + Array(previous?.sources.keys ?? [:].keys)).compactMap { key in
            key.firstIndex(of: ":").map { String(key[key.index(after: $0)...]) }
        }).union(oldUnits.values.flatMap { $0 }.map { $0.region.path })
            .union(newUnits.values.flatMap { $0 }.map { $0.region.path })
        for change in changes {
            let paths = [change.path] + (change.previousPath.map { [$0] } ?? [])
            let ignoredDocumentation = paths.allSatisfy { path in
                path.hasSuffix(".md") && !knownPaths.contains(path) &&
                [current.mappings, previous?.mappings].allSatisfy { mappings in
                    mappings?.ignoredDocumentation?.contains { UIFeatureMappings.matches(path, pattern: $0) } == true
                }
            }
            if ignoredDocumentation {
                ignored.insert(change.path)
            } else if change.path.hasSuffix(".swift"), knownPaths.contains(change.path), analyzedPaths.contains(change.path), !semanticPaths.contains(change.path) {
                ignored.insert(change.path)
            } else if change.isPureMove && change.path.hasSuffix(".pbxproj") {
                ignored.insert(change.path)
            } else if !change.path.hasSuffix(".swift") || !knownPaths.contains(change.path) || !analyzedPaths.contains(change.path) {
                fallback("unclassified_change", "Change lacks a supported semantic source boundary: \(change.path)")
            }
        }
        let hasSemanticChanges = !oldChanged.isEmpty || !newChanged.isEmpty
        // A proven test-entry change is invoked by the test runner, not by
        // unrelated tests' opaque SDK calls. Keep explicit callers in the graph,
        // but do not let uncertainty elsewhere expand this into a suite run.
        // Both revisions must prove every change is an entry, so mixed edits,
        // helpers, lifecycle hooks and unresolved/ambiguous boundaries retain
        // the conservative policy.
        let testEntriesOnly = hasSemanticChanges && previous?.dependencies != nil &&
            oldChanged.allSatisfy { isTestEntry($0, in: previous!) } &&
            newChanged.allSatisfy { isTestEntry($0, in: current) }
        // UI automation runs in another process. With an explicit, complete
        // runtime dependency contract, app impact comes from mapped boundaries
        // and dependsOn, not opaque calls in every UI runner's launch path.
        // Test helpers/lifecycle changes still require the conservative policy.
        let declaredUIRuntime = current.mappings?.runtimeDependencyPolicy == .declared &&
            previous?.mappings?.runtimeDependencyPolicy == .declared && previous?.dependencies != nil &&
            oldChanged.allSatisfy { isProductionOrTestEntry($0, in: previous!) } &&
            newChanged.allSatisfy { isProductionOrTestEntry($0, in: current) }
        if hasSemanticChanges || !changes.isEmpty {
            for message in additionalFallbacks { fallback("base_unavailable", message) }
            if previous?.dependencies == nil { fallback("base_unavailable", "Base compiler graph is unavailable.") }
            for graph in [current, previous].compactMap({ $0 }) {
                for message in graph.diagnostics + (graph.dependencies?.diagnostics ?? []) + graph.sources.values.flatMap(\.diagnostics) {
                    fallback("incomplete_graph", message)
                }
            }
        }
        for (revision, optionalGraph, units) in [("base", previous, oldChanged), ("head", Optional(current), newChanged)] {
            guard let snapshot = optionalGraph, let graph = snapshot.dependencies else { continue }
            let index = DependencyIndex(graph)
            var affected = Set<String>()
            var productionUnits: [SourceUnit] = []
            var productionAffected = Set<String>()
            for unit in units {
                let owners = snapshot.targets.filter { $0.sourceFiles.contains(unit.region.path) }
                let production = owners.isEmpty || owners.contains { !$0.isTest }
                let candidates = unit.kind != "function" && !unit.scope.isEmpty
                    ? owners.reduce(into: Set<String>()) { $0.formUnion(index.byModule[snapshot.modules[$1.name] ?? ""] ?? []) }
                    : index.byFile[unit.region.path] ?? []
                let nodes = candidates.compactMap { graph.functions[$0] }.filter { node in
                    guard !node.regions.isEmpty else { return false }
                    if unit.kind == "function" {
                        return node.regions.contains { $0.path == unit.region.path && $0.startLine >= unit.region.startLine && $0.startLine <= unit.region.endLine }
                    }
                    if !unit.scope.isEmpty {
                        return node.name.contains(unit.scope + ".") && owners.contains { snapshot.modules[$0.name] == node.module }
                    }
                    return node.regions.contains { $0.path == unit.region.path }
                }
                let ids = Set(nodes.map(\.id))
                affected.formUnion(ids)
                if production { productionUnits.append(unit); productionAffected.formUnion(ids) }
                if production && unit.scope.isEmpty && unit.kind != "function" {
                    fallback("file_level_change", "Changed production initialization, configuration or file-level declaration: \(unit.region.path)")
                }
                if unit.kind != "function", !production {
                    // Type layout, stored state, imports and lifecycle declarations
                    // can affect implicit execution outside the explicit call graph.
                    var tests = Set<String>()
                    for test in snapshot.tests where owners.contains(where: { $0.name == target(of: test) }) {
                        let roots = graph.tests[test] ?? []
                        if unit.scope.isEmpty || roots.contains(where: { graph.functions[$0]?.name.contains(unit.scope + ".") == true }) {
                            tests.insert(test)
                        }
                    }
                    include(tests, kind: "dependency", reason: "Changed class state, inheritance, or file-level declaration", revision: revision, path: [unit.region.path, unit.scope])
                }
                if ids.isEmpty {
                    let tests = Set(snapshot.tests.filter { test in owners.contains { $0.name == target(of: test) } })
                    fallback("unresolved_declaration", "Cannot associate changed declaration with compiled functions: \(unit.region.path):\(unit.region.startLine)", tests: production ? inventory : tests)
                }
            }
            let affectedPaths = index.paths(to: affected)
            for test in snapshot.tests where inventory.contains(test) {
                if hasSemanticChanges {
                    for diagnostic in graph.testDiagnostics[test] ?? [] {
                        fallback("unresolved_inheritance", diagnostic + " for " + test, tests: [test])
                    }
                }
                if let path = affectedPaths.path(from: graph.tests[test] ?? []) {
                    include([test], kind: "dependency", reason: "Compiled dependency reaches a changed declaration", revision: revision,
                            path: path.map { graph.functions[$0].map { $0.module + "." + $0.name } ?? $0 })
                }
                if hasSemanticChanges && (graph.tests[test]?.isEmpty ?? true) {
                    fallback("unresolved_test", "Cannot resolve compiled entry point: \(test)", tests: [test])
                }
            }
            if hasSemanticChanges && !testEntriesOnly {
                // Runtime dispatch to known project declarations is represented by
                // candidate SIL edges. Opaque function values and raw pointers are
                // not proof of absence; conservatively include their callers.
                let uncertain = Set(graph.functions.values.filter { node in
                    node.uncertainties.contains {
                        // Imported implementations can call project overrides or
                        // type-erased conformances even without project debug
                        // locations. Ownership alone does not close that edge.
                        $0.hasPrefix("Imported conformance:") || !node.regions.isEmpty &&
                        ($0 == "Indirect function invocation" || $0 == "Raw pointer operation" || $0 == "Global state access" || $0.hasPrefix("Unresolved project dispatch:"))
                    }
                }.map(\.id))
                let uncertainPaths = index.paths(to: uncertain)
                var boundedTargets: [String: TestRuntimeBoundary] = [:]
                let peer = revision == "base" ? current : previous
                for group in Dictionary(grouping: snapshot.mappings?.testRuntimeBoundaries ?? [], by: \.target).values {
                    let boundary = group[0]
                    let targetTests = Set(snapshot.tests.filter { $0.hasPrefix(boundary.target + "/") })
                    let peerBoundaries = peer?.mappings?.testRuntimeBoundaries?.filter { $0.target == boundary.target } ?? []
                    let failure: String?
                    if group.count != 1 || peerBoundaries.count != 1 || peerBoundaries.first != boundary {
                        failure = "Runtime boundary for \(boundary.target) is missing, ambiguous, or changed between revisions"
                    } else if (try? snapshot.mappings?.validate()) == nil {
                        failure = "Invalid runtime boundary policy for \(boundary.target)"
                    } else {
                        failure = boundary.validationFailure(in: snapshot)
                    }
                    if let failure {
                        fallback("invalid_runtime_boundary", "\(revision): \(failure)", tests: targetTests.isEmpty ? inventory.subtracting(uiTests) : targetTests)
                    } else {
                        boundedTargets[boundary.target] = boundary
                    }
                }
                // Both semantic inventories participate, including added/deleted
                // declarations and dependency changes in a stacked comparison.
                // Infrastructure changes retain the existing conservative policy.
                let changesAreProduction = previous != nil &&
                    oldChanged.allSatisfy { isProduction($0, in: previous!) } &&
                    newChanged.allSatisfy { isProduction($0, in: current) }
                let changedModules = Set((oldChanged + newChanged).map { String($0.key.prefix { $0 != ":" }) })
                var bounded: [String: [String]] = [:]
                for test in snapshot.tests where inventory.contains(test) {
                    if declaredUIRuntime && uiTests.contains(test) { continue }
                    if let path = uncertainPaths.path(from: graph.tests[test] ?? []) {
                        if changesAreProduction, let boundary = boundedTargets[target(of: test)],
                           changedModules.isDisjoint(with: boundary.modules) {
                            bounded[boundary.target, default: []].append(test)
                        } else {
                            let uncertainty = graph.functions[path.last!]!.uncertainties
                            let missingImplementation = uncertainty.contains { $0.hasPrefix("Imported conformance:") }
                                ? " Imported conformance ownership is known; its implementation body/runtime effects are unavailable." : ""
                            fallback("unresolved_dependency", "Opaque runtime dependency reachable from \(test); no validated boundary excludes changed modules [\(changedModules.sorted().joined(separator: ", "))]: \(uncertainty.sorted().joined(separator: "; "))" + missingImplementation, tests: [test])
                        }
                    }
                }
                for (target, tests) in bounded {
                    let boundary = boundedTargets[target]!
                    boundaryDecisions.append(RuntimeBoundaryDecision(target: target, revision: revision,
                        modules: boundary.modules.sorted(), changedModules: changedModules.sorted(),
                        boundedUncertaintyTests: tests.sorted(), rationale: boundary.rationale))
                }
            }
            guard !productionUnits.isEmpty, !uiTests.isEmpty else { continue }
            guard let mappings = snapshot.mappings else {
                fallback("missing_ui_mappings", "\(revision): production changes have no explicit UI feature mappings.", tests: uiTests)
                continue
            }
            var matchedFeatures = Set<String>()
            var featurePaths: [String: [String]] = [:]
            var coveredChanges = Set<String>()
            var mappedTests = Set<String>()
            let opaqueProduction = declaredUIRuntime ? Set<String>() : Set(graph.functions.values.filter { node in
                node.uncertainties.contains {
                    $0.hasPrefix("Imported conformance:") || !node.regions.isEmpty &&
                    ($0 == "Indirect function invocation" || $0 == "Raw pointer operation" || $0 == "Global state access" || $0.hasPrefix("Unresolved project dispatch:"))
                }
            }.map(\.id))
            let opaquePaths = index.paths(to: opaqueProduction)
            let mappingIndex = MappingIndex(mappings, snapshot: snapshot, graph: graph, index: index)
            if revision == "head" { headMappingIndex = mappingIndex }
            let featureRoots = mappingIndex.roots
            // Keep only explanations between each feature and boundary, rather
            // than a V-sized distance array for every changed declaration.
            let unitChains: [[String: [String]]] = productionUnits.map { unit in
                let paths = index.paths(to: Set((index.byFile[unit.region.path] ?? []).filter { id in
                    graph.functions[id]!.regions.contains { $0.intersects(unit.region) }
                }).intersection(productionAffected))
                return featureRoots.compactMapValues { paths.path(from: $0) }
            }
            for feature in mappings.features {
                let tests = mappingIndex.tests[feature.name] ?? []
                mappedTests.formUnion(tests)
                for selector in mappingIndex.unmatched[feature.name] ?? [] {
                    fallback("unresolved_mapping_selector", "\(revision): feature \(feature.name) has no discovered tests for \(selector)", tests: uiTests)
                }
                let roots = featureRoots[feature.name]!
                if !declaredUIRuntime && opaquePaths.path(from: roots) != nil {
                    fallback("unresolved_feature_dependency", "\(revision): feature \(feature.name) reaches opaque runtime dependencies.", tests: tests)
                }
                if roots.isEmpty && (!(feature.sources ?? []).isEmpty || !(feature.symbols ?? []).isEmpty) {
                    fallback("unresolved_mapping_boundary", "\(revision): no compiled source/symbol boundary for feature \(feature.name)", tests: uiTests)
                }
                for (unitIndex, unit) in productionUnits.enumerated() {
                    let directlyMapped = (feature.sources ?? []).contains { UIFeatureMappings.matches(unit.region.path, pattern: $0) }
                    let chain = unitChains[unitIndex][feature.name]
                    if directlyMapped || chain != nil {
                        featurePaths[feature.name] = (chain ?? []).map { graph.functions[$0].map { $0.module + "." + $0.name } ?? $0 } + [unit.region.path]
                        matchedFeatures.insert(feature.name)
                        coveredChanges.insert(unit.key)
                    }
                }
            }
            var changed = true
            while changed {
                changed = false
                for feature in mappings.features where !matchedFeatures.contains(feature.name) {
                    if !(Set(feature.dependsOn ?? []).intersection(matchedFeatures)).isEmpty {
                        matchedFeatures.insert(feature.name); changed = true
                        featurePaths[feature.name] = (feature.dependsOn ?? []).filter { matchedFeatures.contains($0) }.sorted()
                    }
                }
            }
            for feature in mappings.features where matchedFeatures.contains(feature.name) {
                let selectors = mappings.selectors(for: feature)
                let tests = mappingIndex.tests[feature.name] ?? []
                include(tests, kind: "explicitMapping", reason: "Affected UI feature: \(feature.name)", revision: revision, path: [feature.name] + (featurePaths[feature.name] ?? []) + selectors)
                if tests.isEmpty { fallback("unresolved_feature_tests", "\(revision): affected feature \(feature.name) has no test mappings.", tests: uiTests) }
            }
            let missing = uiTests.subtracting(mappedTests)
            if !missing.isEmpty { fallback("unmapped_ui_tests", "\(revision): UI tests without feature mappings remain conservatively selected.", tests: missing) }
            for unit in productionUnits where !coveredChanges.contains(unit.key) {
                fallback("unmapped_production_boundary", "\(revision): no UI feature reaches changed production source \(unit.region.path):\(unit.region.startLine)", tests: uiTests)
            }
        }
        if let previous {
            include(inventory.subtracting(previous.tests), kind: "newTest", reason: "Newly discovered test", revision: "head")
        }
        var report = ImpactReport(baseRevision: baseRevision, totalTests: inventory.count, selectedTests: selected.sorted(), explanations: explanations,
                                  fullRunReasons: Array(Set(fullReasons)).sorted(), changedFiles: changes.map(\.path).sorted(), unreferencedChanges: [],
                                  limitations: ["UI feature mappings are explicit dependency declarations, not measured coverage; keep them complete and validate with full runs.",
                                                "Test-entry-only selection assumes independent tests: hidden cross-test calls or order-dependent shared state are not inferred. Explicit compiled callers remain selected.",
                                                "Compiler graphs model the selected build configuration. External runtime behavior and generated code may require conservative fallbacks."])
        report.schemaVersion = 2
        if !boundaryDecisions.isEmpty {
            report.runtimeBoundaryDecisions = boundaryDecisions.sorted { ($0.target, $0.revision) < ($1.target, $1.revision) }
            report.limitations.append("Non-UI runtime boundaries are explicit closed-module contracts validated against compiler imports, test hosts, and visible dependencies in each revision. They require independent full-run validation and exclude undeclared dynamic loading, IPC, and cross-boundary shared-state effects; they are not measured coverage.")
        }
        if declaredUIRuntime {
            report.limitations.append("UI runtime dependency policy is declared in both revisions: opaque runtime relationships must be represented by complete feature boundaries and dependsOn. Unit and test-infrastructure uncertainty remains conservative.")
        }
        report.onlyTestingArguments = report.selectedTests.map { "-only-testing:" + $0 }
        report.explanations.sort { ($0.test, $0.kind, $0.revision, $0.reason, $0.path.joined()) < ($1.test, $1.kind, $1.revision, $1.reason, $1.path.joined()) }
        report.diagnostics = Dictionary(grouping: diagnostics, by: { $0.code + $0.message + $0.tests.joined() }).values.compactMap(\.first).sorted { ($0.code, $0.message) < ($1.code, $1.message) }
        report.ignoredChanges = ignored.sorted()
        if headMappingIndex == nil, let mappings = current.mappings, let graph = current.dependencies {
            headMappingIndex = MappingIndex(mappings, snapshot: current, graph: graph, index: DependencyIndex(graph))
        }
        let declaredTests = headMappingIndex.map { Set($0.tests.values.flatMap { $0 }) } ?? Set(current.tests.filter { test in
            current.mappings?.features.contains { feature in
                current.mappings!.selectors(for: feature).contains { UIFeatureMappings.selects(test, selector: $0) }
            } == true
        })
        report.uiMappingCoverage = UIMappingCoverage(mappingFilePresent: current.mappings != nil,
            mappedTests: uiTests.intersection(declaredTests).sorted(), unmappedTests: uiTests.subtracting(declaredTests).sorted())
        if let mappings = current.mappings, current.dependencies != nil {
            for feature in mappings.features {
                if !(feature.sources ?? []).isEmpty || !(feature.symbols ?? []).isEmpty {
                    let resolved = !(headMappingIndex?.roots[feature.name]?.isEmpty ?? true)
                    if !resolved { report.uiMappingCoverage!.unresolvedBoundaries.append(feature.name) }
                }
                for selector in headMappingIndex?.unmatched[feature.name] ?? [] {
                    report.uiMappingCoverage!.unmatchedSelectors.append(feature.name + ": " + selector)
                }
            }
            report.uiMappingCoverage!.unresolvedBoundaries.sort()
            report.uiMappingCoverage!.unmatchedSelectors.sort()
        }
        return report
    }

    private static func isProductionOrTestEntry(_ unit: SourceUnit, in snapshot: XcodeTestGraph) -> Bool {
        let owners = snapshot.targets.filter { $0.sourceFiles.contains(unit.region.path) }
        return (!owners.isEmpty && owners.allSatisfy { !$0.isTest }) || isTestEntry(unit, in: snapshot)
    }

    private static func isProduction(_ unit: SourceUnit, in snapshot: XcodeTestGraph) -> Bool {
        let module = String(unit.key.prefix { $0 != ":" })
        let owners = snapshot.targets.filter { $0.sourceFiles.contains(unit.region.path) }
        return snapshot.runtimeInventory?.imports[module] != nil && !owners.isEmpty &&
            owners.allSatisfy { !$0.isTest && snapshot.modules[$0.name] == module }
    }

    private static func isTestEntry(_ unit: SourceUnit, in snapshot: XcodeTestGraph) -> Bool {
        guard unit.kind == "function", let graph = snapshot.dependencies else { return false }
        let owners = snapshot.targets.filter { $0.sourceFiles.contains(unit.region.path) }
        guard !owners.isEmpty, owners.allSatisfy(\.isTest) else { return false }
        // Debug information is line based. Two declarations on the same line
        // cannot establish which function changed; retain fallback in that case.
        let overlapping = Set(snapshot.sources.values.flatMap(\.units).filter {
            $0.kind == "function" && $0.region.intersects(unit.region)
        }.map(\.key))
        guard overlapping == [unit.key] else { return false }
        return snapshot.tests.contains { test in
            let parts = test.split(separator: "/").map(String.init)
            guard (2...3).contains(parts.count), let method = parts.last else { return false }
            let name = (unit.scope.isEmpty ? "" : unit.scope + ".") +
                (method.contains("(") ? method : method + "()")
            return (graph.tests[test] ?? []).contains { id in
                guard let node = graph.functions[id], node.name == name,
                      owners.contains(where: { snapshot.modules[$0.name] == node.module }) else { return false }
                return node.regions.contains { $0.path == unit.region.path &&
                    $0.startLine >= unit.region.startLine && $0.startLine <= unit.region.endLine }
            }
        }
    }

    private static func target(of test: String) -> String { String(test.prefix { $0 != "/" }) }
}
