// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Opt-in cache for committed revisions. context must fingerprint inputs outside
/// Git/build settings (for example script environment and external local packages).
public struct XcodeAnalysisCache: Sendable {
    public var directory: URL
    public var context: String
    public var maximumBytes: Int64

    public init(directory: URL, context: String, maximumBytes: Int64 = 5 * 1_024 * 1_024 * 1_024) {
        self.directory = directory.standardizedFileURL.resolvingSymlinksInPath()
        self.context = context
        self.maximumBytes = maximumBytes
    }
}

public struct XcodeAnalysisEvent: Codable, Sendable {
    public var phase: String
    public var revision: String
    public var seconds: Double
    public var detail: String
}

/// One OS lock covers publication, reads, eviction, and staging. A killed process
/// releases the lock; the next holder removes its abandoned staging directory.
/// Different cache directories can run concurrently; no reader observes pruning.
final class XcodeGraphCache {
    private let descriptor: Int32
    let options: XcodeAnalysisCache
    let progress: (String) -> Void
    private let fm = FileManager.default
    private let workspaceName = "work-" + UUID().uuidString
    var work: URL { options.directory.appendingPathComponent(workspaceName) }

    init(_ options: XcodeAnalysisCache, progress: @escaping (String) -> Void) throws {
        guard options.maximumBytes > 0, !options.context.isEmpty else {
            throw ImpactError("Analysis caching requires a nonempty --cache-context and positive --cache-max-bytes.")
        }
        self.options = options; self.progress = progress
        let fm = FileManager.default
        try fm.createDirectory(at: options.directory, withIntermediateDirectories: true)
        let descriptor = open(options.directory.appendingPathComponent("lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw ImpactError("Cannot open analysis cache lock.") }
        progress("Waiting for analysis cache lock: \(options.directory.path)")
        guard flock(descriptor, LOCK_EX) == 0 else {
            close(descriptor); throw ImpactError("Cannot lock analysis cache.")
        }
        do {
            let marker = options.directory.appendingPathComponent(".swift-test-impact-cache-v1")
            if !fm.fileExists(atPath: marker.path) {
                guard try fm.contentsOfDirectory(atPath: options.directory.path).allSatisfy({ $0 == "lock" }) else {
                    throw ImpactError("Analysis cache directory is not empty and has no ownership marker. Choose a dedicated cache directory.")
                }
                try Data("1".utf8).write(to: marker, options: .atomic)
            }
        } catch {
            _ = flock(descriptor, LOCK_UN); close(descriptor); throw error
        }
        self.descriptor = descriptor
    }

    deinit { _ = flock(descriptor, LOCK_UN); close(descriptor) }

    /// argv[0] may be a bare PATH command, or an arbitrary launcher-supplied name.
    /// Ask the loader which executable is running instead of resolving that name.
    static func analyzerExecutable() throws -> URL {
        #if canImport(Darwin)
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        var buffer = [CChar](repeating: 0, count: Int(size))
        guard _NSGetExecutablePath(&buffer, &size) == 0 else {
            throw ImpactError("Cannot determine the running analyzer executable.")
        }
        let path = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        #else
        throw ImpactError("Xcode analysis requires macOS.")
        #endif
    }

    static func digest(_ data: Data) -> String {
        #if canImport(CryptoKit)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #else
        preconditionFailure("Xcode caching requires CryptoKit")
        #endif
    }

    // Xcode/simctl inventories are sets; their array and dictionary order varies
    // between invocations. Build-setting values themselves are opaque strings.
    static func canonicalInventory(_ data: Data) throws -> Data {
        guard !data.isEmpty else { return data }
        func normalize(_ value: Any) throws -> Any {
            if let values = value as? [String: Any] { return try values.mapValues(normalize) }
            if let values = value as? [Any] {
                return try values.map(normalize).sorted {
                    let a = try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys, .fragmentsAllowed])
                    let b = try JSONSerialization.data(withJSONObject: $1, options: [.sortedKeys, .fragmentsAllowed])
                    return a.lexicographicallyPrecedes(b)
                }
            }
            return value
        }
        return try JSONSerialization.data(withJSONObject: normalize(JSONSerialization.jsonObject(with: data)), options: [.sortedKeys, .withoutEscapingSlashes])
    }

    static func runtimeFingerprint(_ data: Data) throws -> String {
        guard !data.isEmpty else { return digest(data) }
        guard var inventory = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let runtimes = inventory["runtimes"] as? [[String: Any]] else {
            throw ImpactError("Unsupported simulator runtime inventory.")
        }
        inventory["runtimes"] = runtimes.map { runtime in
            var result = runtime
            result.removeValue(forKey: "lastUsage") // Changes whenever discovery boots a runtime.
            return result
        }
        return try digest(canonicalInventory(JSONSerialization.data(withJSONObject: inventory)))
    }

