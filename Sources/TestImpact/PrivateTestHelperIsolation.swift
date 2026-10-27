// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation

/// Combines syntax accessibility/escape evidence with actual head consumers.
/// This proof is independent of app feature mappings and opaque SDK dispatch.
enum PrivateTestHelperIsolation {
    /// Scoped to one immutable base/head proof. Active nodes detect cycles;
    /// completed results avoid re-expanding shared ancestors in a helper DAG.
    struct Traversal {
        fileprivate var active = Set<String>()
        fileprivate var completed: [String: Bool] = [:]
        fileprivate var sdkEffectIDs: [String: Set<String>] = [:]
        fileprivate var externalEffects = ExternalHelperEffects()
        fileprivate var receiverOrigins = SDKReceiverOrigins()
        fileprivate var sdkEffectDeclarations: [String: [SourceUnit]] = [:]
        fileprivate(set) var receiverOriginBlocker: String?
        private(set) var evaluationCount = 0
        fileprivate(set) var sharedStateSymbols = Set<String>()
        fileprivate(set) var hasUnprovenCalleeEffects = false

        fileprivate mutating func begin(_ key: String) {
            active.insert(key)
            evaluationCount += 1
        }
    }

    static func proves(_ unit: SourceUnit, previous: SourceUnit?, current: XcodeTestGraph,
                       base: [String: SwiftSourceSnapshot], graph: DependencyGraph, index: DependencyIndex) -> Bool {
        var traversal = Traversal()
        return proves(unit, previous: previous, current: current, base: base, graph: graph, index: index, traversal: &traversal)
    }

    static func proves(_ unit: SourceUnit, previous: SourceUnit?, current: XcodeTestGraph,
                       base: [String: SwiftSourceSnapshot], graph: DependencyGraph, index: DependencyIndex,
                       traversal: inout Traversal, unownedBase: [String: SwiftSourceSnapshot] = [:]) -> Bool {
        // Keep the graph traversal on the heap. Even modest chains overflow
        // Swift Testing's worker stack in unoptimized builds with recursive proofs.
        enum Work {
            case enter(SourceUnit, SourceUnit?)
            case finish(Prepared)
        }
        var pending: [Work] = [.enter(unit, previous)]
        while let work = pending.popLast() {
            switch work {
            case let .enter(candidate, prior):
                if traversal.completed[candidate.key] != nil { continue }
                guard !traversal.active.contains(candidate.key) else {
                    traversal.completed[candidate.key] = false
                    continue
                }
                traversal.begin(candidate.key)
                guard let proof = prepare(candidate, previous: prior, current: current, base: base,
                                          graph: graph, index: index, traversal: &traversal, unownedBase: unownedBase) else {
                    traversal.active.remove(candidate.key)
                    traversal.completed[candidate.key] = false
                    continue
                }
                pending.append(.finish(proof))
                for (caller, old) in proof.helpers.reversed() { pending.append(.enter(caller, old)) }
            case let .finish(proof):
                let key = proof.unit.key
                let callersProven = proof.helpers.allSatisfy { traversal.completed[$0.0.key] == true }
                let result = traversal.completed[key] != false && callersProven &&
                    finish(proof, current: current, graph: graph, index: index, traversal: &traversal)
                traversal.active.remove(key)
                traversal.completed[key] = result
            }
        }
        return traversal.completed[unit.key] == true
    }

    private struct Prepared {
        var unit: SourceUnit
        var syntax: PrivateTestHelperSyntax
        var ids: Set<String>
        var effectIDs: Set<String>
        var sdkBindingsSupported: Bool
        var callers: [SourceUnit]
        var helpers: [(SourceUnit, SourceUnit)]
    }

