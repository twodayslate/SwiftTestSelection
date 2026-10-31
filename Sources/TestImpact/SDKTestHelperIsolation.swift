// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation

/// A closed caller proof for an internal Swift SDK extension plus a small,
/// trusted XCTest query/expectation effect contract at both source revisions.
enum SDKTestHelperIsolation {
    static func blocker(_ unit: SourceUnit, previous: SourceUnit?, current: XcodeTestGraph,
                        base: [String: SwiftSourceSnapshot], graph: DependencyGraph, index: DependencyIndex,
                        unownedBase: [String: SwiftSourceSnapshot] = [:], formattingReview: HelperContractEvaluation? = nil) -> String? {
        guard let evidence = unit.sdkTestHelper, let old = previous?.sdkTestHelper,
              evidence.version == SDKTestHelperSyntax.currentVersion, old.version == evidence.version else { return "Missing supported base/head SDK helper evidence; recapture the head graph" }
        if let reason = evidence.blocker ?? old.blocker { return reason }
        guard previous?.key == unit.key, previous?.region.path == unit.region.path,
              unit.headOnlyBodySupported == true, previous?.headOnlyBodySupported == true else { return "Changed header, ownership or unsupported attributes/macros" }
        guard Set(current.modules.values).isDisjoint(with: SDKTestHelperSyntax.trustedCallerModules) else { return "Project module shadows a trusted SDK module" }
        let module = String(unit.key.prefix { $0 != ":" })
        let owners = current.targets.filter { $0.sourceFiles.contains(unit.region.path) }
        guard !owners.isEmpty, owners.allSatisfy({ $0.isTest && !$0.hasProductionRole && current.modules[$0.name] == module }),
              current.unsupportedSourceInputs?[module]?.isEmpty ?? true, current.unresolvedProductRoles?[module] == nil else { return "Unresolved test-only ownership or unsupported source inputs" }
        guard current.tests.allSatisfy({ test in
            guard let roots = graph.tests[test], !roots.isEmpty, graph.testDiagnostics[test]?.isEmpty ?? true else { return false }
            return roots.allSatisfy { graph.functions[$0] != nil }
        }) else { return "Incomplete test or lifecycle bindings" }
        let headSources = current.sources.filter { $0.key.hasPrefix(module + ":") }
        let baseSources = base.filter { $0.key.hasPrefix(module + ":") }
        let captured = Set(headSources.keys.map { String($0.dropFirst(module.count + 1)) })
        guard current.targets.filter({ current.modules[$0.name] == module }).allSatisfy({ Set($0.sourceFiles).isSubset(of: captured) }),
              Set(headSources.keys) == Set(baseSources.keys) else { return "Missing base/head module sources" }
        if let reason = XCTestCallbackIsolation.blocker(current: current, base: base, unownedBase: unownedBase) { return reason }
        if let reason = environmentBlocker(current: current, base: base, unownedBase: unownedBase,
                                           queriedMembers: evidence.queriedMembers.union(old.queriedMembers)) { return reason }
        if let reason = effectBindingBlocker(unit, previous: previous, current: current, base: base, unownedBase: unownedBase) { return reason }
        let headReferences = headSources.mapValues { SDKTestHelperSyntax.canonicalReferences($0.helperReferences!) }
        let baseReferences = baseSources.mapValues { SDKTestHelperSyntax.canonicalReferences($0.helperReferences!) }
        let headUnits = headSources.values.flatMap(\.units), oldUnits = baseSources.values.flatMap(\.units)
        let byKey = Dictionary(grouping: headUnits, by: \.key), oldByKey = Dictionary(grouping: oldUnits, by: \.key)
        let headByFile = Dictionary(grouping: headUnits.filter { $0.kind == "function" }, by: { $0.region.path })
        let oldByFile = Dictionary(grouping: oldUnits.filter { $0.kind == "function" }, by: { $0.region.path })
        var symbolCache: [String: Set<String>] = [:]
        func symbols(_ unit: SourceUnit) -> Set<String> {
            if let cached = symbolCache[unit.key] { return cached }
            let result = Set((index.byFile[unit.region.path] ?? []).filter { id in
                graph.functions[id]?.module == module && graph.functions[id]!.regions.contains {
                    $0.path == unit.region.path && $0.startLine >= unit.region.startLine && $0.startLine <= unit.region.endLine
                }
            })
            symbolCache[unit.key] = result
            return result
        }
        var testsByRoot: [String: Set<String>] = [:]
        for test in current.tests {
            for root in graph.tests[test] ?? [] { testsByRoot[root, default: []].insert(test) }
        }
        var accepted = Set<String>(), active = Set<String>(), expectedEntries = Set<String>()
        // Explicit enter/finish frames preserve DFS cycle detection without
        // consuming a Swift worker stack frame for every helper in the chain.
        enum Work {
            case enter(SourceUnit)
            case finish(String)
        }
        var pending: [Work] = [.enter(unit)]
        func prepare(_ callee: SourceUnit) -> String? {
            if active.contains(callee.key) { return "Recursive helper callers: \(callee.helperCallableName ?? callee.scope)" }
            if accepted.contains(callee.key) { return nil }
            guard let name = callee.helperCallableName, callee.helperCallerSupported == true, callee.headOnlyBodySupported == true,
                  byKey[callee.key]?.count == 1, let prior = oldByKey[callee.key], prior.count == 1,
                  prior[0].helperCallerSupported == true, prior[0].headOnlyBodySupported == true else { return "Unsupported/dynamic/lifecycle caller or removed base declaration: \(callee.region.path):\(callee.region.startLine)" }
            if !callee.scope.isEmpty && !["XCUIElement", "XCTest.XCUIElement"].contains(callee.scope) {
                guard PrivateTestHelperIsolation.safeHierarchy(callee.scope, module: module, sources: Array(headSources.values)),
                      PrivateTestHelperIsolation.safeHierarchy(callee.scope, module: module, sources: Array(baseSources.values)) else { return "Unresolved or dynamically exposed XCTest helper hierarchy: \(callee.scope)" }
            }
            guard current.sources.filter({ !$0.key.hasPrefix(module + ":") }).values.allSatisfy({ $0.identifierNames?.contains(name) == false }),
                  base.filter({ !$0.key.hasPrefix(module + ":") }).values.allSatisfy({ $0.identifierNames?.contains(name) == false }) else { return "Helper name is referenced outside the owning test module: \(name)" }
            for (path, snapshot) in unownedBase.sorted(by: { $0.key < $1.key }) {
                guard let names = snapshot.identifierNames, !names.contains(name) else {
                    return "Base source outside the head inventory may reference \(name); ownership/callers are unresolved: \(path)"
                }
            }
            let ids = symbols(callee)
            guard !ids.isEmpty else { return "Missing compiled helper: \(name)" }
            let paths = index.paths(to: ids)
            active.insert(callee.key)
            var callerKeys = Set<String>()
            for (referencesByFile, units) in [(headReferences, headByFile), (baseReferences, oldByFile)] {
                var declarations = 0
                for (key, references) in referencesByFile {
                    let allUses = references[SDKTestHelperSyntax.canonicalName(name)]
                    if allUses?.untrustedWrapperImports == true {
                        return "Unresolved assertion/operator binding from untrusted caller imports in \(key) at lines \(allUses!.unsupportedLines.sorted())"
                    }
                    if allUses?.unsupported == true {
                        return "Escaping, stored, nested or unresolved reference to \(name) in \(key) at lines \(allUses!.unsupportedLines.sorted())"
                    }
                    guard let uses = references[SDKTestHelperSyntax.canonicalName(callee.helperReferenceSignature ?? name)] else { continue }
                    declarations += uses.declarations.count
                    guard !uses.unsupported else { return "Escaping, stored, nested or unresolved reference to \(name) in \(key) at lines \(uses.unsupportedLines.sorted())" }
                    let path = String(key.dropFirst(module.count + 1))
                    for line in uses.callers {
                        let matches = (units[path] ?? []).filter { $0.region.startLine == line }
                        guard matches.count == 1, let caller = matches.first,
                              let surviving = byKey[caller.key], surviving.count == 1,
                              surviving[0].region.path == path else { return "Removed or ambiguous caller of \(name): \(path):\(line) (matches=\(matches.count))" }
                        guard paths.path(from: symbols(surviving[0])) != nil else { return "Missing head edge for a base/head caller of \(name): \(path):\(line)" }
                        callerKeys.insert(caller.key)
                    }
                }
                guard declarations == 1 else { return "Ambiguous declaration/overload for \(name)" }
            }
            guard !callerKeys.isEmpty else { return "No source-bound test consumers for \(name)" }
            var helpers: [SourceUnit] = []
            for key in callerKeys.sorted() {
                let caller = byKey[key]![0]
                if XcodeFineSelector.isTestEntry(caller, in: current) {
                    guard caller.headOnlyBodySupported == true else { return "Unsupported test entry attributes" }
                    for id in symbols(caller) { expectedEntries.formUnion(testsByRoot[id] ?? []) }
                    accepted.insert(caller.key)
                } else { helpers.append(caller) }
            }
            pending.append(.finish(callee.key))
            for caller in helpers.reversed() { pending.append(.enter(caller)) }
            return nil
        }
        while let work = pending.popLast() {
            switch work {
            case let .enter(callee):
                if let failure = prepare(callee) { return failure }
            case let .finish(key):
                active.remove(key)
                accepted.insert(key)
            }
        }
        let paths = index.paths(to: symbols(unit))
        let consumers = Set(current.tests.filter { paths.path(from: graph.tests[$0] ?? []) != nil })
        guard !consumers.isEmpty, consumers.isSubset(of: expectedEntries) else { return "Compiler consumers outside the verified source caller graph" }
        // Check all compiler callers, not just one selected explanation path.
        for offset in index.symbols.indices where paths.distance[offset] >= 0 {
            let id = index.symbols[offset]
            guard let node = graph.functions[id], node.module == module else { return "Unknown or cross-module compiler caller" }
            let units = headUnits.filter { unit in unit.kind == "function" && node.regions.contains { region in
                region.path == unit.region.path && region.startLine >= unit.region.startLine && region.startLine <= unit.region.endLine
            } }
            guard !units.isEmpty, units.allSatisfy({ accepted.contains($0.key) }) else { return "Compiler caller has no verified source owner: \(node.name)" }
        }
        var receiverOrigins = SDKReceiverOrigins()
        receiverOrigins.formattingReview = formattingReview
        if let reason = receiverOrigins.blocker(tests: consumers, current: current, graph: graph) {
            return "Unproven SDK receiver origin: " + reason
        }
        return compilerEffectBlocker(unit, graph: graph, index: index)
    }

