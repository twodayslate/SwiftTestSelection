// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// Immutable dense adjacency and source indexes shared by all queries in one
/// revision. Unknown symbols remain vertices, matching DependencyGraph's BFS.
struct DependencyIndex {
    let symbols: [String]
    let ids: [String: Int]
    let forward: [[Int]]
    let reverse: [[Int]]
    let byFile: [String: Set<String>]
    let byModule: [String: Set<String>]

    init(_ graph: DependencyGraph) {
        symbols = Set(graph.functions.keys).union(graph.functions.values.flatMap(\.dependencies))
            .union(graph.tests.values.flatMap { $0 }).sorted()
        let ids = Dictionary(uniqueKeysWithValues: symbols.enumerated().map { ($1, $0) })
        self.ids = ids
        var forward = Array(repeating: [Int](), count: symbols.count)
        var reverse = forward
        var files: [String: Set<String>] = [:], modules: [String: Set<String>] = [:]
        for node in graph.functions.values {
            let source = ids[node.id]!
            forward[source] = node.dependencies.map { ids[$0]! }.sorted()
            for target in forward[source] { reverse[target].append(source) }
            for region in node.regions { files[region.path, default: []].insert(node.id) }
            if !node.regions.isEmpty { modules[node.module, default: []].insert(node.id) }
        }
        self.forward = forward; self.reverse = reverse
        byFile = files; byModule = modules
    }

    func paths(to destinations: Set<String>) -> Paths {
        var distance = Array(repeating: -1, count: symbols.count)
        var queue = destinations.compactMap { ids[$0] }
        for id in queue { distance[id] = 0 }
        var cursor = 0
        while cursor < queue.count {
            let id = queue[cursor]; cursor += 1
            for parent in reverse[id] where distance[parent] == -1 {
                distance[parent] = distance[id] + 1
                queue.append(parent)
            }
        }
        return Paths(index: self, distance: distance, destinations: destinations)
    }

    struct Paths {
        let index: DependencyIndex
        let distance: [Int]
        let destinations: Set<String>
        func path(from roots: Set<String>) -> [String]? {
            if let same = roots.intersection(destinations).min() { return [same] }
            // Original BFS breaks equal-length ties by sorted roots, then sorted
            // edges. Distances allow reconstruction of exactly that same path.
            guard var cursor = roots.compactMap({ index.ids[$0] }).filter({ distance[$0] >= 0 })
                .min(by: { (distance[$0], $0) < (distance[$1], $1) }) else { return nil }
            var result = [index.symbols[cursor]]
            while distance[cursor] > 0 {
                cursor = index.forward[cursor].first { distance[$0] == distance[cursor] - 1 }!
                result.append(index.symbols[cursor])
            }
            return result
        }
    }
}