    private static func prepare(_ unit: SourceUnit, previous: SourceUnit?, current: XcodeTestGraph,
                                base: [String: SwiftSourceSnapshot], graph: DependencyGraph, index: DependencyIndex,
                                traversal: inout Traversal, unownedBase: [String: SwiftSourceSnapshot]) -> Prepared? {
        if [unit.privateTestHelper, previous?.privateTestHelper].compactMap({ $0 }).contains(where: {
            $0.proofVersion == PrivateTestHelperSyntax.currentProofVersion && $0.calleeEffectsSupported != true
        }) { traversal.hasUnprovenCalleeEffects = true }
        guard let syntax = unit.privateTestHelper, syntax.proofVersion == PrivateTestHelperSyntax.currentProofVersion,
              syntax.statements != nil, syntax.calleeEffectsSupported == true, unit.headOnlyBodySupported == true,
              previous == nil || (previous?.headOnlyBodySupported == true &&
                  previous?.privateTestHelper.map { $0.proofVersion == PrivateTestHelperSyntax.currentProofVersion && $0.calleeEffectsSupported == true && syntax.preservesEffects(of: $0) } == true),
              current.tests.allSatisfy({ test in
                  guard let roots = graph.tests[test], !roots.isEmpty, graph.testDiagnostics[test]?.isEmpty ?? true else { return false }
                  return roots.allSatisfy { graph.functions[$0] != nil }
              }) else { return nil }
        guard Set(current.modules.values).isDisjoint(with: SDKTestHelperSyntax.trustedCallerModules),
              (Array(current.sources.values) + Array(base.values) + Array(unownedBase.values)).allSatisfy({ $0.helperNamesUnshadowed == true }) else {
            traversal.hasUnprovenCalleeEffects = true
            return nil
        }
        guard contextAllows(unit, name: syntax.name, existed: previous != nil, current: current, base: base) else { return nil }
        let module = String(unit.key.prefix { $0 != ":" })
        let headUnits = current.sources.values.flatMap(\.units), baseUnits = base.values.flatMap(\.units)
        let ids = symbols(unit, graph: graph, index: index)
        guard !ids.isEmpty else { return nil }
        var callers = headUnits.filter { $0.region.path == unit.region.path && $0.key.hasPrefix(module + ":") &&
            $0.kind == "function" && syntax.callerLines.contains($0.region.startLine) }
        guard callers.count == syntax.callerLines.count else { return nil }
        if let previous, let oldSyntax = previous.privateTestHelper {
            let oldCallers = baseUnits.filter { $0.region.path == previous.region.path && $0.key.hasPrefix(module + ":") &&
                $0.kind == "function" && oldSyntax.callerLines.contains($0.region.startLine) }
            guard oldCallers.count == oldSyntax.callerLines.count else { return nil }
            // Changed/deleted headers have no historical graph proof. Even old
            // callers which stopped calling the helper must survive as entries.
            for old in oldCallers {
                let surviving = headUnits.filter { $0.key == old.key && $0.region.path == old.region.path }
                guard surviving.count == 1 else { return nil }
                callers += surviving
            }
        }
        callers = Dictionary(grouping: callers, by: \.key).values.compactMap(\.first)
        var helpers: [(SourceUnit, SourceUnit)] = []
        for caller in callers {
            guard caller.headOnlyBodySupported == true else { return nil }
            if XcodeFineSelector.isTestEntry(caller, in: current) { continue }
            let old = baseUnits.filter { $0.key == caller.key && $0.region.path == caller.region.path }
            // Only unchanged intermediate helpers may extend the inbound proof.
            // In particular, a head graph says nothing about removed old effects.
            guard old.count == 1, let prior = old.first,
                  caller.privateTestHelper?.statements?.map(\.signature) == prior.privateTestHelper?.statements?.map(\.signature) else { return nil }
            helpers.append((caller, prior))
        }
        guard let effectUnits = effectDeclarations(unit, syntax: syntax, sources: current.sources),
              previous == nil || effectDeclarations(previous!, syntax: previous!.privateTestHelper!, sources: base) != nil else {
            traversal.hasUnprovenCalleeEffects = true
            return nil
        }
        if traversal.sdkEffectIDs[module] == nil {
            let sdk = headUnits.filter { $0.key.hasPrefix(module + ":") && $0.sdkTestHelper?.version == SDKTestHelperSyntax.currentVersion &&
                $0.sdkTestHelper?.blocker == nil && $0.headOnlyBodySupported == true }
            let supported = sdk.filter { callee in
                let owners = current.targets.filter { $0.sourceFiles.contains(callee.region.path) }
                let old = baseUnits.filter { $0.key == callee.key && $0.region.path == callee.region.path }
                return !owners.isEmpty && owners.allSatisfy { $0.isTest && !$0.hasProductionRole && current.modules[$0.name] == module } &&
                    old.count == 1 && old[0].headOnlyBodySupported == true && old[0].sdkTestHelper?.version == SDKTestHelperSyntax.currentVersion && old[0].sdkTestHelper?.blocker == nil &&
                    SDKTestHelperIsolation.effectBindingBlocker(callee, previous: old[0], current: current, base: base, unownedBase: unownedBase) == nil &&
                    SDKTestHelperIsolation.compilerEffectBlocker(callee, graph: graph, index: index) == nil
            }
            let queries = Set(supported.flatMap { $0.sdkTestHelper!.queriedMembers }).union(
                baseUnits.filter { old in supported.contains { $0.key == old.key && $0.region.path == old.region.path } }.compactMap(\.sdkTestHelper).flatMap(\.queriedMembers))
            let environmentSupported = SDKTestHelperIsolation.environmentBlocker(current: current, base: base, unownedBase: unownedBase, queriedMembers: queries) == nil
            traversal.sdkEffectIDs[module] = environmentSupported
                ? supported.reduce(into: Set<String>()) { $0.formUnion(symbols($1, graph: graph, index: index)) } : []
            traversal.sdkEffectDeclarations[module] = environmentSupported
                ? supported + baseUnits.filter { old in supported.contains { $0.key == old.key && $0.region.path == old.region.path } } : []
        }
        guard let sdkMembers = syntax.sdkEffectMembers, syntax.sdkCallShapes != nil,
              previous == nil || (previous?.privateTestHelper?.sdkEffectMembers != nil && previous?.privateTestHelper?.sdkCallShapes != nil) else {
            traversal.hasUnprovenCalleeEffects = true
            return nil
        }
        let historicalMembers = previous?.privateTestHelper?.sdkEffectMembers ?? []
        let sdkBindings = sdkMembers.union(historicalMembers)
        var sdkBindingsSupported = true
        if !sdkBindings.isEmpty {
            // Preserving the old statements does not preserve their bindings:
            // a removed project initializer/member may now resolve to the SDK.
            let revisions = [Array(current.sources.values), Array(base.values) + Array(unownedBase.values)]
            let owners: Set<String> = ["XCTAttachment", "XCUIScreenshot", "XCUIElement", "XCUIApplication",
                                       "XCTestCase", "XCTest", "NSObject", "NSObjectProtocol", "XCUIElementQuery",
                                       "NSPredicate", "XCTNSPredicateExpectation", "XCTWaiter"]
            // Bare SDK construction cannot dynamically invoke a project
            // subclass's initializer. Ordinary member overrides can, so audit
            // those names even when an alias hides the superclass.
            let dynamicMembers = sdkBindings.subtracting(["init"])
            sdkBindingsSupported = SDKTestHelperIsolation.overridesUnshadowed(revisions: revisions,
                members: dynamicMembers, sdkReceivers: owners.subtracting(["NSObject", "NSObjectProtocol"])) &&
                SDKTestHelperIsolation.memberBindingsUnshadowed(revisions: revisions,
                    members: sdkBindings, sdkOwners: owners, provenHelpers: traversal.sdkEffectDeclarations[module] ?? [])
            // Still walk the head's compiler effects so existing shared-state
            // diagnostics survive even when the historical binding is unproven.
            if !sdkBindingsSupported { traversal.hasUnprovenCalleeEffects = true }
        }
        let effectIDs = effectUnits.reduce(into: traversal.sdkEffectIDs[module] ?? []) { $0.formUnion(symbols($1, graph: graph, index: index)) }
        return Prepared(unit: unit, syntax: syntax, ids: ids, effectIDs: effectIDs, sdkBindingsSupported: sdkBindingsSupported, callers: callers, helpers: helpers)
    }

