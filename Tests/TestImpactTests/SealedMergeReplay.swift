// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
import Foundation
import Testing
@testable import TestImpact

/// Diagnostic re-extraction of exact retained compiler bytes. This does not
/// rebuild, replay the compiler, enumerate tests, or replace retained artifacts.
@Test(.enabled(if: ProcessInfo.processInfo.environment["IMPACT_SEALED_MERGE_REPLAY"] != nil))
func sealedImportedMergeReplay() throws {
    struct Input: Decodable { var retained: String; var output: String }
    struct Export: Decodable { var files: [String: String] }
    let path = try #require(ProcessInfo.processInfo.environment["IMPACT_SEALED_MERGE_REPLAY"])
    let inputs = try JSONDecoder().decode([Input].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    for input in inputs {
        let root = URL(fileURLWithPath: input.retained).resolvingSymlinksInPath()
        let source = root.appendingPathComponent("source"), session = root.appendingPathComponent("SILCapture")
        let derived = root.appendingPathComponent("DerivedData"), export = root.appendingPathComponent("source-export.json")
        let seal = try JSONDecoder().decode(CapturedSIL.Seal.self, from: Data(contentsOf: session.appendingPathComponent("build.json")))
        let exported = try JSONDecoder().decode(Export.self, from: Data(contentsOf: export))
        try #require(try ArtifactFiles.manifest(at: source) == exported.files)
        let products = derived.appendingPathComponent("Build/Products")
        let run = try #require(FileManager.default.contentsOfDirectory(at: products, includingPropertiesForKeys: nil).first { $0.pathExtension == "xctestrun" })
        let build = XcodeBuildInputs(derivedData: derived, buildLog: session.appendingPathComponent("build.log"), buildSettings: session.appendingPathComponent("settings.json"), xctestrun: run, revision: seal.revision)
        var capture = try CapturedSIL.load(at: session, root: source, inputs: build,
            logDigest: ArtifactFiles.digest(build.buildLog), settingsDigest: ArtifactFiles.digest(build.buildSettings),
            products: ArtifactFiles.manifest(at: products), toolchain: ArtifactFiles.toolchain(at: source),
            exportedRevision: seal.revision, sourceExportDigest: ArtifactFiles.digest(export))
        capture.exportedSources = (source, exported.files)
        try #require(capture.diagnostics.isEmpty)
        try #require(Set(capture.modules.keys) == Set(seal.inventory.keys))
        var graph = try GraphArchive.decode(Data(contentsOf: root.appendingPathComponent("head-graph.json")))
        let ownership = graph.targets.reduce(into: [String: Set<String>]()) { result, target in
            if let module = graph.modules[target.name] { result[module, default: []].formUnion(target.sourceFiles) }
        }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        var phases: [String: Double] = [:]
        var dependency = XcodeCompilerGraph.extract(log: try String(contentsOf: build.buildLog, encoding: .utf8), sourceRoot: source,
            directory: source, derived: scratch, progress: { print($0) }, ownership: ownership, workers: 3, captured: capture,
            measurement: { phases[$0, default: 0] += $1 })
        try #require(phases["compilerReplay"] == nil)
        try #require(dependency.diagnostics.isEmpty)
        XcodeCompilerGraph.bind(tests: graph.tests, modules: graph.modules, sources: graph.sources, graph: &dependency)
        try #require(dependency.diagnostics.isEmpty)
        try #require(dependency.tests == graph.dependencies?.tests)
        graph.dependencies = dependency
        try graph.validateMappingSymbols(mappingFile: "<sealed replay>", revision: seal.revision, buildContext: [:])
        try capture.validateFiles()
        // The result is comparison evidence, not a replacement runnable artifact.
        graph.buildArtifact = nil
        try GraphArchive.encode(graph).write(to: URL(fileURLWithPath: input.output))
        print("SEALED MERGE REPLAY", input.output, phases)
    }
}
