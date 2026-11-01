// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

/// Saved graph provenance. Base products are not needed to compare cached graphs.
public struct XcodeBuildArtifact: Codable, Sendable {
    public var schemaVersion = 1
    public var id = UUID().uuidString
    public var revision: String
    public var context: [String: String]
    public var toolchain: String
    public var simulatorRuntimes: String? = nil
    public var buildLogDigest: String
    public var buildSettingsDigest: String
    public var productsDirectory: String
    public var xctestrun: String
    public var products: [String: String]
    public var helperBindingBuildFailure: String? = nil
    public var headOnlyBuildEvidence: HeadOnlyBuildEvidence? = nil
    public var helperBindingBuild: HelperBindingBuildEvidence? = nil
    public var helperBindingInputs: String? = nil
    public var helperFormattingBuild: HelperFormattingBuildEvidence? = nil
}

/// Inputs from one successful build-for-testing invocation, kept at their original
/// locations until graph capture completes. revision asserts what was built.
public struct XcodeBuildInputs: Sendable {
    public var derivedData: URL
    public var buildLog: URL
    public var buildSettings: URL
    public var xctestrun: URL
    public var revision: String
    public var discoveryCache: XcodeAnalysisCache?
    public var silCapture: URL?

    public init(derivedData: URL, buildLog: URL, buildSettings: URL, xctestrun: URL, revision: String, discoveryCache: XcodeAnalysisCache? = nil, silCapture: URL? = nil) {
        self.discoveryCache = discoveryCache
        self.silCapture = silCapture
        self.derivedData = derivedData.standardizedFileURL.resolvingSymlinksInPath()
        self.buildLog = buildLog
        self.buildSettings = buildSettings
        self.xctestrun = xctestrun.standardizedFileURL.resolvingSymlinksInPath()
        self.revision = revision
    }
}

