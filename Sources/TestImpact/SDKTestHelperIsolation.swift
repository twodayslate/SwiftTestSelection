// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation

/// A closed caller proof for an internal Swift SDK extension plus a small,
/// trusted XCTest query/expectation effect contract at both source revisions.
enum SDKTestHelperIsolation {
    static func blocker(_ unit: SourceUnit, previous: SourceUnit?, current: XcodeTestGraph,
                        base: [String: SwiftSourceSnapshot], graph: DependencyGraph, index: DependencyIndex,
                        unownedBase: [String: SwiftSourceSnapshot] = [:]) -> String? {
        guard let evidence = unit.sdkTestHelper, let old = previous?.sdkTestHelper,
              evidence.version == SDKTestHelperSyntax.currentVersion, old.version == evidence.version else { return "Missing supported base/head SDK helper evidence" }
        if let reason = evidence.blocker ?? old.blocker { return reason }
        guard previous?.key == unit.key, previous?.region.path == unit.region.path,
              unit.headOnlyBodySupported == true, previous?.headOnlyBodySupported == true else { return "Changed header, ownership or unsupported attributes/macros" }
        guard Set(current.modules.values).isDisjoint(with: SDKTestHelperSyntax.trustedModules) else { return "Project module shadows a trusted SDK module" }
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
        if let reason = environmentBlocker(current: current, base: base, unownedBase: unownedBase,
                                           queriedMembers: evidence.queriedMembers.union(old.queriedMembers)) { return reason }
        if let reason = effectBindingBlocker(unit, previous: previous, current: current, base: base, unownedBase: unownedBase) { return reason }
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
            for (snapshots, units) in [(headSources, headByFile), (baseSources, oldByFile)] {
                var declarations = 0
                for (key, snapshot) in snapshots {
                    let allUses = snapshot.helperReferences?[name]
                    if allUses?.unsupported == true {
                        return "Escaping, stored, nested or unresolved reference to \(name) in \(key) at lines \(allUses!.unsupportedLines.sorted())"
                    }
                    guard let uses = snapshot.helperReferences?[callee.helperReferenceSignature ?? name] else { continue }
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
        let ids = symbols(unit), paths = index.paths(to: symbols(unit))
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
                guard candidate.kind == "function", candidate.helperCallableName == name else { return false }
                guard let a = candidate.helperReferenceSignature, let b = declaration.helperReferenceSignature else { return true }
                return a == b
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
        var pending = Array(ids), visited = Set<String>()
        while let id = pending.popLast() {
            guard visited.insert(id).inserted, let node = graph.functions[id] else { continue }
            if node.hasProjectRuntimeContext {
                guard ids.contains(id) else { return "Project implementation outside the trusted SDK boundary: \(node.name)" }
                if !node.uncertainties.isDisjoint(with: ["Global state access", "Shared state access", "Raw pointer operation"]) {
                    return "Compiler-observed state or pointer effect: \(node.name)"
                }
            }
            pending += node.dependencies.filter { graph.functions[$0]?.hasProjectRuntimeContext == true }
        }
        return nil
    }

    /// Shared effect boundary for changed SDK helpers and SDK callees reached
    /// from private helpers; caller closure is a separate proof.
    static func environmentBlocker(current: XcodeTestGraph, base: [String: SwiftSourceSnapshot],
                                   unownedBase: [String: SwiftSourceSnapshot] = [:], queriedMembers: Set<String>) -> String? {
        guard Set(current.modules.values).isDisjoint(with: SDKTestHelperSyntax.trustedModules) else { return "Project module shadows a trusted SDK module" }
        let sources = Array(current.sources.values) + Array(base.values) + Array(unownedBase.values)
        guard sources.allSatisfy({ $0.diagnostics.isEmpty && $0.helperReferences != nil && $0.sdkHelperNamesUnshadowed == true && $0.dispatchMembers != nil && $0.dispatchOverrides != nil && $0.superclasses != nil && $0.typeAliases != nil }) else { return "Missing reference evidence or shadowed XCTest/query/operator names" }
        let sdkClasses: Set<String> = ["XCUIElement", "NSPredicate", "XCTNSPredicateExpectation", "XCTWaiter"]
        guard sources.allSatisfy({ snapshot in
            snapshot.superclasses!.values.flatMap { $0 }.allSatisfy { !sdkClasses.contains($0.split(separator: ".").last.map(String.init) ?? $0) }
        }) else { return "Project subclass can override the trusted SDK query APIs" }
        let queryOverrides = queriedMembers
        guard sources.allSatisfy({ snapshot in
            snapshot.dispatchOverrides!.allSatisfy { !queryOverrides.contains($0.split(separator: ".").last.map(String.init) ?? $0) }
        }) else { return "Project override can replace a trusted SDK query (including through a type alias)" }
        let waitNames = queriedMembers.intersection(["waitForExistence", "waitForNonExistence"])
        guard sources.allSatisfy({ snapshot in
            snapshot.units.allSatisfy { $0.helperCallableName.map { !waitNames.contains($0) } ?? true }
        }) else { return "Project declaration can replace a trusted SDK wait overload" }
        // A concrete project class/struct/enum cannot be an ancestor of these
        // precompiled SDK classes. Protocols, aliases and unresolved extension
        // owners do not provide that guarantee. The source fingerprint retains
        // the declaration syntax kind, including in existing saved graphs.
        let sdkOwners = sdkClasses.union(["NSObject", "NSObjectProtocol"])
        // The head graph cannot resolve a removed base overload. Audit every
        // queried member and constructor, including inherited/aliased owners.
        // Free functions cannot replace these member calls.
        let members = queriedMembers.union(["init"])
        for revision in [Array(current.sources.values), Array(base.values) + Array(unownedBase.values)] {
            let types = Dictionary(grouping: revision.flatMap(\.units).filter { $0.kind == "type" }, by: {
                String($0.key.prefix { $0 != ":" }) + "." + $0.scope
            })
            let concreteOwners = Set(types.compactMap { name, declarations -> String? in
                // Conditional declarations may share a name. Every candidate
                // must be concrete before excluding this owner from the audit.
                guard declarations.allSatisfy({ unit in
                    ["classDecl[", "structDecl[", "enumDecl["].contains(where: unit.fingerprint.hasPrefix)
                }) else { return nil }
                return name
            })
            let aliases = Set(revision.flatMap { $0.typeAliases! })
            guard revision.allSatisfy({ snapshot in
                let modules = Set(snapshot.units.map { String($0.key.prefix { $0 != ":" }) })
                return snapshot.dispatchMembers!.allSatisfy { member in
                    let parts = member.split(separator: ".")
                    guard let name = parts.last, members.contains(String(name)) else { return true }
                    let owner = parts.dropLast().joined(separator: ".")
                    guard let ownerName = parts.dropLast().last, !sdkOwners.contains(String(ownerName)) else { return false }
                    // Never infer an alias's target from a same-spelled nominal
                    // in another module; source-only resolution is ambiguous.
                    guard !aliases.contains(where: { $0 == owner || $0.hasSuffix("." + owner) }) else { return false }
                    return concreteOwners.contains(owner) || modules.contains { concreteOwners.contains($0 + "." + owner) }
                }
            }) else { return "Project member can replace a trusted SDK query at base or head" }
        }
        let protected: Set<String> = ["XCUIElement.exists", "XCUIElement.value", "XCUIElement.isEnabled", "XCUIElement.isHittable", "XCUIElement.isSelected",
            "NSPredicate.evaluate", "NSPredicate.init", "XCTNSPredicateExpectation.init", "XCTWaiter.wait", "XCUIElement.waitForExistence", "XCUIElement.waitForNonExistence"]
        guard sources.allSatisfy({ snapshot in
            snapshot.dispatchMembers!.allSatisfy { member in !protected.contains(member) && !protected.contains(String(member.split(separator: ".").suffix(2).joined(separator: "."))) }
        }) else { return "Project declarations shadow the trusted SDK query APIs" }
        return nil
    }

}
