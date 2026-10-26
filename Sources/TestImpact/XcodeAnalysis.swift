// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

public struct XcodeConfiguration: Sendable {
    public enum Container: String, Sendable { case project, workspace }
    public var container: Container
    public var path: URL
    public var scheme: String
    public var destination: String
    public var configuration: String?
    public var testPlan: String?
    /// Maximum concurrent compiler/parser jobs (1...8). Serial by default.
    public var extractionWorkers: Int = 1
    /// Opt-in helper from this distribution: Scripts/capture-build.py.
    public var buildTimeSILHelper: URL? = nil
    /// Repository-relative mapping file, read separately from each revision.
    public var mappingsPath: String = ".swift-test-selection.json"

    public init(container: Container, path: URL, scheme: String, destination: String, configuration: String? = nil, testPlan: String? = nil) {
        self.container = container
        self.path = path.standardizedFileURL.resolvingSymlinksInPath()
        self.scheme = scheme
        self.destination = destination
        self.configuration = configuration
        self.testPlan = testPlan
    }

    func arguments(action: String, derivedData: URL) -> [String] {
        var result = [action, "-" + container.rawValue, path.path, "-scheme", scheme,
                      "-destination", destination, "-derivedDataPath", derivedData.path]
        if let configuration { result += ["-configuration", configuration] }
        if let testPlan { result += ["-testPlan", testPlan] }
        if action == "build-for-testing" {
            result.append("MTL_COMPILER_FLAGS=$(inherited) -Xclang -sys-header-deps")
        }
        return result
    }

    func executionArguments(tests: [String], derivedData: URL, resultBundle: URL) throws -> [String] {
        guard !tests.isEmpty else { throw ImpactError("Refusing an unfiltered Xcode test invocation for an empty selection.") }
        guard tests.allSatisfy({ ($0.split(separator: "/").count >= 3 || $0.split(separator: "/").count == 2 && $0.hasSuffix(")")) && !$0.contains("\n") }) else {
            throw ImpactError("An Xcode selection must contain complete target/class/method test identifiers.")
        }
        return arguments(action: "test", derivedData: derivedData) +
            ["-resultBundlePath", resultBundle.path] + tests.sorted().map { "-only-testing:" + $0 }
    }
}

public struct XcodeAnalysis {
    public var options: XcodeConfiguration
    public var progress: (String) -> Void
    public var extractionCancellation = XcodeExtractionCancellation()
    var measurement: (String, Double) -> Void = { _, _ in }

    public init(options: XcodeConfiguration, progress: @escaping (String) -> Void = { _ in }) {
        self.options = options
        self.progress = progress
    }

    public func graph() throws -> XcodeTestGraph {
        let directory = options.path.deletingLastPathComponent()
        let root = (try? GitChanges.repositoryRoot(at: directory)) ?? directory
        return try analyze(options, sourceRoot: root)
    }