extension XcodeAnalysis {
    /// Capture a graph without invoking build-for-testing. Compiler replay still
    /// emits SIL unless validated build-time capture is supplied. Executable
    /// products are never rebuilt by this operation.
    public func graph(from inputs: XcodeBuildInputs) throws -> XcodeTestGraph {
        let root = try GitChanges.repositoryRoot(at: options.path.deletingLastPathComponent())
        let revision = try GitChanges.revision(inputs.revision, at: root)
        try ArtifactFiles.validateCheckout(root: root, revision: revision, buildLog: inputs.buildLog)
        let logDigest = try ArtifactFiles.digest(inputs.buildLog)
        let settingsDigest = try ArtifactFiles.digest(inputs.buildSettings)
        let log = try String(contentsOf: inputs.buildLog, encoding: .utf8)
        guard log.contains("** TEST BUILD SUCCEEDED **"), log.contains("builtin-SwiftDriver -- ") else {
            throw ImpactError("Build log must contain a successful build-for-testing and complete SwiftDriver commands. Use an unfiltered full-build log.")
        }
        let data = try Data(contentsOf: inputs.buildSettings)
        let settings = try JSONDecoder().decode([XcodeBuildSettings].self, from: data)
        try ArtifactFiles.validateBuildLog(log, options: options, root: root, derived: inputs.derivedData, settings: settings)
        try ArtifactFiles.validateCompilerToolchain(log, at: root)
        let products = inputs.derivedData.appendingPathComponent("Build/Products").standardizedFileURL.resolvingSymlinksInPath()
        guard inputs.xctestrun.deletingLastPathComponent() == products else {
            throw ImpactError("--xctestrun must be directly inside --derived-data/Build/Products.")
        }
        try ArtifactFiles.validateSettings(settings, options: options, root: root, derived: inputs.derivedData)
        try ArtifactFiles.validateTestRun(inputs.xctestrun, plan: options.testPlan, scheme: options.scheme)
        progress("Fingerprinting existing test products…")
        let fingerprints = try ArtifactFiles.manifest(at: products, workers: options.extractionWorkers)
        let toolchain = try ArtifactFiles.toolchain(at: root)
        let sourceInputs = try ArtifactFiles.sourceInputs(log: log, directory: options.path.deletingLastPathComponent())
        let mappingInputs = try ArtifactFiles.mappingInputs(path: options.mappingsPath, root: root)
        let cache = try inputs.discoveryCache.map { try XcodeGraphCache($0, progress: progress) }
        try cache?.resetWork()
        defer { if let cache { try? FileManager.default.removeItem(at: cache.work) } }
        var identity = try artifactContext(root: root)
        identity["schema"] = "existing-build-discovery-1"
        identity["revision"] = revision
        identity["sourceRoot"] = root.path
        identity["productsRoot"] = products.path
        // Products can contain several runners with different enabled tests.
        identity["xctestrun"] = inputs.xctestrun.lastPathComponent
        identity["sourceInputs"] = try XcodeGraphCache.key(sourceInputs)
        identity["mappingInputs"] = try XcodeGraphCache.key(mappingInputs)
        identity["products"] = try XcodeGraphCache.key(fingerprints)
        identity["settings"] = settingsDigest
        identity["log"] = logDigest
        identity["toolchain"] = toolchain
        identity["runtimes"] = try ArtifactFiles.runtimeFingerprint(options: options, at: root)
        identity["analyzer"] = try ArtifactFiles.digest(XcodeGraphCache.analyzerExecutable())
        identity["discoveryContext"] = inputs.discoveryCache?.context
        let captured = try inputs.silCapture.map { try CapturedSIL.load(at: $0, root: root, inputs: inputs,
            logDigest: logDigest, settingsDigest: settingsDigest, products: fingerprints, toolchain: toolchain) }
        identity["capture"] = try inputs.silCapture.map { try ArtifactFiles.digest($0.appendingPathComponent("build.json")) } ?? "replay"
        let cached = try cache?.load(identity)
        var graph: XcodeTestGraph
        if let cached {
            progress("Discovery cache hit: exact build products, source revision, settings, runtime and discovery context; reusing inventory and bound graph")
            graph = cached
        } else {
            graph = try analyzeBuild(options, sourceRoot: root, derived: inputs.derivedData, log: log,
                settingsData: data, xctestrun: inputs.xctestrun, captured: captured,
                activeCompilerInputs: Set(sourceInputs.keys.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }))
        }
        try ArtifactFiles.validateCheckout(root: root, revision: revision, buildLog: inputs.buildLog)
        guard try logDigest == ArtifactFiles.digest(inputs.buildLog), try settingsDigest == ArtifactFiles.digest(inputs.buildSettings) else {
            throw ImpactError("Build log or settings changed during capture; retry with stable build inputs.")
        }
        guard try fingerprints == ArtifactFiles.manifest(at: products, workers: options.extractionWorkers) else {
            throw ImpactError("Test products changed during capture; build and capture again without concurrent builds.")
        }
        guard try sourceInputs == ArtifactFiles.sourceInputs(log: log, directory: options.path.deletingLastPathComponent()) else { throw ImpactError("Compiler source inputs changed during capture") }
        guard try mappingInputs == ArtifactFiles.mappingInputs(path: options.mappingsPath, root: root) else {
            throw ImpactError("UI mappings changed during capture; retry with stable inputs")
        }
        try captured?.validateFiles()
        if cached == nil { try cache?.store(graph, identity: identity) }
        var context = try artifactContext(root: root)
        context["sdkAndArchitecture"] = Set(settings.map { entry in
            ["CONFIGURATION", "SDK_NAME", "PLATFORM_NAME", "ARCHS"].map { entry.buildSettings[$0] ?? "" }.joined(separator: "|")
        }).sorted().joined(separator: "\n")
        graph.buildArtifact = XcodeBuildArtifact(revision: revision, context: context, toolchain: toolchain,
            buildLogDigest: logDigest, buildSettingsDigest: settingsDigest,
            productsDirectory: products.path, xctestrun: inputs.xctestrun.lastPathComponent, products: fingerprints)
        graph.buildArtifact?.simulatorRuntimes = try ArtifactFiles.runtimeFingerprint(options: options, at: root)
        graph.buildArtifact?.helperFormattingBuild = try? .capture(log: Data(log.utf8), settings: data, source: root, derived: inputs.derivedData, captured: captured)
        do {
            let evidence = try HelperBindingBuildEvidence.capture(log: log, source: root, sourceInputs: sourceInputs, artifact: graph.buildArtifact!)
            graph.buildArtifact?.helperBindingBuild = evidence
            graph.buildArtifact?.helperBindingInputs = evidence.fingerprint
        } catch {
            graph.buildArtifact?.helperBindingBuildFailure = String(describing: error)
        }
        return graph
    }

    /// Analyze only saved graphs and Git history. No Xcode or compiler subprocesses.
    public func select(base: String, head: String? = nil, mergeBase: Bool = false, fullSuite: Bool = false,
                       baseGraph: XcodeTestGraph, headGraph: XcodeTestGraph) throws -> ImpactReport {
        let root = try GitChanges.repositoryRoot(at: options.path.deletingLastPathComponent())
        let comparison = try RevisionComparison(base: base, head: head ?? "HEAD", mergeBase: mergeBase, root: root)
        let old = try validateArtifactGraph(baseGraph, root: root)
        let new = try validateArtifactGraph(headGraph, root: root)
        guard old.revision == comparison.base, new.revision == comparison.head else {
            throw ImpactError("Cached graph revision mismatch. Supply graphs for resolved base \(comparison.base) and head \(comparison.head!). Merge-base mode requires a graph of the common ancestor.")
        }
        guard old.context == new.context, old.toolchain == new.toolchain, old.simulatorRuntimes == new.simulatorRuntimes else {
            throw ImpactError("Cached graphs have incompatible build contexts, toolchains, or simulator runtimes. Recapture with matching scheme, plan, destination, configuration, SDK and architectures.")
        }
        try validateMappings(in: headGraph, revision: comparison.head!)
        let changes = try GitChanges.readComparison(base: comparison.base, head: comparison.head, at: root)
        var report = XcodeSelector.select(current: headGraph, previous: baseGraph, changes: changes, baseRevision: comparison.base)
        report.headRevision = comparison.head
        report.buildArtifactID = new.id
        report.comparisonMode = comparison.mode
        if fullSuite {
            report.selectedTests = headGraph.tests.sorted()
            report.onlyTestingArguments = report.selectedTests.map { "-only-testing:" + $0 }
            report.explanations += report.selectedTests.map { TestExplanation(test: $0, reason: "Full suite explicitly requested", revision: "head", path: [], kind: "fullSuite") }
        }
        return report
    }

    /// Execute the captured products, even if the checkout has subsequently changed.
    /// Optional relocation must preserve the entire Build/Products tree unchanged.
    public func run(_ report: ImpactReport, using graph: XcodeTestGraph, productsDirectory: URL? = nil) throws -> Int32 {
        try validateMappings(in: graph, revision: graph.buildArtifact?.revision ?? report.headRevision ?? "HEAD")
        let root = try GitChanges.repositoryRoot(at: options.path.deletingLastPathComponent())
        let artifact = try validateArtifactGraph(graph, root: root)
        guard report.headRevision == artifact.revision, report.buildArtifactID == artifact.id,
              Set(report.selectedTests).isSubset(of: Set(graph.tests)) else {
            throw ImpactError("Selection report does not match the captured head graph.")
        }
        guard !report.selectedTests.isEmpty else {
            progress("No selected tests; no Xcode test command was executed.")
            return 0
        }
        let testRun = try verifyBuild(report, using: graph, productsDirectory: productsDirectory)
        let results = options.path.deletingLastPathComponent().appendingPathComponent(".build/test-impact-results/\(UUID().uuidString).xcresult")
        try FileManager.default.createDirectory(at: results.deletingLastPathComponent(), withIntermediateDirectories: true)
        let arguments = try artifactExecutionArguments(tests: report.selectedTests, xctestrun: testRun, resultBundle: results)
        progress("Running \(report.selectedTests.count) selected tests without building; results: \(results.path)")
        let result = try CommandRunner.run("xcodebuild", arguments, at: root, allowFailure: true)
        progress(String(decoding: result.stdout + result.stderr, as: UTF8.self))
        return result.status
    }

    /// Validate a saved selection before handing its xctestrun to a custom runner.
    /// This performs no build or test execution. Empty selections remain empty.
    public func verifyBuild(_ report: ImpactReport, using graph: XcodeTestGraph, productsDirectory: URL? = nil) throws -> URL {
        try validateMappings(in: graph, revision: graph.buildArtifact?.revision ?? report.headRevision ?? "HEAD")
        let root = try GitChanges.repositoryRoot(at: options.path.deletingLastPathComponent())
        let artifact = try validateArtifactGraph(graph, root: root)
        guard report.headRevision == artifact.revision, report.buildArtifactID == artifact.id,
              Set(report.selectedTests).isSubset(of: Set(graph.tests)) else {
            throw ImpactError("Selection report does not match the captured head graph.")
        }
        let products = (productsDirectory ?? URL(fileURLWithPath: artifact.productsDirectory)).standardizedFileURL.resolvingSymlinksInPath()
        guard try artifact.products == ArtifactFiles.manifest(at: products, workers: options.extractionWorkers) else {
            throw ImpactError("Test products differ from the captured graph (missing, modified, or extra files). Restore the matching products or recapture the graph.")
        }
        guard try artifact.toolchain == ArtifactFiles.toolchain(at: root) else {
            throw ImpactError("Execution toolchain differs from the captured build.")
        }
        if let expected = artifact.simulatorRuntimes,
           try expected != ArtifactFiles.runtimeFingerprint(options: options, at: root) {
            throw ImpactError("Simulator runtimes differ from the captured build; build and select again.")
        }
        let testRun = products.appendingPathComponent(artifact.xctestrun)
        try ArtifactFiles.validateTestRun(testRun, plan: options.testPlan, scheme: options.scheme)
        return testRun
    }

    func artifactContext(root: URL) throws -> [String: String] {
        guard options.path.path.hasPrefix(root.path + "/") else { throw ImpactError("Xcode container must be inside the repository.") }
        return ["container": options.container.rawValue, "path": String(options.path.path.dropFirst(root.path.count + 1)),
                "scheme": options.scheme, "destination": options.destination, "configuration": options.configuration ?? "",
                "testPlan": options.testPlan ?? "", "mappings": options.mappingsPath]
    }

    func validateArtifactGraph(_ graph: XcodeTestGraph, root: URL) throws -> XcodeBuildArtifact {
        guard [2, 3, 4].contains(graph.schemaVersion), graph.mappings?.version != 2 || graph.schemaVersion >= 3, graph.analysisKind == "xcode-sil-and-ui-mappings", graph.dependencies != nil,
              !graph.tests.isEmpty, let artifact = graph.buildArtifact, artifact.schemaVersion == 1,
              !artifact.id.isEmpty, !artifact.toolchain.isEmpty, artifact.context["sdkAndArchitecture"]?.isEmpty == false,
              !artifact.products.isEmpty, artifact.products[artifact.xctestrun] != nil,
              artifact.xctestrun == URL(fileURLWithPath: artifact.xctestrun).lastPathComponent else {
            throw ImpactError("Graph lacks supported build-artifact provenance. Capture it with the existing-build graph options.")
        }
        for (key, value) in try artifactContext(root: root) where artifact.context[key] != value {
            throw ImpactError("Cached graph build context does not match --\(key): expected '\(value)', recorded '\(artifact.context[key] ?? "missing")'.")
        }
        return artifact
    }

    func artifactExecutionArguments(tests: [String], xctestrun: URL, resultBundle: URL) throws -> [String] {
        // Share identifier validation with the normal execution path.
        _ = try options.executionArguments(tests: tests, derivedData: resultBundle, resultBundle: resultBundle)
        return ["test-without-building", "-xctestrun", xctestrun.path, "-destination", options.destination,
                "-resultBundlePath", resultBundle.path] + tests.sorted().map { "-only-testing:" + $0 }
    }
}

