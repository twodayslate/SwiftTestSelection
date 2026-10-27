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
    private var results: [Set<String>: Bool] = [:]
    private var effects = ExternalHelperEffects()

    mutating func proves(tests: Set<String>, current: XcodeTestGraph, graph: DependencyGraph) -> Bool {
        if let cached = results[tests] { return cached }
        let result = inspect(tests: tests, current: current, graph: graph)
        results[tests] = result
        return result
    }

    private mutating func inspect(tests: Set<String>, current: XcodeTestGraph, graph: DependencyGraph) -> Bool {
        var pending = Set(tests.flatMap { graph.tests[$0] ?? [] }), visited = Set<String>()
        var external = Set<String>()
        while !pending.isEmpty {
            let batch = pending.subtracting(visited)
            pending = []
            visited.formUnion(batch)
            // SDK implementations are trusted primitives. Expanding their
            // generic protocol dispatch invents unrelated producer paths; their
            // explicit callback references already remain in the calling body.
            let sdk = effects.sdkReceiverDeclarations(batch)
            for id in batch.subtracting(sdk) {
                guard let node = graph.functions[id] else { external.insert(id); continue }
                let owned = node.id.hasSuffix("@emitted:" + node.module) || node.regions.contains {
                    current.sources[node.module + ":" + $0.path] != nil
                }
                guard owned else { external.insert(id); continue }
                // A saved project body with missing provenance is not an opaque
                // external leaf, even if its declaration has a void result.
                guard let direct = node.compilerReferences, node.dynamicCallSignatures != nil,
                      let producers = ExternalHelperEffects.receiverDependencies(node, assertedCallbacks: assertedCallbacks(node, current: current, graph: graph)) else { return false }
                pending.formUnion(direct.union(producers))
            }
        }
        return effects.allowsReceiverOrigins(external)
    }

    private mutating func assertedCallbacks(_ node: FunctionNode, current: XcodeTestGraph, graph: DependencyGraph) -> Set<String> {
        guard node.dynamicCallSignatures?.contains(where: { $0.components(separatedBy: " -> ").count == 4 }) == true else { return [] }
        // Evidence is useful only for the exact saved source owner. Old captures
        // and ambiguous locations cannot exempt a callback-producing call.
        let units = node.regions.flatMap { region in
            (current.sources[node.module + ":" + region.path]?.units ?? []).filter {
                $0.kind == "function" && $0.region.startLine <= region.startLine && $0.region.endLine >= region.startLine
            }
        }
        guard !units.isEmpty, units.allSatisfy({ $0.assertedCallbackInputs != nil }) else { return [] }
        var candidates = Set(units[0].assertedCallbackInputs!.keys)
        for unit in units { candidates.formIntersection(unit.assertedCallbackInputs!.keys) }
        return Set(candidates.filter { name in
            let ranges = units.flatMap { $0.assertedCallbackInputs![name] ?? [] }
            return !ranges.isEmpty && ranges.allSatisfy { range in
                // SIL may anchor a trailing closure at the beginning of a
                // multiline call, before its opening brace. Require coverage of
                // the full explicit closure through its end line. Implicit
                // assertion autoclosures can include earlier captured-variable
                // locations and must not be mistaken for the completion.
                let callbacks = (node.compilerReferences ?? []).compactMap { graph.functions[$0] }.filter { callback in
                    callback.module == node.module && callback.name.hasPrefix("closure #") && callback.regions.contains { $0.path == range.path && $0.startLine <= range.startLine && $0.endLine == range.endLine }
                }
                guard !callbacks.isEmpty else { return false }
                var pending = Set(callbacks.map(\.id)), visited = Set<String>(), external = Set<String>()
                while let id = pending.popFirst() {
                    guard visited.insert(id).inserted else { continue }
                    guard let body = graph.functions[id], body.module == node.module,
                          body.regions.contains(where: { $0.path == range.path && ($0.startLine >= range.startLine && $0.endLine <= range.endLine || $0.startLine <= range.startLine && $0.endLine >= range.endLine) }) else {
                        external.insert(id); continue
                    }
                    guard let refs = body.compilerReferences, let dynamic = body.dynamicCallSignatures,
                          dynamic.allSatisfy({ $0 == "objc_method XCTestExpectation.fulfill!foreign : (XCTestExpectation) -> () -> ()" }),
                          body.dynamicDeclarations.isSubset(of: ["XCTestExpectation.fulfill"]) else { return false }
                    pending.formUnion(refs)
                }
                return effects.allows(external)
            }
        })
    }

}
