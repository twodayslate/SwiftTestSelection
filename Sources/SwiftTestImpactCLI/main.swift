// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

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
  swift-test-impact mapping-review --graph FILE [--mappings PROPOSED.json]
                           [--base-graph FILE --changes FILE.json] [--output FILE]
  swift-test-impact inline-audit --graph FILE [--output FILE]
  swift-test-impact inline-proposal --source FILE --module MODULE --suite CLASS
                           [--method 'testName()'] --payload FILE.json [--output FILE]
  inline-proposal also accepts --coverage-proposal FILE --target TARGET instead of
  --payload/--method, producing a class insertion with original coverage provenance.
  Emits a JSON insertion proposal; never overwrites the source or removes mappings.
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

Optional UI mapping authoring (JSON output; no coverage required for selection):
  coverage plan --graph FILE --suite Target/Class --app-target App [--output FILE]
  coverage import --graph FILE --artifact FILE [--mappings FILE] [--output FILE]
  coverage apply --graph FILE --artifact FILE --mappings FILE [--output FILE]
Repeat --suite and --app-target as needed. Plan reuses a coverage-enabled captured
build once per suite. Import only proposes additions; apply explicitly writes them.
See Documentation/UICoverageMappings.md for collection and portable artifact format.

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

Head-only selection without baseline artifacts or a persistent cache:
  select <Xcode options> --base REV --head REV --merge-base --head-only
         --build-time-sil HELPER --retain-build NEW_DIRECTORY