    private static func finish(_ proof: Prepared, current: XcodeTestGraph, graph: DependencyGraph,
                               index: DependencyIndex, traversal: inout Traversal) -> Bool {
        let callers = proof.callers, syntax = proof.syntax, ids = proof.ids
        let paths = index.paths(to: ids)
        let entries = callers.filter { XcodeFineSelector.isTestEntry($0, in: current) }
        let entrySymbols = entries.reduce(into: Set<String>()) { $0.formUnion(symbols($1, graph: graph, index: index)) }
        let helperSymbols = callers.filter { !XcodeFineSelector.isTestEntry($0, in: current) }
            .reduce(into: Set<String>()) { $0.formUnion(symbols($1, graph: graph, index: index)) }
        let callerPaths = index.paths(to: helperSymbols)
        let expectedTests = Set(current.tests.filter {
            !(graph.tests[$0] ?? []).isDisjoint(with: entrySymbols) || callerPaths.path(from: graph.tests[$0] ?? []) != nil
        })
        let consumers = Set(current.tests.filter { paths.path(from: graph.tests[$0] ?? []) != nil })
        // At least one compiled consumer and a path for every current syntactic
        // caller. Removed old calls need not have a surviving edge.
        guard !consumers.isEmpty, consumers.isSubset(of: expectedTests),
              callers.filter({ syntax.callerLines.contains($0.region.startLine) }).allSatisfy({
                  paths.path(from: symbols($0, graph: graph, index: index)) != nil
              }) else { return false }
        // Reject compiler-observed state/pointer effects in project callees too,
        // including extension helpers reached from the changed body. SDK runtime
        // uncertainty alone is not a route into this private, nonescaping method.
        let projectModules = Set(current.modules.values)
        var pending = Array(ids), visited = Set<String>(), effectsSupported = proof.sdkBindingsSupported
        var usesSDKReceiver = false
        var external = Set<String>()
        while let id = pending.popLast() {
            guard visited.insert(id).inserted else { continue }
            guard let node = graph.functions[id], projectModules.contains(node.module), node.hasProjectRuntimeContext else {
                external.insert(id)
                continue
            }
            usesSDKReceiver = usesSDKReceiver || node.dynamicDeclarations.contains { declaration in
                ["XCUIElement.", "XCUIElementQuery.", "XCUIApplication."].contains { declaration.hasPrefix($0) }
            }
            // XCTest attachment setters do not require a blanket effect
            // exemption. Reads of other objects, including assertion
            // autoclosures in this region, must retain their state checks.
            let unsafeEffects: Set<String> = ["Global state access", "Shared state access", "Raw pointer operation"]
            if projectModules.contains(node.module) && node.hasProjectRuntimeContext &&
                !node.uncertainties.isDisjoint(with: unsafeEffects) {
                if node.uncertainties.contains("Shared state access") { traversal.sharedStateSymbols.insert(id) }
                effectsSupported = false
            }
            if projectModules.contains(node.module) && node.hasProjectRuntimeContext && !proof.effectIDs.contains(id) {
                traversal.hasUnprovenCalleeEffects = true
                effectsSupported = false
            }
            if !ExternalHelperEffects.allowsDynamicCalls(node, sourceCallShapes: syntax.sdkCallShapes) {
                traversal.hasUnprovenCalleeEffects = true
                effectsSupported = false
            }
            pending += node.dependencies
        }
        if !traversal.externalEffects.allows(external) {
            traversal.hasUnprovenCalleeEffects = true
            effectsSupported = false
        }
        if usesSDKReceiver, let reason = traversal.receiverOrigins.blocker(tests: consumers, current: current, graph: graph) {
            traversal.receiverOriginBlocker = reason
            traversal.hasUnprovenCalleeEffects = true
            effectsSupported = false
        }
        return effectsSupported
    }

