// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

public struct PackageAnalyzer {
    public var packagePath: URL
    public var sourceRoot: URL
    public var progress: (String) -> Void

    public init(packagePath: URL, sourceRoot: URL? = nil, progress: @escaping (String) -> Void = { _ in }) {
        self.packagePath = packagePath.standardizedFileURL.resolvingSymlinksInPath()
        self.sourceRoot = (sourceRoot ?? packagePath).standardizedFileURL.resolvingSymlinksInPath()
        self.progress = progress
    }

    public func analyze() throws -> DependencyGraph {
        let fm = FileManager.default
        guard fm.fileExists(atPath: packagePath.appendingPathComponent("Package.swift").path) else {
            throw ImpactError("No Package.swift at \(packagePath.path). This version analyzes SwiftPM packages.")
        }
        let scratch = packagePath.appendingPathComponent(".build/test-impact")
        let common = ["--package-path", packagePath.path, "--scratch-path", scratch.path, "-c", "debug"]
        progress("Building package and tests (test bodies are not executed)…")
        _ = try CommandRunner.run("swift", ["build"] + common + ["--build-tests", "-Xswiftc", "-g"], at: packagePath)
        let binPath = try CommandRunner.run("swift", ["build"] + common + ["--show-bin-path"], at: packagePath).text
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let descriptionURL = URL(fileURLWithPath: binPath).appendingPathComponent("description.json")
        let build: BuildDescription
        do { build = try JSONDecoder().decode(BuildDescription.self, from: Data(contentsOf: descriptionURL)) }
        catch { throw ImpactError("Cannot read SwiftPM's build description. Its format may have changed: \(error)") }
        let metadataData = try CommandRunner.run("swift", ["package", "--package-path", packagePath.path, "describe", "--type", "json"], at: packagePath).stdout
        let metadata = try JSONDecoder().decode(PackageDescription.self, from: metadataData)
        let modules = Set(metadata.targets.filter { $0.module_type == "SwiftTarget" }.map(\.c99name))
        var graph = DependencyGraph(toolchain: try CommandRunner.run("swift", ["--version"], at: packagePath).text.trimmingCharacters(in: .whitespacesAndNewlines))
        if metadata.targets.contains(where: { $0.module_type != "SwiftTarget" }) {
            graph.diagnostics.append("Non-Swift targets are present; selection will fall back to all tests.")
        }

        var dispatchTargets: [String: Set<String>] = [:]
        var seenModules = Set<String>()
        for command in build.swiftCommands.values.sorted(by: { $0.moduleName < $1.moduleName }) where modules.contains(command.moduleName) {
            seenModules.insert(command.moduleName)
            progress("Extracting SIL dependencies: \(command.moduleName)…")
            let output = scratch.appendingPathComponent("\(command.moduleName).sil")
            var arguments = Self.silArguments(command.otherArguments)
            arguments += ["-emit-sil", "-whole-module-optimization", "-Onone", "-g", "-module-name", command.moduleName, "-I", command.importPath]
            arguments += command.sources + ["-o", output.path]
            _ = try CommandRunner.run(command.executable, arguments, at: packagePath)
            let parsed = SILParser.parse(try String(contentsOf: output, encoding: .utf8), module: command.moduleName, sourceRoot: sourceRoot)
            if parsed.functions.isEmpty {
                graph.diagnostics.append("No SIL functions could be read for \(command.moduleName).")
            }
            for (symbol, node) in parsed.functions {
                // Prefer the defining module over imported serialized functions.
                if graph.functions[symbol] == nil || (!node.regions.isEmpty && graph.functions[symbol]!.regions.isEmpty) {
                    graph.functions[symbol] = node
                }
            }
            for (declaration, targets) in parsed.dispatchTargets {
                dispatchTargets[declaration, default: []].formUnion(targets)
            }
        }
        for missing in modules.subtracting(seenModules).sorted() {
            graph.diagnostics.append("No compiler invocation was found for target \(missing).")
        }
        for symbol in Array(graph.functions.keys) {
            for declaration in graph.functions[symbol]!.dynamicDeclarations {
                graph.functions[symbol]!.dependencies.formUnion(dispatchTargets[declaration] ?? [])
            }
        }

        progress("Discovering test identifiers…")
        let listing = try CommandRunner.run("swift", ["test"] + common + ["list", "--skip-build"], at: packagePath).text
        let testModules = Set(metadata.targets.filter { $0.type == "test" }.map(\.c99name))
        for raw in listing.split(separator: "\n") {
            let test = String(raw).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let module = testModules.first(where: { test.hasPrefix($0 + ".") }) else { continue }
            let local = String(test.dropFirst(module.count + 1)).replacingOccurrences(of: "/", with: ".")
            let expected = local.contains("(") ? local : local + "()"
            let matches = graph.functions.values.filter {
                $0.module == module && $0.name == expected && !$0.regions.isEmpty
            }
            graph.tests[test] = Set(matches.map(\.id))
            if local.contains(":") {
                for match in matches {
                    graph.functions[match.id]!.uncertainties.insert("Parameterized test arguments may execute outside the test body")
                }
            }
            if matches.isEmpty {
                graph.diagnostics.append("Cannot map discovered test to a SIL function: \(test)")
            }
        }
        if graph.tests.isEmpty {
            throw ImpactError("No recognizable tests were discovered. Expected XCTest or Swift Testing test identifiers; refusing to report an empty safe selection.")
        }
        // Lifecycle hooks execute outside explicit calls from each XCTest method.
        // Include all user-defined initialization, setup and teardown functions
        // in a test module as roots for that module's tests (conservative).
        for test in Array(graph.tests.keys) {
            guard let module = testModules.first(where: { test.hasPrefix($0 + ".") }) else { continue }
            let hooks = graph.functions.values.filter {
                $0.module == module && !$0.regions.isEmpty &&
                ($0.name.contains(".setUp(") || $0.name.contains(".setUpWithError(") ||
                 $0.name.contains(".tearDown(") || $0.name.contains(".tearDownWithError(") ||
                 (($0.name.contains(".init(") || $0.name.contains(".__allocating_init(") ||
                   $0.name.contains(".deinit")) && hasUserInitialization($0)))
            }
            graph.tests[test]!.formUnion(hooks.map(\.id))
        }
        return graph
    }