    /// A head binding does not identify its old overload. Reject competing
    /// declarations at either revision, including default/variadic signatures
    /// and declarations removed from the captured head inventory.
    static func effectBindingBlocker(_ unit: SourceUnit, previous: SourceUnit?, current: XcodeTestGraph,
                                     base: [String: SwiftSourceSnapshot],
                                     unownedBase: [String: SwiftSourceSnapshot] = [:]) -> String? {
        guard let name = unit.helperCallableName, let old = previous,
              old.key == unit.key, old.region.path == unit.region.path,
              let evidence = unit.sdkTestHelper, let prior = old.sdkTestHelper,
              evidence.version == SDKTestHelperSyntax.currentVersion, prior.version == evidence.version,
              evidence.blocker == nil, prior.blocker == nil,
              unit.headOnlyBodySupported == true, old.headOnlyBodySupported == true else { return "Missing supported base/head SDK callee effects" }
        for (snapshots, declaration) in [(current.sources, unit), (base, old)] {
            let units = snapshots.values.flatMap(\.units)
            let candidates = units.filter { candidate in
                guard candidate.kind == "function", candidate.helperCallableName.map(SDKTestHelperSyntax.canonicalName) == SDKTestHelperSyntax.canonicalName(name) else { return false }
                guard let a = candidate.helperReferenceSignature, let b = declaration.helperReferenceSignature else { return true }
                return SDKTestHelperSyntax.canonicalName(a) == SDKTestHelperSyntax.canonicalName(b)
            }
            guard candidates.count == 1, candidates[0].key == declaration.key,
                  candidates[0].region.path == declaration.region.path else { return "Ambiguous base/head SDK callee overload: \(name)" }
            let owners = Set(units.filter { $0.kind == "function" && $0.region.intersects(declaration.region) }.map(\.key))
            guard owners == [declaration.key] else { return "Ambiguous SDK callee source region: \(name)" }
        }
        for (path, snapshot) in unownedBase.sorted(by: { $0.key < $1.key }) {
            guard snapshot.identifierNames?.contains(name) == false else {
                return "Base source outside the head inventory may declare SDK callee \(name): \(path)"
            }
        }
        return nil
    }

