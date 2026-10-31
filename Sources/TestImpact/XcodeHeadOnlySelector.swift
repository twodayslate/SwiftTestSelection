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
    var mappingPath: String = ".swift-test-selection.json"

    static func read(current: XcodeTestGraph, changes: [FileChange], base: String, root: URL, mappingPath: String, cache: XcodeBaseSourceCache? = nil) throws -> Self {
        let cache = try cache ?? XcodeBaseSourceCache(root: root, base: base)
        try cache.validate(root: root, base: base)
        var result = Self(base: current.sources)
        result.mappingPath = mappingPath
        var mappingDiagnostics: [String] = []
        if let mapping = try cache.content(path: mappingPath) {
            do {
                result.mappings = try JSONDecoder().decode(UIFeatureMappings.self, from: mapping)
                try result.mappings?.validate()
            } catch { mappingDiagnostics.append("Invalid base mapping policy: \(error)") }
        }
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
        let hasContracts = !HelperFormattingContracts.declarations(current.sources, current.mappings).isEmpty || !(result.mappings?.helperFormattingContracts?.isEmpty ?? true)
        let auditCallers = !callerModules.isEmpty || hasContracts
        var basePaths: Set<String>?
        if auditCallers {
            basePaths = try cache.paths()
            if basePaths == nil { result.diagnostics.append("Cannot enumerate base sources at \(base)") }
        }
        for key in current.sources.keys.sorted() {
            guard let colon = key.firstIndex(of: ":") else { result.diagnostics.append("Invalid source snapshot key: \(key)"); continue }
            let module = String(key[..<colon]), path = String(key[key.index(after: colon)...])
            guard paths.contains(path) || auditCallers else { continue }
            // New files outside the scope have no old callers to audit. Do not
            // turn a proven absence into an unrelated scope diagnostic.
            if !paths.contains(path), let basePaths, !basePaths.contains(path) {
                result.base.removeValue(forKey: key)
                continue
            }
            if let snapshot = try cache.snapshot(path: path, module: module) {
                result.base[key] = snapshot
            } else {
                result.base.removeValue(forKey: key)
                result.diagnostics.append("No base source boundary for \(path) at \(base)")
            }
        }
        if auditCallers {
            // Deleted/out-of-target files cannot be found by iterating the head
            // inventory. Inspect their base syntax without inventing module ownership.
            let captured = Set(current.sources.keys.compactMap { key in key.firstIndex(of: ":").map { String(key[key.index(after: $0)...]) } })
            if let basePaths {
                for path in basePaths.sorted() where path.hasSuffix(".swift") && !captured.contains(path) {
                    if let snapshot = try cache.snapshot(path: path, module: "") {
                        result.unownedBaseSources[path] = snapshot
                    } else { result.diagnostics.append("Cannot read unowned base source \(path) at \(base)") }
                }
            }
        }
        result.diagnostics += mappingDiagnostics
        return result
    }
}

