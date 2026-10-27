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
                      let producers = ExternalHelperEffects.receiverDependencies(node) else { return false }
                pending.formUnion(direct.union(producers))
            }
        }
        return effects.allowsReceiverOrigins(external)
    }
}
