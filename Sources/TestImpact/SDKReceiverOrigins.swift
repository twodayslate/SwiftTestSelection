// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation

/// A static SDK method reference does not prove the receiver's runtime class.
/// Factories and setup may supply an imported subclass with effectful overrides.
/// Check the consumer dependency closure, including lifecycle roots, before
/// granting an SDK effect contract. This does not impose purity on test setup.
struct SDKReceiverOrigins {
    // One immutable graph per instance. Shared helper chains often have the
    // same consumer roots; cache both successful and failed closure checks.
    private struct Proof { var blocker: String? }
    private var results: [Set<String>: Proof] = [:]
    private var effects = ExternalHelperEffects()
    // Public immutable constants from XCUIElement.h and XCUIKeyboardKeys.h.
    // Exact names only: a similarly named project global is not an SDK contract.
    private static let sdkConstants: Set<String> = Set(["Default", "Fast", "Slow"].map { "global:XCUIGestureVelocity" + $0 })
        .union(["Delete", "Return", "Enter", "Tab", "Space", "Escape", "UpArrow", "DownArrow", "LeftArrow", "RightArrow",
                "ForwardDelete", "Home", "End", "PageUp", "PageDown", "Clear", "Help", "CapsLock", "Shift", "Control", "Option", "Command",
                "RightShift", "RightControl", "RightOption", "RightCommand"].map { "global:XCUIKeyboardKey" + $0 })
        .union((1...19).map { "global:XCUIKeyboardKeyF" + String($0) })

    mutating func proves(tests: Set<String>, current: XcodeTestGraph, graph: DependencyGraph) -> Bool {
        blocker(tests: tests, current: current, graph: graph) == nil
    }

    mutating func blocker(tests: Set<String>, current: XcodeTestGraph, graph: DependencyGraph) -> String? {
        if let cached = results[tests] { return cached.blocker }
        let result = inspect(tests: tests, current: current, graph: graph)
        results[tests] = Proof(blocker: result)
        return result
    }

