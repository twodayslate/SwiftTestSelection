// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// Caller-owned bundles have stable paths, an exclusive creation operation and a
/// completion marker published last. They never belong to the graph cache LRU.
enum RetainedXcodeBuild {
    static func create(at path: URL, cache: URL) throws -> URL {
        let path = path.standardizedFileURL.resolvingSymlinksInPath()
        let cache = cache.standardizedFileURL.resolvingSymlinksInPath()
        guard path != cache, !path.path.hasPrefix(cache.path + "/"), !cache.path.hasPrefix(path.path + "/") else {
            throw ImpactError("Retained builds and analysis cache must use separate directories.")
        }
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        // withIntermediateDirectories:false refuses an existing leaf; no run can
        // overwrite another run's products or adopt a cancelled partial export.
        guard !FileManager.default.fileExists(atPath: path.path) else {
            throw ImpactError("Retained build directory already exists. Choose a new path or explicitly remove the old caller-owned bundle.")
        }
        // Foundation may accept an existing directory in a racing mkdir. Use the
        // POSIX exclusive operation for a hard ownership boundary.
        guard mkdir(path.path, 0o700) == 0 else { throw ImpactError("Cannot exclusively create retained build directory: \(path.path)") }
        try Data("incomplete".utf8).write(to: path.appendingPathComponent("state"), options: .atomic)
        return path
    }

    private struct Completion: Codable {
        var schemaVersion = 1
        var graphDigest: String
        var inputIdentity: [String: String]
    }

    static func publish(graph: inout XcodeTestGraph, revision: String, context: [String: String], toolchain: String,
                        workspace: URL, settings: Data, log: String, inputIdentity: [String: String]) throws -> URL {
        let products = workspace.appendingPathComponent("DerivedData/Build/Products")
        let runs = try FileManager.default.contentsOfDirectory(at: products, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "xctestrun" }
        guard runs.count == 1 else { throw ImpactError("Retained build requires exactly one .xctestrun; found \(runs.count). Specify one complete test plan.") }
        try ArtifactFiles.validateTestRun(runs[0], plan: context["testPlan"].flatMap { $0.isEmpty ? nil : $0 }, scheme: context["scheme"])
        let settingsFile = workspace.appendingPathComponent("build-settings.json")
        let logFile = workspace.appendingPathComponent("build.log")
        try settings.write(to: settingsFile, options: .atomic)
        try Data(log.utf8).write(to: logFile, options: .atomic)
        var context = context
        let decoded = try JSONDecoder().decode([XcodeBuildSettings].self, from: settings)
        context["sdkAndArchitecture"] = Set(decoded.map { entry in
            ["CONFIGURATION", "SDK_NAME", "PLATFORM_NAME", "ARCHS"].map { entry.buildSettings[$0] ?? "" }.joined(separator: "|")
        }).sorted().joined(separator: "\n")
        graph.buildArtifact = XcodeBuildArtifact(revision: revision, context: context, toolchain: toolchain,
            buildLogDigest: try ArtifactFiles.digest(logFile), buildSettingsDigest: try ArtifactFiles.digest(settingsFile),
            productsDirectory: products.path, xctestrun: runs[0].lastPathComponent, products: try ArtifactFiles.manifest(at: products))
        graph.buildArtifact?.simulatorRuntimes = inputIdentity["simulatorRuntimes"]
        let graphFile = workspace.appendingPathComponent("head-graph.json")
        let encoder = JSONEncoder()
        try encoder.encode(graph).write(to: graphFile, options: .atomic)
        let completion = Completion(graphDigest: try ArtifactFiles.digest(graphFile), inputIdentity: inputIdentity)
        try encoder.encode(completion).write(to: workspace.appendingPathComponent("complete.json"), options: .atomic)
        try FileManager.default.removeItem(at: workspace.appendingPathComponent("state"))
        return graphFile
    }

    static func load(from path: URL) throws -> XcodeTestGraph {
        guard !FileManager.default.fileExists(atPath: path.deletingLastPathComponent().appendingPathComponent("state").path) else {
            throw ImpactError("Retained build is incomplete. Build and select again into a new directory.")
        }
        let completion = try JSONDecoder().decode(Completion.self, from: Data(contentsOf: path.deletingLastPathComponent().appendingPathComponent("complete.json")))
        guard completion.schemaVersion == 1, completion.graphDigest == (try ArtifactFiles.digest(path)) else {
            throw ImpactError("Retained head graph is incomplete, corrupt, or incompatible. Build and select again.")
        }
        return try GraphArchive.decodeValue(XcodeTestGraph.self, from: Data(contentsOf: path))
    }
}

extension XcodeAnalysis {
    /// Loads manual captures or completed retained bundles; partial retained builds
    /// cannot be adopted as ordinary saved graphs after cancellation.
    public static func executionGraph(at path: URL) throws -> XcodeTestGraph {
        let parent = path.deletingLastPathComponent()
        if ["state", "complete.json"].contains(where: { FileManager.default.fileExists(atPath: parent.appendingPathComponent($0).path) }) {
            return try RetainedXcodeBuild.load(from: path)
        }
        return try GraphArchive.decodeValue(XcodeTestGraph.self, from: Data(contentsOf: path))
    }
}
