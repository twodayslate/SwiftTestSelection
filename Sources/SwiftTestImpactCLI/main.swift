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
swift-test-impact — compiler-derived test selection for Swift packages

USAGE
  swift-test-impact graph [--package-path PATH] [--format json|dot] [--output FILE]
  swift-test-impact select --base REVISION [--package-path PATH] [--format text|json]
                           [--output FILE] [--run]

graph builds package/test targets and emits a SIL dependency graph.
select compares REVISION with the current worktree, including staged and untracked
files. It builds both revisions but does not execute test bodies unless --run is
provided. Test discovery loads test binaries and may execute initialization code.

Selection is conservative and experimental. Unsupported or unmapped changes may
select the entire suite. Requires Swift 6+, Git, and a buildable Swift package.
"""

private struct Options {
    var command: String
    var packagePath = FileManager.default.currentDirectoryPath
    var format: String
    var output: String?
    var base: String?
    var run = false

    init(_ arguments: [String]) throws {
        guard let first = arguments.first, ["graph", "select"].contains(first) else {
            throw ImpactError("Expected 'graph' or 'select'. Use --help for usage.")
        }
        command = first
        format = first == "graph" ? "json" : "text"
        var index = 1
        var seen = Set<String>()
        while index < arguments.count {
            let flag = arguments[index]
            index += 1
            guard seen.insert(flag).inserted else { throw ImpactError("Repeated option: \(flag)") }
            if flag == "--run" { run = true; continue }
            guard ["--package-path", "--format", "--output", "--base"].contains(flag), index < arguments.count else {
                throw ImpactError("Unknown option or missing value: \(flag)")
            }
            let value = arguments[index]
            index += 1
            switch flag {
            case "--package-path": packagePath = value
            case "--format": format = value
            case "--output": output = value
            case "--base": base = value
            default: break
            }
        }
        if command == "select" && base == nil { throw ImpactError("select requires --base REVISION.") }
        if command == "graph" && (base != nil || run) { throw ImpactError("--base and --run are only valid with select.") }
        let allowed = command == "graph" ? ["json", "dot"] : ["text", "json"]
        if !allowed.contains(format) { throw ImpactError("Unsupported format '\(format)' for \(command).") }
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
    for reason in report.fullRunReasons { lines.append("Full-suite fallback: \(reason)") }
    for test in report.selectedTests {
        lines.append("\n\(test)")
        for explanation in report.explanations where explanation.test == test {
            lines.append("  [\(explanation.revision)] \(explanation.reason)")
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
        if options.command == "graph" {
            let root = (try? GitChanges.repositoryRoot(at: package)) ?? package
            let graph = try PackageAnalyzer(packagePath: package, sourceRoot: root, progress: log).analyze()
            let data = options.format == "dot" ? Data(graph.dot().utf8) : try encoder.encode(graph)
            try write(data, to: options.output)
        } else {
            let analysis = ImpactAnalysis(packagePath: package, progress: log)
            let report = try analysis.select(base: options.base!)
            let data = options.format == "json" ? try encoder.encode(report) : Data(render(report).utf8)
            try write(data, to: options.output)
            if options.run { exit(try analysis.run(report)) }
        }
    } catch {
        log("error: \(error)")
        exit(1)
    }
}
