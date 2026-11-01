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
        fileprivate var callbacksChecked = false
        fileprivate var callbackBlocker: String?
        fileprivate var sdkEffectDeclarations: [String: [SourceUnit]] = [:]
        // Source bindings and statement preservation are checked during prepare.
        // A successful caller walk separately validates their current effects.
        fileprivate var preservedHelperDeclarations: [String: [SourceUnit]] = [:]
        fileprivate var sdkEnvironmentRejections: [String: (ids: Set<String>, reason: String)] = [:]
        fileprivate(set) var receiverOriginBlocker: String?
        fileprivate(set) var isolationBlocker: String?
        private(set) var evaluationCount = 0
        fileprivate(set) var sharedStateSymbols = Set<String>()
        fileprivate(set) var hasUnprovenCalleeEffects = false

        init(formattingReview: HelperContractEvaluation? = nil) {
            receiverOrigins.formattingReview = formattingReview
        }

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
                    traversal.isolationBlocker = "Recursive helper caller: " + candidate.key
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
                if proof.sdkBindingsSupported {
                    traversal.preservedHelperDeclarations[candidate.key] = [candidate] + (prior.map { [$0] } ?? [])
                }
                pending.append(.finish(proof))
                for (caller, old) in proof.helpers.reversed() { pending.append(.enter(caller, old)) }
            case let .finish(proof):
                let key = proof.unit.key
                let callersProven = proof.helpers.allSatisfy { traversal.completed[$0.0.key] == true }
                let result = traversal.completed[key] != false && callersProven &&
                    finish(proof, current: current, base: base, unownedBase: unownedBase, graph: graph, index: index, traversal: &traversal)
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
              syntax.statements != nil, syntax.calleeEffectsSupported == true, unit.headOnlyBodySupported == true else {
            traversal.isolationBlocker = unit.privateTestHelperBlocker ?? "Missing supported head helper syntax/statements for " + unit.key
            return nil
        }
        if let previous {
            guard previous.headOnlyBodySupported == true, let old = previous.privateTestHelper,
                  old.proofVersion == PrivateTestHelperSyntax.currentProofVersion, old.calleeEffectsSupported == true else {
                traversal.isolationBlocker = previous.privateTestHelperBlocker ?? "Base helper lacks supported nonescaping source/callee evidence: " + previous.key
                return nil
            }
            guard syntax.preservesEffects(of: old) else {
                traversal.isolationBlocker = "Changed helper does not preserve base effect statements: " + previous.key
                return nil
            }
        }
        let missingTests = current.tests.filter { test in
            guard let roots = graph.tests[test], !roots.isEmpty, graph.testDiagnostics[test]?.isEmpty ?? true else { return true }
            return roots.contains { graph.functions[$0] == nil }
        }
        guard missingTests.isEmpty else {
            traversal.isolationBlocker = "Incomplete test/lifecycle compiler roots: " + missingTests.sorted().joined(separator: ", ")
            return nil
        }
        guard Set(current.modules.values).isDisjoint(with: SDKTestHelperSyntax.trustedCallerModules.union(["CoreGraphics"])),
              (Array(current.sources.values) + Array(base.values) + Array(unownedBase.values)).allSatisfy({ $0.helperNamesUnshadowed == true }) else {
            traversal.hasUnprovenCalleeEffects = true
            return nil
        }
        // Imported project operators are already excluded by the source import
        // proof. Within this module, a deleted overload (including a static or
        // conditional one) can silently rebind to Swift at head. Unknown base
        // ownership cannot establish that an operator belongs to another module.
        let module = String(unit.key.prefix { $0 != ":" })
        guard let operators = syntax.effectOperators,
              previous == nil || previous?.privateTestHelper?.effectOperators != nil else {
            traversal.hasUnprovenCalleeEffects = true
            traversal.receiverOriginBlocker = "Missing helper operator binding evidence; refresh source proofs"
            return nil
        }
        let usedOperators = operators.union(previous?.privateTestHelper?.effectOperators ?? [])
        var operatorBindingsSupported = true
        if !usedOperators.isEmpty {
            let sources = current.sources.filter { $0.key.hasPrefix(module + ":") }.map(\.value) +
                base.filter { $0.key.hasPrefix(module + ":") }.map(\.value) + Array(unownedBase.values)
            for source in sources {
                guard source.diagnostics.isEmpty, let declarations = source.helperOperatorDeclarations else {
                    traversal.hasUnprovenCalleeEffects = true
                    traversal.receiverOriginBlocker = source.helperDeclarationsComplete == false
                        ? "Incomplete source operator declarations from macros or unsupported attributes"
                        : "Missing source operator declaration evidence; refresh source proofs"
                    // Keep inspecting compiled effects for a more specific
                    // blocker, but never grant isolation with this inventory.
                    operatorBindingsSupported = false
                    continue
                }
                let rebound = declarations.intersection(usedOperators)
                if !rebound.isEmpty {
                    traversal.hasUnprovenCalleeEffects = true
                    traversal.receiverOriginBlocker = "Unproven helper operator binding at base or head: " + rebound.sorted().joined(separator: ", ")
                    return nil
                }
            }
        }
        if !traversal.callbacksChecked {
            traversal.callbackBlocker = XCTestCallbackIsolation.blocker(current: current, base: base, unownedBase: unownedBase)
            traversal.callbacksChecked = true
        }
        if let reason = traversal.callbackBlocker {
            traversal.receiverOriginBlocker = reason
            traversal.hasUnprovenCalleeEffects = true
            return nil
        }
        guard contextAllows(unit, name: syntax.name, existed: previous != nil, current: current, base: base) else {
            traversal.isolationBlocker = "Unsupported base/head helper accessibility, ownership or type context: " + unit.key
            return nil
        }
        let headUnits = current.sources.values.flatMap(\.units), baseUnits = base.values.flatMap(\.units)
        let ids = symbols(unit, graph: graph, index: index)
        guard !ids.isEmpty else { traversal.isolationBlocker = "Missing compiled helper body: " + unit.key; return nil }
        var callers = headUnits.filter { $0.region.path == unit.region.path && $0.key.hasPrefix(module + ":") &&
            $0.kind == "function" && syntax.callerLines.contains($0.region.startLine) }
        guard callers.count == syntax.callerLines.count else {
            traversal.isolationBlocker = "Missing or ambiguous head source callers at " + unit.region.path + ": " + syntax.callerLines.sorted().map(String.init).joined(separator: ", ")
            return nil
        }
        if let previous, let oldSyntax = previous.privateTestHelper {
            let oldCallers = baseUnits.filter { $0.region.path == previous.region.path && $0.key.hasPrefix(module + ":") &&
                $0.kind == "function" && oldSyntax.callerLines.contains($0.region.startLine) }
            guard oldCallers.count == oldSyntax.callerLines.count else {
                traversal.isolationBlocker = "Missing or ambiguous base source callers at " + previous.region.path + ": " + oldSyntax.callerLines.sorted().map(String.init).joined(separator: ", ")
                return nil
            }
            // Changed/deleted headers have no historical graph proof. Even old
            // callers which stopped calling the helper must survive as entries.
            for old in oldCallers {
                let surviving = headUnits.filter { $0.key == old.key && $0.region.path == old.region.path }
                guard surviving.count == 1 else { traversal.isolationBlocker = "Removed or ambiguous base caller: " + old.key; return nil }
                callers += surviving
            }
        }
        callers = Dictionary(grouping: callers, by: \.key).values.compactMap(\.first)
        var helpers: [(SourceUnit, SourceUnit)] = []
        for caller in callers {
            guard caller.headOnlyBodySupported == true else { traversal.isolationBlocker = "Unsupported caller attributes/body: " + caller.key; return nil }
            if XcodeFineSelector.isTestEntry(caller, in: current) { continue }
            let old = baseUnits.filter { $0.key == caller.key && $0.region.path == caller.region.path }
            // Only unchanged intermediate helpers may extend the inbound proof.
            // In particular, a head graph says nothing about removed old effects.
            guard old.count == 1, let prior = old.first,
                  caller.privateTestHelper?.statements?.map(\.signature) == prior.privateTestHelper?.statements?.map(\.signature) else {
                traversal.isolationBlocker = "Missing, changed or ambiguous intermediate base helper: " + caller.key
                return nil
            }
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
            let environmentBlocker = SDKTestHelperIsolation.environmentBlocker(current: current, base: base, unownedBase: unownedBase, queriedMembers: queries)
            let environmentSupported = environmentBlocker == nil
            let supportedIDs = supported.reduce(into: Set<String>()) { $0.formUnion(symbols($1, graph: graph, index: index)) }
            if let environmentBlocker { traversal.sdkEnvironmentRejections[module] = (supportedIDs, environmentBlocker) }
            traversal.sdkEffectIDs[module] = environmentSupported ? supportedIDs : []
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
        // A macro in another source can synthesize globals, SDK members or
        // XCTest callbacks without spelling their names in the source. Audit
        // every source used by those binding checks, including base-only files.
        // Continue the compiler effect walk to retain more specific diagnostics.
        let incompleteInventories = HelperDeclarationInventory.boundaries(current: current.sources, base: base, unownedBase: unownedBase)
        let declarationsComplete = incompleteInventories.isEmpty
        if !declarationsComplete {
            traversal.hasUnprovenCalleeEffects = true
            traversal.receiverOriginBlocker = HelperDeclarationInventory.summary(incompleteInventories)
        }
        var sdkBindingsSupported = declarationsComplete && operatorBindingsSupported
        if !sdkBindings.isEmpty {
            // Preserving the old statements does not preserve their bindings:
            // a removed project initializer/member may now resolve to the SDK.
            let revisions = [Array(current.sources.values), Array(base.values) + Array(unownedBase.values)]
            let owners: Set<String> = ["XCTAttachment", "XCUIScreenshot", "XCUIElement", "XCUIApplication",
                                       "XCTestCase", "XCTest", "NSObject", "NSObjectProtocol", "XCUIElementQuery",
                                       "NSPredicate", "XCTNSPredicateExpectation", "XCTWaiter", "XCUICoordinate", "CGRect", "CGVector", "CGFloat"]
            // Bare SDK construction cannot dynamically invoke a project
            // subclass's initializer. Ordinary member overrides can, so audit
            // those names even when an alias hides the superclass.
            let dynamicMembers = sdkBindings.subtracting(["init"])
            let bindingBlocker = SDKTestHelperIsolation.memberBindingBlocker(revisions: revisions,
                members: sdkBindings, sdkOwners: owners, provenHelpers: traversal.sdkEffectDeclarations[module] ?? [])
            if let bindingBlocker { traversal.receiverOriginBlocker = bindingBlocker }
            sdkBindingsSupported = sdkBindingsSupported && SDKTestHelperIsolation.overridesUnshadowed(revisions: revisions,
                members: dynamicMembers, sdkReceivers: owners.subtracting(["NSObject", "NSObjectProtocol"])) &&
                bindingBlocker == nil
            // Still walk the head's compiler effects so existing shared-state
            // diagnostics survive even when the historical binding is unproven.
            if !sdkBindingsSupported { traversal.hasUnprovenCalleeEffects = true }
        }
        let effectIDs = effectUnits.reduce(into: traversal.sdkEffectIDs[module] ?? []) { $0.formUnion(symbols($1, graph: graph, index: index)) }
        return Prepared(unit: unit, syntax: syntax, ids: ids, effectIDs: effectIDs, sdkBindingsSupported: sdkBindingsSupported, callers: callers, helpers: helpers)
    }

    private static func finish(_ proof: Prepared, current: XcodeTestGraph, base: [String: SwiftSourceSnapshot],
                               unownedBase: [String: SwiftSourceSnapshot], graph: DependencyGraph,
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
              }) else {
            traversal.isolationBlocker = "Source/compiler caller mismatch for " + proof.unit.key + "; unexpected compiler consumers: " + consumers.subtracting(expectedTests).sorted().joined(separator: ", ") + "; each source caller requires a surviving compiled edge"
            return false
        }
        // Reject compiler-observed state/pointer effects in project callees too,
        // including extension helpers reached from the changed body. SDK runtime
        // uncertainty alone is not a route into this private, nonescaping method.
        let projectModules = Set(current.modules.values)
        var pending = Array(ids), visited = Set<String>(), effectsSupported = proof.sdkBindingsSupported
        var external = Set<String>()
        while let id = pending.popLast() {
            guard visited.insert(id).inserted else { continue }
            guard let node = graph.functions[id], projectModules.contains(node.module), node.hasProjectRuntimeContext else {
                external.insert(id)
                continue
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
                if let rejection = traversal.sdkEnvironmentRejections[node.module], rejection.ids.contains(id) {
                    traversal.receiverOriginBlocker = rejection.reason
                }
                traversal.hasUnprovenCalleeEffects = true
                effectsSupported = false
            }
            if !ExternalHelperEffects.allowsDynamicCalls(node, sourceCallShapes: syntax.sdkCallShapes) {
                traversal.hasUnprovenCalleeEffects = true
                effectsSupported = false
            }
            pending += node.dependencies
        }
        let unprovenExternal = traversal.externalEffects.unprovenEffects(external)
        if !unprovenExternal.isEmpty {
            traversal.receiverOriginBlocker = "Unproven external helper effects: " + unprovenExternal.sorted().joined(separator: ", ")
            traversal.hasUnprovenCalleeEffects = true
            effectsSupported = false
        }
        // Opaque caller/lifecycle code can register XCTest callbacks even for
        // assertion-only helpers that never touch an XCUIElement receiver.
        if let reason = traversal.receiverOrigins.blocker(tests: consumers, current: current, graph: graph) {
            traversal.receiverOriginBlocker = reason
            traversal.hasUnprovenCalleeEffects = true
            effectsSupported = false
        } else if effectsSupported, let reason = historicalCallerBindingBlocker(
            units: traversal.receiverOrigins.checkedSourceUnits(for: consumers), current: current, base: base,
            unownedBase: unownedBase, provenHelpers: traversal.sdkEffectDeclarations.values.flatMap { $0 } +
                traversal.preservedHelperDeclarations.values.flatMap { $0 }) {
            traversal.receiverOriginBlocker = reason
            traversal.hasUnprovenCalleeEffects = true
            effectsSupported = false
        }
        return effectsSupported
    }

    private static func historicalCallerBindingBlocker(units: [SourceUnit]?, current: XcodeTestGraph,
        base: [String: SwiftSourceSnapshot], unownedBase: [String: SwiftSourceSnapshot], provenHelpers: [SourceUnit]) -> String? {
        guard let units, !units.isEmpty else { return "Missing compiler-bound caller source evidence" }
        let checkedModules = Set(units.map { String($0.key.prefix { $0 != ":" }) })
        let oldSources = Array(base.values) + Array(unownedBase.values)
        let oldUnits = oldSources.flatMap(\.units)
        var allUnits = units
        for unit in units {
            let module = String(unit.key.prefix { $0 != ":" })
            // Match by header even after a source move. State-unit keys include
            // their initializers, so include historical storage at this owner.
            // Synthesized initializers can point only at the class header.
            let historical = oldUnits.filter { old in
                // Removed files have an empty module, not their former owner.
                // They may supply this declaration; absence of ownership is
                // not evidence that their historical expressions are unrelated.
                old.key == unit.key || (old.key.hasPrefix(":") && old.key == String(unit.key.dropFirst(module.count))) ||
                    ((old.key.hasPrefix(module + ":") || old.key.hasPrefix(":")) && old.scope == unit.scope &&
                    (["state", "type"].contains(unit.kind) && old.kind == "state" ||
                     unit.kind == "type" && old.helperCallableName.map(SDKTestHelperSyntax.lifecycle.contains) == true))
            }
            for old in historical where old.kind == "function" {
                // Binding names alone say nothing about an SDK effect removed
                // from a caller. Only unchanged statements at the start of the
                // current body retain their execution and lexical context. The
                // helper-specific proof separately permits inserted assertions.
                let preservedHelper = provenHelpers.contains {
                    $0.key == old.key && $0.region.path == old.region.path && $0.fingerprint == old.fingerprint
                }
                let counterparts = units.filter { checked in
                    checked.key == old.key || (old.key.hasPrefix(":") &&
                        old.key == String(checked.key.drop(while: { $0 != ":" })))
                }
                let preservedCaller = counterparts.count == 1 && counterparts.allSatisfy { checked in
                    if checked.fingerprint == old.fingerprint { return true }
                    guard let prior = old.helperCallerStatementSignatures,
                          let head = checked.helperCallerStatementSignatures else { return false }
                    return head.starts(with: prior)
                }
                guard preservedHelper || preservedCaller else {
                    let boundary = old.helperCallableName.map(SDKTestHelperSyntax.lifecycle.contains) == true
                        ? "lifecycle implementation" : "body effects"
                    return "Unproven historical caller " + boundary + " at " + old.region.path + ":" + String(old.region.startLine)
                }
            }
            allUnits += historical
        }
        var operatorsByModule: [String: Set<String>] = [:], globalsByModule: [String: Set<String>] = [:], members = Set<String>()
        for unit in allUnits {
            guard unit.helperRegionEffectsComplete == true else {
                return "Unproven or missing historical caller declaration-body effects at " + unit.region.path + ":" + String(unit.region.startLine)
            }
            // Identical body text can bind to a different external overload
            // after an import changes. Only the head has compiler evidence.
            guard unit.receiverImportsSupported == true else {
                return "Unproven historical caller imports at " + unit.region.path + ":" + String(unit.region.startLine)
            }
            guard let uses = unit.helperBindingUses, let qualified = uses.qualifiedMembers,
                  let implicitOperators = uses.implicitOperators else {
                return "Missing historical caller expression bindings; refresh source proofs"
            }
            let module = String(unit.key.prefix { $0 != ":" })
            // Unknown ownership must consider every checked module's bindings.
            for candidate in module.isEmpty ? checkedModules : [module] {
                operatorsByModule[candidate, default: []].formUnion(uses.operators)
                operatorsByModule[candidate, default: []].formUnion(implicitOperators)
                globalsByModule[candidate, default: []].formUnion(uses.globals)
                // UI.produce and UI.Worker are module globals/type roots, even
                // though SwiftSyntax represents them as member references.
                globalsByModule[candidate, default: []].formUnion(qualified[SDKTestHelperSyntax.canonicalName(candidate)] ?? [])
            }
            members.formUnion(uses.members)
            // Bare references can be getters or method values as well as
            // globals/locals. The head compiler cannot resolve their old binding.
            members.formUnion(uses.globals)
            guard let calls = unit.invocationNames else { return "Missing historical caller invocation names; refresh source proofs" }
            // Bare calls may resolve to members, rather than global functions.
            members.formUnion(calls)
        }
        for (module, operators) in operatorsByModule.sorted(by: { $0.key < $1.key }) where !operators.isEmpty {
            let sources = current.sources.filter { $0.key.hasPrefix(module + ":") }.map(\.value) +
                base.filter { $0.key.hasPrefix(module + ":") }.map(\.value) + Array(unownedBase.values)
            for source in sources {
                guard let declarations = source.helperOperatorDeclarations else { return "Missing historical caller operator declarations; refresh source proofs" }
                let rebound = declarations.intersection(operators)
                if !rebound.isEmpty { return "Unproven caller operator binding at base or head: " + rebound.sorted().joined(separator: ", ") }
            }
        }
        for (module, names) in globalsByModule.sorted(by: { $0.key < $1.key }) {
            let sources = current.sources.filter { $0.key.hasPrefix(module + ":") }.map(\.value) +
                base.filter { $0.key.hasPrefix(module + ":") }.map(\.value) + Array(unownedBase.values)
            for source in sources {
                // @_exported imports make names visible in other files of this
                // module. File-local import proofs cannot close that boundary.
                guard source.helperImportsLocal == true else {
                    return "Unproven module-wide caller imports or missing visibility evidence; refresh source proofs"
                }
                guard let declarations = source.helperGlobalDeclarations else { return "Missing historical caller global declarations; refresh source proofs" }
                for name in Set(declarations.keys).intersection(names).sorted() {
                    // Ordinary source producers are valid only when their exact
                    // bodies occur in the compiler-checked closure. A base-only
                    // overload or changed old body has no such head evidence.
                    let functions = source.units.filter { $0.scope.isEmpty && $0.helperCallableName == name }
                    guard declarations[name] == true, !functions.isEmpty, functions.allSatisfy({ declaration in units.contains {
                        $0.key == declaration.key && $0.fingerprint == declaration.fingerprint
                    } }) else { return "Unproven caller global binding at base or head: " + name }
                }
            }
        }
        let revisions = [Array(current.sources.values), oldSources]
        let knownModules = Set(revisions.joined().flatMap(\.units).map {
            SDKTestHelperSyntax.canonicalName(String($0.key.prefix { $0 != ":" }))
        }).subtracting([""])
        var ownerNames: [String: String] = [:]
        func ownerName(_ unit: SourceUnit) -> String {
            let spelling = String(unit.key.prefix { $0 != ":" }) + ":" + unit.scope
            if let cached = ownerNames[spelling] { return cached }
            let module = SDKTestHelperSyntax.canonicalName(String(unit.key.prefix { $0 != ":" }))
            var scope = SDKTestHelperSyntax.canonicalName(SwiftSourceSnapshot.nominalTypeName(unit.scope) ?? unit.scope)
            // Extension scopes retain their source spelling. A module-qualified
            // scope must join the same audit as the nominal declaration. For
            // unowned base files consider every known module qualification.
            if !module.isEmpty, scope.hasPrefix(module + ".") { scope = String(scope.dropFirst(module.count + 1)) }
            else if module.isEmpty, let qualifier = knownModules.first(where: { scope.hasPrefix($0 + ".") }) {
                scope = String(scope.dropFirst(qualifier.count + 1))
            }
            let owner = module + "." + scope
            ownerNames[spelling] = owner
            return owner
        }
        var auditedOwners = Set(units.filter { !$0.scope.isEmpty }.map(ownerName))
        // A receiver construction can disappear at head. Include project type
        // roots mentioned in either revision, even without a current callee.
        for source in revisions.joined() {
            for type in source.units where type.kind == "type" {
                let module = String(type.key.prefix { $0 != ":" })
                let root = SDKTestHelperSyntax.canonicalName(String(type.scope.split(separator: ".").first ?? ""))
                let leaf = SDKTestHelperSyntax.canonicalName(String(type.scope.split(separator: ".").last ?? ""))
                // Nested types may be referenced lexically or through Self,
                // without spelling their enclosing type or module at all.
                let referenced = globalsByModule[module] ?? []
                let unknownOwner = module.isEmpty && (globalsByModule.values.contains { $0.contains(root) || $0.contains(leaf) } ||
                    members.contains(leaf) ||
                    auditedOwners.contains { $0.hasSuffix("." + SDKTestHelperSyntax.canonicalName(type.scope)) })
                if referenced.contains(root) || referenced.contains(leaf) ||
                    checkedModules.contains(module) && members.contains(leaf) || unknownOwner {
                    auditedOwners.insert(ownerName(type))
                }
            }
        }
        // Follow both superclass and protocol/default-implementation owners.
        // The head closure cannot name a removed ancestor or a default witness
        // displaced by an explicit implementation. Ambiguous names widen proof.
        let typeUnits = revisions.joined().flatMap(\.units).filter { ["type", "extension"].contains($0.kind) }
        // Aliases can hide an extension target, an inherited protocol, or a
        // namespace containing either. Their targets are not resolved here;
        // matching any path component therefore leaves default witnesses opaque.
        let aliases = Set(revisions.joined().flatMap { $0.typeAliases ?? [] }.map(SDKTestHelperSyntax.canonicalName))
        let aliasNames = Set(aliases.compactMap { $0.split(separator: ".").last.map(String.init) })
        func usesAlias(_ name: String) -> Bool {
            name.split(separator: ".").contains { aliasNames.contains(String($0)) }
        }
        let aliasedExtensions = typeUnits.filter { declaration in
            guard declaration.kind == "extension" else { return false }
            let scope = SDKTestHelperSyntax.canonicalName(SwiftSourceSnapshot.nominalTypeName(declaration.scope) ?? declaration.scope)
            return usesAlias(scope)
        }
        if let declaration = aliasedExtensions.first(where: { $0.helperInheritedTypes?.isEmpty != true }) {
            return "Unproven historical caller extension through a type alias at " + declaration.region.path + ":" + String(declaration.region.startLine)
        }
        let typeOwners = Set(typeUnits.map(ownerName))
        let classOwners = Set(Dictionary(grouping: typeUnits.filter { $0.kind == "type" }, by: ownerName).compactMap { owner, declarations in
            declarations.allSatisfy { $0.fingerprint.hasPrefix("classDecl[") } ? owner : nil
        })
        let sdkClasses: Set<String> = ["XCTestCase", "XCTest.XCTestCase", "NSObject", "Foundation.NSObject"]
        var conformingOwners = Set<String>(), parentOwners: [String: Set<String>] = [:]
        var pendingOwners = Array(auditedOwners), visitedOwners = Set<String>()
        while let owner = pendingOwners.popLast() {
            guard visitedOwners.insert(owner).inserted else { continue }
            // A removed extension can lose ownership independently of its
            // nominal type, including an ancestor discovered during this walk.
            for candidate in typeOwners where candidate != owner &&
                (candidate.hasPrefix(".") && owner.hasSuffix(candidate) ||
                 owner.hasPrefix(".") && candidate.hasSuffix(owner)) {
                if auditedOwners.insert(candidate).inserted { pendingOwners.append(candidate) }
            }
            for source in revisions.joined() {
                for declaration in source.units where ["type", "extension"].contains(declaration.kind) && ownerName(declaration) == owner {
                    let isClass = declaration.fingerprint.hasPrefix("classDecl[")
                    if isClass, source.superclasses?.first(where: {
                        SDKTestHelperSyntax.canonicalName($0.key) == owner ||
                            SDKTestHelperSyntax.canonicalName($0.key) == String(declaration.key.prefix { $0 != ":" }) + "." + SDKTestHelperSyntax.canonicalName(declaration.scope)
                    }) == nil {
                        return "Missing historical caller superclass evidence; refresh source proofs"
                    }
                    guard let parents = declaration.helperInheritedTypes else {
                        return "Missing historical caller conformance evidence; refresh source proofs"
                    }
                    // `protocol P where Self: Q` also supplies Q's defaults.
                    // Conditional and same-type requirements need resolution
                    // beyond the nominal ancestry inventory, at both revisions.
                    guard declaration.helperGenericRequirements?.isEmpty == true else {
                        return "Unproven or missing historical caller generic requirements at " + declaration.region.path + ":" + String(declaration.region.startLine)
                    }
                    for parent in parents {
                        guard let nominal = SwiftSourceSnapshot.nominalTypeName(parent) else {
                            return "Unproven historical caller inherited type: " + parent
                        }
                        let name = SDKTestHelperSyntax.canonicalName(nominal)
                        guard !usesAlias(name) else {
                            return "Unproven historical caller inherited type alias: " + parent
                        }
                        let candidates = typeOwners.filter { $0 == name || $0.hasSuffix("." + name) }
                        // A class's known superclass does not supply protocol
                        // defaults. Imported protocols still require checking
                        // every project witness on their conforming owner.
                        if !isClass || (!sdkClasses.contains(name) &&
                            (candidates.isEmpty || !candidates.isSubset(of: classOwners))) {
                            conformingOwners.insert(owner)
                        }
                        parentOwners[owner, default: []].formUnion(candidates)
                        for ancestor in candidates {
                            if auditedOwners.insert(ancestor).inserted { pendingOwners.append(ancestor) }
                        }
                    }
                }
            }
        }
        // Even without an inheritance clause an aliased extension can supply
        // defaults or witnesses for any participating conformance. If there is
        // none, ordinary member binding checks can still prove unused extensions.
        if !conformingOwners.isEmpty, let declaration = aliasedExtensions.first {
            return "Unproven historical caller extension through a type alias at " + declaration.region.path + ":" + String(declaration.region.startLine)
        }
        // Overrides on descendants can supply a conformance inherited from a
        // source superclass or protocol, including one removed at head.
        var expanded = true
        while expanded {
            expanded = false
            for (owner, parents) in parentOwners where !parents.isDisjoint(with: conformingOwners) {
                if conformingOwners.insert(owner).inserted { expanded = true }
            }
        }
        // Synthesized initializers have no explicit member declaration. Their
        // historical stored-property initializers must independently match the
        // head body. SIL may locate a synthesized initializer only at its type
        // header; that evidence is usable only while both revisions still have
        // synthesized construction, without a competing explicit initializer.
        let headUnits = current.sources.values.flatMap(\.units)
        func storedInitializerIsProven(_ old: SourceUnit) -> Bool {
            guard old.helperRegionEffectsComplete == true else { return false }
            if units.contains(where: { $0.key == old.key && $0.fingerprint == old.fingerprint }) { return true }
            guard old.helperStoredInitializer == true else { return false }
            let module = String(old.key.prefix { $0 != ":" })
            func sameOwner(_ unit: SourceUnit) -> Bool {
                unit.key.hasPrefix(module + ":") && ownerName(unit) == ownerName(old)
            }
            guard headUnits.contains(where: { $0.key == old.key && $0.fingerprint == old.fingerprint }),
                  units.contains(where: { sameOwner($0) && $0.kind == "type" }),
                  !(headUnits + oldUnits).contains(where: {
                      sameOwner($0) && $0.helperDeclaredMembers?.contains("init") == true
                  }) else { return false }
            return true
        }
        for (revision, sources) in revisions.enumerated() {
            for unit in sources.flatMap(\.units) {
                let owner = ownerName(unit)
                guard auditedOwners.contains(owner) else { continue }
                // Changed ancestry can also lead to an imported or aliased
                // superclass without an auditable project body. Authenticate
                // the header itself rather than trusting the head's ancestry.
                if revision == 1, ["type", "extension"].contains(unit.kind),
                   (unit.fingerprint.hasPrefix("classDecl[") || conformingOwners.contains(owner)),
                   !headUnits.contains(where: { $0.key == unit.key && $0.fingerprint == unit.fingerprint }) {
                    return "Unproven historical caller type or conformance header at " + unit.region.path + ":" + String(unit.region.startLine)
                }
                // XCTest invokes lifecycle hooks without spelling their names
                // in a caller. Reading their old bindings does not prove an old
                // body whose direct SDK effects disappeared from the head graph.
                // Constructors, destructors and lifecycle properties are not
                // FunctionDeclSyntax, but also execute implicitly.
                guard let declarations = unit.helperDeclaredMembers else {
                    return "Missing historical caller member declaration evidence; refresh source proofs"
                }
                // A default implementation can invoke any requirement without
                // its name appearing at the call site (isEmpty, first, iteration,
                // formatting, etc.). With no base compiler, every source member
                // of a participating historical conformance needs exact head
                // closure evidence. An unchanged spelling is not an effect proof.
                if revision == 1, conformingOwners.contains(owner), !declarations.isEmpty,
                   unit.bodylessProtocolRequirement == nil,
                   !(unit.fingerprint.hasPrefix("typeAliasDecl[") &&
                     headUnits.contains { $0.key == unit.key && $0.fingerprint == unit.fingerprint }),
                   !(unit.helperEnumCaseWithoutDefaults == true && unit.helperEnumCaseValueArguments == true &&
                     headUnits.contains { $0.key == unit.key && $0.fingerprint == unit.fingerprint }),
                   !storedInitializerIsProven(unit) {
                    return "Unproven historical caller conformance implementation at " + unit.region.path + ":" + String(unit.region.startLine)
                }
                if !declarations.isDisjoint(with: SDKTestHelperSyntax.lifecycle.union(["init", "deinit"])),
                   !units.contains(where: { $0.key == unit.key && $0.fingerprint == unit.fingerprint }) {
                    return "Unproven historical caller lifecycle implementation at " + unit.region.path + ":" + String(unit.region.startLine)
                }
                guard unit.kind == "state" else { continue }
                guard let initialized = unit.helperStoredInitializer else {
                    return "Missing historical caller storage initializer evidence; refresh source proofs"
                }
                if revision == 1, initialized, !storedInitializerIsProven(unit) {
                    return "Unproven historical caller storage initializer at " + unit.region.path + ":" + String(unit.region.startLine)
                }
            }
        }
        let historicalDeclarations = oldUnits.filter { old in units.contains {
            $0.key == old.key && $0.fingerprint == old.fingerprint
        } }
        let proven = provenHelpers + units + historicalDeclarations
        let owners = SDKReceiverContracts.bindingNames.union(["NSObject", "NSObjectProtocol", "XCTest", "XCUIElementQuery", "XCUICoordinate", "CGRect", "CGVector"])
        // The dispatch inventories keep raw source scopes. Preserve those
        // aliases too when passing normalized owners into their binding audit.
        let dispatchOwners = auditedOwners.union(revisions.joined().flatMap(\.units).filter {
            auditedOwners.contains(ownerName($0))
        }.map { SDKTestHelperSyntax.canonicalName(String($0.key.prefix { $0 != ":" }) + "." + $0.scope) })
        if let reason = SDKTestHelperIsolation.memberBindingBlocker(revisions: revisions, members: members,
            sdkOwners: owners, provenHelpers: proven, auditedProjectOwners: dispatchOwners) { return "Caller expression: " + reason }
        guard SDKTestHelperIsolation.overridesUnshadowed(revisions: revisions, members: members.subtracting(["init"]),
            sdkReceivers: owners.subtracting(["NSObject", "NSObjectProtocol", "XCTest"]), provenMethods: proven) else { return "Unproven historical caller member override" }
        return nil
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

    static func isXCTestHelper(_ unit: SourceUnit, current: XcodeTestGraph) -> Bool {
        let module = String(unit.key.prefix { $0 != ":" })
        let owners = current.targets.filter { $0.sourceFiles.contains(unit.region.path) }
        guard !owners.isEmpty, owners.allSatisfy({ $0.isTest && !$0.hasProductionRole && current.modules[$0.name] == module }) else { return false }
        return safeHierarchy(unit.scope, module: module,
            sources: current.sources.filter { $0.key.hasPrefix(module + ":") }.map(\.value))
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
        let headUnits = headSources.flatMap(\.units)
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
              extensionsSupported(owner: unit.scope, module: module, revisions: [moduleSources, oldModuleSources]),
              Set(headUnits.filter { $0.kind == "function" && $0.region.intersects(unit.region) }.map(\.key)) == [unit.key] else { return false }
        return true
    }

    /// Empty extension headers are containers, not callable declarations. Their
    /// multiplicity has no effect, provided the owner is a unique existing final
    /// XCTest class and every extension is unconditional and unadorned.
    static func provesExtensionHeaders(_ units: [SourceUnit], current: XcodeTestGraph,
                                       base: [String: SwiftSourceSnapshot]) -> Bool {
        guard let unit = units.first, units.allSatisfy({ $0.kind == "extension" && $0.plainExtension == true && $0.scope == unit.scope }) else { return false }
        let module = String(unit.key.prefix { $0 != ":" })
        let revisions = [current.sources, base].map { sources in
            sources.filter { $0.key.hasPrefix(module + ":") }.map(\.value)
        }
        return extensionsSupported(owner: unit.scope, module: module, revisions: revisions)
    }

    private static func extensionsSupported(owner: String, module: String, revisions: [[SwiftSourceSnapshot]]) -> Bool {
        for sources in revisions {
            let units = sources.flatMap(\.units)
            let extensions = units.filter { $0.kind == "extension" && [$0.scope, module + "." + $0.scope].contains(module + "." + owner) }
            guard extensions.allSatisfy({ $0.plainExtension == true }) else { return false }
            // With no extensions, retain the existing class-body proof. An
            // extension requires explicit finality and unambiguous ancestry.
            if !extensions.isEmpty || revisions.contains(where: { $0.flatMap(\.units).contains { $0.kind == "extension" && $0.scope == owner } }) {
                let classes = units.filter { $0.kind == "type" && $0.scope == owner }
                guard classes.count == 1, sources.compactMap({ $0.classFinality?[owner] }) == [true],
                      safeHierarchy(owner, module: module, sources: sources) else { return false }
            }
        }
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
