// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import TestImpact
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

private let usage = """
swift-test-impact — compiler-derived test selection for Swift and Xcode

USAGE
  swift-test-impact graph [--package-path PATH] [--format json|dot] [--output FILE]
  swift-test-impact select --base REVISION [--head REVISION] [--merge-base]
                           [--package-path PATH] [--format text|json]
                           [--output FILE] [--full-suite] [--run]
  swift-test-impact graph|select --project PATH.xcodeproj | --workspace PATH.xcworkspace
                           --scheme NAME --destination DESTINATION [--test-plan NAME]
                           [--configuration NAME] [--mappings REPOSITORY_RELATIVE_PATH]
                           [--base REVISION] [--head REVISION] [--merge-base]
                           [--format FORMAT] [--output FILE] [--full-suite] [--run]

Existing Xcode builds:
  graph <Xcode options> --derived-data PATH --build-log FILE --build-settings FILE
        --xctestrun FILE --revision REVISION --output head-graph.json
  select <Xcode options> --base REVISION [--head REVISION] [--merge-base]
         --base-graph FILE --head-graph FILE [--run] [--test-products PATH]

Capture requires a clean checkout of the built revision and an unfiltered successful
build-for-testing log. Keep original source/DerivedData paths until capture finishes.
Cached selection uses Git history and saved graphs only; head defaults to HEAD.
--run with cached graphs uses test-without-building and fingerprinted products.
--test-products relocates the intact Build/Products directory for execution.

Normal graph builds targets and emits compiled dependency graphs. Without cached
graphs, select analyzes both revisions; omitting --head includes staged, unstaged
and untracked worktree files.
--merge-base compares against the common ancestor of base and head (or HEAD).
--head builds and executes an isolated export of that exact revision.

Xcode mode selects individual test methods through syntax and SIL dependencies.
UI feature mappings bridge the app/test process boundary; missing mappings and
unresolved dependencies produce explicit conservative fallbacks. The default
mapping file is .swift-test-selection.json at the Git repository root.

Analysis does not execute test bodies; discovery can execute initialization code.
--run executes the selection. --full-suite includes every discovered enabled test
in the chosen scheme/plan. Omit --run to review the report without executing tests.

Requires Swift 6+ and Git. Xcode mode requires macOS and test enumeration (Xcode 15+).
Compiler/build formats are version-sensitive; validate against full runs before CI use.
"""

private struct Options {
    var command: String
    var packagePath = FileManager.default.currentDirectoryPath
    var format: String
    var output: String?
    var base: String?
    var run = false
    var head: String?
    var mergeBase = false
    var fullSuite = false
    var xcode: XcodeConfiguration?
    var buildInputs: XcodeBuildInputs?
    var baseGraph: String?
    var headGraph: String?
    var testProducts: String?

    init(_ arguments: [String]) throws {
        guard let first = arguments.first, ["graph", "select"].contains(first) else {
            throw ImpactError("Expected 'graph' or 'select'. Use --help for usage.")
        }
        command = first
        format = first == "graph" ? "json" : "text"
        var index = 1
        var seen = Set<String>()
        var project: String?
        var workspace: String?
        var scheme: String?
        var destination: String?
        var configuration: String?
        var testPlan: String?
        var mappings: String?
        var derivedData: String?
        var buildLog: String?
        var buildSettings: String?
        var xctestrun: String?
        var revision: String?
        while index < arguments.count {
            let flag = arguments[index]
            index += 1
            guard seen.insert(flag).inserted else { throw ImpactError("Repeated option: \(flag)") }
            if flag == "--run" { run = true; continue }
            if flag == "--merge-base" { mergeBase = true; continue }
            if flag == "--full-suite" { fullSuite = true; continue }
            guard ["--package-path", "--format", "--output", "--base", "--project", "--workspace", "--scheme", "--destination", "--configuration", "--test-plan", "--head", "--mappings", "--derived-data", "--build-log", "--build-settings", "--xctestrun", "--revision", "--base-graph", "--head-graph", "--test-products"].contains(flag), index < arguments.count else {
                throw ImpactError("Unknown option or missing value: \(flag)")
            }
            let value = arguments[index]
            index += 1
            switch flag {
            case "--package-path": packagePath = value
            case "--format": format = value
            case "--output": output = value
            case "--base": base = value
            case "--head": head = value
            case "--mappings": mappings = value
            case "--derived-data": derivedData = value
            case "--build-log": buildLog = value
            case "--build-settings": buildSettings = value
            case "--xctestrun": xctestrun = value
            case "--revision": revision = value
            case "--base-graph": baseGraph = value
            case "--head-graph": headGraph = value
            case "--test-products": testProducts = value
            case "--project": project = value
            case "--workspace": workspace = value
            case "--scheme": scheme = value
            case "--destination": destination = value
            case "--configuration": configuration = value
            case "--test-plan": testPlan = value
            default: break
            }
        }
        let captureCount = [derivedData, buildLog, buildSettings, xctestrun, revision].compactMap { $0 }.count
        if captureCount > 0 {
            guard captureCount == 5, command == "graph", project != nil || workspace != nil else {
                throw ImpactError("Existing-build capture requires Xcode graph mode and all of --derived-data, --build-log, --build-settings, --xctestrun, --revision.")
            }
            buildInputs = XcodeBuildInputs(derivedData: URL(fileURLWithPath: derivedData!), buildLog: URL(fileURLWithPath: buildLog!),
                buildSettings: URL(fileURLWithPath: buildSettings!), xctestrun: URL(fileURLWithPath: xctestrun!), revision: revision!)
        }
        if baseGraph != nil || headGraph != nil {
            guard command == "select", baseGraph != nil, headGraph != nil, project != nil || workspace != nil else {
                throw ImpactError("Cached selection requires Xcode select mode and both --base-graph and --head-graph.")
            }
        }
        if testProducts != nil && (baseGraph == nil || !run) {
            throw ImpactError("--test-products requires cached selection with --run.")
        }
        if command == "select" && base == nil { throw ImpactError("select requires --base REVISION.") }
        if command == "graph" && (base != nil || run || head != nil || mergeBase || fullSuite) { throw ImpactError("Comparison, execution, and full-suite options are only valid with select.") }
        let allowed = command == "graph" ? ["json", "dot"] : ["text", "json"]
        if !allowed.contains(format) { throw ImpactError("Unsupported format '\(format)' for \(command).") }
        if project != nil && workspace != nil { throw ImpactError("Choose --project or --workspace, not both.") }
        if let container = project ?? workspace {
            guard !seen.contains("--package-path") else { throw ImpactError("--package-path cannot be combined with an Xcode container.") }
            guard let scheme, !scheme.isEmpty, let destination, !destination.isEmpty else {
                throw ImpactError("Xcode mode requires --scheme and --destination.")
            }
            xcode = XcodeConfiguration(container: project != nil ? .project : .workspace,
                                       path: URL(fileURLWithPath: container), scheme: scheme, destination: destination,
                                       configuration: configuration, testPlan: testPlan)
            if let mappings { xcode!.mappingsPath = mappings }
        } else if scheme != nil || destination != nil || configuration != nil || testPlan != nil || mappings != nil {
            throw ImpactError("Xcode options require --project or --workspace.")
        }
    }
}

