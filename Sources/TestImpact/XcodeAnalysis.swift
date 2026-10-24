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
        return result
    }

    func executionArguments(tests: [String], derivedData: URL, resultBundle: URL) throws -> [String] {
        guard !tests.isEmpty else { throw ImpactError("Refusing an unfiltered Xcode test invocation for an empty selection.") }
        guard tests.allSatisfy({ $0.split(separator: "/").count >= 3 && !$0.contains("\n") }) else {
            throw ImpactError("An Xcode selection must contain complete target/class/method test identifiers.")
        }
        return arguments(action: "test", derivedData: derivedData) +
            ["-resultBundlePath", resultBundle.path] + tests.sorted().map { "-only-testing:" + $0 }
    }
}

public struct XcodeAnalysis {
    public var options: XcodeConfiguration
    public var progress: (String) -> Void

    public init(options: XcodeConfiguration, progress: @escaping (String) -> Void = { _ in }) {
        self.options = options
        self.progress = progress
    }

    public func graph() throws -> XcodeTestGraph {
        let directory = options.path.deletingLastPathComponent()
        let root = (try? GitChanges.repositoryRoot(at: directory)) ?? directory
        return try analyze(options, sourceRoot: root)
    }

    public func select(base: String) throws -> ImpactReport {
        let root = try GitChanges.repositoryRoot(at: options.path.deletingLastPathComponent())
        guard options.path.path.hasPrefix(root.path + "/") else { throw ImpactError("Xcode container must be inside the Git repository.") }
        let revision = try GitChanges.revision(base, at: root)
        let changes = try GitChanges.read(base: revision, at: root)
        let current = try analyze(options, sourceRoot: root)
        if changes.isEmpty {
            return XcodeSelector.select(current: current, previous: current, changes: [], baseRevision: revision)
        }
        let exported = FileManager.default.temporaryDirectory.appendingPathComponent("swift-test-impact-xcode-base-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: exported) }
        var previous: XcodeTestGraph?
        var fallbacks: [String] = []
        do {
            progress("Exporting base revision \(revision.prefix(12)) for Xcode analysis…")
            try GitChanges.export(base: revision, from: root, into: exported)
            var baseOptions = options
            baseOptions.path = exported.appendingPathComponent(String(options.path.path.dropFirst(root.path.count + 1)))
            previous = try analyze(baseOptions, sourceRoot: exported)
        } catch {
            fallbacks.append("Cannot analyze the base Xcode build; selecting all currently discovered tests. \(error)")
        }
        return XcodeSelector.select(current: current, previous: previous, changes: changes,
                                    baseRevision: revision, additionalFallbacks: fallbacks)
    }

    public func run(_ report: ImpactReport) throws -> Int32 {
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
        let arguments = try options.executionArguments(tests: report.selectedTests, derivedData: temporary, resultBundle: results)
        let result = try CommandRunner.run("xcodebuild", arguments, at: directory, allowFailure: true)
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
        let directory = configuration.path.deletingLastPathComponent()
        let derived = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: derived) }
        let buildArguments = configuration.arguments(action: "build-for-testing", derivedData: derived)
        progress("Building Xcode scheme \(configuration.scheme) for \(configuration.destination) (no test bodies)…")
        _ = try CommandRunner.run("xcodebuild", buildArguments, at: directory)
        let settingsData = try CommandRunner.run("xcodebuild", buildArguments + ["-showBuildSettings", "-json"], at: directory).stdout
        let settings = try JSONDecoder().decode([XcodeBuildSettings].self, from: settingsData)
        var targets: [XcodeTarget] = []
        var diagnostics: [String] = []
        var classifiedLists = Set<URL>()
        func sourcePaths(in list: URL, sourceDirectory: URL) throws -> Set<String> {
            let lines = try String(contentsOf: list, encoding: .utf8)
            let root = sourceRoot.standardizedFileURL.resolvingSymlinksInPath().path + "/"
            return Set(try XcodeSourceFileList.parse(lines).compactMap { decoded in
                let file = URL(fileURLWithPath: decoded, relativeTo: sourceDirectory)
                    .standardizedFileURL.resolvingSymlinksInPath()
                return file.path.hasPrefix(root) ? String(file.path.dropFirst(root.count)) : nil
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
                for case let file as URL in enumerator where file.pathExtension == "SwiftFileList" {
                    classifiedLists.insert(file.standardizedFileURL.resolvingSymlinksInPath())
                    paths.formUnion(try sourcePaths(in: file, sourceDirectory: URL(fileURLWithPath: entry.buildSettings["SRCROOT"] ?? directory.path, isDirectory: true)))
                }
            }
            let target = XcodeTarget(name: name, productType: type, sourceFiles: paths)
            if target.isTest && paths.isEmpty {
                diagnostics.append("No in-repository Swift source ownership was found for test target \(name); narrowing is unavailable.")
            }
            targets.append(target)
        }
        // Scheme settings may omit transitive build targets. Preserve their
        // inputs as unclassified ownership, especially files shared with tests.
        // Otherwise a production dependency could look like test-only source.
        var unclassifiedSources = Set<String>()
        if let enumerator = FileManager.default.enumerator(at: derived, includingPropertiesForKeys: nil) {
            for case let file as URL in enumerator where file.pathExtension == "SwiftFileList" {
                guard !classifiedLists.contains(file.standardizedFileURL.resolvingSymlinksInPath()) else { continue }
                unclassifiedSources.formUnion(try sourcePaths(in: file, sourceDirectory: directory))
            }
        }
        if !unclassifiedSources.isEmpty {
            targets.append(XcodeTarget(name: "Unclassified build inputs", productType: "unknown", sourceFiles: unclassifiedSources))
        }
        progress("Enumerating Xcode tests (runner initialization may require UI automation permissions)…")
        let enumeration = derived.appendingPathComponent("test-enumeration.json")
        _ = try CommandRunner.run("xcodebuild", configuration.arguments(action: "test-without-building", derivedData: derived) + [
            "-enumerate-tests", "-test-enumeration-style", "flat", "-test-enumeration-format", "json",
            "-test-enumeration-output-path", enumeration.path
        ], at: directory)
        let tests = try XcodeTestEnumeration.parse(Data(contentsOf: enumeration))
        let testTargets = Set(targets.filter(\.isTest).map(\.name))
        for test in tests where !testTargets.contains(String(test.prefix(while: { $0 != "/" }))) {
            diagnostics.append("No build-target metadata for discovered test: \(test)")
        }
        return XcodeTestGraph(targets: targets, tests: tests, diagnostics: Array(Set(diagnostics)).sorted())
    }
}

private struct XcodeBuildSettings: Decodable {
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
    public static func parse(_ data: Data) throws -> [String] {
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
        let tests = Set(inventory.values.flatMap { $0.enabledTests.map(\.identifier) }).sorted()
        guard !tests.isEmpty else { throw ImpactError("Xcode enumerated no enabled tests; refusing to infer a safe empty selection.") }
        guard tests.allSatisfy({ $0.split(separator: "/").count >= 3 }) else {
            throw ImpactError("Xcode did not return complete target/class/method identifiers. Enumeration may be incomplete.")
        }
        return tests
    }
}