    static func key(_ identity: [String: String]) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return digest(try encoder.encode(identity))
    }

    private struct Entry: Codable {
        var identity: [String: String]
        var digest: String
    }

    func resetWork() throws {
        if fm.fileExists(atPath: work.path) { try fm.removeItem(at: work) }
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        // Only private staging names are removed. Committed entries are directories.
        for file in try fm.contentsOfDirectory(at: options.directory, includingPropertiesForKeys: nil)
            where file.lastPathComponent.hasPrefix("stage-") ||
                file.lastPathComponent.hasPrefix("work-") && file.lastPathComponent != workspaceName {
                try fm.removeItem(at: file)
            }
    }

    func load(_ identity: [String: String]) throws -> XcodeTestGraph? {
        let key = try Self.key(identity)
        let entry = options.directory.appendingPathComponent(key)
        guard fm.fileExists(atPath: entry.path) else {
            progress("Cache miss \(key.prefix(12)): no entry matching revision, analyzer, toolchain, settings and input context")
            return nil
        }
        do {
            let manifest = try JSONDecoder().decode(Entry.self, from: Data(contentsOf: entry.appendingPathComponent("manifest.json")))
            let data = try Data(contentsOf: entry.appendingPathComponent("graph.json"))
            guard manifest.identity == identity, manifest.digest == Self.digest(data) else { throw ImpactError("identity/checksum mismatch") }
            let graph = try JSONDecoder().decode(XcodeTestGraph.self, from: data)
            guard graph.schemaVersion == 2, graph.analysisKind == "xcode-sil-and-ui-mappings", graph.dependencies != nil,
                  !graph.tests.isEmpty, graph.buildArtifact == nil else { throw ImpactError("unsupported or incomplete graph") }
            try fm.setAttributes([.modificationDate: Date()], ofItemAtPath: entry.path)
            progress("Cache hit \(key.prefix(12)): validated graph, source snapshots and complete test inventory")
            return graph
        } catch {
            progress("Cache invalidated \(key.prefix(12)): \(error); rebuilding")
            try fm.removeItem(at: entry)
            return nil
        }
    }

    func store(_ graph: XcodeTestGraph, identity: [String: String]) throws {
        guard graph.dependencies != nil, !graph.tests.isEmpty, graph.buildArtifact == nil else {
            throw ImpactError("Refusing to cache an empty graph or execution products.")
        }
        let destination = options.directory.appendingPathComponent(try Self.key(identity))
        let stage = options.directory.appendingPathComponent("stage-" + UUID().uuidString)
        try fm.createDirectory(at: stage, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: stage) }
        let encoder = JSONEncoder()
        let data = try encoder.encode(graph)
        let manifest = try encoder.encode(Entry(identity: identity, digest: Self.digest(data)))
        guard Int64(data.count + manifest.count) <= options.maximumBytes else {
            progress("Cache bypass: graph exceeds --cache-max-bytes; analysis remains usable")
            return
        }
        try data.write(to: stage.appendingPathComponent("graph.json"))
        try manifest.write(to: stage.appendingPathComponent("manifest.json"))
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.moveItem(at: stage, to: destination)
        try prune()
    }

    func prune() throws {
        let entries = try fm.contentsOfDirectory(at: options.directory, includingPropertiesForKeys: [.contentModificationDateKey])
            .filter { $0.lastPathComponent.count == 64 && $0.lastPathComponent.allSatisfy(\.isHexDigit) }
            .sorted { (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast <
                      (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast }
        var sizes: [URL: Int64] = [:]
        for entry in entries {
            let files = try fm.contentsOfDirectory(at: entry, includingPropertiesForKeys: [.fileSizeKey])
            sizes[entry] = try files.reduce(0) { try $0 + Int64($1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
        }
        var total = sizes.values.reduce(0, +)
        for entry in entries where total > options.maximumBytes {
            try fm.removeItem(at: entry); total -= sizes[entry]!
            progress("Cache evicted \(entry.lastPathComponent.prefix(12)): disk budget")
        }
    }
}

extension XcodeAnalysis {
    func selectCached(base: String, head: String, mergeBase: Bool, fullSuite: Bool, cache configuration: XcodeAnalysisCache) throws -> ImpactReport {
        let root = try GitChanges.repositoryRoot(at: options.path.deletingLastPathComponent())
        let context = try artifactContext(root: root)
        let comparison = try RevisionComparison(base: base, head: head, mergeBase: mergeBase, root: root)
        let changes = try GitChanges.readComparison(base: comparison.base, head: comparison.head, at: root)
        let cache = try XcodeGraphCache(configuration, progress: progress)
        try cache.resetWork(); try cache.prune()
        defer { try? FileManager.default.removeItem(at: cache.work) }
        var events: [XcodeAnalysisEvent] = []
        func timed<T>(_ phase: String, revision: String, detail: String = "", _ body: () throws -> T) rethrows -> T {
            let start = Date()
            defer {
                let seconds = Date().timeIntervalSince(start)
                events.append(.init(phase: phase, revision: revision, seconds: seconds, detail: detail))
                progress(String(format: "%@: %.2f s (%@)", phase, seconds, String(revision.prefix(12))))
            }
            return try body()
        }
        let toolchain = try ArtifactFiles.toolchain(at: root)
        let sdk = try CommandRunner.run("xcodebuild", ["-showsdks", "-json"], at: root).text
        let analyzer = try ArtifactFiles.digest(XcodeGraphCache.analyzerExecutable())
        let origin = try CommandRunner.run("git", ["remote", "get-url", "origin"], at: root, allowFailure: true)
        let repository = origin.status == 0 ? origin.text : try CommandRunner.run("git", ["rev-parse", "--path-format=absolute", "--git-common-dir"], at: root).text
        let runtimes = options.destination.contains("Simulator") ? try CommandRunner.run("xcrun", ["simctl", "list", "runtimes", "-j"], at: root).stdout : Data()
        func graph(_ revision: String) throws -> XcodeTestGraph {
            try cache.resetWork()
            let source = cache.work.appendingPathComponent("source")
            let derived = cache.work.appendingPathComponent("DerivedData")
            try GitChanges.export(base: revision, from: root, into: source)
            var options = self.options; options.path = source.appendingPathComponent(context["path"]!)
            // Resolve settings/packages before lookup. No build, enumeration, or
            // compiler extraction occurs on a hit. Locked resolution cannot float.
            let args = options.arguments(action: "build-for-testing", derivedData: derived) + ["-onlyUsePackageVersionsFromResolvedFile"]
            let settings = try timed("buildSettings", revision: revision) {
                try CommandRunner.run("xcodebuild", args + ["-showBuildSettings", "-json"], at: options.path.deletingLastPathComponent()).stdout
            }
            let decoded = try JSONDecoder().decode([XcodeBuildSettings].self, from: settings)
            guard !decoded.isEmpty else { throw ImpactError("Cannot cache empty build settings.") }
            let normalized = String(decoding: try XcodeGraphCache.canonicalInventory(settings), as: UTF8.self).replacingOccurrences(of: cache.work.path, with: "<CACHE-WORK>")
            var identity = context
            identity["schema"] = "xcode-analysis-cache-1/graph-2"
            identity["repository"] = XcodeGraphCache.digest(Data(repository.utf8))
            identity["revision"] = revision
            identity["analyzerExecutable"] = analyzer
            identity["toolchain"] = toolchain
            identity["sdks"] = XcodeGraphCache.digest(try XcodeGraphCache.canonicalInventory(Data(sdk.utf8)))
            identity["simulatorRuntimes"] = try XcodeGraphCache.runtimeFingerprint(runtimes)
            identity["settings"] = XcodeGraphCache.digest(Data(normalized.utf8))
            identity["externalInputs"] = configuration.context
            let found = try timed("graphLoad", revision: revision) { try cache.load(identity) }
            events.append(.init(phase: "cache", revision: revision, seconds: 0, detail: found == nil ? "miss: incompatible or absent entry; fresh build required" : "hit: no build, enumeration or extraction"))
            if let found { return found }
            let build = try timed("build", revision: revision) {
                try CommandRunner.run("xcodebuild", args, at: options.path.deletingLastPathComponent())
            }
            var measured = self
            measured.measurement = { phase, seconds in
                events.append(.init(phase: phase, revision: revision, seconds: seconds, detail: "fresh analysis"))
            }
            let result = try measured.analyzeBuild(options, sourceRoot: source, derived: derived, log: build.text, settingsData: settings)
            try timed("graphPublish", revision: revision) { try cache.store(result, identity: identity) }
            return result
        }
        let current = try graph(comparison.head!)
        var previous: XcodeTestGraph?
        var fallbacks: [String] = []
        if comparison.base == comparison.head { previous = current }
        else {
            do { previous = try graph(comparison.base) }
            catch { fallbacks.append("Cannot analyze base revision: \(error)") }
        }
        var report = timed("selection", revision: comparison.head!) {
            XcodeSelector.select(current: current, previous: previous, changes: changes, baseRevision: comparison.base, additionalFallbacks: fallbacks)
        }
        report.headRevision = comparison.head; report.comparisonMode = comparison.mode
        if fullSuite {
            report.selectedTests = current.tests.sorted()
            report.onlyTestingArguments = report.selectedTests.map { "-only-testing:" + $0 }
            report.explanations += report.selectedTests.map { TestExplanation(test: $0, reason: "Full suite explicitly requested", revision: "head", path: [], kind: "fullSuite") }
        }
        report.analysisEvents = events
        return report
    }
}