    /// The read-only syntax language cannot invoke other project functions.
    /// Inspect actual compiler targets so inherited SDK-name overloads cannot
    /// acquire trusted effects merely by spelling waitForExistence, etc.
    static func compilerEffectBlocker(_ unit: SourceUnit, graph: DependencyGraph, index: DependencyIndex) -> String? {
        let module = String(unit.key.prefix { $0 != ":" })
        let ids = Set((index.byFile[unit.region.path] ?? []).filter { id in
            graph.functions[id]?.module == module && graph.functions[id]!.regions.contains {
                $0.path == unit.region.path && $0.startLine >= unit.region.startLine && $0.startLine <= unit.region.endLine
            }
        })
        guard !ids.isEmpty else { return "Missing compiled SDK callee: \(unit.helperCallableName ?? unit.key)" }
        var pending = Array(ids), visited = Set<String>(), external = Set<String>()
        var effects = ExternalHelperEffects()
        while let id = pending.popLast() {
            guard visited.insert(id).inserted else { continue }
            guard let node = graph.functions[id], node.hasProjectRuntimeContext else {
                external.insert(id)
                continue
            }
            if node.hasProjectRuntimeContext {
                guard ids.contains(id) else { return "Project implementation outside the trusted SDK boundary: \(node.name)" }
                if !node.uncertainties.isDisjoint(with: ["Global state access", "Shared state access", "Raw pointer operation"]) {
                    return "Compiler-observed state or pointer effect: \(node.name)"
                }
            }
            guard ExternalHelperEffects.allowsDynamicCalls(node) else {
                return "Unproven dynamic callee effect: \(node.name)"
            }
            pending += node.dependencies
        }
        guard effects.allows(external) else { return "Unproven external SDK-helper callee effects" }
        return nil
    }