    private mutating func inspect(tests: Set<String>, current: XcodeTestGraph, graph: DependencyGraph) -> String? {
        let sources = Dictionary(grouping: current.sources.map { (String($0.key.prefix { $0 != ":" }), $0.value) }, by: { $0.0 })
        func stateBlocker(_ node: FunctionNode) -> String? {
            if node.uncertainties.contains("Raw pointer operation") { return "Raw pointer operation" }
            guard !node.uncertainties.isDisjoint(with: ["Shared state access", "Global state access"]) || node.stateAccesses?.isEmpty == false else { return nil }
            guard let accesses = node.stateAccesses, !accesses.isEmpty else { return "Missing shared-state access evidence; recapture sealed SIL" }
            let snapshots = (sources[node.module] ?? []).map { $0.1 }
            for access in accesses.sorted() {
                // Exact SDK constants, never arbitrary scalar-looking globals.
                if Self.sdkConstants.contains(access) { continue }
                guard access.hasPrefix("field:"), !snapshots.isEmpty,
                      snapshots.allSatisfy({ $0.literalStoredProperties != nil && $0.typeAliases != nil &&
                          !$0.typeAliases!.contains(where: { $0.split(separator: ".").last == "StringLiteralType" }) }) else { return "Unproven shared receiver storage: " + access }
                let field = SDKTestHelperSyntax.canonicalName(String(access.dropFirst(6)))
                let proofs = snapshots.compactMap { $0.literalStoredProperties![field] }
                guard !proofs.isEmpty, proofs.allSatisfy({ $0 }) else { return "Unproven shared receiver storage: " + access }
            }
            return nil
        }
        // Test binding includes ancestor allocation thunks as lifecycle roots.
        // A final concrete test is allocated once; ancestor initializer bodies
        // run on that instance, not on an arbitrary ancestor metatype. Omit only
        // those synthetic roots, keeping their bodies and any actual call edges.
        // An explicitly invoked ancestor allocator is still visited normally.
        func roots(_ test: String) -> Set<String> {
            let roots = graph.tests[test] ?? []
            let parts = test.split(separator: "/").map(String.init)
            guard parts.count >= 3, let module = current.modules[parts[0]] else { return roots }
            let snapshots = (sources[module] ?? []).map { $0.1 }
            let concrete = parts[1]
            let declarations = snapshots.flatMap(\.units).filter { $0.kind == "type" && $0.scope == concrete }
            let finality = snapshots.compactMap { $0.classFinality?[concrete] }
            guard declarations.count == 1, !finality.isEmpty, finality.allSatisfy({ $0 }),
                  PrivateTestHelperIsolation.safeHierarchy(concrete, module: module, sources: snapshots) else { return roots }
            let classes = Dictionary(grouping: snapshots.flatMap { ($0.helperSafeClasses ?? [:]).map { ($0.key, $0.value) } }, by: { $0.0 })
            var ancestors = Set<String>(), owner = concrete
            while let parents = classes[module + "." + owner], parents.count == 1 {
                let parent = parents[0].1
                guard ancestors.insert(parent).inserted else { break }
                owner = parent
            }
            return roots.filter { id in
                guard let node = graph.functions[id], node.module == module,
                      let owner = ancestors.first(where: { node.name.hasPrefix($0 + ".__allocating_init(") }) else { return true }
                let initializer = node.name.replacingOccurrences(of: owner + ".__allocating_init(", with: owner + ".init(")
                return !roots.contains { graph.functions[$0]?.module == module && graph.functions[$0]?.name == initializer }
            }
        }
        var pending = Set(tests.flatMap { roots($0) }), visited = Set<String>()
        var external = Set<String>()
        while !pending.isEmpty {
            let batch = pending.subtracting(visited)
            pending = []
            visited.formUnion(batch)
            // SDK implementations are trusted primitives. Expanding their
            // generic protocol dispatch invents unrelated producer paths; their
            // explicit callback references already remain in the calling body.
            let sdk = effects.sdkReceiverDeclarations(batch)
            for id in batch.subtracting(sdk).sorted() {
                guard let node = graph.functions[id] else { external.insert(id); continue }
                let owned = node.id.hasSuffix("@emitted:" + node.module) || node.regions.contains {
                    current.sources[node.module + ":" + $0.path] != nil
                }
                guard owned else { external.insert(id); continue }
                if let reason = stateBlocker(node) { return "\(reason) in \(node.module).\(node.name)" }
                // A saved project body with missing provenance is not an opaque
                // external leaf, even if its declaration has a void result.
                guard let direct = node.compilerReferences else { return "Missing compiler references for \(node.module).\(node.name)" }
                var checked = node
                // A final source-bound XCTest class has no descendant override.
                // The generic dispatch graph may carry a broad warning caused by
                // unrelated constructors whose ancestry is unknown. Clear only
                // that exact warning on this class's allocating initializer;
                // missing callees and every other uncertainty remain checked.
                for uncertainty in node.uncertainties where uncertainty.hasPrefix("Unresolved project dispatch: ") && uncertainty.hasSuffix(".init (incomplete override ancestry)") {
                    let owner = String(uncertainty.dropFirst("Unresolved project dispatch: ".count).dropLast(".init (incomplete override ancestry)".count))
                    let snapshots = (sources[node.module] ?? []).map { $0.1 }
                    let declarations = snapshots.flatMap(\.units).filter { $0.kind == "type" && $0.scope == owner }
                    let finality = snapshots.compactMap { $0.classFinality?[owner] }
                    if node.name.hasPrefix(owner + ".__allocating_init("), declarations.count == 1,
                       !finality.isEmpty, finality.allSatisfy({ $0 }),
                       node.resolvedDynamicDeclarations.contains(owner + ".init"),
                       PrivateTestHelperIsolation.safeHierarchy(owner, module: node.module, sources: snapshots) {
                        checked.uncertainties.remove(uncertainty)
                    }
                }
                switch ExternalHelperEffects.receiverProof(checked) {
                case let .success(producers): pending.formUnion(direct.union(producers))
                case let .failure(error): return "\(error) in \(node.module).\(node.name)"
                }
            }
        }
        let unresolved = effects.unprovenReceiverOrigins(external).sorted()
        guard unresolved.isEmpty else {
            return "Missing implementation or SDK origin contract for external producer(s): " + unresolved.prefix(8).joined(separator: ", ") +
                (unresolved.count > 8 ? " (and \(unresolved.count - 8) more)" : "")
        }
        return nil
    }

}
