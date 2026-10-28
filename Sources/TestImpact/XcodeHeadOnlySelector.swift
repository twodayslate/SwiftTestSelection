// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation

/// Source evidence only. No compiler graph, ownership, imports or test inventory
/// is manufactured for the base. Unchanged files may share the head's syntax
/// snapshot because Git proves identical bytes, not because imports prove edges.
struct XcodeHeadOnlySources {
    var base: [String: SwiftSourceSnapshot]
    var mappings: UIFeatureMappings?
    var diagnostics: [String] = []
    /// Git sources absent from the captured head inventory have unknown base ownership.
    var unownedBaseSources: [String: SwiftSourceSnapshot] = [:]

    static func read(current: XcodeTestGraph, changes: [FileChange], base: String, root: URL, mappingPath: String) throws -> Self {
        var result = Self(base: current.sources)
        let paths = Set(changes.flatMap { [$0.path] + ($0.previousPath.map { [$0] } ?? []) })
        // Internal SDK extensions are visible throughout their test module. A
        // scoped diff cannot substitute head syntax for changed base callers in
        // other files or targets: removed calls/escapes and overloads must remain
        // visible even when a file's target membership changed at head.
        let callerModules = Set(current.sources.compactMap { key, snapshot -> String? in
            guard let colon = key.firstIndex(of: ":"), paths.contains(String(key[key.index(after: colon)...])),
                  snapshot.units.contains(where: { $0.sdkTestHelper != nil || $0.privateTestHelper != nil }) else { return nil }
            return String(key[..<colon])
        })
        var basePaths: Set<String>?
        if !callerModules.isEmpty {
            let listing = try CommandRunner.run("git", ["ls-tree", "-r", "--name-only", "-z", base, "--"], at: root, allowFailure: true)
            if listing.status == 0 { basePaths = Set(listing.stdout.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }) }
            else { result.diagnostics.append("Cannot enumerate base sources at \(base)") }
        }
        for key in current.sources.keys.sorted() {
            guard let colon = key.firstIndex(of: ":") else { result.diagnostics.append("Invalid source snapshot key: \(key)"); continue }
            let module = String(key[..<colon]), path = String(key[key.index(after: colon)...])
            guard paths.contains(path) || !callerModules.isEmpty else { continue }
            // New files outside the scope have no old callers to audit. Do not
            // turn a proven absence into an unrelated scope diagnostic.
            if !paths.contains(path), let basePaths, !basePaths.contains(path) {
                result.base.removeValue(forKey: key)
                continue
            }
            let data = try CommandRunner.run("git", ["show", base + ":" + path], at: root, allowFailure: true)
            if data.status == 0, let text = String(data: data.stdout, encoding: .utf8) {
                result.base[key] = SwiftSourceSnapshot.parse(text, path: path, module: module)
            } else {
                result.base.removeValue(forKey: key)
                result.diagnostics.append("No base source boundary for \(path) at \(base)")
            }
        }
        if !callerModules.isEmpty {
            // Deleted/out-of-target files cannot be found by iterating the head
            // inventory. Inspect their base syntax without inventing module ownership.
            let captured = Set(current.sources.keys.compactMap { key in key.firstIndex(of: ":").map { String(key[key.index(after: $0)...]) } })
            if let basePaths {
                for path in basePaths.sorted() where path.hasSuffix(".swift") && !captured.contains(path) {
                    let data = try CommandRunner.run("git", ["show", base + ":" + path], at: root, allowFailure: true)
                    if data.status == 0, let text = String(data: data.stdout, encoding: .utf8) {
                        result.unownedBaseSources[path] = .parse(text, path: path, module: "")
                    } else { result.diagnostics.append("Cannot read unowned base source \(path) at \(base)") }
                }
            }
        }
        let mapping = try CommandRunner.run("git", ["show", base + ":" + mappingPath], at: root, allowFailure: true)
        if mapping.status == 0 {
            do {
                result.mappings = try JSONDecoder().decode(UIFeatureMappings.self, from: mapping.stdout)
                try result.mappings?.validate()
            } catch { result.diagnostics.append("Invalid base mapping policy: \(error)") }
        }
        return result
    }
}