    /// Shared effect boundary for changed SDK helpers and SDK callees reached
    /// from private helpers; caller closure is a separate proof.
    static func environmentBlocker(current: XcodeTestGraph, base: [String: SwiftSourceSnapshot],
                                   unownedBase: [String: SwiftSourceSnapshot] = [:], queriedMembers: Set<String>) -> String? {
        guard Set(current.modules.values).isDisjoint(with: SDKTestHelperSyntax.trustedCallerModules) else { return "Project module shadows a trusted SDK module" }
        // Source snapshots (including saved captures) preserve backticks in
        // declaration spelling. Compare semantic names without altering source
        // fingerprints or requiring a fresh capture.
        let canonicalName = SDKTestHelperSyntax.canonicalName
        let queriedMembers = Set(queriedMembers.map(canonicalName))
        let sources = Array(current.sources.values) + Array(base.values) + Array(unownedBase.values)
        guard sources.allSatisfy({ $0.diagnostics.isEmpty && $0.helperReferences != nil && $0.sdkHelperNamesUnshadowed == true && $0.dispatchMembers != nil && $0.dispatchOverrides != nil && $0.superclasses != nil && $0.typeAliases != nil }) else { return "Missing reference evidence or shadowed XCTest/query/operator names" }
        let sdkClasses: Set<String> = ["XCUIElement", "NSPredicate", "XCTNSPredicateExpectation", "XCTWaiter"]
        guard sources.allSatisfy({ snapshot in
            snapshot.superclasses!.values.flatMap { $0 }.allSatisfy { !sdkClasses.contains(canonicalName($0).split(separator: ".").last.map(String.init) ?? canonicalName($0)) }
        }) else { return "Project subclass can override the trusted SDK query APIs" }
        let queryOverrides = queriedMembers
        guard sources.allSatisfy({ snapshot in
            snapshot.dispatchOverrides!.allSatisfy { !queryOverrides.contains(canonicalName($0).split(separator: ".").last.map(String.init) ?? canonicalName($0)) }
        }) else { return "Project override can replace a trusted SDK query (including through a type alias)" }
        let waitNames = queriedMembers.intersection(["waitForExistence", "waitForNonExistence"])
        guard sources.allSatisfy({ snapshot in
            snapshot.units.allSatisfy { $0.helperCallableName.map { !waitNames.contains(canonicalName($0)) } ?? true }
        }) else { return "Project declaration can replace a trusted SDK wait overload" }
        if let blocker = memberBindingBlocker(revisions: [Array(current.sources.values), Array(base.values) + Array(unownedBase.values)],
            members: queriedMembers.union(["init"]), sdkOwners: sdkClasses.union(["NSObject", "NSObjectProtocol"])) {
            return "Project member can replace a trusted SDK query at base or head: " + blocker
        }
        let protected: Set<String> = ["XCUIElement.exists", "XCUIElement.value", "XCUIElement.isEnabled", "XCUIElement.isHittable", "XCUIElement.isSelected",
            "NSPredicate.evaluate", "NSPredicate.init", "XCTNSPredicateExpectation.init", "XCTWaiter.wait", "XCUIElement.waitForExistence", "XCUIElement.waitForNonExistence"]
        guard sources.allSatisfy({ snapshot in
            snapshot.dispatchMembers!.allSatisfy { member in
                let name = canonicalName(member)
                return !protected.contains(name) && !protected.contains(String(name.split(separator: ".").suffix(2).joined(separator: ".")))
            }
        }) else { return "Project declarations shadow the trusted SDK query APIs" }
        return nil
    }