/// Supports surviving function bodies and proven isolated private test helper
/// additions with unchanged ownership/build inputs. Other structural edits cannot recover vanished old edges:
/// they select the full head inventory with an explicit uncertainty diagnostic.
/// This does not delegate to the two-graph selector with a synthetic previous.
enum XcodeHeadOnlySelector {
    static func select(current: XcodeTestGraph, source: XcodeHeadOnlySources, changes: [FileChange],
                       baseRevision: String, documentation: Set<String> = [], buildEvidenceFailure: String? = nil, excludedTestEntries: Set<String> = [], applyHelperContracts: Bool = true) -> ImpactReport {
        let originalCurrent = current
        let mappingFilePresent = current.mappings != nil
        let inline = InlineUIMappings.resolve(current)
        let current = inline.applying(to: current)
        let inventory = Set(current.tests)
        func target(_ test: String) -> String { String(test.prefix { $0 != "/" }) }
        let uiTargets = Set(current.targets.filter(\.isUITest).map(\.name))
        let uiTests = inventory.filter { uiTargets.contains(target($0)) }
        var selected = Set<String>(), ignored = Set<String>(), fullReasons = Set<String>()
        var explanations: [TestExplanation] = [], diagnostics: [SelectionDiagnostic] = []
        var fallbackUnits: [SourceUnit] = []
        let review = HelperFormattingContracts.validate(current: current, source: source, baseRevision: baseRevision)
        var contractDecisions = review.decisions
        var evaluations: [HelperContractEvaluation] = []
        let oldContracts = HelperFormattingContracts.declarations(source.base, source.mappings)
        let newContracts = HelperFormattingContracts.declarations(current.sources, current.mappings)
        let changedPaths = Set(changes.map(\.path))
        let directiveIDs = Set((Array(current.sources) + Array(source.base)).filter { key, _ in
            guard let colon = key.firstIndex(of: ":") else { return false }
            return changedPaths.contains(String(key[key.index(after: colon)...]))
        }.flatMap { $0.value.helperContracts?.contracts.map(\.id) ?? [] })
        let policyHelpers = Set((oldContracts + newContracts).filter { contract in
            (changedPaths.contains(source.mappingPath) || directiveIDs.contains(contract.id)) &&
            oldContracts.filter { $0.id == contract.id } != newContracts.filter { $0.id == contract.id }
        }.map(\.helper))
        func include(_ tests: Set<String>, kind: String, reason: String, path: [String] = []) {
            let tests = tests.intersection(inventory)
            selected.formUnion(tests)
            explanations += tests.sorted().map { TestExplanation(test: $0, reason: reason, revision: "head", path: path, kind: kind) }
        }
        func fallback(_ code: String, _ reason: String, tests: Set<String>? = nil, path: [String] = []) {
            let tests = (tests ?? inventory).intersection(inventory)
            guard !tests.isEmpty else { return }
            let boundary = reason.contains("runtime formatting conformances") ? evaluations.last?.encountered.last : nil
            let boundaryPath = boundary.map { [$0.helper, $0.producerSymbol, $0.assertionSymbol, $0.substitutions] } ?? path
            let detail = SelectionFallback.explain(code: code, message: reason, units: fallbackUnits, path: boundaryPath, allTests: tests == inventory)
            diagnostics.append(.init(fallback: detail, code: code, message: reason + " " + detail.requiredEvidence, tests: tests.sorted()))
            include(tests, kind: "fallback", reason: reason)
            if tests == inventory { fullReasons.insert(reason) }
        }
        for (key, snapshot) in Array(current.sources) + Array(source.base) {
            for error in snapshot.helperContracts?.diagnostics ?? [] {
                fallback("helper_contract_invalid", key + ": " + error)
            }
        }
        for decision in contractDecisions where decision.status == "invalid" {
            // An invalid declaration cannot expand a no-op into an execution request,
            // but remains auditable and never participates in narrowing.
            let message = decision.contractID + ": " + decision.failures.joined(separator: "; ")
            var detail = SelectionFallback.explain(code: "helper_contract_invalid", message: message,
                units: current.sources.values.flatMap(\.units).filter { $0.key == decision.helper })
            detail.supportedDeclaration = "helperFormattingContracts v1"
            detail.validationFailures = decision.failures
            diagnostics.append(.init(fallback: detail, code: "helper_contract_invalid", message: message, tests: []))
        }
        for diagnostic in inline.diagnostics {
            fallback(diagnostic.code, diagnostic.message, tests: Set(diagnostic.tests))
        }
        let oldPolicies = InlineUIMappings.policyPaths(source.base)
        let newPolicies = InlineUIMappings.policyPaths(current.sources)
        let policyPaths = Set(oldPolicies.keys).union(newPolicies.keys).filter { oldPolicies[$0] != newPolicies[$0] }
        if !policyPaths.isEmpty {
            fallback("head_only_inline_policy_changed", "Inline UI policy changed without base compiler bindings: " + policyPaths.sorted().joined(separator: ", "), tests: uiTests)
        }
        if !inline.features.isEmpty, let graph = current.dependencies {
            let mi = MappingIndex(UIFeatureMappings(features: inline.features), snapshot: current, graph: graph, index: DependencyIndex(graph))
            for feature in inline.features where feature.when == nil {
                for entry in mi.unresolvedEntries[feature.name] ?? [] {
                    fallback("unresolved_mapping_boundary", "\(feature.name): no compiled boundary matches \(entry)", tests: Set(feature.tests ?? []))
                }
            }
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
        let paths = Set(changes.map(\.path)).union((source.base.values.flatMap(\.units) + current.sources.values.flatMap(\.units)).filter { policyHelpers.contains($0.key) }.map { $0.region.path })
        let old = Dictionary(grouping: source.base.values.flatMap(\.units).filter { paths.contains($0.region.path) }, by: \.key)
        let new = Dictionary(grouping: current.sources.values.flatMap(\.units).filter { paths.contains($0.region.path) }, by: \.key)
        let excludedKeys = independentEntryKeys(current: current, excluding: excludedTestEntries)
        let dependencyIndex = current.dependencies.map(DependencyIndex.init)
        var isolatedHelpers = Set<String>(), isolatedSDKHelpers = Set<String>()
        var changed: [SourceUnit] = []
        var semanticPaths = policyPaths.union(HelperFormattingContracts.changedPolicyPaths(base: source.base, head: current.sources))
        for key in Set(old.keys).union(new.keys).sorted() {
            let before = old[key] ?? [], after = new[key] ?? []
            guard before.map(fingerprint).sorted() != after.map(fingerprint).sorted() || policyHelpers.contains(key) else { continue }
            fallbackUnits = before + after
            let evaluation = HelperContractEvaluation(helper: key, contracts: applyHelperContracts ? review.contracts : [],
                diagnosticCode: after.first?.sdkTestHelper != nil ? "head_only_sdk_helper_boundary" : "head_only_helper_callee_effects")
            evaluations.append(evaluation)
            semanticPaths.formUnion((before + after).map { $0.region.path })
            if PrivateTestHelperIsolation.provesExtensionHeaders(before + after, current: current, base: source.base) { continue }
            if after.count == 1, let unit = after.first, (unit.sdkTestHelper != nil || ["XCUIElement", "XCTest.XCUIElement"].contains(unit.scope)),
               let graph = current.dependencies, let index = dependencyIndex {
                if let blocker = SDKTestHelperIsolation.blocker(unit, previous: before.count == 1 ? before.first : nil,
                                                               current: current, base: source.base, graph: graph, index: index, unownedBase: source.unownedBaseSources, formattingReview: evaluation) {
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
                var traversal = PrivateTestHelperIsolation.Traversal(formattingReview: evaluation)
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
                if unit.privateTestHelper != nil, !traversal.hasUnprovenCalleeEffects, traversal.sharedStateSymbols.isEmpty {
                    fallback("head_only_helper_isolation", (traversal.isolationBlocker ?? "Unproven source/compiler caller isolation for " + unit.key) + " at \(unit.region.path):\(unit.region.startLine). No formatting declaration supplies missing historical caller evidence.")
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
        fallbackUnits = []
        let owned = Set(current.targets.flatMap(\.sourceFiles))
        func onlyContractMappingChange() -> Bool {
            guard var before = source.mappings, var after = originalCurrent.mappings else { return false }
            before.helperFormattingContracts = nil; after.helperFormattingContracts = nil
            let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
            return (try? encoder.encode(before)) == (try? encoder.encode(after))
        }
        let analyzed = Set(current.sources.keys.map { key in
            key.firstIndex(of: ":").map { String(key[key.index(after: $0)...]) } ?? key
        })
        for change in changes {
            if change.path == source.mappingPath, onlyContractMappingChange(), oldContracts != newContracts {
                // The affected helpers above are semantic change roots, even if
                // only the directive changed. Never ignore a mapping dependency edit.
                continue
            } else if change.previousPath != nil {
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
                fallbackUnits = [unit]
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
            // Positive compiler paths survive every failed isolation gate. A
            // broad fallback is an additional reason, not a replacement for
            // already observed helper/fixture dependencies.
            for (key, units) in new where !excludedKeys.contains(key) &&
                ((old[key] ?? []).map(fingerprint).sorted() != units.map(fingerprint).sorted() || policyHelpers.contains(key)) {
                for unit in units where unit.kind == "function" {
                    let module = String(unit.key.prefix { $0 != ":" })
                    affected.formUnion((index.byFile[unit.region.path] ?? []).filter { id in
                        let node = graph.functions[id]!
                        return node.module == module && node.regions.contains { $0.path == unit.region.path && $0.startLine >= unit.region.startLine && $0.startLine <= unit.region.endLine }
                    })
                }
            }
            fallbackUnits = changed
            let affectedPaths = index.paths(to: affected)
            for test in inventory.sorted() {
                if let path = affectedPaths.path(from: graph.tests[test] ?? []) {
                    include([test], kind: "dependency", reason: path.last.map(sdkSymbols.contains) == true ? "Head compiler dependencies reach a changed SDK test helper; source/compiler query and caller checks passed; consult helperContractDecisions for any reviewed formatting assumptions" : path.last.map(isolatedSymbols.contains) == true ? "Head compiler dependencies reach a changed body; private helper isolation passed source/compiler checks; consult helperContractDecisions for any reviewed formatting assumptions" : "Head compiler dependencies reach a surviving body with an unchanged declaration header", path: path.map { graph.functions[$0].map { $0.module + "." + $0.name } ?? $0 })
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
                    if let path = opaque.path(from: graph.tests[test] ?? []) {
                        fallback("head_only_runtime_uncertainty", "Opaque head runtime dependency may reach the change; no base compiler evidence validates isolation for \(test)", tests: [test], path: path)
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
                    var featurePaths: [String: [String]] = [:]
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
                            let chain = index.paths(to: ids).path(from: mi.roots[feature.name] ?? [])
                            if (feature.sources ?? []).contains(where: { UIFeatureMappings.matches(unit.region.path, pattern: $0) }) || chain != nil {
                                matched.insert(feature.name); covered.insert(unit.key)
                                featurePaths[feature.name] = (chain ?? []).map { graph.functions[$0].map { $0.module + "." + $0.name } ?? $0 } + [unit.region.path]
                            }
                        }
                    }
                    var previous = Set<String>()
                    while previous != matched {
                        previous = matched
                        for feature in mappings.features where !matched.contains(feature.name) && !Set(feature.dependsOn ?? []).isDisjoint(with: matched) {
                            matched.insert(feature.name)
                            featurePaths[feature.name] = (feature.dependsOn ?? []).filter { matched.contains($0) }.sorted()
                        }
                    }
                    for feature in mappings.features where matched.contains(feature.name) {
                        let tests = mi.tests[feature.name] ?? []
                        include(tests, kind: "explicitMapping", reason: "Head dependency or declared feature dependency reaches a surviving changed body", path: [feature.name] + (featurePaths[feature.name] ?? []))
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
        report.uiMappingCoverage = .init(mappingFilePresent: mappingFilePresent,
            mappedTests: uiTests.intersection(mapped).sorted(), unmappedTests: uiTests.subtracting(mapped).sorted())
        if let mi = mappingIndex, let mappings = current.mappings {
            report.uiMappingCoverage?.unresolvedBoundaries = mappings.features.filter {
                (!($0.sources ?? []).isEmpty || !($0.symbols ?? []).isEmpty) && (mi.roots[$0.name]?.isEmpty ?? true)
            }.map(\.name).sorted()
            report.uiMappingCoverage?.unmatchedSelectors = mi.unmatched.flatMap { name, selectors in selectors.map { name + ": " + $0 } }.sorted()
        }
        for i in contractDecisions.indices {
            let discharged = evaluations.flatMap { $0.discharged[contractDecisions[i].contractID] ?? [] }
            if !discharged.isEmpty {
                contractDecisions[i].status = "discharged"
                contractDecisions[i].dischargedBoundaries = discharged
            }
        }
        report.helperContractDecisions = contractDecisions.isEmpty ? nil : contractDecisions
        if contractDecisions.contains(where: { $0.status == "discharged" }) {
            report.limitations.append("Exact XCTest failure-formatting boundaries were discharged by reviewed declarations. This trust is separate from compiler-proven isolation and observed coverage; all remaining diagnostics still apply.")
        }
        let boundaries = evaluations.flatMap(\.encountered)
        report.formattingBoundaries = boundaries.isEmpty ? nil : boundaries
        report.finishFallbackEvidence()
        if !boundaries.isEmpty || !newContracts.isEmpty {
            var helperSymbols: [String: [String]] = [:]
            for key in Set(boundaries.map(\.helper)).union(newContracts.map(\.helper)) {
                let units = current.sources.values.flatMap(\.units).filter { $0.key == key }
                helperSymbols[key] = (current.dependencies?.functions.values.filter { node in
                    node.module == String(key.prefix { $0 != ":" }) && units.contains { unit in
                        node.regions.contains { $0.path == unit.region.path && $0.startLine >= unit.region.startLine && $0.endLine <= unit.region.endLine }
                    }
                }.map(\.id) ?? []).sorted()
            }
            report.helperContractReviewContext = .init(baseRevision: baseRevision,
                baseSources: HelperFormattingContracts.fingerprint(source.base, unowned: source.unownedBaseSources),
                headSources: HelperFormattingContracts.fingerprint(current.sources),
                toolchain: current.buildArtifact?.toolchain ?? current.dependencies?.toolchain ?? "",
                buildContext: HelperFormattingContracts.buildContext(current), helperSymbols: helperSymbols)
        }
        if applyHelperContracts, !newContracts.isEmpty {
            let baseline = select(current: originalCurrent, source: source, changes: changes, baseRevision: baseRevision,
                documentation: documentation, buildEvidenceFailure: buildEvidenceFailure,
                excludedTestEntries: excludedTestEntries, applyHelperContracts: false)
            report.helperContractPreview = .init(withoutDeclarations: baseline.selectedTests, withDeclarations: report.selectedTests,
                added: Set(report.selectedTests).subtracting(baseline.selectedTests).sorted(),
                removed: Set(baseline.selectedTests).subtracting(report.selectedTests).sorted())
        }
        return report
    }
}
