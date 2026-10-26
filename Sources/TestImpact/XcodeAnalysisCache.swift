// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

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

/// A cache-only baseline policy never builds the base revision. The default
/// preserves the existing two-revision build behavior.
public enum XcodeCachedBasePolicy: String, Sendable {
    case build
    case require
    case fullSuite = "full-suite"
}

/// CLI exit status 3. Encoded as one JSON line on stderr, never as a test report.
public struct XcodeCachedBaseUnavailable: Error, Codable, Sendable {
    public let code: String
    public let revision: String
    public let reason: String

    init(revision: String, reason: String) {
        self.code = "cached_base_unavailable"
        self.revision = revision
        self.reason = reason
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

    /// Rewrite only known spellings of this exact workspace, at path boundaries.
    /// Settings can contain /tmp even when the exported workspace uses /private/tmp.
    static func normalizedSettings(_ data: Data, workspace: URL, aliases: [URL] = []) throws -> Data {
        func physical(_ url: URL) -> String {
            if let path = realpath(url.path, nil) { defer { free(path) }; return String(cString: path) }
            return url.standardizedFileURL.resolvingSymlinksInPath().path
        }
        let canonical = physical(workspace)
        var paths = Set([canonical, workspace.standardizedFileURL.path])
        for alias in aliases where physical(alias) == canonical { paths.insert(alias.standardizedFileURL.path) }
        // Darwin's system aliases are bidirectional; Foundation sometimes keeps
        // the short spelling. Confirm each candidate still resolves to this root.
        for path in Array(paths) {
            for short in ["/tmp", "/var", "/etc"] {
                let long = "/private" + short
                let alternate: String?
                if path.hasPrefix(long + "/") { alternate = String(path.dropFirst(8)) }
                else if path.hasPrefix(short + "/") { alternate = "/private" + path }
                else { alternate = nil }
                if let alternate, physical(URL(fileURLWithPath: alternate)) == canonical { paths.insert(alternate) }
            }
        }
        paths.formUnion(paths.map { $0.replacingOccurrences(of: " ", with: "\\ ") })
        let expressions = try paths.sorted { $0.count > $1.count }.map { path in
            try NSRegularExpression(pattern: #"(^|[\s"'=,:;@])(-[IFL])?"# + NSRegularExpression.escapedPattern(for: path) + #"(?=$|[/"'=,:;])"#)
        }
        func normalize(_ value: Any) -> Any {
            if let values = value as? [String: Any] { return values.mapValues(normalize) }
            if let values = value as? [Any] { return values.map(normalize) }
            guard var string = value as? String else { return value }
            for expression in expressions {
                string = expression.stringByReplacingMatches(in: string, range: NSRange(string.startIndex..., in: string), withTemplate: "$1$2<CACHE-WORK>")
            }
            return string
        }
        return try canonicalInventory(JSONSerialization.data(withJSONObject: normalize(JSONSerialization.jsonObject(with: data))))
    }

    static func key(_ identity: [String: String]) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return digest(try encoder.encode(identity))
    }

    private struct Entry: Codable {
        var identity: [String: String]
        var digest: String
        var payload: String? = nil
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

    func load(_ identity: [String: String], onMiss: (String) -> Void = { _ in }) throws -> XcodeTestGraph? {
        try load(identity, as: XcodeTestGraph.self, onMiss: onMiss) { graph in
            guard graph.schemaVersion == 2, graph.analysisKind == "xcode-sil-and-ui-mappings", graph.dependencies != nil,
                  !graph.tests.isEmpty, graph.buildArtifact == nil else { throw ImpactError("unsupported or incomplete graph") }
        }
    }

    func loadModule(_ identity: [String: String], report: Bool = true) throws -> SILModule? {
        try load(identity, as: SILModule.self, report: report) { module in
            guard !module.functions.isEmpty else { throw ImpactError("empty module fragment") }
        }
    }

    private func load<T: Decodable>(_ identity: [String: String], as type: T.Type, report: Bool = true, onMiss: (String) -> Void = { _ in }, validate: (T) throws -> Void) throws -> T? {
        let notify: (String) -> Void = report ? progress : { _ in }
        let key = try Self.key(identity)
        let entry = options.directory.appendingPathComponent(key)
        guard fm.fileExists(atPath: entry.path) else {
            let reason = "No entry matching analyzer, toolchain, settings and input identity (absent, evicted or incompatible)"
            notify("Cache miss \(key.prefix(12)): \(reason)")
            onMiss(reason)
            return nil
        }
        do {
            let manifest = try JSONDecoder().decode(Entry.self, from: Data(contentsOf: entry.appendingPathComponent("manifest.json")))
            let payload = manifest.payload ?? "graph.json"
            guard ["graph.json", "graph.bin"].contains(payload) else { throw ImpactError("unsupported cache payload") }
            let data = try Data(contentsOf: entry.appendingPathComponent(payload))
            guard manifest.identity == identity, manifest.digest == Self.digest(data) else { throw ImpactError("identity/checksum mismatch") }
            let graph = try GraphArchive.decodeValue(type, from: data)
            try validate(graph)
            try fm.setAttributes([.modificationDate: Date()], ofItemAtPath: entry.path)
            notify("Cache hit \(key.prefix(12)): validated identity and payload checksum")
            return graph
        } catch {
            notify("Cache invalidated \(key.prefix(12)): \(error)")
            onMiss("Invalid cache entry: \(error)")
            try fm.removeItem(at: entry)
            return nil
        }
    }

    func store(_ graph: XcodeTestGraph, identity: [String: String]) throws {
        guard graph.dependencies != nil, !graph.tests.isEmpty, graph.buildArtifact == nil else {
            throw ImpactError("Refusing to cache an empty graph or execution products.")
        }
        try publish(graph, identity: identity)
    }

    func storeModule(_ module: SILModule, identity: [String: String]) throws {
        guard !module.functions.isEmpty else { throw ImpactError("Refusing to cache an empty module fragment.") }
        try publish(module, identity: identity)
    }

    private func publish<T: Encodable>(_ graph: T, identity: [String: String]) throws {
        let destination = options.directory.appendingPathComponent(try Self.key(identity))
        let stage = options.directory.appendingPathComponent("stage-" + UUID().uuidString)
        try fm.createDirectory(at: stage, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: stage) }
        let encoder = JSONEncoder()
        let data = try GraphArchive.encodeValue(graph)
        let manifest = try encoder.encode(Entry(identity: identity, digest: Self.digest(data), payload: "graph.bin"))
        guard Int64(data.count + manifest.count) <= options.maximumBytes else {
            progress("Cache bypass: graph exceeds --cache-max-bytes; analysis remains usable")
            return
        }
        try data.write(to: stage.appendingPathComponent("graph.bin"))
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
    func selectCached(base: String, head: String, mergeBase: Bool, fullSuite: Bool, cache configuration: XcodeAnalysisCache, retainingBuildAt retained: URL? = nil, cachedBasePolicy: XcodeCachedBasePolicy = .build, headOnly: Bool = false) throws -> ImpactReport {
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
        let captureMode = try options.buildTimeSILHelper.map { try XcodeBuildTimeCapture(helper: $0) }
        var pendingCapture: (workspace: URL, settings: Data, identity: [String: String], capture: CapturedSIL)?
        var retainedGraphPath: String?
        var headDocumentation = Set<String>()
        var headBuildUncertainty: String?
        func graph(_ revision: String, keepBuild: Bool = false, cacheOnly: Bool = false) throws -> XcodeTestGraph {
            try extractionCancellation.check()
            try cache.resetWork()
            let workspace: URL
            if keepBuild, let retained {
                workspace = try RetainedXcodeBuild.create(at: retained, cache: configuration.directory)
                progress("Retaining head build at \(workspace.path); incomplete bundles after cancellation require explicit cleanup.")
            } else { workspace = cache.work }
            let source = workspace.appendingPathComponent("source")
            let derived = workspace.appendingPathComponent("DerivedData")
            try GitChanges.export(base: revision, from: root, into: source)
            var options = self.options; options.path = source.appendingPathComponent(context["path"]!)
            // Resolve settings/packages before lookup. No build, enumeration, or
            // compiler extraction occurs on a hit. Locked resolution cannot float.
            let args = options.arguments(action: "build-for-testing", derivedData: derived) + ["-onlyUsePackageVersionsFromResolvedFile"]
            var settings = try timed("buildSettings", revision: revision) {
                try CommandRunner.run("xcodebuild", args + ["-showBuildSettings", "-json"], at: options.path.deletingLastPathComponent()).stdout
            }
            let decoded = try JSONDecoder().decode([XcodeBuildSettings].self, from: settings)
            guard !decoded.isEmpty else { throw ImpactError("Cannot cache empty build settings.") }
            let normalized = try XcodeGraphCache.normalizedSettings(settings, workspace: workspace, aliases: keepBuild ? retained.map { [$0] } ?? [] : [])
            var identity = context
            identity["schema"] = "xcode-analysis-cache-1/graph-2"
            identity["repository"] = XcodeGraphCache.digest(Data(repository.utf8))
            identity["revision"] = revision
            identity["analyzerExecutable"] = analyzer
            identity["toolchain"] = toolchain
            identity["sdks"] = XcodeGraphCache.digest(try XcodeGraphCache.canonicalInventory(Data(sdk.utf8)))
            identity["simulatorRuntimes"] = try XcodeGraphCache.runtimeFingerprint(runtimes)
            identity["settings"] = XcodeGraphCache.digest(normalized)
            identity["externalInputs"] = configuration.context
            identity["buildTimeSIL"] = captureMode?.identity ?? "replay"
            var missReason = "No compatible cache entry"
            let found = try timed("graphLoad", revision: revision) { try cache.load(identity, onMiss: { missReason = $0 }) }
            events.append(.init(phase: "cache", revision: revision, seconds: 0, detail: found == nil ? "miss: " + missReason : "hit: no build, enumeration or extraction"))
            if let found, !keepBuild { return found }
            if cacheOnly { throw XcodeCachedBaseUnavailable(revision: revision, reason: missReason) }
            if found != nil { progress("Reusing head analysis; building its executable products once for retention.") }
            let buildLog = keepBuild ? workspace.appendingPathComponent("build.log") : nil
            if let buildLog {
                try settings.write(to: workspace.appendingPathComponent("build-settings.json"), options: .atomic)
                progress("Full build log (retained on failure): \(buildLog.path)")
            }
            // Keep diagnostics outside disposable cache work from the outset:
            // cancellation cannot depend on running a catch/defer copy.
            let captureDiagnostics: URL?
            if captureMode != nil, !keepBuild {
                captureDiagnostics = retained?.appendingPathComponent("base-capture-failure") ?? FileManager.default.temporaryDirectory.appendingPathComponent("swift-test-impact-capture-" + UUID().uuidString)
                try FileManager.default.createDirectory(at: captureDiagnostics!, withIntermediateDirectories: false)
            } else { captureDiagnostics = nil }
            var graphSucceeded = false
            defer {
                if graphSucceeded, let captureDiagnostics { try? FileManager.default.removeItem(at: captureDiagnostics) }
            }
            let buildText: String
            var captured: CapturedSIL?
            if let captureMode {
                let captureStart = Date()
                let result = try captureMode.build(options: options, source: source, workspace: workspace,
                    revision: revision, context: configuration.context, diagnostics: captureDiagnostics, progress: progress)
                buildText = result.log; settings = result.settings; captured = result.captured
                events.append(.init(phase: "build", revision: revision, seconds: result.buildSeconds, detail: "build-for-testing with supplementary SIL"))
                events.append(.init(phase: "captureValidation", revision: revision, seconds: max(0, Date().timeIntervalSince(captureStart) - result.buildSeconds), detail: "wrapper setup, settings and export/product/capture seals"))
            } else {
                buildText = try timed("build", revision: revision) {
                    try CommandRunner.run("xcodebuild", args, at: options.path.deletingLastPathComponent(), combinedLog: buildLog).text
                }
            }
            try extractionCancellation.check()
            var measured = self
            measured.measurement = { phase, seconds in
                events.append(.init(phase: phase, revision: revision, seconds: seconds, detail: "fresh analysis"))
            }
            var result: XcodeTestGraph
            if let found, XcodeSourceOwnership.metadataMatches(found, log: buildText, root: source, derived: derived, captured: captured) {
                result = found
            }
            else {
                if found != nil { progress("Cached analysis has different or unverifiable generated-input/product-role evidence; extracting the new build.") }
                result = try measured.analyzeBuild(options, sourceRoot: source, derived: derived, log: buildText, settingsData: settings, moduleCache: XcodeModuleCache(cache: cache, identity: identity, source: source, derived: derived, workspace: workspace, directory: options.path.deletingLastPathComponent(), workers: options.extractionWorkers), captured: captured)
                try extractionCancellation.check()
                try captured?.validateFiles()
                try timed("graphPublish", revision: revision) { try cache.store(result, identity: identity) }
            }
            try extractionCancellation.check()
            try captured?.validateFiles()
            if headOnly {
                try timed("headBuildEvidence", revision: revision) {
                    let evidence = try XcodeBuildEvidence(log: buildText, root: source, derived: derived, captured: captured)
                    try evidence.validate(log: buildText, boundaries: result.generatedSourceBoundaries?.values.flatMap { $0 } ?? [])
                    let compiler = try CommandRunner.run("xcrun", ["--find", "swiftc"], at: source).text.trimmingCharacters(in: .whitespacesAndNewlines)
                    let files = try XcodeBuildEvidence.repositoryInputFiles(root: source, derived: derived)
                    let proof = evidence.documentationEvidence(files: files, compiler: compiler)
                    headDocumentation = Set(proof.allowed)
                    if !proof.uncertainty.isEmpty { headBuildUncertainty = proof.uncertainty.joined(separator: "; ") }
                }
            }
            if keepBuild, let captured {
                // Capture selection commits its retained bundle only after both
                // revision captures succeed. A bad base cannot leave a completed
                // executable capture bundle behind.
                pendingCapture = (workspace, settings, identity, captured)
            } else if keepBuild {
                retainedGraphPath = try timed("retainBuild", revision: revision) {
                    try RetainedXcodeBuild.publish(graph: &result, revision: revision, context: context,
                        toolchain: toolchain, workspace: workspace, settings: settings,
                        inputIdentity: identity)
                }.path
            }
            graphSucceeded = true
            return result
        }
        // Resolve and validate the actual baseline before creating a retained
        // head workspace. Keep the validated graph in memory across head cache
        // publication/eviction; never perform a second lookup that could rebuild.
        var previous: XcodeTestGraph?
        var baselineMiss: XcodeCachedBaseUnavailable?
        var fallbacks: [String] = []
        if cachedBasePolicy != .build && !fullSuite {
            do { previous = try graph(comparison.base, cacheOnly: true) }
            catch {
                try extractionCancellation.check()
                let miss = error as? XcodeCachedBaseUnavailable ?? XcodeCachedBaseUnavailable(
                    revision: comparison.base, reason: "Baseline validation failed: \(error)")
                if cachedBasePolicy == .require { throw miss }
                baselineMiss = miss
                fallbacks.append("Cached baseline unavailable at \(miss.revision): \(miss.reason); full suite requested by policy")
                events.append(.init(phase: "cachedBaseFallback", revision: miss.revision, seconds: 0, detail: miss.reason))
                progress(fallbacks.last!)
            }
        }
        var current = try graph(comparison.head!, keepBuild: retained != nil)
        if !headOnly && cachedBasePolicy == .build {
            if comparison.base == comparison.head { previous = current }
            else {
                do { previous = try graph(comparison.base) }
                catch {
                    if captureMode != nil { throw error }
                    fallbacks.append("Cannot analyze base revision: \(error)")
                }
            }
        } else if fullSuite { previous = current }
        if let pendingCapture {
            try extractionCancellation.check()
            try pendingCapture.capture.validateFiles()
            retainedGraphPath = try timed("retainBuild", revision: comparison.head!) {
                try RetainedXcodeBuild.publish(graph: &current, revision: comparison.head!, context: context,
                    toolchain: toolchain, workspace: pendingCapture.workspace, settings: pendingCapture.settings,
                    inputIdentity: pendingCapture.identity, capture: pendingCapture.capture)
            }.path
        }
        let baseSources = try headOnly ? timed("baseSourceSyntax", revision: comparison.base, detail: "Git syntax only; no baseline build or compiler graph") {
            try XcodeHeadOnlySources.read(current: current, changes: changes, base: comparison.base, root: root, mappingPath: options.mappingsPath)
        } : nil
        var report = timed("selection", revision: comparison.head!) {
            if let baseSources {
                return XcodeHeadOnlySelector.select(current: current, source: baseSources, changes: changes,
                    baseRevision: comparison.base, documentation: headDocumentation, buildEvidenceFailure: headBuildUncertainty)
            }
            return XcodeSelector.select(current: current, previous: previous, changes: changes, baseRevision: comparison.base, additionalFallbacks: fallbacks)
        }
        report.headRevision = comparison.head; report.comparisonMode = comparison.mode
        report.buildArtifactID = current.buildArtifact?.id
        report.buildArtifactPath = retainedGraphPath
        if fullSuite || baselineMiss != nil {
            report.selectedTests = current.tests.sorted()
            report.onlyTestingArguments = report.selectedTests.map { "-only-testing:" + $0 }
            report.explanations += report.selectedTests.map { TestExplanation(test: $0, reason: baselineMiss == nil ? "Full suite explicitly requested" : "Full suite requested by cached-base miss policy", revision: "head", path: [], kind: "fullSuite") }
        }
        if let baselineMiss {
            report.diagnostics.append(SelectionDiagnostic(code: baselineMiss.code,
                message: "\(baselineMiss.revision): \(baselineMiss.reason)", tests: current.tests.sorted()))
        }
        report.analysisEvents = events
        return report
    }
}
