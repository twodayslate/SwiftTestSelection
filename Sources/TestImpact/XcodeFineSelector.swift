// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

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
        // Both revisions must opt into treating source locations as diagnostics.
        // Explicit macro/directive syntax remains executable under either policy.
        let locationPolicy: UIFeatureMappings.SourceLocationPolicy
        if let head = current.mappings, let base = previous?.mappings,
           let policy = head.sourceLocationPolicy, base.sourceLocationPolicy == policy,
           (try? head.validate()) != nil, (try? base.validate()) != nil {
            locationPolicy = policy
        } else {
            locationPolicy = .semantic
        }
        func fingerprint(_ unit: SourceUnit) -> String {
            switch locationPolicy {
            case .semantic: return unit.fingerprint
            case .diagnostic: return unit.syntaxFingerprint ?? unit.fingerprint
            case .diagnosticLineColumn:
                guard let files = unit.fileLocationValues else { return unit.fingerprint }
                return SourceUnit.withLocations(files, syntax: unit.syntaxFingerprint ?? unit.fingerprint)
            }
        }
        let oldUnits = Dictionary(grouping: previous?.sources.values.flatMap(\.units) ?? [], by: \.key)
        let newUnits = Dictionary(grouping: current.sources.values.flatMap(\.units), by: \.key)
        let sourceUnits: [SourceUnit] = oldUnits.values.flatMap { $0 } + newUnits.values.flatMap { $0 }
        let missingCallerMetadata = sourceUnits.contains { unit in
            unit.locationDefaultKinds == nil || unit.callerLocations == nil ||
                unit.locationDefaultNames == nil || unit.invocationNames == nil
        }
        if locationPolicy != .diagnostic, missingCallerMetadata,
           changes.contains(where: { $0.path.hasSuffix(".swift") || $0.previousPath?.hasSuffix(".swift") == true }) {
            fallback("incomplete_caller_locations", "Saved source snapshots lack caller-location metadata. Regenerate both graphs before using semantic or diagnosticLineColumn location selection.")
        }
        let oldUnitsByFile = Dictionary(grouping: oldUnits.values.flatMap { $0 }, by: { $0.region.path })
        let newUnitsByFile = Dictionary(grouping: newUnits.values.flatMap { $0 }, by: { $0.region.path })
        var oldChanged: [SourceUnit] = []
        var newChanged: [SourceUnit] = []
        // A bare #line/#file default is evaluated in its caller. Source syntax
        // and dependency edges can both stay identical while that value changes.
        // Match source invocations as well as compiler edges: transparent helpers
        // and enum constructors can lose their call edges even under -Onone.
        let callerKinds = locationPolicy == .diagnostic ? [:] : callerLocationKinds(current)
            .merging(previous.map(callerLocationKinds) ?? [:], uniquingKeysWith: { $0.union($1) })
        func comparisonFingerprint(_ unit: SourceUnit) -> String {
            var kinds = callerKinds[unit.key] ?? []
            if locationPolicy == .diagnosticLineColumn { kinds.subtract(["line", "column"]) }
            guard !kinds.isEmpty else { return fingerprint(unit) }
            return fingerprint(unit) + "@caller[" + kinds.sorted().map { kind in
                let value = unit.callerLocations.map { $0[kind] ?? "" }
                return kind + ":" + (value ?? "unknown:" + unit.region.path + ":" + String(unit.region.startLine))
            }.joined(separator: "|") + "]"
        }
        for key in Set(oldUnits.keys).union(newUnits.keys) {
            let old = oldUnits[key] ?? [], new = newUnits[key] ?? []
            if old.map(comparisonFingerprint).sorted() != new.map(comparisonFingerprint).sorted() {
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
        var comparisonContext = UIConditionContext(sides:
            previous.map { [.init(revision: "base", snapshot: $0, changed: oldChanged)] } ?? [],
            unavailableReason: nil)
        comparisonContext.sides.append(.init(revision: "head", snapshot: current, changed: newChanged))
        if previous == nil { comparisonContext.unavailableReason = "Base compiler evidence unavailable" }
        if missingCallerMetadata && locationPolicy != .diagnostic {
            comparisonContext.unavailableReason = "Saved snapshots lack caller-location metadata"
        }
        var conditionDecisions: [UIConditionDecision] = []
        for (revision, snapshot) in [("base", previous), ("head", Optional(current))] {
            guard let snapshot, let mappings = snapshot.mappings else { continue }
            do { try mappings.validate() }
            catch { fallback("invalid_ui_mappings", "\(revision): \(error)", tests: uiTests) }
            for feature in mappings.features {
                guard let condition = feature.when else { continue }
                let result = comparisonContext.evaluate(condition)
                conditionDecisions.append(.init(feature: feature.name, revision: revision, result: result))
                let tests = Set(inventory.filter { test in mappings.selectors(for: feature).contains { UIFeatureMappings.selects(test, selector: $0) } })
                for selector in mappings.selectors(for: feature) where !inventory.contains(where: { UIFeatureMappings.selects($0, selector: selector) }) {
                    fallback("unresolved_mapping_selector", "\(revision): feature \(feature.name) has no discovered tests for \(selector)", tests: uiTests)
                }
                if result.status == .unresolved {
                    fallback("unresolved_mapping_condition", "\(revision): \(feature.name): \(result.explanation)", tests: tests.isEmpty ? uiTests : tests)
                } else if result.status == .matched {
                    include(tests, kind: "explicitCondition", reason: "\(feature.name): \(result.explanation)", revision: revision)
                    if tests.isEmpty { fallback("unresolved_feature_tests", "\(revision): affected feature \(feature.name) has no test mappings.", tests: uiTests) }
                }
            }
        }
        let knownPaths = Set((current.targets + (previous?.targets ?? [])).flatMap(\.sourceFiles))
        let generatedBoundaries = Array(current.generatedSourceBoundaries?.values ?? [:].values).flatMap { $0 } +
            Array(previous?.generatedSourceBoundaries?.values ?? [:].values).flatMap { $0 }
        func ignoredDocumentation(_ path: String) -> Bool {
            path.hasSuffix(".md") && !knownPaths.contains(path) &&
                [current.mappings, previous?.mappings].allSatisfy { mappings in
                    mappings?.ignoredDocumentation?.contains { UIFeatureMappings.matches(path, pattern: $0) } == true
                } && generatedBoundaries.allSatisfy { boundary in
                    guard boundary.documentationEvidenceVersion == 3,
                          let files = boundary.repositoryInputFiles, let documentation = boundary.documentationInputs else { return false }
                    return files[path] == nil || documentation.contains(path)
                }
        }
        // Git comparison proves these edits only substitute PBXFileReference
        // paths for byte-identical moves. Apply the same exemption to the
        // repository fingerprint; generator settings/content still compare.
        let projectReferenceMoves = Set(changes.filter {
            $0.isPureMove && $0.path.hasSuffix(".pbxproj")
        }.map(\.path))
        func comparable(_ boundaries: [GeneratedSourceBoundary]?, ignoring paths: Set<String>) -> [GeneratedSourceBoundary]? {
            boundaries?.map { boundary in
                var result = boundary
                // Explanations are not semantic generator inputs.
                result.documentationBlockers = nil
                if let files = boundary.repositoryInputFiles, let documentation = boundary.documentationInputs,
                   (try? XcodeGraphCache.key(files)) == boundary.repositoryInputs {
                    let filtered = files.filter { !paths.contains($0.key) }
                    result.repositoryInputFiles = filtered
                    result.repositoryInputs = (try? XcodeGraphCache.key(filtered)) ?? boundary.repositoryInputs
                    result.documentationInputs = documentation.filter { !paths.contains($0) }
                }
                return result
            }.sorted { $0.logicalPath < $1.logicalPath }
        }
        // Unchanged validated generated inputs are an equivalence boundary.
        // Changed/one-sided evidence never disappears merely because Git has no
        // path for DerivedSources. Unsupported inputs retain their existing gate.
        let generatedModules = Set(current.generatedSourceBoundaries?.keys ?? [:].keys)
            .union(previous?.generatedSourceBoundaries?.keys ?? [:].keys)
        for module in generatedModules.sorted() {
            let old = previous?.generatedSourceBoundaries?[module], new = current.generatedSourceBoundaries?[module]
            if old == new { continue }
            // Every existing file must be proven outside build inputs on both
            // sides. Added/deleted docs need evidence only on the side they exist.
            let boundaries = (old ?? []) + (new ?? [])
            let candidates = Set(boundaries.flatMap { $0.documentationInputs ?? [] }).filter(ignoredDocumentation)
            var excluded = Set(candidates.filter { path in
                boundaries.allSatisfy { boundary in
                    guard let files = boundary.repositoryInputFiles, let documentation = boundary.documentationInputs else { return false }
                    return files[path] == nil || documentation.contains(path)
                }
            })
            excluded.formUnion(projectReferenceMoves.filter { path in
                boundaries.allSatisfy { $0.repositoryInputFiles?[path] != nil }
            })
            if comparable(old, ignoring: excluded) != comparable(new, ignoring: excluded) {
                fallback("generated_input_changed", "Generated source content, generator settings or resource/build inputs changed or lack matching evidence for \(module).")
            }
        }
        let semanticPaths = Set((oldChanged + newChanged).map { $0.region.path })
        let analyzedPaths = Set((Array(current.sources.keys) + Array(previous?.sources.keys ?? [:].keys)).compactMap { key in
            key.firstIndex(of: ":").map { String(key[key.index(after: $0)...]) }
        }).union(oldUnits.values.flatMap { $0 }.map { $0.region.path })
            .union(newUnits.values.flatMap { $0 }.map { $0.region.path })
        for change in changes {
            let paths = [change.path] + (change.previousPath.map { [$0] } ?? [])
            if paths.allSatisfy(ignoredDocumentation) {
                ignored.insert(change.path)
            } else if change.path.hasSuffix(".swift"), knownPaths.contains(change.path), analyzedPaths.contains(change.path), !semanticPaths.contains(change.path) {
                ignored.insert(change.path)
            } else if change.isPureMove && change.path.hasSuffix(".pbxproj") {
                ignored.insert(change.path)
            } else if !change.path.hasSuffix(".swift") || !knownPaths.contains(change.path) || !analyzedPaths.contains(change.path) {
                let blockers = Set(paths.flatMap { path in
                    generatedBoundaries.flatMap { $0.documentationBlockers?[path] ?? [] }
                }).sorted()
                if !blockers.isEmpty {
                    diagnostics.append(SelectionDiagnostic(code: "documentation_exclusion_blocked",
                        message: "Cannot exclude \(change.path) from build inputs: " + blockers.joined(separator: "; "), tests: inventory.sorted()))
                }
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
        let changedModuleNames = Set((oldChanged + newChanged).map { String($0.key.prefix { $0 != ":" }) })
        let compatibleRoles = changedModuleNames.allSatisfy { module in
            let before = previous?.targets.filter { previous?.modules[$0.name] == module } ?? []
            let after = current.targets.filter { current.modules[$0.name] == module }
            guard (before + after).contains(where: { $0.productType == XcodeSourceOwnership.productType }) else { return true }
            return before.count == 1 && after.count == 1 && before[0].recoveredRole != nil &&
                before[0].recoveredRole == after[0].recoveredRole &&
                previous?.runtimeInventory?.imports[module] != nil && current.runtimeInventory?.imports[module] != nil
        }
        let declaredUIRuntime = compatibleRoles && current.mappings?.runtimeDependencyPolicy == .declared &&
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
            let changedModules = Set(units.map { String($0.key.prefix { $0 != ":" }) })
            for module in changedModules.sorted() {
                if let message = snapshot.unresolvedProductRoles?[module] {
                    diagnostics.append(SelectionDiagnostic(code: "unresolved_product_role", message: "\(revision) \(module): \(message); runtime isolation cannot narrow this module", tests: []))
                }
                if let inputs = snapshot.unsupportedSourceInputs?[module], !inputs.isEmpty {
                    fallback("unsupported_source_ownership", "Changed module \(module) also compiles inputs without a repository semantic boundary: " + inputs.joined(separator: ", "))
                }
            }
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
                let uncertain = Set(graph.functions.values.filter(\.hasOpaqueRuntimeDependency).map(\.id))
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
                // Proven test entry bodies cannot invalidate an unrelated runtime
                // closure. Keep their modules in the boundary comparison and all
                // dependency selections; helpers/lifecycle/state remain conservative.
                let changesHaveIsolatedOwnership = compatibleRoles && previous != nil &&
                    oldChanged.allSatisfy { isProduction($0, in: previous!) || isTestEntry($0, in: previous!) } &&
                    newChanged.allSatisfy { isProduction($0, in: current) || isTestEntry($0, in: current) }
                let changedModules = Set((oldChanged + newChanged).map { String($0.key.prefix { $0 != ":" }) })
                var bounded: [String: [String]] = [:]
                for test in snapshot.tests where inventory.contains(test) {
                    if declaredUIRuntime && uiTests.contains(test) { continue }
                    if let path = uncertainPaths.path(from: graph.tests[test] ?? []) {
                        if changesHaveIsolatedOwnership, let boundary = boundedTargets[target(of: test)],
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
            let opaqueProduction = declaredUIRuntime ? Set<String>() : Set(graph.functions.values.filter(\.hasOpaqueRuntimeDependency).map(\.id))
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
                    let directlyMapped = ((feature.sources ?? []) + (feature.when?.sourcePatterns ?? [])).contains { UIFeatureMappings.matches(unit.region.path, pattern: $0) }
                    let chain = unitChains[unitIndex][feature.name]
                    if directlyMapped || chain != nil {
                        featurePaths[feature.name] = (chain ?? []).map { graph.functions[$0].map { $0.module + "." + $0.name } ?? $0 } + [unit.region.path]
                        if feature.when == nil { matchedFeatures.insert(feature.name) }
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
        report.uiConditionDecisions = conditionDecisions.isEmpty ? nil : conditionDecisions
        if !conditionDecisions.isEmpty {
            report.limitations.append("AND/OR conditions are explicit user selection policies, not proof that omitted tests cannot fail. A false condition is not a veto on other selections.")
        }
        report.schemaVersion = 2
        if locationPolicy == .diagnostic {
            report.limitations.append("Source-location policy is diagnostic in both revisions: implicit location-value changes do not select tests. Location literals must not control application behavior; explicit macro/directive syntax and compiled dependency changes still participate.")
        } else if locationPolicy == .diagnosticLineColumn {
            report.limitations.append("Source-location policy is diagnosticLineColumn in both revisions: implicit line/column changes do not select tests when supported by saved evidence. Line and column values must not control application behavior; file/fileID/filePath values, explicit macro/directive syntax and compiled dependency changes remain semantic.")
        }
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

    private static func callerLocationKinds(_ snapshot: XcodeTestGraph) -> [String: Set<String>] {
        let units = snapshot.sources.values.flatMap(\.units)
        let defaults = units.filter { !($0.locationDefaultKinds?.isEmpty ?? true) }
        guard !defaults.isEmpty else { return [:] }
        let allKinds = defaults.reduce(into: Set<String>()) { $0.formUnion($1.locationDefaultKinds ?? []) }
        var kindsByName: [String: Set<String>] = [:]
        for unit in defaults {
            for (name, kinds) in unit.locationDefaultNames ?? [:] {
                kindsByName[name, default: []].formUnion(kinds)
            }
        }
        // Name matching is deliberately an over-approximation across modules,
        // overloads, receivers and argument slots. A surviving SIL definition is
        // not evidence that all its calls survived mandatory inlining/lowering.
        var result: [String: Set<String>] = [:]
        for unit in units {
            let names = unit.invocationNames ?? []
            guard !names.isEmpty else { continue }
            // `reader()` and `holder.reader()` spell the receiver, not
            // callAsFunction. Its edge can disappear through mandatory inlining,
            // so source names cannot rule out an implicit callable-object call.
            // Interpret the stored declaration name here to cover saved graphs too.
            var kinds = (kindsByName["*"] ?? []).union(kindsByName["callAsFunction"] ?? [])
            for name in names { kinds.formUnion(name == "*" ? allKinds : kindsByName[name] ?? []) }
            if !kinds.isEmpty { result[unit.key, default: []].formUnion(kinds) }
        }
        guard let graph = snapshot.dependencies else {
            return Dictionary(units.map { ($0.key, allKinds) }, uniquingKeysWith: { $0.union($1) })
        }
        let byFile = Dictionary(grouping: units, by: { $0.region.path })
        var symbolsByUnit: [String: Set<String>] = [:]
        var unitsBySymbol: [String: Set<String>] = [:]
        for node in graph.functions.values {
            for region in node.regions {
                for unit in byFile[region.path] ?? [] where unit.key.hasPrefix(node.module + ":") &&
                    region.startLine >= unit.region.startLine && region.startLine <= unit.region.endLine {
                    symbolsByUnit[unit.key, default: []].insert(node.id)
                    unitsBySymbol[node.id, default: []].insert(unit.key)
                }
            }
        }
        var defaultSymbols: [String: Set<String>] = [:]
        var unresolved = Set<String>()
        for unit in defaults {
            let kinds = unit.locationDefaultKinds ?? []
            let symbols = symbolsByUnit[unit.key] ?? []
            if symbols.isEmpty { unresolved.formUnion(kinds) }
            for symbol in symbols { defaultSymbols[symbol, default: []].formUnion(kinds) }
        }
        // A missing declaration binding cannot prove absence of callers.
        let sourceModules = Set(snapshot.modules.values)
        for node in graph.functions.values {
            let kinds = node.dependencies.reduce(into: Set<String>()) { $0.formUnion(defaultSymbols[$1] ?? []) }
            guard !kinds.isEmpty else { continue }
            let callers = unitsBySymbol[node.id] ?? []
            if callers.isEmpty && sourceModules.contains(node.module) { unresolved.formUnion(kinds) }
            for key in callers { result[key, default: []].formUnion(kinds) }
        }
        if !unresolved.isEmpty {
            for unit in units { result[unit.key, default: []].formUnion(unresolved) }
        }
        return result
    }

    private static func isProductionOrTestEntry(_ unit: SourceUnit, in snapshot: XcodeTestGraph) -> Bool {
        let owners = snapshot.targets.filter { $0.sourceFiles.contains(unit.region.path) }
        return (!owners.isEmpty && owners.allSatisfy { $0.hasProductionRole }) || isTestEntry(unit, in: snapshot)
    }

    private static func isProduction(_ unit: SourceUnit, in snapshot: XcodeTestGraph) -> Bool {
        let module = String(unit.key.prefix { $0 != ":" })
        let owners = snapshot.targets.filter { $0.sourceFiles.contains(unit.region.path) }
        return snapshot.runtimeInventory?.imports[module] != nil && !owners.isEmpty &&
            owners.allSatisfy { $0.hasProductionRole && snapshot.modules[$0.name] == module }
    }

    static func isTestEntry(_ unit: SourceUnit, in snapshot: XcodeTestGraph) -> Bool {
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
