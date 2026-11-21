// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
import Foundation
import Testing
@testable import TestImpact

@Test func compiledHeadOnlyRuntimeBoundaryRequiresFullHistoricalEvidence() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let files = [
        "Core": "import Foundation\npublic func evaluate(_ body: () -> String) -> String { body() }\npublic func identifier() -> String { evaluate { UUID().uuidString } }",
        "App": "public func label() -> String { \"before\" }",
        "CoreTests": "import XCTest\nimport Core\nfinal class CoreCase: XCTestCase { func testID() { XCTAssertFalse(identifier().isEmpty) } }",
        "Hosted": "import XCTest\nimport App\nfinal class AppCase: XCTestCase { func testLabel() { XCTAssertFalse(label().isEmpty) } }"
    ]
    for (module, text) in files { try Data(text.utf8).write(to: root.appendingPathComponent(module + ".swift")) }
    var policy = UIFeatureMappings(features: [])
    policy.ignoredDocumentation = ["**.md"]
    policy.testRuntimeBoundaries = [.init(target: "CoreTests", modules: ["CoreTests", "Core"], rationale: "Hostless Core and test-owned fixtures only; no app loading, IPC, callbacks into App, or app-owned shared state.")]
    try JSONEncoder().encode(policy).write(to: root.appendingPathComponent(".swift-test-selection.json"))
    func git(_ args: [String]) throws -> String { try CommandRunner.run("git", args, at: root).text.trimmingCharacters(in: .whitespacesAndNewlines) }
    _ = try git(["init", "-q"])
    _ = try git(["add", "."])
    _ = try git(["-c", "user.name=Tests", "-c", "user.email=tests@example.invalid", "commit", "-qm", "base"])
    let base = try git(["rev-parse", "HEAD"])
    let changedApp = files["App"]!.replacingOccurrences(of: "before", with: "after")
    try Data(changedApp.utf8).write(to: root.appendingPathComponent("App.swift"))
    _ = try git(["add", "App.swift"])
    _ = try git(["-c", "user.name=Tests", "-c", "user.email=tests@example.invalid", "commit", "-qm", "head"])
    let head = try git(["rev-parse", "HEAD"])
    let comparison = try RevisionComparison(base: base, head: head, mergeBase: true, root: root)
    #expect(comparison.base == base)
    let platform = try CommandRunner.run("xcrun", ["--sdk", "macosx", "--show-sdk-platform-path"], at: root).text.trimmingCharacters(in: .whitespacesAndNewlines)
    var current = XcodeTestGraph(targets: [], tests: ["CoreTests/CoreCase/testID()", "Hosted/AppCase/testLabel()"])
    var graph = DependencyGraph(), tables: [String: Set<String>] = [:]
    // Build only the head modules. The base exists solely as Git source bytes.
    for module in ["Core", "App", "CoreTests", "Hosted"] {
        let path = module + ".swift"
        current.targets.append(.init(name: module, productType: ["CoreTests", "Hosted"].contains(module) ? "com.apple.product-type.bundle.unit-test" : "com.apple.product-type.framework", sourceFiles: [path]))
        current.modules[module] = module
        current.sources[module + ":" + path] = .parse(module == "App" ? changedApp : files[module]!, path: path, module: module)
        let sil = root.appendingPathComponent(module + ".sil")
        _ = try CommandRunner.run("xcrun", ["swiftc", "-module-name", module, "-I", root.path,
            "-F", platform + "/Developer/Library/Frameworks", "-I", platform + "/Developer/usr/lib", "-g", "-Onone",
            "-emit-module", "-emit-module-path", root.appendingPathComponent(module + ".swiftmodule").path,
            "-emit-sil", "-whole-module-optimization", root.appendingPathComponent(path).path, "-o", sil.path], at: root)
        let parsed = try SILParser.parse(file: sil, module: module, sourceRoot: root)
        for (id, node) in parsed.functions where graph.functions[id] == nil || !node.regions.isEmpty { graph.functions[id] = node }
        for (key, values) in parsed.dispatchTargets { tables[key, default: []].formUnion(values) }
    }
    XcodeCompilerGraph.resolveDispatch(&graph, tables: tables)
    XcodeCompilerGraph.bind(tests: current.tests, modules: current.modules, sources: current.sources, graph: &graph)
    current.dependencies = graph
    current.runtimeInventory = .init(imports: ["Core": [], "App": [], "CoreTests": ["Core"], "Hosted": ["App"]], hosts: ["CoreTests": ["CoreTests"], "Hosted": ["Hosted", "App"]])
    current.mappings = policy
    // Explicit test doubles for the production capture seals. Separate capture
    // tests exercise creation/validation of these seals from actual build files.
    var artifact = XcodeBuildArtifact(revision: head, context: [:], toolchain: "fixture", buildLogDigest: "log", buildSettingsDigest: "settings", productsDirectory: root.path, xctestrun: "Tests.xctestrun", products: [:])
    artifact.headOnlyBuildEvidence = .init(buildLogDigest: "log", buildSettingsDigest: "settings", documentation: [])
    artifact.helperFormattingBuild = .init(fingerprint: "effective", buildLogDigest: "log", buildSettingsDigest: "settings")
    artifact.helperBindingBuild = .init(sourceInputs: "sources", inputFiles: ["SDK": "bytes"], importedModules: ["Core": ["Foundation"]], buildLogDigest: "log", buildSettingsDigest: "settings", productsDigest: try XcodeGraphCache.key(artifact.products))
    current.buildArtifact = artifact
    let changes = try GitChanges.readComparison(base: base, head: head, at: root)
    let sourceCache = try XcodeBaseSourceCache(root: root, base: base)
    let source = try XcodeHeadOnlySources.read(current: current, changes: changes, base: base, root: root, mappingPath: ".swift-test-selection.json", cache: sourceCache)
    #expect(sourceCache.counts.headSyntaxReuse == 3)
    #expect(sourceCache.counts.parses == 1)
    func select(_ candidate: XcodeTestGraph, _ old: XcodeHeadOnlySources = source, revision: String? = nil) -> ImpactReport {
        XcodeHeadOnlySelector.select(current: candidate, source: old, changes: changes, baseRevision: revision ?? base)
    }
    let narrowed = select(current)
    #expect(narrowed.selectedTests == [current.tests[1]], "\(narrowed.diagnostics)")
    #expect(narrowed.runtimeBoundaryDecisions?.first?.status == "validated")
    #expect(narrowed.runtimeBoundaryDecisions?.first?.boundedUncertaintyTests == [current.tests[0]])
    // The same captured code plus authenticated documentation must compose with
    // a closed boundary, including a scope that only sees the App change.
    try Data("Documentation only\n".utf8).write(to: root.appendingPathComponent("AGENTS.md"))
    _ = try git(["add", "AGENTS.md"])
    _ = try git(["-c", "user.name=Tests", "-c", "user.email=tests@example.invalid", "commit", "-qm", "docs"])
    var documented = current
    documented.buildArtifact?.revision = try git(["rev-parse", "HEAD"])
    documented.buildArtifact?.headOnlyBuildEvidence?.documentation = ["AGENTS.md"]
    let withDocs = try GitChanges.readComparison(base: base, head: documented.buildArtifact!.revision, at: root)
    let docsSource = try XcodeHeadOnlySources.read(current: documented, changes: withDocs, base: base, root: root, mappingPath: ".swift-test-selection.json")
    let mixed = XcodeHeadOnlySelector.select(current: documented, source: docsSource, changes: withDocs, baseRevision: base, documentation: ["AGENTS.md"])
    #expect(mixed.ignoredChanges == ["AGENTS.md"])
    #expect(mixed.selectedTests == narrowed.selectedTests)
    #expect(mixed.runtimeBoundaryDecisions?.first?.status == "validated")
    #expect(select(documented, docsSource).selectedTests == narrowed.selectedTests)
    for condition in ["build-input", "uncertain-build", "changed-policy", "missing-policy", "stale-head"] {
        var candidate = documented
        switch condition {
        case "build-input": candidate.buildArtifact?.headOnlyBuildEvidence?.documentation = []
        case "uncertain-build": candidate.buildArtifact?.headOnlyBuildEvidence?.uncertainty = "Unknown build task"
        case "changed-policy": candidate.mappings?.ignoredDocumentation = ["AGENTS.md"]
        case "missing-policy": candidate.mappings?.ignoredDocumentation = nil
        case "stale-head": candidate.buildArtifact?.revision = head
        default: break
        }
        #expect(select(candidate, docsSource).selectedTests.contains(current.tests[0]), "\(condition)")
    }
    // A trailing comment changes bytes without changing native syntax or any
    // semantic source location. String literals and caller location shifts do.
    for suffix in [" // trailing comment", "\n// another comment"] {
        let text = files["Core"]! + suffix
        try Data(text.utf8).write(to: root.appendingPathComponent("Core.swift"))
        _ = try git(["add", "Core.swift"])
        _ = try git(["-c", "user.name=Tests", "-c", "user.email=tests@example.invalid", "commit", "-qm", "comment"])
        var candidate = documented
        candidate.buildArtifact?.revision = try git(["rev-parse", "HEAD"])
        candidate.sources["Core:Core.swift"] = .parse(text, path: "Core.swift", module: "Core")
        let full = try GitChanges.readComparison(base: base, head: candidate.buildArtifact!.revision, at: root)
        let old = try XcodeHeadOnlySources.read(current: candidate, changes: full, base: base, root: root, mappingPath: ".swift-test-selection.json")
        let report = XcodeHeadOnlySelector.select(current: candidate, source: old, changes: full, baseRevision: base, documentation: ["AGENTS.md"])
        #expect(report.selectedTests == narrowed.selectedTests, "\(report.diagnostics)")
        #expect(report.runtimeBoundaryDecisions?.first?.status == "validated")
    }
    for failure in ["build", "inputs", "base", "source", "byte-identity", "contract", "host", "edge", "imports", "unowned", "lifecycle", "macro", "body", "generated"] {
        var candidate = current, old = source
        switch failure {
        case "build": candidate.buildArtifact?.headOnlyBuildEvidence = nil
        case "inputs": candidate.buildArtifact?.helperBindingBuild?.inputFiles = [:]
        case "base": old.runtimeBoundaryEvidence = nil
        case "source": old.base.removeValue(forKey: "Core:Core.swift")
        case "byte-identity": candidate.sources["Core:Core.swift"]?.sourceBlobIDs = nil
        case "contract": old.mappings?.testRuntimeBoundaries?[0].rationale += "changed"
        case "host": candidate.runtimeInventory?.hosts["CoreTests"]?.insert("App")
        case "edge":
            let caller = try #require(graph.tests[current.tests[0]]?.first)
            let app = try #require(graph.functions.values.first { $0.module == "App" && $0.name == "label()" })
            candidate.dependencies?.functions[caller]?.dependencies.insert(app.id)
            candidate.dependencies?.functions[caller]?.compilerReferences = [app.id]
        case "imports": candidate.runtimeInventory?.imports["Core"] = ["App"]
        case "unowned": old.unownedBaseSources["Deleted.swift"] = .parse("func hidden() {}", path: "Deleted.swift", module: "")
        case "lifecycle": candidate.dependencies?.testDiagnostics[current.tests[0]] = ["Missing inherited setup"]
        case "macro": candidate.sources["Core:Core.swift"]?.helperDeclarationsComplete = false
        case "body": candidate.sources["Core:Core.swift"]?.units[1].fingerprint += "changed body"
        case "generated": candidate.unsupportedSourceInputs = ["Core": ["Unowned generated source"]]
        default: break
        }
        let report = select(candidate, old)
        #expect(report.selectedTests.contains(current.tests[0]), "\(failure): \(report.diagnostics)")
        #expect(report.runtimeBoundaryDecisions?.first?.status == "unproven", "\(failure)")
    }
    #expect(select(current, revision: "stale-base").runtimeBoundaryDecisions?.first?.status == "unproven")
    // Scope filtering must never conceal a changed build input in the full diff.
    try Data("changed host".utf8).write(to: root.appendingPathComponent("Config.xcconfig"))
    _ = try git(["add", "Config.xcconfig"])
    _ = try git(["-c", "user.name=Tests", "-c", "user.email=tests@example.invalid", "commit", "-qm", "config"])
    current.buildArtifact?.revision = try git(["rev-parse", "HEAD"])
    current.buildArtifact?.headOnlyBuildEvidence?.documentation = ["AGENTS.md"]
    let scopedSource = try XcodeHeadOnlySources.read(current: current, changes: changes, base: base, root: root, mappingPath: ".swift-test-selection.json")
    #expect(scopedSource.runtimeBoundaryEvidence?.failure != nil)
    let scoped = select(current, scopedSource)
    #expect(scoped.selectedTests.contains(current.tests[0]))
    #expect(scoped.runtimeBoundaryDecisions?.first?.failures?.first?.contains("Config.xcconfig") == true)
}

@Test func runtimeBoundaryGitEvidenceDoesNotAuthenticateSymlinkContents() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("func value() {}".utf8).write(to: root.appendingPathComponent("Real.swift"))
    try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("Link.swift").path, withDestinationPath: "Real.swift")
    func git(_ args: [String]) throws -> String { try CommandRunner.run("git", args, at: root).text.trimmingCharacters(in: .whitespacesAndNewlines) }
    _ = try git(["init", "-q"])
    _ = try git(["add", "."])
    _ = try git(["-c", "user.name=Tests", "-c", "user.email=tests@example.invalid", "commit", "-qm", "sources"])
    let revision = try git(["rev-parse", "HEAD"])
    let cache = try XcodeBaseSourceCache(root: root, base: revision)
    let evidence = try cache.runtimeEvidence(headRevision: revision)
    #expect(evidence.sourcePaths == ["Real.swift", "Link.swift"])
    #expect(evidence.regularSourcePaths == ["Real.swift"])
}
