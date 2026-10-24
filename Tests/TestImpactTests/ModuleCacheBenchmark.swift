// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import Testing
@testable import TestImpact

/// Opt-in release module-cache probe/benchmark. JSON string fields: root,
/// derived, workspace, log, cache, output, revision, context; optional reference.
/// mode=identities performs input validation only. Default extracts dependencies.
@Test func moduleCacheBenchmark() throws {
    guard let path = ProcessInfo.processInfo.environment["IMPACT_MODULE_CACHE_BENCHMARK"] else { return }
    let config = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    func url(_ key: String) throws -> URL { URL(fileURLWithPath: try #require(config[key])) }
    var messages: [String] = []
    func progress(_ text: String) {
        messages.append(text)
        FileHandle.standardOutput.write(Data((text + "\n").utf8))
    }
    let cache = try XcodeGraphCache(.init(directory: try url("cache"), context: try #require(config["context"])), progress: progress)
    let root = try url("root")
    let log = try String(contentsOf: url("log"), encoding: .utf8)
    let identity = ["revision": try #require(config["revision"]), "externalInputs": try #require(config["context"]),
                    "analyzerExecutable": try ArtifactFiles.digest(XcodeGraphCache.analyzerExecutable()),
                    "toolchain": try ArtifactFiles.toolchain(at: root)]
    let fragments = XcodeModuleCache(cache: cache, identity: identity, source: root, derived: try url("derived"), workspace: try url("workspace"))
    let start = Date()
    fragments.prepare(log: log)
    var keys: [String: String] = [:]
    for line in log.components(separatedBy: .newlines) {
        guard let marker = line.range(of: "builtin-SwiftDriver -- ") else { continue }
        let arguments = try XcodeSourceFileList.parse(String(line[marker.upperBound...]))
        if let index = arguments.firstIndex(of: "-module-name"), index + 1 < arguments.count,
           let value = fragments.identity(for: arguments[index + 1]) {
            keys[arguments[index + 1]] = try XcodeGraphCache.key(value)
        }
    }
    var result: [String: Any] = ["moduleKeys": keys, "inputValidationSeconds": Date().timeIntervalSince(start)]
    if config["mode"] != "identities" {
        let reference = try JSONDecoder().decode(XcodeTestGraph.self, from: Data(contentsOf: url("reference")))
        let ownership = reference.targets.reduce(into: [String: Set<String>]()) { result, target in
            if let module = reference.modules[target.name] { result[module, default: []].formUnion(target.sourceFiles) }
        }
        let extraction = Date()
        let graph = XcodeCompilerGraph.extract(log: log, sourceRoot: root, directory: root, derived: try url("derived"), progress: progress, ownership: ownership, moduleCache: config["mode"] == "fresh" ? nil : fragments)
        result["extractionSeconds"] = Date().timeIntervalSince(extraction)
        try #require(graph.diagnostics.isEmpty)
        result["functions"] = graph.functions.count
        let nodes: [[String: Any]] = graph.functions.values.sorted { $0.id < $1.id }.map { node in
            ["id": node.id, "module": node.module, "name": node.name,
             "regions": node.regions.map { ["path": $0.path, "start": String($0.startLine), "end": String($0.endLine)] }.sorted { ($0["path"]!, $0["start"]!, $0["end"]!) < ($1["path"]!, $1["start"]!, $1["end"]!) },
             "dependencies": node.dependencies.sorted(), "dynamic": node.dynamicDeclarations.sorted(),
             "resolved": node.resolvedDynamicDeclarations.sorted(), "uncertainty": node.uncertainties.sorted()]
        }
        result["semanticDigest"] = XcodeGraphCache.digest(try JSONSerialization.data(withJSONObject: nodes, options: [.sortedKeys]))
    }
    result["messages"] = messages
    try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .prettyPrinted]).write(to: try url("output"))
}