    private func hasUserInitialization(_ node: FunctionNode) -> Bool {
        node.regions.contains { region in
            guard let text = try? String(contentsOf: sourceRoot.appendingPathComponent(region.path), encoding: .utf8) else { return true }
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            guard region.startLine > 0, region.endLine <= lines.count else { return true }
            let source = lines[(region.startLine - 1)..<region.endLine].joined(separator: "\n")
            return source.range(of: #"\b(init|deinit|var|let)\b"#, options: .regularExpression) != nil
        }
    }

    static func silArguments(_ arguments: [String]) -> [String] {
        let flags: Set<String> = ["-incremental", "-enable-batch-mode", "-serialize-diagnostics", "-parseable-output", "-emit-objc-header", "-emit-module", "-emit-module-interface", "-emit-package-module-interface", "-emit-private-module-interface", "-c"]
        let pairs: Set<String> = ["-index-store-path", "-emit-objc-header-path", "-emit-module-path", "-emit-module-interface-path", "-emit-private-module-interface-path", "-emit-package-module-interface-path", "-output-file-map", "-serialize-diagnostics-path", "-num-threads"]
        var result: [String] = []
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            index += 1
            // Forward compiler/plugin/Clang flags and their arguments unchanged.
            if ["-Xfrontend", "-Xcc", "-Xlinker"].contains(argument), index < arguments.count {
                result += [argument, arguments[index]]
                index += 1
            } else if pairs.contains(argument) {
                index += 1
            } else if !flags.contains(argument), !argument.hasPrefix("-j") {
                result.append(argument)
            }
        }
        return result
    }
}

private struct BuildDescription: Decodable {
    var swiftCommands: [String: SwiftCommand]
}

private struct SwiftCommand: Decodable {
    var executable: String
    var moduleName: String
    var importPath: String
    var sources: [String]
    var otherArguments: [String]
}

private struct PackageDescription: Decodable {
    struct Target: Decodable {
        var c99name: String
        var module_type: String
        var type: String
    }
    var targets: [Target]
}
