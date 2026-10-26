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
                           [--extraction-workers 1...8]
                           [--base REVISION] [--head REVISION] [--merge-base]
                           [--format FORMAT] [--output FILE] [--full-suite] [--run]

Persistent Xcode analysis:
  select <Xcode options> --base REV --head REV [--merge-base]
         --analysis-cache PATH --cache-context EXTERNAL_INPUT_DIGEST
         [--cache-max-bytes BYTES] [--cached-base-policy require|full-suite]
Cache hits validate settings/toolchain and reuse graphs without build or enumeration.
External input context must cover environment/scripts/local dependencies outside Git.
--cached-base-policy checks the resolved base before the head build, never building
that base. require exits 3 with a JSON error on stderr; full-suite selects all head
tests on a miss. Explicit --full-suite skips baseline lookup with either policy.
The default disk limit is 5 GiB. New revisions rebuild; worktrees are not cached.

Retain the analyzed head for execution after selection exits:
  select <Xcode options> --base REV --head REV --retain-build NEW_DIRECTORY
        [--build-time-sil /path/to/Scripts/capture-build.py]
  run <Xcode options> --report impact.json --head-graph NEW_DIRECTORY/head-graph.json
  verify-build <Xcode options> --report impact.json --head-graph FILE
Retained directories are caller-owned; remove them explicitly after execution.
verify-build emits the validated xctestrun path for custom runners. Empty selections
must be skipped by those runners. --test-products relocates an intact products tree.
select --head REV --run automatically reuses its head build, then cleans it up.

Existing Xcode builds:
  graph <Xcode options> --derived-data PATH --build-log FILE --build-settings FILE
        --xctestrun FILE --revision REVISION --output head-graph.json
        [--sil-capture SEALED_SESSION] [--format json|binary]
        [--discovery-cache PATH --discovery-context INPUT_DIGEST]
  select <Xcode options> --base REVISION [--head REVISION] [--merge-base]
         --base-graph FILE --head-graph FILE [--run] [--test-products PATH]