    public func select(base: String, head: String? = nil, mergeBase: Bool = false, fullSuite: Bool = false, cache: XcodeAnalysisCache? = nil, retainingBuildAt: URL? = nil, cachedBasePolicy: XcodeCachedBasePolicy = .build, headOnly: Bool = false) throws -> ImpactReport {
        if headOnly {
            guard head != nil, options.buildTimeSILHelper != nil, retainingBuildAt != nil, cachedBasePolicy == .build else {
                throw ImpactError("Head-only analysis requires a committed head, build-time SIL, retained products, and no cached-base policy.")
            }
        }
        guard cachedBasePolicy == .build || cache != nil else {
            throw ImpactError("A cached-base policy requires an explicit analysis cache and context.")
        }
        if cache != nil || retainingBuildAt != nil || options.buildTimeSILHelper != nil {
            guard let head else { throw ImpactError("--analysis-cache requires an explicit --head revision; worktree analysis is never cached.") }
            let scratch = cache == nil ? try temporaryDirectory() : nil
            defer { if let scratch { try? FileManager.default.removeItem(at: scratch) } }
            let cache = cache ?? XcodeAnalysisCache(directory: scratch!, context: "uncached-" + UUID().uuidString, maximumBytes: 1)
            return try selectCached(base: base, head: head, mergeBase: mergeBase, fullSuite: fullSuite, cache: cache, retainingBuildAt: retainingBuildAt, cachedBasePolicy: cachedBasePolicy, headOnly: headOnly)
        }
        let root = try GitChanges.repositoryRoot(at: options.path.deletingLastPathComponent())
        guard options.path.path.hasPrefix(root.path + "/") else { throw ImpactError("Xcode container must be inside the Git repository.") }
        let comparison = try RevisionComparison(base: base, head: head, mergeBase: mergeBase, root: root)
        let changes = try GitChanges.readComparison(base: comparison.base, head: comparison.head, at: root)
        let relative = String(options.path.path.dropFirst(root.path.count + 1))
        let temporary = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        var headOptions = options
        var headRoot = root
        if let head = comparison.head {
            headRoot = temporary.appendingPathComponent("head")
            try GitChanges.export(base: head, from: root, into: headRoot)
            headOptions.path = headRoot.appendingPathComponent(relative)
        }
        let current = try analyze(headOptions, sourceRoot: headRoot)
        var previous: XcodeTestGraph?
        var fallbacks: [String] = []
        if changes.isEmpty { previous = current }
        else {
            do {
                progress("Analyzing base revision \(comparison.base.prefix(12))…")
                let exported = temporary.appendingPathComponent("base")
                try GitChanges.export(base: comparison.base, from: root, into: exported)
                var baseOptions = options
                baseOptions.path = exported.appendingPathComponent(relative)
                previous = try analyze(baseOptions, sourceRoot: exported)
            } catch { fallbacks.append("Cannot analyze base revision: \(error)") }
        }
        var report = XcodeSelector.select(current: current, previous: previous, changes: changes, baseRevision: comparison.base, additionalFallbacks: fallbacks)
        report.headRevision = comparison.head ?? "WORKTREE"
        report.comparisonMode = comparison.mode
        if fullSuite {
            report.selectedTests = current.tests.sorted()
            report.onlyTestingArguments = report.selectedTests.map { "-only-testing:" + $0 }
            report.explanations += report.selectedTests.map { TestExplanation(test: $0, reason: "Full suite explicitly requested", revision: "head", path: [], kind: "fullSuite") }
        }
        return report
    }

    public func run(_ report: ImpactReport) throws -> Int32 {
        if let path = report.buildArtifactPath {
            let graph = try RetainedXcodeBuild.load(from: URL(fileURLWithPath: path))
            return try run(report, using: graph)
        }
        guard !report.selectedTests.isEmpty else {
            progress("No selected tests; no Xcode test command was executed.")
            return 0
        }
        let temporary = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let directory = options.path.deletingLastPathComponent()
        let results = directory.appendingPathComponent(".build/test-impact-results/\(UUID().uuidString).xcresult")
        try FileManager.default.createDirectory(at: results.deletingLastPathComponent(), withIntermediateDirectories: true)
        progress("Running \(report.selectedTests.count) selected Xcode tests; results: \(results.path)")
        var executionOptions = options
        if let head = report.headRevision, head != "WORKTREE" {
            let root = try GitChanges.repositoryRoot(at: directory)
            let exported = temporary.appendingPathComponent("execution-source")
            try GitChanges.export(base: head, from: root, into: exported)
            executionOptions.path = exported.appendingPathComponent(String(options.path.path.dropFirst(root.path.count + 1)))
        }
        let arguments = try executionOptions.executionArguments(tests: report.selectedTests, derivedData: temporary.appendingPathComponent("DerivedData"), resultBundle: results)
        let result = try CommandRunner.run("xcodebuild", arguments, at: executionOptions.path.deletingLastPathComponent(), allowFailure: true)
        progress(String(decoding: result.stdout + result.stderr, as: UTF8.self))
        return result.status
    }