// Internal so the invariants can be tested without requiring an Xcode build.
enum ArtifactFiles {
    static func digest(_ file: URL) throws -> String {
        #if canImport(CryptoKit)
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = SHA256()
        while try withSILAutoreleasePool({
            guard let data = try handle.read(upToCount: 1_048_576), !data.isEmpty else { return false }
            hash.update(data: data)
            return true
        }) {}
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
        #else
        throw ImpactError("Xcode artifact capture requires macOS with CryptoKit.")
        #endif
    }

    static func manifest(at root: URL, workers: Int = 1) throws -> [String: String] {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ImpactError("Test products directory is missing: \(root.path)")
        }
        var result: [String: String] = [:]
        var regularFiles: [(String, URL)] = []
        let canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath().path
        func walk(_ directory: URL, relative: String) throws {
            for file in try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey]) {
                let values = try file.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey])
                let path = relative + file.lastPathComponent
                if values.isSymbolicLink == true {
                    guard file.standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(canonicalRoot + "/") else {
                        throw ImpactError("Test product symlink escapes the products directory: \(path)")
                    }
                    result[path] = "symlink:" + (try fm.destinationOfSymbolicLink(atPath: file.path))
                } else if values.isDirectory == true { try walk(file, relative: path + "/") }
                else if values.isRegularFile == true { regularFiles.append((path, file)) }
                else { throw ImpactError("Unsupported test product file: \(path)") }
            }
        }
        try walk(root, relative: "")
        for (path, hash) in try BoundedWork.map(regularFiles, workers: workers, { ($0.0, try digest($0.1)) }) { result[path] = hash }
        guard !result.isEmpty else { throw ImpactError("Test products directory is empty.") }
        return result
    }

    static func mappingInputs(path: String, root: URL) throws -> [String: String] {
        let file = try UIFeatureMappings.fileURL(path: path, root: root)
        return ["path": file.path, "contents": FileManager.default.fileExists(atPath: file.path) ? try digest(file) : "missing"]
    }

    /// Fingerprint only inputs referenced by this build's compiler commands.
    /// DerivedData also retains lists from inactive configurations/removed targets.
    static func sourceInputs(log: String, directory: URL) throws -> [String: String] {
        var result = try XcodeBuildEvidence.fingerprints(log: log)
        var commandDirectory = directory
        var sources = Set<URL>()
        func absolute(_ path: String, at directory: URL) -> URL {
            URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: directory.path, isDirectory: true)).standardizedFileURL
        }
        func expand(_ arguments: [String], at directory: URL, visiting: Set<String> = []) throws -> [String] {
            var expanded: [String] = []
            for argument in arguments {
                guard argument.hasPrefix("@") else { expanded.append(argument); continue }
                let list = absolute(String(argument.dropFirst()), at: directory)
                let canonical = list.resolvingSymlinksInPath().path
                guard !visiting.contains(canonical), visiting.count < 64 else {
                    throw ImpactError("Recursive compiler response file: \(list.path)")
                }
                result[list.path] = canonical + ":" + (try digest(list))
                let contents = try XcodeSourceFileList.parse(String(contentsOf: list, encoding: .utf8))
                expanded += try expand(contents, at: directory, visiting: visiting.union([canonical]))
            }
            return expanded
        }
        for raw in log.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("cd ") {
                let paths = try XcodeSourceFileList.parse(String(line.dropFirst(3)))
                if paths.count == 1 { commandDirectory = absolute(paths[0], at: directory) }
            }
            guard let marker = line.range(of: "builtin-SwiftDriver -- ") else { continue }
            let arguments = try expand(XcodeSourceFileList.parse(String(line[marker.upperBound...])), at: commandDirectory)
            var sourceDirectory = commandDirectory
            if let i = arguments.lastIndex(of: "-working-directory"), i + 1 < arguments.count {
                sourceDirectory = absolute(arguments[i + 1], at: commandDirectory)
            }
            var i = 1 // Skip the compiler executable.
            while i < arguments.count {
                let argument = arguments[i]
                if argument == "-filelist" {
                    guard i + 1 < arguments.count else { throw ImpactError("Missing compiler file-list operand") }
                    let list = absolute(arguments[i + 1], at: sourceDirectory)
                    result[list.path] = list.resolvingSymlinksInPath().path + ":" + (try digest(list))
                    // -filelist uses literal paths, one per line, unlike @response files.
                    for path in try String(contentsOf: list, encoding: .utf8).split(whereSeparator: \.isNewline) {
                        sources.insert(absolute(String(path), at: sourceDirectory))
                    }
                    i += 2
                } else {
                    if argument.hasSuffix(".swift") { sources.insert(absolute(argument, at: sourceDirectory)) }
                    i += 1
                }
            }
        }
        guard !sources.isEmpty else { throw ImpactError("Missing compiler source inventory") }
        for source in sources {
            result[source.path] = source.resolvingSymlinksInPath().path + ":" + (try digest(source))
        }
        return result
    }

    static func toolchain(at root: URL) throws -> String {
        try CommandRunner.run("xcodebuild", ["-version"], at: root).text + CommandRunner.run("xcrun", ["swiftc", "--version"], at: root).text
    }

    static func runtimeFingerprint(options: XcodeConfiguration, at root: URL) throws -> String {
        let data = options.destination.contains("Simulator") ? try CommandRunner.run("xcrun", ["simctl", "list", "runtimes", "-j"], at: root).stdout : Data()
        return try XcodeGraphCache.runtimeFingerprint(data)
    }

    static func validateCheckout(root: URL, revision: String, buildLog: URL) throws {
        guard try GitChanges.revision("HEAD", at: root) == revision,
              try CommandRunner.run("git", ["status", "--porcelain", "--untracked-files=all"], at: root).stdout.isEmpty else {
            throw ImpactError("Artifact capture requires a clean checkout at --revision. Keep build outputs outside the repository or gitignored.")
        }
        guard let built = try buildLog.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else {
            throw ImpactError("Cannot determine build log timestamp for freshness validation.")
        }
        let paths = try CommandRunner.run("git", ["ls-files", "-z"], at: root).stdout.split(separator: 0)
        for path in paths {
            let file = root.appendingPathComponent(String(decoding: path, as: UTF8.self))
            if let date = try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, date > built {
                throw ImpactError("Repository input changed after the build log was written: \(file.path). Build again before capture.")
            }
        }
    }

    static func validateCompilerToolchain(_ log: String, at root: URL) throws {
        let selected = try CommandRunner.run("xcrun", ["--find", "swiftc"], at: root).text.trimmingCharacters(in: .whitespacesAndNewlines)
        let expected = URL(fileURLWithPath: selected).resolvingSymlinksInPath()
        for line in log.components(separatedBy: .newlines) {
            guard let marker = line.range(of: "builtin-SwiftDriver -- ") else { continue }
            let arguments = try XcodeSourceFileList.parse(String(line[marker.upperBound...]))
            guard let compiler = arguments.first, URL(fileURLWithPath: compiler).resolvingSymlinksInPath() == expected else {
                throw ImpactError("Build log compiler differs from the selected Xcode/Swift toolchain. Select the original toolchain before capture.")
            }
        }
    }

    static func validateBuildLog(_ log: String, options: XcodeConfiguration, root: URL, derived: URL, settings: [XcodeBuildSettings] = []) throws {
        let lines = log.components(separatedBy: .newlines)
        let headers = lines.indices.filter { lines[$0].trimmingCharacters(in: .whitespaces) == "Command line invocation:" }
        guard headers.count == 1, let index = headers.first, index + 1 < lines.count else {
            throw ImpactError("Expected one unfiltered xcodebuild command-line header in the build log.")
        }
        let arguments = try XcodeSourceFileList.parse(lines[index + 1])
        func value(_ flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        if let configuration = value("-configuration"),
           (options.configuration != nil && options.configuration != configuration || settings.contains { $0.buildSettings["CONFIGURATION"] != configuration }) {
            throw ImpactError("Build log configuration differs from the requested configuration or supplied settings.")
        }
        if let plan = value("-testPlan"), let expected = options.testPlan, plan != expected {
            throw ImpactError("Build log test plan differs from --test-plan.")
        }
        guard arguments.contains("build-for-testing"), value("-scheme") == options.scheme,
              value("-destination") == options.destination,
              let container = value("-" + options.container.rawValue),
              URL(fileURLWithPath: container, relativeTo: root).standardizedFileURL.resolvingSymlinksInPath() == options.path,
              let output = value("-derivedDataPath"),
              URL(fileURLWithPath: output, relativeTo: root).standardizedFileURL.resolvingSymlinksInPath() == derived else {
            throw ImpactError("Build log command does not match the supplied container, scheme, destination and DerivedData. Use absolute build paths and matching arguments.")
        }
    }

    static func validateSettings(_ settings: [XcodeBuildSettings], options: XcodeConfiguration, root: URL, derived: URL) throws {
        guard !settings.isEmpty else { throw ImpactError("Build settings are empty.") }
        for entry in settings {
            let values = entry.buildSettings
            guard ["CONFIGURATION", "SDK_NAME", "PLATFORM_NAME", "ARCHS"].allSatisfy({ values[$0]?.isEmpty == false }) else {
                throw ImpactError("Build settings omit configuration, SDK, platform, or architectures; capture complete -showBuildSettings -json output.")
            }
            guard let temporary = values["TARGET_TEMP_DIR"], URL(fileURLWithPath: temporary).standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(derived.path + "/"),
                  let source = values["SRCROOT"], URL(fileURLWithPath: source).standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(root.path + "/") || URL(fileURLWithPath: source).standardizedFileURL.resolvingSymlinksInPath() == root else {
                throw ImpactError("Build settings do not belong to the supplied checkout and DerivedData. Capture settings with the same xcodebuild arguments as the build.")
            }
            if let configuration = options.configuration, values["CONFIGURATION"] != configuration {
                throw ImpactError("Build settings configuration differs from --configuration.")
            }
        }
    }

    static func validateTestRun(_ file: URL, plan: String?, scheme: String? = nil) throws {
        let data = try Data(contentsOf: file)
        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              (plist["__xctestrun_metadata__"] as? [String: Any])?["FormatVersion"] as? Int == 2,
              let configurations = plist["TestConfigurations"] as? [[String: Any]], !configurations.isEmpty else {
            throw ImpactError("Expected a version 2 .xctestrun generated by build-for-testing.")
        }
        if let scheme, let recorded = (plist["ContainerInfo"] as? [String: Any])?["SchemeName"] as? String, recorded != scheme {
            throw ImpactError("The .xctestrun scheme differs from --scheme.")
        }
        if let plan, (plist["TestPlan"] as? [String: Any])?["Name"] as? String != plan {
            throw ImpactError("The .xctestrun test plan differs from --test-plan.")
        }
        // Product paths must relocate with Build/Products; absolute paths could
        // otherwise execute a different build even after manifest validation.
        for configuration in configurations {
            for target in configuration["TestTargets"] as? [[String: Any]] ?? [] {
                guard target["TestBundlePath"] is String else { throw ImpactError("Missing TestBundlePath in .xctestrun.") }
                for path in target["DependentProductPaths"] as? [String] ?? [] {
                    guard path.hasPrefix("__TESTROOT__/"), !path.split(separator: "/").contains("..") else {
                        throw ImpactError("External dependent product path in .xctestrun: \(path)")
                    }
                }
                for key in ["TestBundlePath", "TestHostPath", "UITargetAppPath"] {
                    if let path = target[key] as? String {
                        // Unhosted iOS Simulator unit tests use Xcode's own
                        // xctest agent. Its identity is bound by the toolchain
                        // check; it is not a relocatable application product.
                        let platformAgent = key == "TestHostPath"
                            && path == "__PLATFORMS__/iPhoneSimulator.platform/Developer/Library/Xcode/Agents/xctest"
                        guard (platformAgent || path.hasPrefix("__TESTROOT__/") || path.hasPrefix("__TESTHOST__/")),
                              !path.split(separator: "/").contains("..") else {
                            throw ImpactError("Non-relocatable or escaping \(key) in .xctestrun: \(path)")
                        }
                    }
                }
            }
        }
    }
}
