// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import Testing
@testable import TestImpact

/// Opt-in: IMPACT_EXTRACTION_BENCHMARK points to a JSON configuration containing
/// root, derived, log, reference, output and workers (all string values).
@Test func xcodeExtractionBenchmark() throws {
    guard let path = ProcessInfo.processInfo.environment["IMPACT_EXTRACTION_BENCHMARK"] else { return }
    let config = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    func url(_ key: String) throws -> URL { URL(fileURLWithPath: try #require(config[key])) }
    let reference = try JSONDecoder().decode(XcodeTestGraph.self, from: Data(contentsOf: try url("reference")))
    let ownership = reference.targets.reduce(into: [String: Set<String>]()) { result, target in
        if let module = reference.modules[target.name] { result[module, default: []].formUnion(target.sourceFiles) }
    }
    let workerText = try #require(config["workers"])
    let workers = try #require(Int(workerText))
    let root = try url("root")
    let log = try String(contentsOf: url("log"), encoding: .utf8)
    let start = Date()
    let graph = XcodeCompilerGraph.extract(log: log, sourceRoot: root, directory: root, derived: try url("derived"), progress: {
        FileHandle.standardOutput.write(Data(($0 + "\n").utf8))
    }, ownership: ownership, workers: workers)
    let seconds = Date().timeIntervalSince(start)
    try #require(graph.diagnostics.isEmpty, "Extraction must be complete for a valid benchmark")
    let nodes: [[String: Any]] = graph.functions.values.sorted { $0.id < $1.id }.map { node in
        ["id": node.id, "module": node.module, "name": node.name,
         "regions": node.regions.map { ["path": $0.path, "start": String($0.startLine), "end": String($0.endLine)] }.sorted { ($0["path"]!, $0["start"]!, $0["end"]!) < ($1["path"]!, $1["start"]!, $1["end"]!) },
         "dependencies": node.dependencies.sorted(), "dynamic": node.dynamicDeclarations.sorted(),
         "resolved": node.resolvedDynamicDeclarations.sorted(), "uncertainty": node.uncertainties.sorted()]
    }
    let digest = XcodeGraphCache.digest(try JSONSerialization.data(withJSONObject: nodes, options: [.sortedKeys]))
    let result: [String: Any] = ["workers": workers, "extractionSeconds": seconds, "functions": graph.functions.count, "semanticDigest": digest, "diagnostics": graph.diagnostics]
    try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: try url("output"))
}