    /// The source effect walk is deliberately not an overload resolver. Reject
    /// competing same-class, inherited or global declarations at both revisions,
    /// then check the actual head compiler callees against the resulting regions.
    private static func effectDeclarations(_ unit: SourceUnit, syntax: PrivateTestHelperSyntax,
                                           sources: [String: SwiftSourceSnapshot]) -> [SourceUnit]? {
        guard let lines = syntax.effectCalleeLines, !lines.isEmpty else { return nil }
        let module = String(unit.key.prefix { $0 != ":" })
        let snapshots = sources.filter { $0.key.hasPrefix(module + ":") }.map(\.value)
        let units = snapshots.flatMap(\.units)
        var scopes: Set<String> = ["", unit.scope], pending = [unit.scope]
        while let name = pending.popLast() {
            let qualified = name.hasPrefix(module + ".") ? name : module + "." + name
            for snapshot in snapshots {
                if let parent = snapshot.helperSafeClasses?[qualified] {
                    let local = parent.hasPrefix(module + ".") ? String(parent.dropFirst(module.count + 1)) : parent
                    if scopes.insert(local).inserted { pending.append(local) }
                }
            }
        }
        var result: [SourceUnit] = []
        for (name, line) in lines {
            let matches = units.filter { $0.kind == "function" && $0.helperCallableName == name &&
                (scopes.contains($0.scope) || scopes.contains(String($0.scope.dropFirst(module.count + 1))) && $0.scope.hasPrefix(module + ".")) }
            guard matches.count == 1, let declaration = matches.first,
                  declaration.scope == unit.scope, declaration.region.path == unit.region.path,
                  declaration.region.startLine == line else { return nil }
            result.append(declaration)
        }
        return result
    }

    static func provesAddedEntry(_ unit: SourceUnit, current: XcodeTestGraph,
                                 base: [String: SwiftSourceSnapshot]) -> Bool {
        guard let name = unit.independentAddedTestEntry, unit.headOnlyBodySupported == true,
              XcodeFineSelector.isTestEntry(unit, in: current) else { return false }
        return contextAllows(unit, name: name, existed: false, current: current, base: base)
    }