Compares native Git source syntax; unsupported changes broaden explicitly.
  --selection-scopes FILE adds scoped reports from the same captured head graph.

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
--strict-mappings requires every head symbols entry to resolve in this build,
even for empty diffs or --full-suite. Available with Xcode select/run/verify-build.
Failures emit JSON diagnostics on stderr and exit 4 before executing tests.
Base mappings retain conservative handling so a head commit can repair them.

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
    var headOnly = false
    var selectionScopes: SelectionScopes?
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
        var strictMappings = false
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
            if flag == "--head-only" { headOnly = true; continue }
            if flag == "--full-suite" { fullSuite = true; continue }
            if flag == "--strict-mappings" { strictMappings = true; continue }
            guard ["--package-path", "--format", "--output", "--base", "--project", "--workspace", "--scheme", "--destination", "--configuration", "--test-plan", "--head", "--mappings", "--derived-data", "--build-log", "--build-settings", "--xctestrun", "--revision", "--base-graph", "--head-graph", "--test-products", "--analysis-cache", "--cache-context", "--cache-max-bytes", "--cached-base-policy", "--retain-build", "--report", "--extraction-workers", "--discovery-cache", "--discovery-context", "--sil-capture", "--build-time-sil", "--selection-scopes"].contains(flag), index < arguments.count else {
                throw ImpactError("Unknown option or missing value: \(flag)")
            }
            let value = arguments[index]
            index += 1
            switch flag {
            case "--selection-scopes": selectionScopes = try JSONDecoder().decode(SelectionScopes.self, from: Data(contentsOf: URL(fileURLWithPath: value)))
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
        if selectionScopes != nil && !headOnly { throw ImpactError("--selection-scopes requires --head-only") }
        try selectionScopes?.validate()
        if headOnly {
            guard command == "select", head != nil, buildTimeSIL != nil, retainedBuild != nil || run,
                  project != nil || workspace != nil, baseGraph == nil, headGraph == nil, cachedBasePolicy == .build else {
                throw ImpactError("--head-only requires Xcode select, --head, --build-time-sil, and --retain-build or --run; cannot combine with saved graphs or --cached-base-policy.")
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
        if strictMappings && (command == "graph" || project == nil && workspace == nil) {
            throw ImpactError("--strict-mappings requires Xcode select, run, or verify-build.")
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
            xcode!.strictMappings = strictMappings
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
    if let mode = report.analysisMode { lines.append("Analysis mode: " + mode) }
    if let head = report.headRevision { lines.append("Head: " + head + " (" + (report.comparisonMode ?? "direct") + ")") }
    for decision in report.uiConditionDecisions ?? [] {
        lines.append("UI condition [\(decision.revision)] \(decision.feature): \(decision.result.status.rawValue)")
        func describe(_ result: UIConditionResult, indent: String) {
            lines.append(indent + result.operation + (result.pattern.map { " " + $0 } ?? "") + ": " + result.status.rawValue)
            if let reason = result.reason { lines.append(indent + "  " + reason) }
            for change in result.changes { lines.append(indent + "  " + change) }
            for child in result.children { describe(child, indent: indent + "  ") }
        }
        describe(decision.result, indent: "  ")
    }
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
} else if arguments.first == "coverage" {
    do { try CoverageCommand.run(Array(arguments.dropFirst())) }
    catch {
        let data = try! JSONSerialization.data(withJSONObject: ["code": "coverage_command_failed", "message": String(describing: error)], options: [.sortedKeys])
        FileHandle.standardError.write(data + Data("\n".utf8)); exit(1)
    }
} else {
    do {
        if arguments.first == "mapping-review" {
            var values: [String: String] = [:]
            var cursor = 1
            while cursor < arguments.count {
                let key = arguments[cursor]
                guard ["--graph", "--mappings", "--base-graph", "--changes", "--output"].contains(key),
                      values[key] == nil, cursor + 1 < arguments.count else { throw ImpactError("Invalid mapping-review option: " + key) }
                values[key] = arguments[cursor + 1]; cursor += 2
            }
            guard let path = values["--graph"], (values["--base-graph"] == nil) == (values["--changes"] == nil) else {
                throw ImpactError("mapping-review requires --graph and both --base-graph/--changes for a comparison")
            }
            if let output = values["--output"] {
                let destination = URL(fileURLWithPath: output).standardizedFileURL.resolvingSymlinksInPath()
                guard values.filter({ $0.key != "--output" }).values.allSatisfy({ URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath() != destination }) else {
                    throw ImpactError("Review output must differ from every input")
                }
            }
            func data(_ path: String) throws -> Data { try Data(contentsOf: URL(fileURLWithPath: path)) }
            let graph = try GraphArchive.decode(data(path))
            let proposed = try values["--mappings"].map { try JSONDecoder().decode(UIFeatureMappings.self, from: data($0)) }
            let base = try values["--base-graph"].map { try GraphArchive.decode(data($0)) }
            let changes = try values["--changes"].map { try JSONDecoder().decode([FileChange].self, from: data($0)) }
            let review = MappingMaintenance.review(current: graph, proposed: proposed, previous: base, changes: changes)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try write(encoder.encode(review), to: values["--output"])
            exit(0)
        }
        if arguments.first == "inline-audit" {
            var values: [String: String] = [:]
            var cursor = 1
            while cursor < arguments.count {
                let key = arguments[cursor]
                guard ["--graph", "--output"].contains(key), values[key] == nil, cursor + 1 < arguments.count else {
                    throw ImpactError("inline-audit requires --graph FILE and optional --output FILE")
                }
                values[key] = arguments[cursor + 1]; cursor += 2
            }
            guard let path = values["--graph"] else { throw ImpactError("inline-audit requires --graph FILE") }
            if let output = values["--output"], URL(fileURLWithPath: output).standardizedFileURL.resolvingSymlinksInPath() == URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath() {
                throw ImpactError("Audit output must differ from its input graph")
            }
            let graph = try GraphArchive.decode(Data(contentsOf: URL(fileURLWithPath: path)))
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try write(encoder.encode(InlineMappingAudit.inspect(graph)), to: values["--output"])
            exit(0)
        }
        if arguments.first == "inline-proposal" {
            var values: [String: String] = [:]
            var cursor = 1
            let allowed: Set<String> = ["--source", "--module", "--suite", "--method", "--payload", "--output", "--coverage-proposal", "--target"]
            while cursor < arguments.count {
                let key = arguments[cursor]
                guard allowed.contains(key), values[key] == nil, cursor + 1 < arguments.count else {
                    throw ImpactError("inline-proposal expects unique --source, --module, --suite, --payload and optional --method/--output values")
                }
                values[key] = arguments[cursor + 1]; cursor += 2
            }
            guard let path = values["--source"], let module = values["--module"], let suite = values["--suite"] else {
                throw ImpactError("inline-proposal requires --source, --module and --suite")
            }
            if let output = values["--output"], [path, values["--payload"], values["--coverage-proposal"]].compactMap({ $0 }).contains(where: { URL(fileURLWithPath: output).standardizedFileURL.resolvingSymlinksInPath() == URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath() }) {
                throw ImpactError("Proposal output must differ from source and evidence inputs; review and apply proposedSource separately")
            }
            let source = try String(contentsOfFile: path, encoding: .utf8)
            let proposal: InlineMappingAuthoring.Proposal
            if let coverage = values["--coverage-proposal"], let target = values["--target"], values["--payload"] == nil, values["--method"] == nil {
                proposal = try InlineMappingAuthoring.proposeCoverage(source: source, path: path, module: module, target: target, suite: suite,
                    proposalData: Data(contentsOf: URL(fileURLWithPath: coverage)))
            } else if let payload = values["--payload"], values["--coverage-proposal"] == nil, values["--target"] == nil {
                proposal = try InlineMappingAuthoring.propose(source: source, path: path, module: module, suite: suite, method: values["--method"],
                    payload: String(contentsOfFile: payload, encoding: .utf8))
            } else { throw ImpactError("Provide --payload, or --coverage-proposal with --target and no --method") }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try write(encoder.encode(proposal), to: values["--output"])
            exit(0)
        }
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
                        cache: options.cachePath.map { XcodeAnalysisCache(directory: URL(fileURLWithPath: $0), context: options.cacheContext!, maximumBytes: options.cacheMaxBytes) }, retainingBuildAt: retained, cachedBasePolicy: options.cachedBasePolicy, headOnly: options.headOnly, selectionScopes: options.selectionScopes)
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
    } catch let validation as MappingValidationError {
        if let data = try? JSONEncoder().encode(validation) {
            FileHandle.standardError.write(data + Data("\n".utf8))
        }
        exit(4)
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