    /// Overrides matter only when their declaring class can be a receiver of
    /// the SDK call. Resolve each revision independently; aliases, missing class
    /// declarations and cycles cannot establish an unrelated hierarchy.
    static func overridesUnshadowed(revisions: [[SwiftSourceSnapshot]], members: Set<String>, sdkReceivers: Set<String>,
                                    provenMethods: [SourceUnit] = []) -> Bool {
        let canonical = SDKTestHelperSyntax.canonicalName
        for revision in revisions {
            guard revision.allSatisfy({ $0.dispatchOverrides != nil && $0.superclasses != nil && $0.typeAliases != nil }) else { return false }
            let parents = Dictionary(grouping: revision.flatMap { $0.superclasses!.map { (canonical($0.key), $0.value) } }, by: { $0.0 })
            let aliases = Set(revision.flatMap { $0.typeAliases! }.map(canonical))
            var results: [String: Bool] = [:]
            func unrelated(_ owner: String) -> Bool {
                if let result = results[owner] { return result }
                var pending = owner, seen = Set<String>()
                while seen.insert(pending).inserted {
                    if aliases.contains(pending) { return false }
                    guard let candidates = parents[pending], candidates.count == 1 else { return false }
                    let supers = candidates[0].1
                    if supers.isEmpty { return true }
                    guard supers.count == 1, let nominal = SwiftSourceSnapshot.nominalTypeName(supers[0]) else { return false }
                    let name = canonical(nominal)
                    // Swift looks through enclosing lexical scopes before the
                    // module. A suffix search can pick an unrelated nested class
                    // or skip a nested alias in favor of a module-level class.
                    // Aliases (including inherited nested aliases) are opaque.
                    let components = name.split(separator: ".").map(String.init)
                    if aliases.contains(where: { alias in
                        components.contains { alias == $0 || alias.hasSuffix("." + $0) }
                    }) { return false }
                    var scope = pending.split(separator: ".").dropLast().map(String.init)
                    var resolved: String?
                    while !scope.isEmpty {
                        let owner = scope.joined(separator: ".")
                        let candidate = owner + "." + name
                        if parents[candidate] != nil { resolved = candidate; break }
                        // An enclosing class can inherit a nested type. Do not
                        // skip that lookup and bind a module-level namesake.
                        if parents[owner]?.contains(where: { !$0.1.isEmpty }) == true { return false }
                        scope.removeLast()
                    }
                    if let match = resolved ?? (parents[name] != nil ? name : nil) {
                        pending = match
                        continue
                    }
                    // An inherited nested nominal is not resolved by this
                    // limited lookup. Never infer an SDK root from that gap.
                    if parents.keys.contains(where: { $0.hasSuffix("." + name) }) { return false }
                    if sdkReceivers.contains(name.split(separator: ".").last.map(String.init) ?? name) { return false }
                    // A direct subclass of NSObject cannot also be a subclass
                    // of an unrelated precompiled XCTest receiver class.
                    return ["NSObject", "Foundation.NSObject"].contains(name)
                }
                return false
            }
            for snapshot in revision {
                for spelling in snapshot.dispatchOverrides! {
                    let parts = canonical(spelling).split(separator: ".")
                    guard let member = parts.last, members.contains(String(member)) else { continue }
                    let owner = parts.dropLast().joined(separator: ".")
                    // The caller traversal may already have checked an exact
                    // lifecycle/receiver implementation. Every overload at this
                    // revision must match; a removed or changed body cannot use
                    // a similarly named implementation from the head graph.
                    let methods = snapshot.units.filter {
                        $0.helperCallableName.map(canonical) == String(member) &&
                            canonical(String($0.key.prefix { $0 != ":" }) + "." + $0.scope) == owner
                    }
                    if !methods.isEmpty, methods.allSatisfy({ method in provenMethods.contains {
                        $0.key == method.key && $0.region.path == method.region.path && $0.fingerprint == method.fingerprint
                    } }) { continue }
                    let result = unrelated(owner)
                    results[owner] = result
                    if !result { return false }
                }
            }
        }
        return true
    }