    private func temporaryDirectory() throws -> URL {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("swift-test-impact-xcode-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        return path
    }

    private func analyze(_ configuration: XcodeConfiguration, sourceRoot: URL) throws -> XcodeTestGraph {
        guard FileManager.default.fileExists(atPath: configuration.path.path) else {
            throw ImpactError("Xcode container does not exist: \(configuration.path.path)")
        }
        let derived = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: derived) }
        let directory = configuration.path.deletingLastPathComponent()
        let arguments = configuration.arguments(action: "build-for-testing", derivedData: derived)
        progress("Building Xcode scheme \(configuration.scheme) for \(configuration.destination) (no test bodies)…")
        let build = try CommandRunner.run("xcodebuild", arguments, at: directory)
        let settings = try CommandRunner.run("xcodebuild", arguments + ["-showBuildSettings", "-json"], at: directory).stdout
        return try analyzeBuild(configuration, sourceRoot: sourceRoot, derived: derived, log: build.text, settingsData: settings)
    }

    func analyzeBuild(_ configuration: XcodeConfiguration, sourceRoot: URL, derived: URL,
                      log: String, settingsData: Data, xctestrun: URL? = nil, moduleCache: XcodeModuleCache? = nil, captured: CapturedSIL? = nil,
                      activeCompilerInputs: Set<String>? = nil) throws -> XcodeTestGraph {
        guard FileManager.default.fileExists(atPath: configuration.path.path) else {
            throw ImpactError("Xcode container does not exist: \(configuration.path.path)")
        }
        let directory = configuration.path.deletingLastPathComponent()
        let evidenceStart = Date()
        let settings = try JSONDecoder().decode([XcodeBuildSettings].self, from: settingsData)
        var targets: [XcodeTarget] = []
        var diagnostics: [String] = []
        var classifiedLists = Set<URL>()
        var listOwners: [URL: Set<String>] = [:]
        var unsupportedInputs: [String: [String]] = [:]
        var generated: [String: [GeneratedSourceBoundary]] = [:], roleDiagnostics: [String: String] = [:]
        let evidence = try? XcodeBuildEvidence(log: log, root: sourceRoot, derived: derived, captured: captured)
        var modules: [String: String] = [:]
        var sources: [String: SwiftSourceSnapshot] = [:]
        func isActiveList(_ file: URL) -> Bool {
            activeCompilerInputs?.contains(file.standardizedFileURL.resolvingSymlinksInPath().path) ?? true
        }
        func sourcePaths(in list: URL, sourceDirectory: URL) throws -> Set<String> {
            let lines = try String(contentsOf: list, encoding: .utf8)
            let root = sourceRoot.standardizedFileURL.resolvingSymlinksInPath().path + "/"
            return Set(try XcodeSourceFileList.parse(lines).compactMap { decoded in
                let file = URL(fileURLWithPath: decoded, relativeTo: sourceDirectory)
                    .standardizedFileURL.resolvingSymlinksInPath()
                return file.path.hasPrefix(root) && !file.path.hasPrefix(derived.standardizedFileURL.resolvingSymlinksInPath().path + "/") ? String(file.path.dropFirst(root.count)) : nil
            })
        }
        for entry in settings {
            guard let name = entry.buildSettings["TARGET_NAME"], let type = entry.buildSettings["PRODUCT_TYPE"] else {
                diagnostics.append("Xcode build settings omit target name or product type.")
                continue
            }
            var paths = Set<String>()
            if let temporaryPath = entry.buildSettings["TARGET_TEMP_DIR"],
               let enumerator = FileManager.default.enumerator(at: URL(fileURLWithPath: temporaryPath), includingPropertiesForKeys: nil) {
                for case let file as URL in enumerator where file.pathExtension == "SwiftFileList" && isActiveList(file) {
                    let resolvedList = file.standardizedFileURL.resolvingSymlinksInPath()
                    classifiedLists.insert(resolvedList)
                    listOwners[resolvedList, default: []].insert(name)
                    paths.formUnion(try sourcePaths(in: file, sourceDirectory: URL(fileURLWithPath: entry.buildSettings["SRCROOT"] ?? directory.path, isDirectory: true)))
                }
            }
            let target = XcodeTarget(name: name, productType: type, sourceFiles: paths)
            if target.isTest && paths.isEmpty {
                diagnostics.append("No in-repository Swift source ownership was found for test target \(name); narrowing is unavailable.")
            }
            targets.append(target)
            if let module = entry.buildSettings["PRODUCT_MODULE_NAME"] {
                modules[name] = module
            }
        }
        XcodeSourceOwnership.recover(log: log, sourceRoot: sourceRoot, derived: derived, activeInputs: activeCompilerInputs,
            targets: &targets, modules: &modules, listOwners: listOwners, unsupportedInputs: &unsupportedInputs, classifiedLists: &classifiedLists, diagnostics: &diagnostics, evidence: evidence, generated: &generated, roleDiagnostics: &roleDiagnostics)
        measurement("buildEvidence", Date().timeIntervalSince(evidenceStart))
        let sourceJobs = targets.flatMap { target -> [(String, String)] in
            guard let module = modules[target.name] else { return [] }
            return target.sourceFiles.sorted().map { (module, $0) }
        }
        for (key, snapshot) in try BoundedWork.map(sourceJobs, workers: configuration.extractionWorkers, { module, path in
            let text = try String(contentsOf: sourceRoot.appendingPathComponent(path), encoding: .utf8)
            return (module + ":" + path, SwiftSourceSnapshot.parse(text, path: path, module: module))
        }) { sources[key] = snapshot }
        // Preserve active lists that neither settings nor compiler invocations
        // could classify, especially files shared with tests.
        // Otherwise a production dependency could look like test-only source.
        var unclassifiedSources = Set<String>()
        if let enumerator = FileManager.default.enumerator(at: derived, includingPropertiesForKeys: nil) {
            for case let file as URL in enumerator where file.pathExtension == "SwiftFileList" && isActiveList(file) {
                guard !classifiedLists.contains(file.standardizedFileURL.resolvingSymlinksInPath()) else { continue }
                unclassifiedSources.formUnion(try sourcePaths(in: file, sourceDirectory: directory))
            }
        }
        if !unclassifiedSources.isEmpty {
            targets.append(XcodeTarget(name: "Unclassified build inputs", productType: "unknown", sourceFiles: unclassifiedSources))
        }
        progress("Enumerating Xcode tests (runner initialization may require UI automation permissions)…")
        let scratch = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let enumeration = scratch.appendingPathComponent("test-enumeration.json")
        let enumerationArguments = xctestrun.map {
            ["test-without-building", "-xctestrun", $0.path, "-destination", configuration.destination]
        } ?? configuration.arguments(action: "test-without-building", derivedData: derived)
        let enumerationStart = Date()
        _ = try CommandRunner.run("xcodebuild", enumerationArguments + [
            "-enumerate-tests", "-test-enumeration-style", "flat", "-test-enumeration-format", "json",
            "-test-enumeration-output-path", enumeration.path
        ], at: directory)
        measurement("enumeration", Date().timeIntervalSince(enumerationStart))
        var suites = Set<String>()
        for (target, module) in modules {
            for key in sources.values.flatMap({ $0.inheritance.keys }) where key.hasPrefix(module + ".") {
                suites.insert(target + "/" + key.dropFirst(module.count + 1))
            }
        }
        let tests = try XcodeTestEnumeration.parse(Data(contentsOf: enumeration), emptySuiteIdentifiers: suites)
        let testTargets = Set(targets.filter(\.isTest).map(\.name))
        for test in tests where !testTargets.contains(String(test.prefix(while: { $0 != "/" }))) {
            diagnostics.append("No build-target metadata for discovered test: \(test)")
        }
        let ownership = targets.reduce(into: [String: Set<String>]()) { result, target in
            if let module = modules[target.name] { result[module, default: []].formUnion(target.sourceFiles) }
        }
        let extractionStart = Date()
        var dependencies = XcodeCompilerGraph.extract(log: log, sourceRoot: sourceRoot, directory: directory, derived: scratch, progress: progress, ownership: ownership, workers: configuration.extractionWorkers, cancellation: extractionCancellation, moduleCache: moduleCache, captured: captured, measurement: measurement)
        measurement("extraction", Date().timeIntervalSince(extractionStart))
        progress("Binding compiler dependencies to \(tests.count) enumerated tests…")
        let binding = AnalysisMeasurement()
        XcodeCompilerGraph.bind(tests: tests, modules: modules, sources: sources, graph: &dependencies)
        progress(binding.report("Bound Xcode test dependencies"))
        for target in targets where !target.sourceFiles.isEmpty {
            if let module = modules[target.name], !dependencies.functions.values.contains(where: { $0.module == module && !$0.regions.isEmpty }) {
                dependencies.diagnostics.append("No compiled functions for target \(target.name)")
            }
        }
        var result = XcodeTestGraph(targets: targets, tests: tests, diagnostics: Array(Set(diagnostics)).sorted())
        result.dependencies = dependencies
        result.modules = modules
        try evidence?.validate(log: log, boundaries: generated.values.flatMap { $0 })
        result.generatedSourceBoundaries = generated
        result.unresolvedProductRoles = roleDiagnostics
        result.unsupportedSourceInputs = unsupportedInputs
        result.sources = sources
        result.runtimeInventory = XcodeRuntimeInventory.capture(log: log, settings: settings)
        let mappingURL = try UIFeatureMappings.fileURL(path: configuration.mappingsPath, root: sourceRoot)
        if FileManager.default.fileExists(atPath: mappingURL.path) {
            do {
                result.mappings = try JSONDecoder().decode(UIFeatureMappings.self, from: Data(contentsOf: mappingURL))
                try result.mappings?.validate()
            } catch {
                result.mappings = nil
                result.diagnostics.append("Invalid UI mappings: \(error)")
            }
        }
        return result
    }
}