    private static func contextAllows(_ unit: SourceUnit, name: String, existed: Bool, current: XcodeTestGraph,
                                      base: [String: SwiftSourceSnapshot]) -> Bool {
        let module = String(unit.key.prefix { $0 != ":" })
        let owners = current.targets.filter { $0.sourceFiles.contains(unit.region.path) }
        guard !owners.isEmpty, owners.allSatisfy({ $0.isTest && !$0.hasProductionRole && current.modules[$0.name] == module }),
              current.unsupportedSourceInputs?[module]?.isEmpty ?? true,
              current.unresolvedProductRoles?[module] == nil else { return false }
        let headSources = Array(current.sources.values), baseSources = Array(base.values)
        guard (headSources + baseSources).allSatisfy({ $0.helperNamesUnshadowed == true }) else { return false }
        let headUnits = headSources.flatMap(\.units), baseUnits = baseSources.flatMap(\.units)
        func snapshotsInModule(_ snapshots: [String: SwiftSourceSnapshot]) -> [SwiftSourceSnapshot] {
            snapshots.filter { key, snapshot in
                key.hasPrefix(module + ":") || snapshot.units.contains { $0.key.hasPrefix(module + ":") }
            }.map(\.value)
        }
        let moduleSources = snapshotsInModule(current.sources)
        let oldModuleSources = snapshotsInModule(base)
        if unit.privateTestHelper?.localAttachmentState == true {
            guard (moduleSources + oldModuleSources).allSatisfy({ $0.attachmentAddUnshadowed == true }) else { return false }
        }
        // No missing module source, legacy evidence, overload in another file, or
        // inaccessible extension/alias may be mistaken for a closed caller set.
        let capturedPaths = Set(moduleSources.flatMap(\.units).map { $0.region.path }).union(
            current.sources.keys.filter { $0.hasPrefix(module + ":") }.map { String($0.dropFirst(module.count + 1)) })
        guard current.targets.filter({ current.modules[$0.name] == module }).allSatisfy({ Set($0.sourceFiles).isSubset(of: capturedPaths) }),
              (moduleSources + oldModuleSources).allSatisfy({ $0.identifierNames != nil && $0.helperSafeClasses != nil }),
              moduleSources.filter({ !$0.units.contains { $0.region.path == unit.region.path } }).allSatisfy({ !$0.identifierNames!.contains(name) }),
              oldModuleSources.filter({ !existed || !$0.units.contains { $0.region.path == unit.region.path } }).allSatisfy({ !$0.identifierNames!.contains(name) }),
              safeHierarchy(unit.scope, module: module, sources: moduleSources),
              safeHierarchy(unit.scope, module: module, sources: oldModuleSources),
              !(headUnits + baseUnits).contains(where: { $0.kind == "extension" && [$0.scope, module + "." + $0.scope].contains(module + "." + unit.scope) }),
              Set(headUnits.filter { $0.kind == "function" && $0.region.intersects(unit.region) }.map(\.key)) == [unit.key] else { return false }
        return true
    }

    private static func symbols(_ unit: SourceUnit, graph: DependencyGraph, index: DependencyIndex) -> Set<String> {
        let module = String(unit.key.prefix { $0 != ":" })
        return Set((index.byFile[unit.region.path] ?? []).filter { id in
            let node = graph.functions[id]!
            return node.module == module && node.regions.contains { $0.path == unit.region.path &&
                $0.startLine >= unit.region.startLine && $0.startLine <= unit.region.endLine }
        })
    }

    static func safeHierarchy(_ name: String, module: String, sources: [SwiftSourceSnapshot]) -> Bool {
        let classes = sources.flatMap { ($0.helperSafeClasses ?? [:]).map { ($0.key, $0.value) } }
        let aliases = Set(sources.flatMap { $0.typeAliases ?? [] })
        var name = name, visited = Set<String>()
        while visited.insert(name).inserted {
            let qualified = name.hasPrefix(module + ".") ? name : module + "." + name
            guard !aliases.contains(qualified) else { return false }
            let matches = classes.filter { $0.0 == qualified }
            if ["XCTestCase", "XCTest.XCTestCase"].contains(name) {
                return matches.isEmpty && !sources.flatMap(\.units).contains { $0.kind == "type" && $0.scope == name }
            }
            let declarations = sources.flatMap(\.units).filter { $0.key.hasPrefix(module + ":") &&
                $0.kind == "type" && module + "." + $0.scope == qualified }
            guard matches.count == 1, declarations.count == 1 else { return false }
            name = matches[0].1
        }
        return false
    }
}