    /// A concrete project nominal cannot be an ancestor of a precompiled SDK
    /// class. Protocol, alias and unresolved owners cannot establish that fact.
    /// Use separate revision inventories so a head declaration cannot resolve an
    /// ambiguous historical owner. This also works with existing saved snapshots.
    static func memberBindingsUnshadowed(revisions: [[SwiftSourceSnapshot]], members: Set<String>,
                                         sdkOwners: Set<String>, provenHelpers: [SourceUnit] = []) -> Bool {
        memberBindingBlocker(revisions: revisions, members: members, sdkOwners: sdkOwners, provenHelpers: provenHelpers) == nil
    }

    static func memberBindingBlocker(revisions: [[SwiftSourceSnapshot]], members: Set<String>,
                                    sdkOwners: Set<String>, provenHelpers: [SourceUnit] = [],
                                    auditedProjectOwners: Set<String> = []) -> String? {
        let canonicalName = SDKTestHelperSyntax.canonicalName
        guard revisions.joined().allSatisfy({ $0.diagnostics.isEmpty && $0.dispatchMembers != nil && $0.typeAliases != nil }) else {
            return "Missing declaration/member binding evidence"
        }
        for (revisionIndex, revision) in revisions.enumerated() {
            let types = Dictionary(grouping: revision.flatMap(\.units).filter { $0.kind == "type" }, by: {
                canonicalName(String($0.key.prefix { $0 != ":" }) + "." + $0.scope)
            })
            let concreteOwners = Set(types.compactMap { name, declarations -> String? in
                // All conditional candidates must be concrete before their
                // members can be excluded from an SDK binding audit.
                guard declarations.allSatisfy({ unit in
                    ["classDecl[", "structDecl[", "enumDecl["].contains(where: unit.fingerprint.hasPrefix)
                }) else { return nil }
                return name
            })
            let aliases = Set(revision.flatMap { $0.typeAliases! }.map(canonicalName))
            for snapshot in revision.sorted(by: { ($0.units.first?.region.path ?? "") < ($1.units.first?.region.path ?? "") }) {
                let modules = Set(snapshot.units.map { canonicalName(String($0.key.prefix { $0 != ":" })) })
                for member in snapshot.dispatchMembers!.sorted() {
                    let parts = canonicalName(member).split(separator: ".")
                    guard let name = parts.last, members.contains(String(name)) else { continue }
                    let owner = parts.dropLast().joined(separator: ".")
                    let declarations = snapshot.units.filter { canonicalName($0.scope) == owner }
                    let location = declarations.first(where: {
                        $0.helperCallableName.map(canonicalName) == String(name) ||
                        name == "init" && $0.fingerprint.hasPrefix("initializerDecl[")
                    })?.region ?? declarations.first?.region
                    let rejected = "Unproven member binding \(member) at \(location?.path ?? "unknown source"):\(location?.startLine ?? 0) (revision \(revisionIndex + 1))"
                    // Requirements cannot authenticate SDK namesakes or aliases.
                    let aliasedOwner = aliases.contains { $0 == owner || $0.hasSuffix("." + owner) }
                    let unshadowedOwner = parts.dropLast().last.map { !sdkOwners.contains(String($0)) } == true && !aliasedOwner
                    let auditedOwner = auditedProjectOwners.contains(owner) ||
                        modules.contains { auditedProjectOwners.contains($0 + "." + owner) } ||
                        (modules.contains("") && auditedProjectOwners.contains { $0.hasSuffix("." + owner) })
                    if name == "subscript", !auditedOwner, !aliasedOwner {
                        // A labeled-only subscript cannot replace the SDK's
                        // single unlabeled getter. An alias may name a checked
                        // project receiver, whose labeled overloads still matter.
                        let subscripts = declarations.filter { $0.fingerprint.hasPrefix("subscriptDecl[") }
                        if !subscripts.isEmpty, subscripts.allSatisfy({ $0.subscriptAcceptsSingleUnlabeledArgument == false }) { continue }
                    }
                    let methods = declarations.filter { $0.helperCallableName.map(canonicalName) == String(name) }
                    let requirements = declarations.filter { $0.bodylessProtocolRequirement == String(name) }
                    // Evidence comes only from direct protocol members with no body.
                    // Each extension/default implementation has its own dispatch
                    // inventory and must pass this audit independently.
                    if unshadowedOwner, !requirements.isEmpty,
                       declarations.filter({ $0.kind == "type" }).allSatisfy({ $0.fingerprint.hasPrefix("protocolDecl[") }),
                       methods.allSatisfy({ $0.bodylessProtocolRequirement == String(name) }),
                       (name != "init" || declarations.filter { $0.fingerprint.hasPrefix("initializerDecl[") }.allSatisfy { $0.bodylessProtocolRequirement == "init" }) {
                        continue
                    }
                    // Preserve support for older bodyless method evidence, but
                    // never infer an initializer requirement from a state unit.
                    let typesAtOwner = declarations.filter { $0.kind == "type" }
                    if unshadowedOwner, !typesAtOwner.isEmpty, typesAtOwner.allSatisfy({ $0.fingerprint.hasPrefix("protocolDecl[") }),
                       !methods.isEmpty, declarations.allSatisfy({ ["type", "function"].contains($0.kind) }),
                       methods.allSatisfy({ $0.headOnlyBodySupported == true && $0.key.hasSuffix(":" + ($0.syntaxFingerprint ?? $0.fingerprint)) }) { continue }
                    if auditedOwner {
                        // Concrete project types cannot shadow SDK members, but
                        // callers can invoke them directly. Every declaration
                        // in the historical overload set needs its own proof.
                        guard declarations.allSatisfy({ $0.helperDeclaredMembers != nil }) else { return rejected }
                        let implementations = declarations.filter { $0.helperDeclaredMembers!.contains(String(name)) }
                        guard !implementations.isEmpty, implementations.allSatisfy({ declaration in
                            if declaration.helperEnumCaseWithoutDefaults == true {
                                // Literal arguments acquire their type from the
                                // case signature. A changed payload or project
                                // alias can run a different literal initializer.
                                return declaration.helperEnumCaseValueArguments == true && revisions.allSatisfy { sources in
                                    sources.flatMap(\.units).contains {
                                        $0.key == declaration.key && $0.fingerprint == declaration.fingerprint &&
                                            $0.helperEnumCaseWithoutDefaults == true && $0.helperEnumCaseValueArguments == true
                                    }
                                }
                            }
                            return provenHelpers.contains {
                                $0.key == declaration.key && $0.region.path == declaration.region.path && $0.fingerprint == declaration.fingerprint
                            }
                        }) else { return rejected }
                        continue
                    }
                    // A name-only dispatch record is exempt only when every
                    // overload is proven and no unmodeled member can compete.
                    if !provenHelpers.isEmpty, !methods.isEmpty,
                       declarations.allSatisfy({ ["type", "extension", "function"].contains($0.kind) }),
                       methods.allSatisfy({ method in provenHelpers.contains {
                           $0.key == method.key && $0.region.path == method.region.path && $0.fingerprint == method.fingerprint
                       } }) { continue }
                    guard unshadowedOwner,
                          concreteOwners.contains(owner) || modules.contains(where: { concreteOwners.contains($0 + "." + owner) }) else { return rejected }
                }
            }
        }
        return nil
    }

}