/// Supports surviving function bodies and proven isolated private test helper
/// additions with unchanged ownership/build inputs. Other structural edits cannot recover vanished old edges:
/// they select the full head inventory with an explicit uncertainty diagnostic.
/// This does not delegate to the two-graph selector with a synthetic previous.
enum XcodeHeadOnlySelector {
    static func select(current: XcodeTestGraph, source: XcodeHeadOnlySources, changes: [FileChange],
                       baseRevision: String, documentation: Set<String> = [], buildEvidenceFailure: String? = nil, excludedTestEntries: Set<String> = []) -> ImpactReport {
        let inventory = Set(current.tests)
        func target(_ test: String) -> String { String(test.prefix { $0 != "/" }) }
        let uiTargets = Set(current.targets.filter(\.isUITest).map(\.name))
        let uiTests = inventory.filter { uiTargets.contains(target($0)) }
        var selected = Set<String>(), ignored = Set<String>(), fullReasons = Set<String>()
        var explanations: [TestExplanation] = [], diagnostics: [SelectionDiagnostic] = []
        func include(_ tests: Set<String>, kind: String, reason: String, path: [String] = []) {
            let tests = tests.intersection(inventory)
            selected.formUnion(tests)
            explanations += tests.sorted().map { TestExplanation(test: $0, reason: reason, revision: "head", path: path, kind: kind) }
        }
        func fallback(_ code: String, _ reason: String, tests: Set<String>? = nil) {
            let tests = (tests ?? inventory).intersection(inventory)
            guard !tests.isEmpty else { return }
            diagnostics.append(.init(code: code, message: reason, tests: tests.sorted()))
            include(tests, kind: "fallback", reason: reason)
            if tests == inventory { fullReasons.insert(reason) }
        }
        var conditionDecisions: [UIConditionDecision] = []
        let conditionContext = UIConditionContext(sides: [.init(revision: "head", snapshot: current, changed: [])],
            unavailableReason: "Head-only mode does not support UI conditions without base compiler evidence")
        for (revision, mappings) in [("base", source.mappings), ("head", current.mappings)] {
            guard let mappings else { continue }
            do { try mappings.validate() }
            catch { fallback("invalid_ui_mappings", "\(revision): \(error)", tests: uiTests) }
            for feature in mappings.features {
                guard let condition = feature.when else { continue }
                let result = conditionContext.evaluate(condition)
                conditionDecisions.append(.init(feature: feature.name, revision: revision, result: result))
                // Unsupported conditions never masquerade as a valid false result,
                // including no-op comparisons and conditions removed at head.
                fallback("head_only_unsupported_condition", "\(revision): \(feature.name): \(result.explanation)", tests: uiTests)
            }
        }
        let locationPolicy = current.mappings?.sourceLocationPolicy == source.mappings?.sourceLocationPolicy
            ? current.mappings?.sourceLocationPolicy ?? .semantic : .semantic
        func fingerprint(_ unit: SourceUnit) -> String {
            let syntax: String
            switch locationPolicy {
            case .semantic: syntax = unit.fingerprint
            case .diagnostic: return unit.syntaxFingerprint ?? unit.fingerprint
            case .diagnosticLineColumn:
                guard let files = unit.fileLocationValues else { return unit.fingerprint }
                syntax = SourceUnit.withLocations(files, syntax: unit.syntaxFingerprint ?? unit.fingerprint)
            }
            // Over-approximate caller defaults without inventing base compiler
            // edges. This also preserves fixture file identity for moved callers.
            return syntax + (unit.callerLocations ?? [:]).filter { key, _ in
                locationPolicy != .diagnosticLineColumn || !["line", "column"].contains(key)
            }.sorted { $0.key < $1.key }.map { "@\($0.key)=\($0.value)" }.joined()
        }
        let paths = Set(changes.map(\.path))
        let old = Dictionary(grouping: source.base.values.flatMap(\.units).filter { paths.contains($0.region.path) }, by: \.key)
        let new = Dictionary(grouping: current.sources.values.flatMap(\.units).filter { paths.contains($0.region.path) }, by: \.key)
        let excludedKeys = independentEntryKeys(current: current, excluding: excludedTestEntries)
        let dependencyIndex = current.dependencies.map(DependencyIndex.init)
        var isolatedHelpers = Set<String>(), isolatedSDKHelpers = Set<String>()
        var changed: [SourceUnit] = []
        var semanticPaths = Set<String>()
        for key in Set(old.keys).union(new.keys).sorted() {
            let before = old[key] ?? [], after = new[key] ?? []
            guard before.map(fingerprint).sorted() != after.map(fingerprint).sorted() else { continue }
            semanticPaths.formUnion((before + after).map { $0.region.path })
            if PrivateTestHelperIsolation.provesExtensionHeaders(before + after, current: current, base: source.base) { continue }
            if after.count == 1, let unit = after.first, (unit.sdkTestHelper != nil || ["XCUIElement", "XCTest.XCUIElement"].contains(unit.scope)),
               let graph = current.dependencies, let index = dependencyIndex {
                if let blocker = SDKTestHelperIsolation.blocker(unit, previous: before.count == 1 ? before.first : nil,
                                                               current: current, base: source.base, graph: graph, index: index, unownedBase: source.unownedBaseSources) {
                    fallback("head_only_sdk_helper_boundary", "SDK test helper isolation is unproven: \(blocker) (\(unit.region.path):\(unit.region.startLine))")
                } else {
                    isolatedHelpers.insert(key)
                    isolatedSDKHelpers.insert(key)
                    changed.append(unit)
                    continue
                }
            }
            if before.count <= 1, after.count == 1, let unit = after.first,
               let graph = current.dependencies, let index = dependencyIndex {
                // An added helper needs an isolation proof because no base
                // compiler edges exist. A surviving body can still use ordinary
                // dependency selection, with runtime fallback where needed.
                if before.isEmpty, let blocker = unit.privateTestHelperBlocker,
                   PrivateTestHelperIsolation.isXCTestHelper(unit, current: current) {
                    fallback("head_only_helper_callee_effects", "Private helper effect is unsupported: \(blocker) (\(unit.region.path):\(unit.region.startLine))")
                    continue
                }
                let proofs = [unit.privateTestHelper, before.first?.privateTestHelper].compactMap { $0 }
                if proofs.contains(where: { $0.proofVersion != PrivateTestHelperSyntax.currentProofVersion }) {
                    fallback("head_only_helper_proof_version", "Private helper proof is missing or uses an unsupported version; recapture the head graph: \(unit.region.path)")
                    continue
                }
                if proofs.contains(where: { $0.calleeEffectsSupported != true }) {
                    fallback("head_only_helper_callee_effects", "Private helper reaches an unproven callee effect boundary: \(unit.region.path):\(unit.region.startLine)")
                    continue
                }
                var traversal = PrivateTestHelperIsolation.Traversal()
                if PrivateTestHelperIsolation.proves(unit, previous: before.first, current: current, base: source.base,
                                                     graph: graph, index: index, traversal: &traversal, unownedBase: source.unownedBaseSources) {
                    isolatedHelpers.insert(key)
                    changed.append(unit)
                    continue
                }
                // Shared-object reads are not globally classified as opaque:
                // ordinary production fields have useful compiler dependencies.
                // A failed helper effect proof needs its own explicit fallback,
                // since SDK operations on a shared object can affect other tests.
                if traversal.hasUnprovenCalleeEffects {
                    let detail = traversal.receiverOriginBlocker.map { "; " + $0 } ?? ""
                    fallback("head_only_helper_callee_effects", "Private helper caller chain reaches an unproven callee effect boundary: \(unit.region.path):\(unit.region.startLine)" + detail)
                }
                if !traversal.sharedStateSymbols.isEmpty {
                    fallback("head_only_helper_shared_state", "Shared state in private helper callers or callees cannot be isolated: \(unit.region.path):\(unit.region.startLine)")
                }
            }
            // New independent entries are covered only by an explicit separate
            // execution policy, after proving no existing source name is rebound.
            if before.isEmpty, after.count == 1, let unit = after.first, excludedKeys.contains(key),
               PrivateTestHelperIsolation.provesAddedEntry(unit, current: current, base: source.base) { continue }
            guard before.count == 1, after.count == 1, let a = before.first, let b = after.first,
                  a.kind == "function", b.kind == "function", a.region.path == b.region.path else {
                fallback("head_only_declaration_change", "Added, deleted, ambiguous or changed declaration/header has no base compiler edges: \((before + after).first?.region.path ?? key)")
                continue
            }
            guard a.headOnlyBodySupported == true && b.headOnlyBodySupported == true else {
                fallback("head_only_unsupported_body", "Attributes, macros or opaque result types can change callers outside a surviving body: \(b.region.path):\(b.region.startLine)")
                continue
            }
            // A separate execution of this entry does not cover effects from
            // structural changes or unsupported bodies outside its call graph.
            if excludedKeys.contains(key) { continue }
            changed.append(b)
        }
        let owned = Set(current.targets.flatMap(\.sourceFiles))
        let analyzed = Set(current.sources.keys.map { key in
            key.firstIndex(of: ":").map { String(key[key.index(after: $0)...]) } ?? key
        })
        for change in changes {
            if change.previousPath != nil {
                fallback("head_only_move", "Moved source/file identity lacks old compiler ownership: \(change.previousPath!) → \(change.path)")
            } else if change.path.hasSuffix(".swift"), owned.contains(change.path), analyzed.contains(change.path) {
                if !semanticPaths.contains(change.path) { ignored.insert(change.path) }
            } else if change.path.hasSuffix(".md"), documentation.contains(change.path), !owned.contains(change.path),
                      [current.mappings, source.mappings].allSatisfy({ $0?.ignoredDocumentation?.contains { UIFeatureMappings.matches(change.path, pattern: $0) } == true }) {
                ignored.insert(change.path)
            } else {
                fallback("head_only_build_input", "Resource, build setting, mapping, generated input or unowned source requires full coverage without base build evidence: \(change.path)")
            }
        }
        if !changes.isEmpty {
            for error in source.diagnostics { fallback("head_only_source_unavailable", error) }
            for error in current.diagnostics + current.sources.values.flatMap(\.diagnostics) + source.base.values.flatMap(\.diagnostics) + (current.dependencies?.diagnostics ?? []) {
                fallback("head_only_incomplete_graph", error)
            }
            if let buildEvidenceFailure { fallback("head_only_build_evidence", buildEvidenceFailure) }
        }
        var mappingIndex: MappingIndex?
        if let graph = current.dependencies {
            let index = dependencyIndex!
            if let mappings = current.mappings { mappingIndex = MappingIndex(mappings, snapshot: current, graph: graph, index: index) }
            var affected = Set<String>(), isolatedSymbols = Set<String>(), sdkSymbols = Set<String>(), production: [SourceUnit] = []
            for unit in changed {
                let module = String(unit.key.prefix { $0 != ":" })
                let owners = current.targets.filter { $0.sourceFiles.contains(unit.region.path) }
                guard !owners.isEmpty, owners.allSatisfy({ current.modules[$0.name] == module && ($0.isTest || $0.hasProductionRole) }) else {
                    fallback("head_only_ownership", "No unambiguous head ownership for \(unit.region.path)")
                    continue
                }
                if !(current.unsupportedSourceInputs?[module]?.isEmpty ?? true) || current.unresolvedProductRoles?[module] != nil {
                    fallback("head_only_ownership", "Changed module \(module) has unsupported source inputs or an unresolved product role")
                }
                let overlapping = Set(current.sources.values.flatMap(\.units).filter { $0.kind == "function" && $0.region.intersects(unit.region) }.map(\.key))
                guard overlapping == [unit.key] else {
                    fallback("head_only_ambiguous_location", "Overlapping declaration locations cannot identify the changed body in \(unit.region.path)")
                    continue
                }
                let ids = Set((index.byFile[unit.region.path] ?? []).filter { id in
                    let node = graph.functions[id]!
                    return node.module == module && node.regions.contains { $0.path == unit.region.path && $0.startLine >= unit.region.startLine && $0.startLine <= unit.region.endLine }
                })
                if ids.isEmpty { fallback("head_only_unresolved_body", "No compiled function for surviving body \(unit.region.path):\(unit.region.startLine)") }
                affected.formUnion(ids)
                if isolatedHelpers.contains(unit.key) { isolatedSymbols.formUnion(ids) }
                if isolatedSDKHelpers.contains(unit.key) { sdkSymbols.formUnion(ids) }
                if owners.contains(where: { !$0.isTest }) { production.append(unit) }
            }
            let affectedPaths = index.paths(to: affected)
            for test in inventory.sorted() {
                if let path = affectedPaths.path(from: graph.tests[test] ?? []) {
                    include([test], kind: "dependency", reason: path.last.map(sdkSymbols.contains) == true ? "Head compiler dependencies reach a changed SDK test helper; base/head read-only query effects and closed source/compiled callers are verified" : path.last.map(isolatedSymbols.contains) == true ? "Head compiler dependencies reach a changed body; private helper isolation is verified from base/head syntax and compiled consumers" : "Head compiler dependencies reach a surviving body with an unchanged declaration header", path: path.map { graph.functions[$0].map { $0.module + "." + $0.name } ?? $0 })
                }
                if !changed.isEmpty {
                    let roots = graph.tests[test] ?? []
                    if roots.isEmpty || roots.contains(where: { graph.functions[$0] == nil }) {
                        fallback("head_only_unresolved_test", "Missing or incomplete compiled head entry for \(test)", tests: [test])
                    }
                    for message in graph.testDiagnostics[test] ?? [] { fallback("head_only_unresolved_test", message, tests: [test]) }
                }
            }
            let entriesOnly = !changed.isEmpty && changed.allSatisfy { isolatedHelpers.contains($0.key) || XcodeFineSelector.isTestEntry($0, in: current) }
            if !changed.isEmpty && !entriesOnly {
                let opaque = index.paths(to: Set(graph.functions.values.filter(\.hasOpaqueRuntimeDependency).map(\.id)))
                let productionKeys = Set(production.map(\.key))
                // App feature contracts do not isolate test helpers or lifecycle
                // code. A mixed production edit must preserve their uncertainty.
                let declaredUI = current.mappings?.runtimeDependencyPolicy == .declared && source.mappings?.runtimeDependencyPolicy == .declared &&
                    changed.allSatisfy { productionKeys.contains($0.key) || isolatedHelpers.contains($0.key) || XcodeFineSelector.isTestEntry($0, in: current) }
                for test in inventory.sorted() {
                    if !production.isEmpty, uiTests.contains(test), declaredUI { continue }
                    if opaque.path(from: graph.tests[test] ?? []) != nil {
                        fallback("head_only_runtime_uncertainty", "Opaque head runtime dependency may reach the change; no base compiler evidence validates isolation for \(test)", tests: [test])
                    }
                }
            }
            if !production.isEmpty {
                // Head host metadata is truthful. Never label an app-hosted or
                // unresolved test host as hostless using source imports/contracts.
                for group in Dictionary(grouping: inventory.subtracting(uiTests), by: target).sorted(by: { $0.key < $1.key }) {
                    let module = current.modules[group.key]
                    if module == nil || current.runtimeInventory?.hosts[group.key] != Set([module!]) {
                        fallback("head_only_test_host", "App-hosted or unresolved test runtime can execute changed production code outside explicit test roots: \(group.key)", tests: Set(group.value))
                    }
                }
                if let mappings = current.mappings, let mi = mappingIndex {
                    var matched = Set<String>(), mappedTests = Set<String>(), covered = Set<String>()
                    for feature in mappings.features {
                        let tests = mi.tests[feature.name] ?? []
                        mappedTests.formUnion(tests)
                        if !(mi.unmatched[feature.name]?.isEmpty ?? true) ||
                            (!(feature.sources ?? []).isEmpty || !(feature.symbols ?? []).isEmpty) && (mi.roots[feature.name]?.isEmpty ?? true) {
                            fallback("head_only_unresolved_mapping", "Unresolved UI tests or source boundary for \(feature.name)", tests: uiTests)
                        }
                        if feature.when != nil { continue }
                        for unit in production {
                            let ids = Set((index.byFile[unit.region.path] ?? []).filter { id in graph.functions[id]!.regions.contains { $0.intersects(unit.region) } }).intersection(affected)
                            if (feature.sources ?? []).contains(where: { UIFeatureMappings.matches(unit.region.path, pattern: $0) }) ||
                                index.paths(to: ids).path(from: mi.roots[feature.name] ?? []) != nil {
                                matched.insert(feature.name); covered.insert(unit.key)
                            }
                        }
                    }
                    var previous = Set<String>()
                    while previous != matched {
                        previous = matched
                        for feature in mappings.features where !Set(feature.dependsOn ?? []).isDisjoint(with: matched) { matched.insert(feature.name) }
                    }
                    for feature in mappings.features where matched.contains(feature.name) {
                        let tests = mi.tests[feature.name] ?? []
                        include(tests, kind: "explicitMapping", reason: "Head dependency or declared feature dependency reaches a surviving changed body", path: [feature.name])
                        if tests.isEmpty { fallback("head_only_unresolved_mapping", "Affected feature \(feature.name) has no tests", tests: uiTests) }
                    }
                    fallback("head_only_unmapped_ui", "UI tests outside explicit mappings remain selected", tests: uiTests.subtracting(mappedTests))
                    if !production.allSatisfy({ covered.contains($0.key) }) { fallback("head_only_unmapped_production", "Changed production body has no UI feature boundary", tests: uiTests) }
                    if mappings.runtimeDependencyPolicy != .declared || source.mappings?.runtimeDependencyPolicy != .declared {
                        fallback("head_only_ui_runtime", "No unchanged declared cross-process UI dependency contract", tests: uiTests)
                    }
                } else { fallback("head_only_missing_mappings", "Production changes need explicit UI dependency mappings", tests: uiTests) }
            }
        } else if !changes.isEmpty { fallback("head_only_incomplete_graph", "Missing head compiler graph") }
        var report = ImpactReport(baseRevision: baseRevision, totalTests: inventory.count, selectedTests: selected.sorted(), explanations: explanations,
            fullRunReasons: fullReasons.sorted(), changedFiles: changes.map(\.path).sorted(), unreferencedChanges: [], limitations: [
                "Head-only mode has no base compiler graph. Except for proven isolated private test helper additions, added/deleted/moved declarations, signature, dispatch, state, resource and configuration changes conservatively select all head tests.",
                "Focused selection supports surviving function bodies with unchanged headers and private test helpers whose nonescaping source callers and compiler bindings prove isolation. Head dependency paths are evidence; absent old edges are never treated as proof for structural changes.",
                "Tests are assumed independent. Non-UI runtime isolation is not inferred from base source imports; app-hosted and opaque runtime effects retain explicit fallbacks.",
                "UI feature mappings are explicit dependency contracts, not measured coverage. Validate selections with full runs."])
        report.uiConditionDecisions = conditionDecisions.isEmpty ? nil : conditionDecisions
        report.schemaVersion = 2; report.analysisMode = "head-only-git-syntax"
        report.onlyTestingArguments = report.selectedTests.map { "-only-testing:" + $0 }
        report.ignoredChanges = ignored.sorted()
        report.diagnostics = diagnostics.sorted { ($0.code, $0.message) < ($1.code, $1.message) }
        report.explanations.sort { ($0.test, $0.kind, $0.reason) < ($1.test, $1.kind, $1.reason) }
        let mapped = Set(mappingIndex?.tests.values.flatMap { $0 } ?? [])
        report.uiMappingCoverage = .init(mappingFilePresent: current.mappings != nil,
            mappedTests: uiTests.intersection(mapped).sorted(), unmappedTests: uiTests.subtracting(mapped).sorted())
        if let mi = mappingIndex, let mappings = current.mappings {
            report.uiMappingCoverage?.unresolvedBoundaries = mappings.features.filter {
                (!($0.sources ?? []).isEmpty || !($0.symbols ?? []).isEmpty) && (mi.roots[$0.name]?.isEmpty ?? true)
            }.map(\.name).sorted()
            report.uiMappingCoverage?.unmatchedSelectors = mi.unmatched.flatMap { name, selectors in selectors.map { name + ": " + $0 } }.sorted()
        }
        return report
    }
}