struct XcodeBuildSettings: Decodable {
    var buildSettings: [String: String]
}

enum XcodeSourceFileList {
    /// Xcode writes compiler response-file arguments: spaces and backslashes
    /// can be escaped, and paths can be quoted. No shell is involved here.
    static func parse(_ text: String) throws -> [String] {
        var paths: [String] = []
        var token = ""
        var quote: Character?
        var escaped = false
        for character in text {
            if escaped {
                token.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if let currentQuote = quote {
                if character == currentQuote { quote = nil } else { token.append(character) }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character.isWhitespace {
                if !token.isEmpty { paths.append(token); token = "" }
            } else {
                token.append(character)
            }
        }
        guard !escaped, quote == nil else { throw ImpactError("Malformed Xcode Swift source-file list.") }
        if !token.isEmpty { paths.append(token) }
        return paths
    }
}

public enum XcodeTestEnumeration {
    /// Xcode can exit successfully while returning enumeration errors. Never
    /// interpret such an incomplete inventory as an empty or safe selection.
    public static func parse(_ data: Data, emptySuiteIdentifiers: Set<String> = []) throws -> [String] {
        struct Inventory: Decodable {
            struct Plan: Decodable {
                struct Test: Decodable { var identifier: String }
                var enabledTests: [Test]
            }
            var errors: [String]?
            var values: [Plan]
        }
        let inventory = try JSONDecoder().decode(Inventory.self, from: data)
        if let errors = inventory.errors, !errors.isEmpty {
            throw ImpactError("Xcode test enumeration failed: " + errors.joined(separator: "; "))
        }
        let identifiers = Set(inventory.values.flatMap { $0.enabledTests.map(\.identifier) })
        // Flat enumeration includes empty XCTestCase base classes. Only remove
        // suites whose class declarations were independently found in source.
        // Two-component Swift Testing function IDs remain executable tests.
        let tests = identifiers.subtracting(emptySuiteIdentifiers).sorted()
        guard !tests.isEmpty else { throw ImpactError("Xcode enumerated no enabled tests; refusing to infer a safe empty selection.") }
        guard tests.allSatisfy({ $0.split(separator: "/").count >= 3 || $0.split(separator: "/").count == 2 && $0.hasSuffix(")") }) else {
            throw ImpactError("Xcode did not return complete test identifiers. Enumeration may be incomplete.")
        }
        return tests
    }
}