private func log(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

private func write(_ data: Data, to path: String?) throws {
    if let path {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        log("Wrote \(url.path)")
    } else {
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}

private func render(_ report: ImpactReport) -> String {
    var lines = ["Selected \(report.selectedTests.count) of \(report.totalTests) tests", "Base: \(report.baseRevision)"]
    if let head = report.headRevision { lines.append("Head: " + head + " (" + (report.comparisonMode ?? "direct") + ")") }
    for diagnostic in report.diagnostics { lines.append("Diagnostic [\(diagnostic.code)]: \(diagnostic.message)") }
    for reason in report.fullRunReasons { lines.append("Full-suite fallback: \(reason)") }
    for test in report.selectedTests {
        lines.append("\n\(test)")
        for explanation in report.explanations where explanation.test == test {
            lines.append("  [\(explanation.kind), \(explanation.revision)] \(explanation.reason)")
            if !explanation.path.isEmpty { lines.append("    " + explanation.path.joined(separator: " → ")) }
        }
    }
    if report.selectedTests.isEmpty { lines.append("No tests selected; no execution is needed by this analysis.") }
    if !report.unreferencedChanges.isEmpty {
        lines.append("\nChanged functions with no statically identified test path:")
        lines += report.unreferencedChanges.map { "  " + $0 }
    }
    lines.append("\nExperimental static analysis; inspect fallbacks and validate against full-suite runs before relying on it in CI.")
    return lines.joined(separator: "\n") + "\n"
}

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.isEmpty || arguments.contains("--help") || arguments.contains("-h") {
    print(usage)
} else {
    do {
        let options = try Options(arguments)
        let package = URL(fileURLWithPath: options.packagePath)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        if let xcode = options.xcode {
            let analysis = XcodeAnalysis(options: xcode, progress: log)
            if options.command == "graph" {
                let graph = try options.buildInputs.map { try analysis.graph(from: $0) } ?? analysis.graph()
                let data = options.format == "dot" ? Data(graph.dot().utf8) : try encoder.encode(graph)
                try write(data, to: options.output)
            } else {
                let headGraph = try options.headGraph.map { try JSONDecoder().decode(XcodeTestGraph.self, from: Data(contentsOf: URL(fileURLWithPath: $0))) }
                let report: ImpactReport
                if let headGraph, let basePath = options.baseGraph {
                    let baseGraph = try JSONDecoder().decode(XcodeTestGraph.self, from: Data(contentsOf: URL(fileURLWithPath: basePath)))
                    report = try analysis.select(base: options.base!, head: options.head, mergeBase: options.mergeBase,
                        fullSuite: options.fullSuite, baseGraph: baseGraph, headGraph: headGraph)
                } else {
                    report = try analysis.select(base: options.base!, head: options.head, mergeBase: options.mergeBase, fullSuite: options.fullSuite)
                }
                let data = options.format == "json" ? try encoder.encode(report) : Data(render(report).utf8)
                try write(data, to: options.output)
                if options.run {
                    if let headGraph {
                        exit(try analysis.run(report, using: headGraph, productsDirectory: options.testProducts.map { URL(fileURLWithPath: $0) }))
                    }
                    exit(try analysis.run(report))
                }
            }
        } else if options.command == "graph" {
            let root = (try? GitChanges.repositoryRoot(at: package)) ?? package
            let graph = try PackageAnalyzer(packagePath: package, sourceRoot: root, progress: log).analyze()
            let data = options.format == "dot" ? Data(graph.dot().utf8) : try encoder.encode(graph)
            try write(data, to: options.output)
        } else {
            let analysis = ImpactAnalysis(packagePath: package, progress: log)
            let report = try analysis.select(base: options.base!, head: options.head, mergeBase: options.mergeBase, fullSuite: options.fullSuite)
            let data = options.format == "json" ? try encoder.encode(report) : Data(render(report).utf8)
            try write(data, to: options.output)
            if options.run { exit(try analysis.run(report)) }
        }
    } catch {
        log("error: \(error)")
        exit(1)
    }
}
