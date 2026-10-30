// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
import Foundation
import Testing
@testable import TestImpact

private struct MappingReplayInput: Decodable {
    struct Capture: Decodable { var name: String; var graph: String; var sourceRoot: String }
    struct Replacement: Decodable { var path: String; var needle: String; var replacement: String }
    struct Probe: Decodable { var name: String; var replacements: [Replacement]; var documentation: [String] }
    var captures: [Capture]; var probes: [Probe]; var rounds: Int; var output: String
}

/// Opt-in, same-source comparison of independent mapping captures. Hypothetical
/// base-body edits use the ordinary head-only selector; no compiler edges change.
@Test(.enabled(if: ProcessInfo.processInfo.environment["IMPACT_MAPPING_COMPARISON"] != nil))
func mappingComparisonReplay() throws {
    let path = try #require(ProcessInfo.processInfo.environment["IMPACT_MAPPING_COMPARISON"])
    let input = try JSONDecoder().decode(MappingReplayInput.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    try #require(input.captures.count >= 2 && (1...20).contains(input.rounds))
    var graphs: [XcodeTestGraph] = []
    var expectedRelationships: [String: Set<String>]?
    for capture in input.captures {
        let graph = try GraphArchive.decode(Data(contentsOf: URL(fileURLWithPath: capture.graph)))
        try graph.validateMappingSymbols(mappingFile: "<capture>", revision: "head", buildContext: [:])
        let combined = InlineUIMappings.resolve(graph).applying(to: graph)
        let dependency = try #require(graph.dependencies), mappings = try #require(combined.mappings)
        let index = MappingIndex(mappings, snapshot: combined, graph: dependency, index: DependencyIndex(dependency))
        let features = Dictionary(uniqueKeysWithValues: mappings.features.map { ($0.name, $0) })
        func roots(_ feature: String, visited: Set<String> = []) -> Set<String> {
            guard !visited.contains(feature) else { return [] }
            var result = index.roots[feature] ?? []
            for parent in features[feature]?.dependsOn ?? [] { result.formUnion(roots(parent, visited: visited.union([feature]))) }
            return result
        }
        var relationships: [String: Set<String>] = [:]
        for feature in mappings.features {
            let names = Set(roots(feature.name).compactMap { dependency.functions[$0].map { $0.module + "." + $0.name } })
            for test in index.tests[feature.name] ?? [] { relationships[test, default: []].formUnion(names) }
        }
        if let expectedRelationships { #expect(relationships == expectedRelationships) }
        else { expectedRelationships = relationships }
        if let first = graphs.first { #expect(graph.tests.sorted() == first.tests.sorted()) }
        graphs.append(graph)
    }
    var rows: [[String: Any]] = [], selectedByProbe: [String: [String]] = [:]
    for round in 0..<input.rounds {
        let order = round.isMultiple(of: 2) ? Array(graphs.indices) : Array(graphs.indices.reversed())
        for index in order {
            let graph = graphs[index], capture = input.captures[index]
            for probe in input.probes {
                var sources = XcodeHeadOnlySources(base: graph.sources, mappings: graph.mappings)
                var changes = probe.documentation.map { FileChange(path: $0, requiresFallback: true) }
                for edit in probe.replacements {
                    let original = try String(contentsOf: URL(fileURLWithPath: capture.sourceRoot).appendingPathComponent(edit.path), encoding: .utf8)
                    try #require(original.components(separatedBy: edit.needle).count == 2)
                    let old = original.replacingOccurrences(of: edit.needle, with: edit.replacement)
                    let keys = graph.sources.keys.filter { $0.hasSuffix(":" + edit.path) }
                    try #require(!keys.isEmpty)
                    for key in keys {
                        let module = String(key.prefix { $0 != ":" })
                        sources.base[key] = SwiftSourceSnapshot.parse(old, path: edit.path, module: module)
                    }
                    let line = try #require(original.components(separatedBy: "\n").firstIndex { $0.contains(edit.needle) }) + 1
                    let region = SourceRegion(path: edit.path, startLine: line, endLine: line)
                    changes.append(.init(path: edit.path, oldRegions: [region], newRegions: [region]))
                }
                let start = Date()
                let report = XcodeHeadOnlySelector.select(current: graph, source: sources, changes: changes,
                    baseRevision: "hypothetical-body-edit", documentation: Set(probe.documentation))
                let elapsed = Date().timeIntervalSince(start)
                if let expected = selectedByProbe[probe.name] { #expect(report.selectedTests == expected, "\(capture.name): \(probe.name)") }
                else { selectedByProbe[probe.name] = report.selectedTests }
                rows.append(["capture": capture.name, "probe": probe.name, "round": round, "seconds": elapsed,
                    "selected": report.selectedTests, "diagnosticCodes": Set(report.diagnostics.map(\.code)).sorted()])
            }
        }
    }
    try JSONSerialization.data(withJSONObject: ["rows": rows, "mappedMethods": expectedRelationships?.count ?? 0], options: [.prettyPrinted, .sortedKeys])
        .write(to: URL(fileURLWithPath: input.output))
}