Capture requires a clean checkout of the built revision and an unfiltered successful
build-for-testing log. Keep original source/DerivedData paths until capture finishes.
Build-time SIL input must be sealed by Scripts/capture-build.py; incomplete modules
replay explicitly. Discovery reuse requires stable runner initialization inputs.
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
    var retainedBuild: String?
    var reportPath: String?
    var cachedBasePolicy: XcodeCachedBasePolicy = .build
    var cachePath: String?
    var cacheContext: String?
    var cacheMaxBytes: Int64 = 5 * 1_024 * 1_024 * 1_024

    init(_ arguments: [String]) throws {
        guard let first = arguments.first, ["graph", "select", "run", "verify-build"].contains(first) else {
            throw ImpactError("Expected 'graph', 'select', 'run' or 'verify-build'. Use --help for usage.")
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
        var extractionWorkers = 1
        var derivedData: String?
        var buildLog: String?
        var buildSettings: String?
        var xctestrun: String?
        var revision: String?
        var discoveryCache: String?
        var discoveryContext: String?
        var silCapture: String?
        var buildTimeSIL: String?
        while index < arguments.count {
            let flag = arguments[index]
            index += 1
            guard seen.insert(flag).inserted else { throw ImpactError("Repeated option: \(flag)") }
            if flag == "--run" { run = true; continue }
            if flag == "--merge-base" { mergeBase = true; continue }
            if flag == "--full-suite" { fullSuite = true; continue }
            guard ["--package-path", "--format", "--output", "--base", "--project", "--workspace", "--scheme", "--destination", "--configuration", "--test-plan", "--head", "--mappings", "--derived-data", "--build-log", "--build-settings", "--xctestrun", "--revision", "--base-graph", "--head-graph", "--test-products", "--analysis-cache", "--cache-context", "--cache-max-bytes", "--cached-base-policy", "--retain-build", "--report", "--extraction-workers", "--discovery-cache", "--discovery-context", "--sil-capture", "--build-time-sil"].contains(flag), index < arguments.count else {
                throw ImpactError("Unknown option or missing value: \(flag)")
            }
            let value = arguments[index]
            index += 1
            switch flag {
            case "--discovery-cache": discoveryCache = value
            case "--discovery-context": discoveryContext = value
            case "--sil-capture": silCapture = value
            case "--build-time-sil": buildTimeSIL = value
            case "--extraction-workers":
                guard let count = Int(value), (1...8).contains(count) else { throw ImpactError("--extraction-workers must be between 1 and 8.") }
                extractionWorkers = count
            case "--retain-build": retainedBuild = value
            case "--report": reportPath = value
            case "--analysis-cache": cachePath = value
            case "--cache-context": cacheContext = value
            case "--cached-base-policy":
                guard let policy = XcodeCachedBasePolicy(rawValue: value), policy != .build else {
                    throw ImpactError("--cached-base-policy must be require or full-suite.")
                }
                cachedBasePolicy = policy
            case "--cache-max-bytes":
                guard let size = Int64(value), size > 0 else { throw ImpactError("--cache-max-bytes must be positive.") }
                cacheMaxBytes = size
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
        if cachePath != nil || cacheContext != nil || seen.contains("--cache-max-bytes") || seen.contains("--cached-base-policy") {
            guard cachePath != nil, cacheContext?.isEmpty == false, head != nil, command == "select",
                  project != nil || workspace != nil, baseGraph == nil, headGraph == nil else {
                throw ImpactError("Analysis caching requires Xcode select, --head, --analysis-cache and --cache-context; cannot combine with saved graph inputs.")
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
        if discoveryCache != nil || discoveryContext != nil {
            guard buildInputs != nil, let discoveryCache, let discoveryContext, !discoveryContext.isEmpty else {
                throw ImpactError("Discovery caching requires existing-build graph inputs, --discovery-cache and --discovery-context (fingerprint runner initialization inputs).")
            }
            buildInputs!.discoveryCache = XcodeAnalysisCache(directory: URL(fileURLWithPath: discoveryCache), context: discoveryContext)
        }
        if buildTimeSIL != nil {
            guard command == "select", head != nil, project != nil || workspace != nil,
                  baseGraph == nil, headGraph == nil, captureCount == 0, silCapture == nil else {
                throw ImpactError("--build-time-sil HELPER requires Xcode select with --head and fresh revision analysis; use --sil-capture for saved build sessions.")
            }
        }
        if let silCapture {
            guard buildInputs != nil else { throw ImpactError("--sil-capture requires existing-build graph inputs.") }
            buildInputs!.silCapture = URL(fileURLWithPath: silCapture)
        }
        let savedExecution = command == "run" || command == "verify-build"
        if seen.contains("--extraction-workers") && (savedExecution || baseGraph != nil || headGraph != nil) {
            throw ImpactError("--extraction-workers requires fresh Xcode graph extraction.")
        }
        if savedExecution {
            guard reportPath != nil, headGraph != nil, project != nil || workspace != nil,
                  baseGraph == nil, base == nil, head == nil, !mergeBase, !fullSuite, !run,
                  retainedBuild == nil, captureCount == 0 else {
                throw ImpactError("run/verify-build require Xcode options, --report and --head-graph; comparison/build options are not accepted.")
            }
        } else if reportPath != nil { throw ImpactError("--report is only valid with run or verify-build.") }
        if retainedBuild != nil {
            guard command == "select", head != nil, project != nil || workspace != nil, headGraph == nil, baseGraph == nil else {
                throw ImpactError("--retain-build requires Xcode select with an explicit --head and no saved graph inputs.")
            }
        }
        if !savedExecution && (baseGraph != nil || headGraph != nil) {
            guard command == "select", baseGraph != nil, headGraph != nil, project != nil || workspace != nil else {
                throw ImpactError("Cached selection requires Xcode select mode and both --base-graph and --head-graph.")
            }
        }
        if testProducts != nil && !savedExecution && (baseGraph == nil || !run) {
            throw ImpactError("--test-products requires cached selection with --run.")
        }
        if command == "select" && base == nil { throw ImpactError("select requires --base REVISION.") }
        if command == "graph" && (base != nil || run || head != nil || mergeBase || fullSuite) { throw ImpactError("Comparison, execution, and full-suite options are only valid with select.") }
        let allowed = command == "graph" ? ["json", "dot", "binary"] : ["text", "json"]
        if !allowed.contains(format) { throw ImpactError("Unsupported format '\(format)' for \(command).") }
        if format == "binary" && (project == nil && workspace == nil || output == nil) { throw ImpactError("Binary graph output requires Xcode mode and --output FILE.") }
        if project != nil && workspace != nil { throw ImpactError("Choose --project or --workspace, not both.") }
        if let container = project ?? workspace {
            guard !seen.contains("--package-path") else { throw ImpactError("--package-path cannot be combined with an Xcode container.") }
            guard let scheme, !scheme.isEmpty, let destination, !destination.isEmpty else {
                throw ImpactError("Xcode mode requires --scheme and --destination.")
            }
            xcode = XcodeConfiguration(container: project != nil ? .project : .workspace,
                                       path: URL(fileURLWithPath: container), scheme: scheme, destination: destination,
                                       configuration: configuration, testPlan: testPlan)
            xcode!.extractionWorkers = extractionWorkers
            xcode!.buildTimeSILHelper = buildTimeSIL.map { URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath() }
            if let mappings { xcode!.mappingsPath = mappings }
        } else if scheme != nil || destination != nil || configuration != nil || testPlan != nil || mappings != nil || seen.contains("--extraction-workers") {
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
            if options.command == "run" || options.command == "verify-build" {
                let report = try JSONDecoder().decode(ImpactReport.self, from: Data(contentsOf: URL(fileURLWithPath: options.reportPath!)))
                let graph = try XcodeAnalysis.executionGraph(at: URL(fileURLWithPath: options.headGraph!))
                let products = options.testProducts.map { URL(fileURLWithPath: $0) }
                if options.command == "run" { exit(try analysis.run(report, using: graph, productsDirectory: products)) }
                let testRun = try analysis.verifyBuild(report, using: graph, productsDirectory: products)
                try write(try JSONSerialization.data(withJSONObject: ["xctestrun": testRun.path,
                    "headRevision": report.headRevision!, "buildArtifactID": report.buildArtifactID!,
                    "shouldRun": !report.selectedTests.isEmpty, "selectedTests": report.selectedTests,
                    "onlyTestingArguments": report.selectedTests.map { "-only-testing:" + $0 }], options: [.prettyPrinted, .sortedKeys]), to: options.output)
            } else if options.command == "graph" {
                let graph = try options.buildInputs.map { try analysis.graph(from: $0) } ?? analysis.graph()
                let data = options.format == "binary" ? try GraphArchive.encode(graph) : options.format == "dot" ? Data(graph.dot().utf8) : try encoder.encode(graph)
                try write(data, to: options.output)
            } else {
                let headGraph = try options.headGraph.map { try XcodeAnalysis.executionGraph(at: URL(fileURLWithPath: $0)) }
                let temporaryRetention = options.run && options.head != nil && headGraph == nil && options.retainedBuild == nil
                    ? FileManager.default.temporaryDirectory.appendingPathComponent("swift-impact-execution-" + UUID().uuidString) : nil
                defer { if let temporaryRetention { try? FileManager.default.removeItem(at: temporaryRetention) } }
                let retained = options.retainedBuild.map { URL(fileURLWithPath: $0) } ?? temporaryRetention
                let report: ImpactReport
                if let headGraph, let basePath = options.baseGraph {
                    let baseGraph = try XcodeAnalysis.executionGraph(at: URL(fileURLWithPath: basePath))
                    report = try analysis.select(base: options.base!, head: options.head, mergeBase: options.mergeBase,
                        fullSuite: options.fullSuite, baseGraph: baseGraph, headGraph: headGraph)
                } else {
                    report = try analysis.select(base: options.base!, head: options.head, mergeBase: options.mergeBase, fullSuite: options.fullSuite,
                        cache: options.cachePath.map { XcodeAnalysisCache(directory: URL(fileURLWithPath: $0), context: options.cacheContext!, maximumBytes: options.cacheMaxBytes) }, retainingBuildAt: retained, cachedBasePolicy: options.cachedBasePolicy)
                }
                let data = options.format == "json" ? try encoder.encode(report) : Data(render(report).utf8)
                try write(data, to: options.output)
                if options.run {
                    if let headGraph {
                        exit(try analysis.run(report, using: headGraph, productsDirectory: options.testProducts.map { URL(fileURLWithPath: $0) }))
                    }
                    let status = try analysis.run(report)
                    // exit() does not execute Swift defers. Release only the
                    // automatically owned bundle before terminating the CLI.
                    if let temporaryRetention { try FileManager.default.removeItem(at: temporaryRetention) }
                    exit(status)
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
    } catch let miss as XcodeCachedBaseUnavailable {
        if let data = try? JSONEncoder().encode(miss) {
            FileHandle.standardError.write(data + Data("\n".utf8))
        }
        exit(3)
    } catch {
        log("error: \(error)")
        exit(1)
    }
}
