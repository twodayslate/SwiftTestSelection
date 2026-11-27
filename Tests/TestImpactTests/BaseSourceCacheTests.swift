// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation
import Testing
@testable import TestImpact

func diagnosticJSON(_ report: ImpactReport) throws -> Data {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(report.diagnostics)
}

private struct SourceRepository {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("base-syntax-" + UUID().uuidString)
    init() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        _ = try git(["init", "-q"])
        _ = try git(["config", "user.email", "tests@example.invalid"])
        _ = try git(["config", "user.name", "Tests"])
    }
    func git(_ args: [String]) throws -> String {
        try CommandRunner.run("git", args, at: root).text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    func write(_ path: String, _ text: String) throws {
        try Data(text.utf8).write(to: root.appendingPathComponent(path))
    }
    func commit() throws -> String {
        _ = try git(["add", "."]); _ = try git(["commit", "-qm", "fixture"])
        return try git(["rev-parse", "HEAD"])
    }
}

@Test func retainedComparisonSyntaxRequiresTheCapturedHeadBytes() throws {
    let repo = try SourceRepository()
    defer { try? FileManager.default.removeItem(at: repo.root) }
    let path = "Caller.swift", key = "App:Caller.swift"
    let text = "#if DEBUG\nfunc call() { record() }\n#endif"
    try repo.write(path, text)
    let head = try repo.commit()
    let native = SwiftSourceSnapshot.parse(text, path: path, module: "App")
    var archived = native
    archived.parserVersion = 4
    // Old parsers used the presumed file for both kinds, even when it
    // disagreed with the physical path supplied to the macro or SDK.
    let index = try #require(native.units.firstIndex { $0.kind == "function" })
    archived.units[index].conditionalBranch = nil
    archived.units[index].callerLocations?["filePath"] = native.units[index].callerLocations?["file"]
    let original = try #require(archived.units[index].callerLocations)
    #expect(original != native.units[index].callerLocations)
    var graph = XcodeTestGraph(targets: [], tests: [])
    graph.sources[key] = archived
    try repo.write(path, text + " // different bytes")
    let other = try repo.commit()
    try graph.refreshLegacyComparisonSyntax(paths: [path], revision: other, root: repo.root)
    #expect(graph.sources[key]?.units[index].callerLocations == original)
    #expect(SwiftSourceSnapshot.legacyConditionalPaths(in: graph.sources, touching: [path]) == [path])
    try graph.refreshLegacyComparisonSyntax(paths: [], revision: head, root: repo.root)
    #expect(graph.sources[key]?.units[index].callerLocations == original)
    try graph.refreshLegacyComparisonSyntax(paths: [path], revision: head, root: repo.root)
    #expect(graph.sources[key]?.units[index].callerLocations == native.units[index].callerLocations)
    #expect(graph.sources[key]?.units[index].conditionalBranch == native.units[index].conditionalBranch)
    #expect(SwiftSourceSnapshot.legacyConditionalPaths(in: graph.sources, touching: [path]).isEmpty)
    #expect(graph.sources[key]?.parserVersion == 4)
}

@Test func legacySourceKeysRequireIndependentModuleOwnership() throws {
    let path = "Shared:Tests.swift"
    let ui = SwiftSourceSnapshot.parse("func value() {}", path: path, module: "UI")
    let other = SwiftSourceSnapshot.parse("func value() {}", path: path, module: "Other")
    var graph = XcodeTestGraph(targets: [
        .init(name: "UITests", productType: "com.apple.product-type.bundle.ui-testing", sourceFiles: [path]),
        .init(name: "OtherTests", productType: "com.apple.product-type.bundle.unit-test", sourceFiles: [path])
    ], tests: [])
    graph.modules = ["UITests": "UI", "OtherTests": "Other"]
    graph.sources = [path: ui]
    #expect(Set(graph.comparisonGraph.sources.keys) == [path])
    let repo = try SourceRepository()
    defer { try? FileManager.default.removeItem(at: repo.root) }
    try repo.write(path, "func value() {}")
    let revision = try repo.commit()
    let read = try XcodeHeadOnlySources.read(current: graph, changes: [], base: revision, root: repo.root, mappingPath: "mapping.json")
    #expect(read.diagnostics.contains("Invalid source snapshot key: " + path))

    graph.sources["Other:" + path] = ui
    #expect(graph.comparisonGraph.sources[path] != nil)
    graph.sources["Other:" + path] = other
    #expect(Set(graph.comparisonGraph.sources.keys) == ["UI:" + path, "Other:" + path])
    graph.sources["UI:" + path] = ui
    #expect(Set(graph.comparisonGraph.sources.keys) == Set(graph.sources.keys))
}

@Test func emptyArchiveRecordsRequireUnambiguousTargetMembership() {
    let path = "UI:Shared.swift"
    let empty = SwiftSourceSnapshot.parse("// placeholder", path: path, module: "Other")
    var graph = XcodeTestGraph(targets: [
        .init(name: "OtherTests", productType: "test", sourceFiles: [path])
    ], tests: [])
    graph.modules = ["OtherTests": "Other", "UITests": "UI"]
    graph.sources = [path: empty]
    #expect(Set(graph.comparisonGraph.sources.keys) == ["Other:" + path])
    #expect(graph.comparisonGraph.diagnostics.isEmpty)

    graph.targets.append(.init(name: "UITests", productType: "test", sourceFiles: [path]))
    #expect(!graph.comparisonGraph.diagnostics.isEmpty)
    graph.targets[1].sourceFiles = ["Shared.swift"]
    #expect(!graph.comparisonGraph.diagnostics.isEmpty)
    graph.sources["Other:" + path] = empty
    #expect(!graph.comparisonGraph.diagnostics.isEmpty)
    graph.sources[path] = SwiftSourceSnapshot.parse("", path: "Shared.swift", module: "UI")
    #expect(Set(graph.comparisonGraph.sources.keys) == [path, "Other:" + path])
    #expect(graph.comparisonGraph.diagnostics.isEmpty)
    graph.targets.removeLast()
    graph.sources = [path: empty]
    graph.sources[path]?.inlineMappings?.module = nil
    #expect(Set(graph.comparisonGraph.sources.keys) == ["Other:" + path])
    #expect(graph.comparisonGraph.diagnostics.isEmpty)
}

@Test(arguments: [false, true])
func legacyPathCanOccupyAnotherRecordsQualifiedKey(empty: Bool) {
    let path = "Shared.swift", prefixed = "UI:" + path
    let contents = empty ? "// placeholder" : "func value() {}"
    var graph = XcodeTestGraph(targets: [
        .init(name: "UI", productType: "test", sourceFiles: [path]),
        .init(name: "Other", productType: "test", sourceFiles: [prefixed])
    ], tests: [])
    graph.modules = ["UI": "UI", "Other": "Other"]
    graph.sources = [path: .parse(contents, path: path, module: "UI"),
                     prefixed: .parse(contents, path: prefixed, module: "Other")]
    for key in graph.sources.keys { graph.sources[key]?.inlineMappings?.module = nil }
    let comparison = graph.comparisonGraph
    #expect(comparison.diagnostics.isEmpty)
    #expect(Set(comparison.sources.keys) == ["UI:" + path, "Other:" + prefixed])
    #expect(Set(graph.sources.keys) == [path, prefixed])
}

@Test(arguments: ["otherFile", "getter", "builder"])
func savedGraphLocationComparisonAcrossParserVersions(edit: String) throws {
    let repo = try SourceRepository()
    defer { try? FileManager.default.removeItem(at: repo.root) }
    let options = XcodeConfiguration(container: .project, path: repo.root.appendingPathComponent("Fixture.xcodeproj"),
                                     scheme: "Fixture", destination: "fixture")
    let analysis = XcodeAnalysis(options: options)
    var context = try analysis.artifactContext(root: repo.root)
    context["sdkAndArchitecture"] = "fixture"
    let path = "Helpers.swift", key = "UI:" + path
    let entry = "UI/Suite/observes()", control = "UI/Control/unrelated()"
    let tests = "import Testing\nstruct Suite { @Test func observes() { #expect(caller() == 2) } }\nstruct Control { @Test func unrelated() {} }"
    let declaration = edit == "builder" ? "@B func caller() -> Int {\n    2\n\n}" :
        "private struct Plain { var value: Int {\n    return 2\n\n} }\nfunc caller() -> Int { Plain().value }"
    let support = "import Dispatch\n@resultBuilder enum B { static func buildExpression(_ x: Int, line: Int = #line) -> Int { line }; static func buildBlock(_ x: Int) -> Int { x } }"
    let compiler = try CommandRunner.run("xcrun", ["--find", "swiftc"], at: repo.root).text.trimmingCharacters(in: .whitespacesAndNewlines)
    let plugins = URL(fileURLWithPath: compiler).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("lib/swift/host/plugins/testing")
    func capture(_ helper: String, support: String) throws -> (XcodeTestGraph, String) {
        let files = [path: helper, "Tests.swift": tests, "Support.swift": support, "Placeholder.swift": "// Reserved."]
        for (path, text) in files { try repo.write(path, text) }
        _ = try repo.git(["add"] + files.keys.sorted())
        _ = try repo.git(["commit", "-qm", "source revision"])
        let revision = try repo.git(["rev-parse", "HEAD"])
        var graph = try boundaryGraph(files, tests: [entry, control], root: repo.root,
                                      compilerArguments: ["-plugin-path", plugins.path], compiler: compiler)
        graph.mappings = nil
        graph.buildArtifact = .init(revision: revision, context: context, toolchain: "fixture", buildLogDigest: "log",
                                    buildSettingsDigest: "settings", productsDirectory: repo.root.path,
                                    xctestrun: "Tests.xctestrun", products: ["Tests.xctestrun": "fixture"])
        return (graph, revision)
    }
    let before = try capture(declaration, support: support)
    let after = try capture(edit == "otherFile" ? declaration :
        declaration.replacingOccurrences(of: "\n    ", with: "\n\n    ").replacingOccurrences(of: "2\n\n}", with: "2\n}"),
        support: edit == "otherFile" ? support + "\n// documentation" : support)
    func legacy(_ native: XcodeTestGraph) throws -> XcodeTestGraph {
        var graph = native
        graph.sources[key]!.parserVersion = 32
        for i in graph.sources[key]!.units.indices {
            graph.sources[key]!.units[i].builderLocations = ["line": "v32 positions"]
        }
        return try GraphArchive.decode(GraphArchive.encode(graph))
    }
    let pairs = try [(legacy(before.0), after.0), (before.0, legacy(after.0))]
    for (base, head) in pairs {
        for barePath in [false, true] {
            var previous = base
            if barePath {
                for file in [path, "Placeholder.swift"] { previous.sources[file] = previous.sources.removeValue(forKey: "UI:" + file) }
            }
            let report = try analysis.select(base: before.1, head: after.1, baseGraph: previous, headGraph: head)
            #expect(report.selectedTests == (edit == "builder" ? [entry] : []))
            #expect(report.diagnostics.isEmpty)
        }
    }
    if edit == "getter" {
        var retained = try legacy(after.0)
        for file in [path, "Placeholder.swift"] { retained.sources[file] = retained.sources.removeValue(forKey: "UI:" + file) }
        retained.sources["Placeholder.swift"]?.inlineMappings?.module = nil
        retained.buildArtifact?.headOnlyBuildEvidence = .init(buildLogDigest: "log", buildSettingsDigest: "settings", documentation: [])
        let replay = try analysis.selectHeadOnly(base: before.1, head: after.1, headGraph: retained)
        #expect(replay.selectedTests.isEmpty)
        #expect(replay.ignoredChanges.contains(path))
        #expect(replay.diagnostics.isEmpty)
    }
}

@Test(arguments: [false, true])
func savedReplayProjectsUnchangedConditionalCallersOfRemovedOverload(barePaths: Bool) throws {
    let repo = try SourceRepository()
    defer { try? FileManager.default.removeItem(at: repo.root) }
    let caller = """
    import XCTest
    final class Cases: XCTestCase {
    #if DEBUG
        func testReading() { queryHelper(1) }
    #else
        func testReading() { queryHelper(2) }
    #endif
    }
    """
    let surviving = "func queryHelper<T>(_ value: T) {}"
    try repo.write("Suite.swift", caller)
    try repo.write("Helpers.swift", surviving + "\nfunc queryHelper(_ value: Int) {}")
    let base = try repo.commit()
    try repo.write("Helpers.swift", surviving)
    let head = try repo.commit()
    let entry = "UI/Cases/testReading()"
    var graph = try boundaryGraph(["Suite.swift": caller, "Helpers.swift": surviving], tests: [entry],
                                  root: repo.root, compilerArguments: ["-DDEBUG"])
    for key in graph.sources.keys {
        graph.sources[key]!.parserVersion = 4
        for i in graph.sources[key]!.units.indices { graph.sources[key]!.units[i].conditionalBranch = nil }
    }
    let options = XcodeConfiguration(container: .project, path: repo.root.appendingPathComponent("Fixture.xcodeproj"),
                                     scheme: "Fixture", destination: "fixture")
    let analysis = XcodeAnalysis(options: options)
    var context = try analysis.artifactContext(root: repo.root)
    context["sdkAndArchitecture"] = "fixture"
    graph.buildArtifact = .init(revision: head, context: context, toolchain: "fixture", buildLogDigest: "log",
                                buildSettingsDigest: "settings", productsDirectory: repo.root.path,
                                xctestrun: "Tests.xctestrun", products: ["Tests.xctestrun": "fixture"])
    graph.buildArtifact?.headOnlyBuildEvidence = .init(buildLogDigest: "log", buildSettingsDigest: "settings", documentation: [])
    let scopes = SelectionScopes(scopes: [.init(name: "helper", paths: ["Helpers.swift"])])
    let key = "UI:Suite.swift"
    let capturedBlobs = try #require(graph.sources[key]?.sourceBlobIDs)
    let identities: [Set<String>?] = [capturedBlobs, ["unrelated"], nil]
    for blobs in identities {
        graph.sources[key]?.sourceBlobIDs = blobs
        var stored = graph
        if barePaths {
            for path in ["Suite.swift", "Helpers.swift"] { stored.sources[path] = stored.sources.removeValue(forKey: "UI:" + path) }
        }
        let saved = try GraphArchive.decode(GraphArchive.encode(stored))
        let report = try analysis.selectHeadOnly(base: base, head: head, headGraph: saved, selectionScopes: scopes)
        for replay in [report, try #require(report.selectionScopes?.first?.report)] {
            #expect(!replay.diagnostics.contains { $0.code == "head_only_source_unavailable" })
            let removed = try #require(replay.headOnlyDeclarationChanges?.first { $0.change == "removed" })
            let callers = removed.historicalReferences.filter { $0.sourceKey == key }.flatMap { $0.possibleCallers ?? [] }
            #expect(Set(callers.map { $0.baseRegion.startLine }) == [4, 6])
            for caller in callers {
                let expected = blobs == capturedBlobs && caller.baseRegion.startLine == 4 ? [entry] : []
                #expect(caller.survivingTestEntries == expected)
            }
            #expect(replay.selectedTests == [entry])
        }
    }
}

@Test func unauditedRetainedSourceReadSkipsFullComparison() throws {
    let repo = try SourceRepository()
    defer { try? FileManager.default.removeItem(at: repo.root) }
    let before = "func value() -> Int { 0 }"
    let after = "func value() -> Int { 1 }"
    try repo.write("App.swift", before)
    for index in 0..<200 { try repo.write("File\(index).txt", "before") }
    let base = try repo.commit()
    try repo.write("App.swift", after)
    for index in 0..<200 { try repo.write("File\(index).txt", "after") }
    let head = try repo.commit()
    var current = XcodeTestGraph(targets: [], tests: [])
    current.sources = ["App:App.swift": .parse(after, path: "App.swift", module: "App")]
    current.buildArtifact = .init(revision: head, context: [:], toolchain: "fixture", buildLogDigest: "log", buildSettingsDigest: "settings", productsDirectory: repo.root.path, xctestrun: "fixture", products: [:])
    let cache = try XcodeBaseSourceCache(root: repo.root, base: base)
    let result = try XcodeHeadOnlySources.read(current: current, changes: [.init(path: "App.swift")], base: base, root: repo.root, mappingPath: "mapping.json", cache: cache)
    #expect(result.runtimeBoundaryEvidence == nil)
    #expect(cache.counts.treeReads == 0)
    #expect(cache.counts.parses == 1)
    #expect(cache.counts.headSyntaxReuse == 0)
    #expect(result.base["App:App.swift"]?.units.map(\.fingerprint) == SwiftSourceSnapshot.parse(before, path: "App.swift", module: "App").units.map(\.fingerprint))
}

@Test(arguments: ["sdk", "local", "crossFile", "unverifiedInputs"])
func scopedIndentationAuditsOnlyEligibleLocalCalls(callee: String) throws {
    let repo = try SourceRepository()
    defer { try? FileManager.default.removeItem(at: repo.root) }
    let call = callee == "sdk" ? "print(1)" : "local()"
    let declaration = callee == "crossFile" ? "" : "func local() {}\n"
    let before = declaration + "func caller() {\n    " + call + "\n}"
    let after = before.replacingOccurrences(of: "    ", with: "        ")
    try repo.write("Caller.swift", before)
    try repo.write("Unowned.swift", "func other() {}")
    var files = ["Caller.swift": after]
    if callee == "crossFile" {
        files["Support.swift"] = "func local() {}"
        try repo.write("Support.swift", "func local() {}")
    }
    let base = try repo.commit()
    var current = try boundaryGraph(files, tests: [], root: repo.root)
    current.mappings = nil
    let discovery = SwiftTestingDiscoveryRoots.sharedDiscoveryID
    current.dependencies?.functions[discovery] = FunctionNode(id: discovery, module: "Testing", name: "discovery")
    let cache = try XcodeBaseSourceCache(root: repo.root, base: base)
    let result = try XcodeHeadOnlySources.read(current: current, changes: [.init(path: "Caller.swift")], base: base,
                                                root: repo.root, mappingPath: "mapping.json", cache: cache,
                                                allowHistoricalCallerProofs: callee != "unverifiedInputs")
    #expect(cache.counts.treeReads == (callee == "local" ? 1 : 0))
    #expect(cache.counts.parses == (callee == "local" ? 2 : 1))
    #expect((result.unownedBaseSources["Unowned.swift"] != nil) == (callee == "local"))
}

@Test(arguments: ["manifest", "competingName", "competingStorage", "competingType", "unknownExpansion"])
func unownedBaseFilesOnlyBlockAffectedLocationProofs(scenario: String) throws {
    let repo = try SourceRepository()
    defer { try? FileManager.default.removeItem(at: repo.root) }
    let before = "func name() -> Bool { true }\nfunc caller() -> Bool {\n    return name()\n}"
    let after = before.replacingOccurrences(of: "    return", with: "        return")
    let tests = "import Testing\nstruct Cases { @Test func check() { #expect(caller()) } }"
    try repo.write("Caller.swift", before)
    try repo.write("Tests.swift", tests)
    try repo.write("Package.swift", "// swift-tools-version: 6.0\nimport PackageDescription\nlet package = Package(name: \"Fixture\")")
    if scenario == "competingName" { try repo.write("Removed.swift", "func name(_ line: Int = #line) -> Int { line }") }
    if scenario == "competingStorage" { try repo.write("Removed.swift", "let (name, other) = ({ true }, 0)") }
    if scenario == "competingType" { try repo.write("Removed.swift", "struct name {}") }
    if scenario == "unknownExpansion" { try repo.write("Removed.swift", "#makeHelpers()") }
    let base = try repo.commit()
    let compiler = try CommandRunner.run("xcrun", ["--find", "swiftc"], at: repo.root).text.trimmingCharacters(in: .whitespacesAndNewlines)
    let plugins = URL(fileURLWithPath: compiler).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("lib/swift/host/plugins/testing")
    let id = "UI/Cases/check()"
    var graph = try boundaryGraph(["Caller.swift": after, "Tests.swift": tests], tests: [id], root: repo.root,
                                  compilerArguments: ["-plugin-path", plugins.path], compiler: compiler)
    graph.mappings = nil
    let changes = [FileChange(path: "Caller.swift")]
    let source = try XcodeHeadOnlySources.read(current: graph, changes: changes, base: base, root: repo.root, mappingPath: "mapping.json")
    #expect(source.unownedBaseSources["Package.swift"] != nil)
    let report = XcodeHeadOnlySelector.select(current: graph, source: source, changes: changes, baseRevision: base)
    #expect(report.selectedTests == (scenario == "manifest" ? [] : [id]))
}

@Test(arguments: ["Types.swift", "Kit/Package.swift", "Kit/Package@swift-6.swift", "Generator.swift"])
func scopedCallerLocationsSurviveAnImportedOverloadInTheBase(input: String) throws {
    let repo = try SourceRepository()
    defer { try? FileManager.default.removeItem(at: repo.root) }
    let path = "Helpers.swift", entry = "UI/Cases/observes()"
    let before = "import External\nfunc record(_ value: Payload) -> Int { 0 }\nfunc position() -> Int { record(0) }"
    let after = before.replacingOccurrences(of: "\nfunc position", with: "\n\nfunc position")
    let tests = "import Testing\nstruct Cases { @Test func observes() { #expect(position() == 3) } }"
    try repo.write(path, before)
    let conditionalAlias = "#if BASE_TYPE\ntypealias Payload = String\n#else\ntypealias Payload = Int\n#endif"
    func writeBuildInput(define: Bool) throws {
        if input.hasPrefix("Kit/") {
            try FileManager.default.createDirectory(at: repo.root.appendingPathComponent("Kit"), withIntermediateDirectories: true)
            let settings = define ? #".define("BASE_TYPE")"# : ""
            try repo.write(input, """
                // swift-tools-version: 6.0
                import PackageDescription
                let package = Package(name: "Fixture", targets: [.testTarget(name: "UI", swiftSettings: [\(settings)])])
                """)
        } else if input == "Generator.swift" {
            try repo.write(input, define ? #"print("-D BASE_TYPE")"# : #"print("")"#)
        }
    }
    try writeBuildInput(define: true)
    try repo.write("Types.swift", input == "Types.swift" ? "typealias Payload = String" : conditionalAlias)
    try repo.write("Tests.swift", tests)
    let base = try repo.commit()
    try writeBuildInput(define: false)
    let files = [path: after, "Types.swift": input == "Types.swift" ? "typealias Payload = Int" : conditionalAlias, "Tests.swift": tests]
    for (path, text) in files { try repo.write(path, text) }
    let head = try repo.commit()

    // The base overload supplies #line at the call. The unchanged signature of
    // the local overload becomes applicable only after the out-of-scope change.
    try repo.write("External.swift", "public func record(_ value: Int, line: Int = #line) -> Int { line }")
    let library = repo.root.appendingPathComponent("libExternal.a")
    _ = try CommandRunner.run("xcrun", ["swiftc", "-emit-library", "-static", "-emit-module", "-module-name", "External",
        "External.swift", "-o", library.path], at: repo.root)
    let compiler = try CommandRunner.run("xcrun", ["--find", "swiftc"], at: repo.root).text.trimmingCharacters(in: .whitespacesAndNewlines)
    let plugins = URL(fileURLWithPath: compiler).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("lib/swift/host/plugins/testing")
    var graph = try boundaryGraph(files, tests: [entry], root: repo.root, compilerArguments: ["-plugin-path", plugins.path, "-I", repo.root.path],
                                  compiler: compiler, linkArguments: [library.path])
    graph.mappings = nil
    let scopes = try XcodeHeadOnlySelector.scopedReports(current: graph, requests: .init(scopes: [.init(name: "helper", paths: [path])]),
        changes: GitChanges.readComparison(base: base, head: head, at: repo.root), baseRevision: base, headRevision: head,
        root: repo.root, mappingPath: "mapping.json", documentation: [], buildEvidenceFailure: nil)
    let report = try #require(scopes.first?.report)
    #expect(!report.ignoredChanges.contains(path))
    #expect(report.explanations.contains { $0.test == entry && $0.kind == "dependency" })
}

@Test func omittedBuildInputPreservesPotentialInlinedCallers() throws {
    let repo = try SourceRepository()
    defer { try? FileManager.default.removeItem(at: repo.root) }
    let path = "Helpers.swift", entry = "UI/Suite/observes()"
    let before = "@_transparent func gate() -> Bool { false }"
    let after = "@_transparent func gate() -> Bool { true }"
    let tests = "import Testing\nstruct Suite { @Test func observes() { #expect(!result()) } }"
    let resultSource = "#if HEAD\nfunc result() -> Bool { false }\n#endif"
    // The base target compiles a generated implementation. At head it compiles
    // the tracked implementation instead and no longer includes Generated.swift.
    try repo.write(path, before)
    try repo.write("Tests.swift", tests)
    try repo.write("Result.swift", resultSource)
    try repo.write("Build.xcconfig", "SWIFT_ACTIVE_COMPILATION_CONDITIONS = BASE")
    let base = try repo.commit()
    try repo.write("Build.xcconfig", "SWIFT_ACTIVE_COMPILATION_CONDITIONS = HEAD\nEXCLUDED_SOURCE_FILE_NAMES = Generated.swift")
    try repo.write(path, after)
    let head = try repo.commit()
    try repo.write("Generated.swift", "func result() -> Bool { gate() }")
    try repo.write("main.swift", "print(result())")
    for (implementation, expected) in [(before, "false"), (after, "true")] {
        try repo.write(path, implementation)
        _ = try CommandRunner.run("xcrun", ["swiftc", path, "Generated.swift", "Result.swift", "main.swift", "-o", "probe"], at: repo.root)
        #expect(try CommandRunner.run(repo.root.appendingPathComponent("probe").path, [], at: repo.root).text.trimmingCharacters(in: .whitespacesAndNewlines) == expected)
    }
    let files = [path: after, "Tests.swift": tests, "Result.swift": resultSource]
    let compiler = try CommandRunner.run("xcrun", ["--find", "swiftc"], at: repo.root).text.trimmingCharacters(in: .whitespacesAndNewlines)
    let plugins = URL(fileURLWithPath: compiler).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("lib/swift/host/plugins/testing")
    var graph = try boundaryGraph(files, tests: [entry], root: repo.root, compilerArguments: ["-plugin-path", plugins.path, "-D", "HEAD"], compiler: compiler)
    graph.mappings = nil
    let scopes = try XcodeHeadOnlySelector.scopedReports(current: graph, requests: .init(scopes: [.init(name: "helper", paths: [path])]),
        changes: GitChanges.readComparison(base: base, head: head, at: repo.root), baseRevision: base, headRevision: head,
        root: repo.root, mappingPath: "mapping.json", documentation: [], buildEvidenceFailure: nil)
    let report = try #require(scopes.first?.report)
    #expect(report.selectedTests == [entry])
    #expect(report.diagnostics.contains { $0.code == "head_only_unsupported_body" })
}

@Test(arguments: ["interpolation", "trailingClosure", "keyPathSubscript", "explicitReturn", "shorthandGetter", "explicitGetter", "subscriptGetter",
                  "setter", "observer", "closureBinding", "wrappedClosureBinding", "returnedClosure", "implicitlyReturnedClosure", "implicitMethod", "implicitGetter",
                  "unusedPrivateInitializer", "unusedPrivateStep", "inlinedPrivateInitializer"])
func callerLocationsAcrossWhitespaceEdits(form: String) throws {
    let repo = try SourceRepository()
    defer { try? FileManager.default.removeItem(at: repo.root) }
    let entry = "UI/Suite/observes()", control = "UI/Control/unrelated()"
    let path = "Helpers.swift", key = "UI:" + path
    let before: String, after: String, support: String
    let ordinaryBodies = [
        "explicitReturn": ("func value() -> Int { BODY }", "Plain().value()", "return 2"),
        "shorthandGetter": ("var value: Int { BODY }", "Plain().value", "return 2"),
        "explicitGetter": ("var value: Int { get { BODY } }", "Plain().value", "return 2"),
        "subscriptGetter": ("subscript(_ i: Int) -> Int { get { BODY } set {} }", "Plain()[0]", "return 2"),
        "setter": ("var storage = 1; var value: Int { get { storage } set { BODY } }",
                   "var p = Plain(); p.value = 2; return p.value", "storage = newValue"),
        "observer": ("var storage = 1; var value = 0 { didSet { BODY } }",
                     "var p = Plain(); p.value = 2; return p.storage", "storage = value"),
        "closureBinding": ("func value() -> Int { let f: () -> Int = { BODY }; return f() }", "Plain().value()", "2"),
        "wrappedClosureBinding": ("func value() -> Int { let f = ({ BODY }); return f() }", "Plain().value()", "2"),
        "returnedClosure": ("func value() -> () -> Int { return { BODY } }", "Plain().value()()", "2"),
        "implicitlyReturnedClosure": ("func value() -> () -> Int { ({ BODY }) }", "Plain().value()()", "2"),
        "implicitMethod": ("func value() -> Int { BODY }", "Plain().value()", "2"),
        "implicitGetter": ("var value: Int { BODY }", "Plain().value", "2")
    ]
    let privateMembers = [
        "unusedPrivateInitializer": "init(line: Int = #line) {}",
        "unusedPrivateStep": "static func buildExpression(_ value: Int, line: Int = #line) -> Int { line }",
        "inlinedPrivateInitializer": "@inline(__always) init(line: Int = #line) {}"
    ]
    if let member = privateMembers[form] {
        support = "private struct Stamp { \(member) }"
        before = "struct Plain { func answer() -> Int {\n    2\n\n} }\nfunc caller() -> Int { Plain().answer() }"
        after = before.replacingOccurrences(of: "\n    2\n\n", with: "\n\n    2\n")
    } else if let (declaration, call, statement) = ordinaryBodies[form] {
        support = "import Dispatch"
        let source = "private struct Plain { \(declaration) }\nfunc caller() -> Int { \(call) }"
        before = source.replacingOccurrences(of: " BODY ", with: "\n    \(statement)\n\n")
        after = source.replacingOccurrences(of: " BODY ", with: "\n\n    \(statement)\n")
    } else if form == "trailingClosure" {
        support = "func read(line: Int = #line, _ f: () -> Int, next: () -> Int) -> Int { line }"
        before = "func caller() -> Int { read\n    { 2 } next: { 3 }\n\n}"
        after = "func caller() -> Int { read\n\n    { 2 } next: { 3 }\n}"
    } else if form == "keyPathSubscript" {
        support = "struct Source { subscript(_ i: Int, line: Int = #line) -> Int { line } }"
        let literal = #"    let path = \Source.[0]"#
        let apply = "    return Source()[keyPath: path]\n}"
        before = "func caller() -> Int {\n" + literal + "\n\n" + apply
        after = "func caller() -> Int {\n\n" + literal + "\n" + apply
    } else {
        before = "func pass(_ value: Output) -> Int { value.line }" + "\n" + #"func caller() -> Int { pass("\(2)") }"#
        after = "\n" + before
        support = """
        struct Output: ExpressibleByStringInterpolation {
            struct Builder: StringInterpolationProtocol {
                var line: Int
                @_transparent init(literalCapacity: Int, interpolationCount: Int) { line = 0 }
                @_transparent mutating func appendLiteral(_ value: StaticString) {}
                @_transparent mutating func appendInterpolation(_ value: Int, line: Int = #line) { self.line = line }
            }
            var line: Int
            @_transparent init(stringLiteral value: StaticString) { line = 0 }
            @_transparent init(stringInterpolation: Builder) { line = stringInterpolation.line }
        }
        """
    }
    let tests = "import Testing\nstruct Suite { @Test func observes() { #expect(caller() == 2) } }\nstruct Control { @Test func unrelated() {} }"
    try repo.write("Support.swift", support)
    try repo.write("Tests.swift", tests)
    try repo.write(path, before)
    let base = try repo.commit()
    try repo.write(path, after)
    let head = try repo.commit()
    let compiler = try CommandRunner.run("xcrun", ["--find", "swiftc"], at: repo.root).text.trimmingCharacters(in: .whitespacesAndNewlines)
    let plugins = URL(fileURLWithPath: compiler).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("lib/swift/host/plugins/testing")
    func capture(_ text: String) throws -> XcodeTestGraph {
        var graph = try boundaryGraph([path: text, "Support.swift": support, "Tests.swift": tests], tests: [entry, control],
            root: repo.root, compilerArguments: ["-plugin-path", plugins.path], compiler: compiler)
        graph.mappings = nil
        return graph
    }
    let previous = try capture(before), current = try capture(after)
    let changes = try GitChanges.readComparison(base: base, head: head, at: repo.root)
    func reports(_ graph: XcodeTestGraph) throws -> [ImpactReport] {
        let source = try XcodeHeadOnlySources.read(current: graph, changes: changes, base: base, root: repo.root, mappingPath: "mapping.json")
        return [XcodeFineSelector.select(current: graph, previous: previous, changes: changes, baseRevision: base),
                XcodeHeadOnlySelector.select(current: graph, source: source, changes: changes, baseRevision: base)]
    }
    let index = try #require(current.sources[key]?.units.firstIndex { $0.helperCallableName == "caller" })
    let caller = try #require(current.sources[key]?.units[index])
    if form == "interpolation" {
        #expect(caller.invocationNames == ["pass", "appendInterpolation"])
        #expect(caller.hasOnlyDirectSourceCalls != true)
    }
    if form == "keyPathSubscript" {
        #expect(caller.invocationNames?.contains("subscript") == true)
        #expect(caller.hasOnlyDirectSourceCalls != true)
    }
    let ignoresEdit = ordinaryBodies[form] != nil || privateMembers[form] != nil
    for report in try reports(current) {
        if ignoresEdit {
            #expect(report.selectedTests.isEmpty)
            #expect(report.ignoredChanges.contains(path))
        } else {
            #expect(report.selectedTests.contains(entry))
            #expect(!report.ignoredChanges.contains(path))
        }
        #expect(report.diagnostics.isEmpty)
    }
    var legacy = current
    if privateMembers[form] != nil {
        let provider = "UI:Support.swift"
        legacy.sources[provider]?.parserVersion = form == "inlinedPrivateInitializer" ? 36 : 35
        legacy.sources[provider]?.privateLocationDefaultOwners = nil
        legacy = try GraphArchive.decode(GraphArchive.encode(legacy))
        for report in try reports(legacy) { #expect(report.selectedTests.contains(entry)) }

        var differentBlob = legacy
        differentBlob.sources[provider]?.sourceBlobIDs = ["different"]
        try differentBlob.refreshLegacyComparisonSyntax(paths: [path], revision: head, root: repo.root)
        #expect(differentBlob.sources[provider]?.privateLocationDefaultOwners == legacy.sources[provider]?.privateLocationDefaultOwners)
    }
    if ignoresEdit {
        legacy.sources[key]?.parserVersion = form == "explicitReturn" ? 31 : 32
        for i in legacy.sources[key]!.units.indices {
            legacy.sources[key]!.units[i].builderLocations = ["line": "legacy body"]
        }
        try legacy.refreshLegacyComparisonSyntax(paths: [path], revision: head, root: repo.root)
        if privateMembers[form] != nil {
            #expect(legacy.sources["UI:Support.swift"]?.privateLocationDefaultOwners == ["Stamp"])
        }
        #expect(legacy.sources[key]?.units.map(\.builderLocations) == current.sources[key]?.units.map(\.builderLocations))
        for report in try reports(legacy) { #expect(report.selectedTests.isEmpty) }
        return
    }
    legacy.sources[key]?.parserVersion = form == "interpolation" ? 28 : 31
    legacy.sources[key]?.units[index].hasOnlyDirectSourceCalls = true
    legacy.sources[key]?.units[index].invocationNames = ["pass"]
    legacy.sources[key]?.units[index].callerLocations = [:]
    legacy = try GraphArchive.decode(GraphArchive.encode(legacy))
    for report in try reports(legacy) {
        #expect(report.selectedTests.contains(entry))
        #expect(report.diagnostics.contains { $0.code == "incomplete_caller_locations" })
    }
    try legacy.refreshLegacyComparisonSyntax(paths: [path], revision: head, root: repo.root)
    #expect(legacy.sources[key]?.units[index].callerLocations == caller.callerLocations)
    #expect(legacy.sources[key]?.units[index].invocationNames == caller.invocationNames)
    #expect(legacy.sources[key]?.units[index].hasOnlyDirectSourceCalls == caller.hasOnlyDirectSourceCalls)
    for report in try reports(legacy) {
        #expect(report.selectedTests.contains(entry))
        #expect(!report.diagnostics.contains { $0.code == "incomplete_caller_locations" })
    }
}

@Test func unrelatedInitializerCannotMakeAnOrdinaryMethodABuilder() {
    let path = "Caller.swift"
    let caller = SwiftSourceSnapshot.parse("struct Plain { func answer() -> Int { 2 } }", path: path, module: "App")
    let stamp = SwiftSourceSnapshot.parse("struct Stamp { init(line: Int = #line) {} }", path: "Stamp.swift", module: "App")
    let sources = ["App:" + path: caller, "App:Stamp.swift": stamp]
    let locations = ResultBuilderLocations(policy: .semantic, sources: [sources], modules: ["App"],
        incompleteInputs: false, touching: [path])
    #expect(caller.units.allSatisfy { locations.kinds[$0].isEmpty })
}

@Test(arguments: [false, true]) func unusedPrivateDefaultsDoNotAffectOtherCompiledCalls(sameTypeName: Bool) throws {
    let repo = try SourceRepository()
    defer { try? FileManager.default.removeItem(at: repo.root) }
    let path = "Helpers.swift", test = "UI/Suite/testObserves()"
    let owner = sameTypeName ? "Stamp" : "Plain"
    let support = "private struct Stamp { init(line: Int = #line) {}; func answer() -> Int { identity(1) } }"
    let tests = "import XCTest\nfinal class Suite: XCTestCase { func testObserves() { XCTAssertEqual(caller(), 2) } }"
    let before = "func identity(_ x: Int) -> Int { x }\nprivate struct \(owner) { func answer() -> Int {\n    identity(2)\n\n} }\nfunc caller() -> Int { \(owner)().answer() }"
    let after = before.replacingOccurrences(of: "\n    identity(2)\n\n", with: "\n\n    identity(2)\n")
    func capture(_ text: String) throws -> XcodeTestGraph {
        var graph = try boundaryGraph([path: text, "Support.swift": support, "Tests.swift": tests], tests: [test], root: repo.root)
        graph.mappings = nil
        return graph
    }
    let previous = try capture(before), current = try capture(after)
    let report = XcodeFineSelector.select(current: current, previous: previous, changes: [.init(path: path)], baseRevision: "base")
    #expect(report.selectedTests.isEmpty)
    #expect(report.ignoredChanges.contains(path))
    #expect(report.diagnostics.isEmpty)
}

@Test func privateLocationDefaultsStayWithTheirOwnerAndNestedTypes() throws {
    let path = "Helpers.swift"
    let text = """
        #if !OTHER
        @resultBuilder private struct Stamp {
            @inline(__always) static func buildExpression(_ x: Int, line: Int = #line) -> Int { line }
            static func buildBlock(_ x: Int) -> Int { x }
            struct Nested { func inside() -> Int { buildExpression(1) } }
        }
        #endif
        struct Other { func outside() -> Int { 2 } }
        """
    let file = SwiftSourceSnapshot.parse(text, path: path, module: "App")
    let otherFile = SwiftSourceSnapshot.parse("struct Stamp { func elsewhere() -> Int { 2 } }", path: "Other.swift", module: "App")
    let otherModule = SwiftSourceSnapshot.parse("struct Stamp { func elsewhere() -> Int { 2 } }", path: path, module: "Other")
    let sources = ["App:Helpers.swift": file, "App:Other.swift": otherFile, "Other:Helpers.swift": otherModule]
    let locations = ResultBuilderLocations(policy: .semantic, sources: [sources], modules: ["App", "Other"],
        incompleteInputs: false, touching: [path])
    #expect(file.privateLocationDefaultOwners == ["Stamp"])
    let inside = try #require(file.units.first { $0.helperCallableName == "inside" })
    #expect(locations.kinds[inside] == ["line"])
    let outside = try #require(file.units.first { $0.helperCallableName == "outside" })
    #expect(locations.kinds[outside].isEmpty)
    #expect((otherFile.units + otherModule.units).allSatisfy { locations.kinds[$0].isEmpty })
}

@Test func privateClassDefaultsRemainVisibleToDynamicMemberLookup() throws {
    let repo = try SourceRepository()
    defer { try? FileManager.default.removeItem(at: repo.root) }
    let path = "Helpers.swift", entry = "UI/Suite/testCaller()"
    let before = """
        import Foundation
        private final class Stamp { @objc func stamped(_ value: Int = #line) -> Int { value } }
        func caller(_ value: AnyObject) -> Int {
            return value.stamped?() ?? 0

        }
        """
    let after = before.replacingOccurrences(of: "    return value.stamped?() ?? 0\n\n", with: "\n    return value.stamped?() ?? 0\n")
    let tests = "import XCTest\nfinal class Suite: XCTestCase { func testCaller() { XCTAssertEqual(caller(NSObject()), 0) } }"
    try repo.write(path, before)
    try repo.write("Tests.swift", tests)
    let base = try repo.commit()
    try repo.write(path, after)
    let head = try repo.commit()
    func capture(_ text: String) throws -> XcodeTestGraph {
        var graph = try boundaryGraph([path: text, "Tests.swift": tests], tests: [entry], root: repo.root)
        graph.mappings = nil
        return graph
    }
    let previous = try capture(before), current = try capture(after)
    let file = try #require(current.sources["UI:" + path])
    #expect(file.privateLocationDefaultOwners?.isEmpty == true)
    // The v36 archive field only proved absence of a written type name.
    var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(file)) as? [String: Any])
    json["parserVersion"] = 36
    json["unreferencedPrivateTypes"] = ["Stamp"]
    json.removeValue(forKey: "privateLocationDefaultOwners")
    let archived = try JSONDecoder().decode(SwiftSourceSnapshot.self, from: JSONSerialization.data(withJSONObject: json))
    #expect(archived.privateLocationDefaultOwners == nil)
    var legacy = current
    legacy.sources["UI:" + path] = archived
    let changes = try GitChanges.readComparison(base: base, head: head, at: repo.root)
    for graph in [current, legacy] {
        let source = try XcodeHeadOnlySources.read(current: graph, changes: changes, base: base, root: repo.root, mappingPath: "mapping.json")
        #expect(XcodeFineSelector.select(current: graph, previous: previous, changes: changes, baseRevision: base).selectedTests == [entry])
        #expect(XcodeHeadOnlySelector.select(current: graph, source: source, changes: changes, baseRevision: base).selectedTests == [entry])
    }
}

@Test(arguments: ["function", "closure", "nestedClosure", "nestedGetterClosure", "nestedSetterClosure", "nestedBindingClosure",
                  "attributedSetter", "extensionWitness", "groupedArgument", "builderExpressionClosure", "callableStep", "constructorStep", "privateConstructorStep", "conditionalReturn", "witness", "explicitGetWitness", "binary", "implicitBinary", "macro"])
func implicitResultBuilderLocationsSelectTheirTest(form: String) throws {
    let repo = try SourceRepository()
    defer { try? FileManager.default.removeItem(at: repo.root) }
    let path = "Helpers.swift", key = "UI:" + path
    var support = """
        @resultBuilder enum LineBuilder {
            @_transparent static func buildExpression(_ value: Int, line: Int = #line) -> Int { line }
            @_transparent static func buildBlock(_ value: Int) -> Int { value }
        }
        func evaluate(@LineBuilder _ body: () -> Int) -> Int { body() }
        protocol Reading { @LineBuilder var value: Int { get } }
        """
    let library = FileManager.default.temporaryDirectory.appendingPathComponent("builder-kit-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: library) }
    var compilerArguments: [String] = [], linkArguments: [String] = []
    let helperSource: String
    switch form {
    case "macro":
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        let plugin = try macroPlugin(expansion: "@_transparent static func buildExpression(_ value: Int, line: Int = #line) -> Int { line }", root: library)
        compilerArguments = ["-load-plugin-executable", plugin]
        support = """
            @attached(member, names: named(buildExpression))
            macro addBuilderStep() = #externalMacro(module: "ReviewMacros", type: "MakeBindings")
            @resultBuilder @addBuilderStep enum LineBuilder {
                @_transparent static func buildBlock(_ value: Int) -> Int { value }
            }
            """
        helperSource = "@LineBuilder func caller() -> Int {\n    1\n}"
    case "binary", "implicitBinary":
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        let source = library.appendingPathComponent("Builder.swift")
        try support.replacingOccurrences(of: "enum LineBuilder", with: "public enum LineBuilder")
            .replacingOccurrences(of: "static func", with: "public static func")
            .write(to: source, atomically: true, encoding: .utf8)
        _ = try CommandRunner.run("xcrun", ["swiftc", "-parse-as-library", "-emit-module", "-emit-library",
            "-static", "-module-name", "BuilderKit", "Builder.swift"], at: library)
        compilerArguments = ["-I", library.path]
        linkArguments = [library.appendingPathComponent("libBuilderKit.a").path]
        support = ""
        let imported: String
        if form == "implicitBinary" {
            compilerArguments += ["-Xfrontend", "-import-module", "-Xfrontend", "BuilderKit"]
            imported = ""
        } else {
            imported = "import BuilderKit\n"
        }
        helperSource = imported + "@LineBuilder func caller() -> Int {\n    1\n}"
    case "constructorStep", "privateConstructorStep":
        // The String overload enables buildExpression. For integer literals,
        // Swift resolves the same name to an initializer through the type alias.
        let access = form == "privateConstructorStep" ? "private " : ""
        support = """
        \(access)struct Step {
            let line: Int
            init(_ value: Int, line: Int = #line) { self.line = line }
        }
        \(access)protocol Expressions {}
        extension Expressions { static func buildExpression(_ text: String) -> Step { Step(0) } }
        @resultBuilder \(access)enum LineBuilder: Expressions {
            typealias buildExpression = Step
            static func buildBlock(_ step: Step) -> Int { step.line }
        }
        """
        let caller = "@LineBuilder func caller() -> Int {\n    1\n}"
        if form == "privateConstructorStep" {
            helperSource = support + "\n" + caller
            support = ""
        } else {
            helperSource = caller
        }
    case "callableStep":
        support = """
        struct Step { @_transparent func callAsFunction(_ value: Int, line: Int = #line) -> Int { line } }
        @resultBuilder enum LineBuilder {
            static let buildExpression = Step()
            static func buildExpression(_ text: String) -> Int { 0 }
            static func buildBlock(_ value: Int) -> Int { value }
        }
        """
        helperSource = "@LineBuilder func caller() -> Int {\n    1\n}"
    case "conditionalReturn":
        helperSource = "@LineBuilder func caller() -> Int {\n#if NEVER_DEFINED\nreturn 0\n#endif\n    1\n}"
    case "nestedClosure":
        helperSource = "struct Plain { func value() -> Int { return evaluate {\n    1\n} } }\nfunc caller() -> Int { Plain().value() }"
    case "nestedGetterClosure":
        helperSource = "struct Plain { var value: Int { get { return evaluate {\n    1\n} } } }\nfunc caller() -> Int { Plain().value }"
    case "groupedArgument":
        helperSource = "func caller() -> Int { evaluate(({\n    1\n})) }"
    case "builderExpressionClosure":
        support += "\n@resultBuilder enum Outer { static func buildExpression(@LineBuilder _ f: () -> Int) -> Int { f() }; static func buildBlock(_ x: Int) -> Int { x } }"
        helperSource = "@Outer func caller() -> Int {\n    {\n    1\n    }\n}"
    case "nestedSetterClosure":
        helperSource = "struct Plain { var storage = 0; var value: Int { get { storage } set { storage = evaluate {\n    1\n} } } }\nfunc caller() -> Int { var p = Plain(); p.value = 2; return p.value }"
    case "nestedBindingClosure":
        helperSource = "func caller() -> Int { let f: () -> Int = { evaluate {\n    1\n} }; return f() }"
    case "attributedSetter":
        support += "\n@resultBuilder enum SetterBuilder { static func buildExpression(_ x: Int, line: Int = #line) -> Int { line }; static func buildBlock(_ x: Int) { saved = x } }; var saved = 0"
        helperSource = "struct Plain { var value: Int { get { saved } @SetterBuilder set {\n    1\n} } }\nfunc caller() -> Int { var p = Plain(); p.value = 2; return p.value }"
    case "extensionWitness":
        helperSource = "private struct Reader { var value: Int {\n    1\n} }\nextension Reader: Reading {}\nfunc caller() -> Int { Reader().value }"
    case "explicitGetWitness":
        helperSource = "struct Reader: Reading { var value: Int { get {\n    1\n} } }\nfunc caller() -> Int { Reader().value }"
    case "function": helperSource = "@LineBuilder func caller() -> Int {\n    1\n}"
    case "closure": helperSource = "func caller() -> Int { evaluate {\n    1\n} }"
    default: helperSource = "struct Reader: Reading { var value: Int {\n    1\n} }\nfunc caller() -> Int { Reader().value }"
    }
    // Move only the builder expression. Callers and enclosing source bounds stay fixed.
    let before = helperSource.replacingOccurrences(of: "    1\n", with: "    1\n\n")
    let after = helperSource.replacingOccurrences(of: "    1\n", with: "\n    1\n")
    let entry = "UI/Suite/observes()", control = "UI/Control/unrelated()"
    let expected = try #require(before.components(separatedBy: "\n").firstIndex(of: "    1")) + 1
    let tests = "import Testing\nstruct Suite { @Test func observes() { #expect(caller() == \(expected)) } }\nstruct Control { @Test func unrelated() {} }"
    try repo.write("Support.swift", support)
    try repo.write("Tests.swift", tests)
    try repo.write(path, before)
    let base = try repo.commit()
    try repo.write(path, after)
    let head = try repo.commit()
    let compiler = try CommandRunner.run("xcrun", ["--find", "swiftc"], at: repo.root).text.trimmingCharacters(in: .whitespacesAndNewlines)
    let plugins = URL(fileURLWithPath: compiler).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("lib/swift/host/plugins/testing")
    func capture(_ text: String) throws -> XcodeTestGraph {
        var graph = try boundaryGraph([path: text, "Support.swift": support, "Tests.swift": tests], tests: [entry, control],
            root: repo.root, compilerArguments: ["-plugin-path", plugins.path] + compilerArguments, compiler: compiler, linkArguments: linkArguments)
        graph.mappings = nil
        return graph
    }
    let old = try capture(before), current = try capture(after)
    let changes = try GitChanges.readComparison(base: base, head: head, at: repo.root)
    func reports(_ baseGraph: XcodeTestGraph, _ headGraph: XcodeTestGraph) throws -> [ImpactReport] {
        let source = try XcodeHeadOnlySources.read(current: headGraph, changes: changes, base: base, root: repo.root, mappingPath: "mapping.json")
        return [XcodeFineSelector.select(current: headGraph, previous: baseGraph, changes: changes, baseRevision: base),
                XcodeHeadOnlySelector.select(current: headGraph, source: source, changes: changes, baseRevision: base)]
    }
    for report in try reports(old, current) {
        #expect(report.selectedTests.contains(entry))
        #expect(!report.ignoredChanges.contains(path))
    }
    if form == "implicitBinary" {
        var savedBase = old, savedHead = current
        savedBase.dependencies?.compilerImplicitImports = nil
        savedHead.dependencies?.compilerImplicitImports = nil
        for report in try reports(savedBase, savedHead) {
            #expect(report.selectedTests.contains(entry))
            #expect(!report.ignoredChanges.contains(path))
        }
    }
    var diagnostic = current, previousDiagnostic = old
    diagnostic.mappings = UIFeatureMappings(features: [])
    diagnostic.mappings?.sourceLocationPolicy = .diagnosticLineColumn
    previousDiagnostic.mappings = diagnostic.mappings
    let diagnosticSource = XcodeHeadOnlySources(base: old.sources, mappings: diagnostic.mappings)
    #expect(XcodeFineSelector.select(current: diagnostic, previous: previousDiagnostic, changes: changes, baseRevision: base).selectedTests.isEmpty)
    #expect(XcodeHeadOnlySelector.select(current: diagnostic, source: diagnosticSource, changes: changes, baseRevision: base).selectedTests.isEmpty)

    var legacy = current
    for i in legacy.sources[key]!.units.indices { legacy.sources[key]!.units[i].builderLocations = nil }
    for version in [SwiftSourceSnapshot.currentParserVersion, 30, 29] {
        legacy.sources[key]?.parserVersion = version
        for report in try reports(old, legacy) {
            #expect(report.selectedTests.contains(entry))
            #expect(report.diagnostics.contains { $0.code == "incomplete_caller_locations" })
        }
    }
    try legacy.refreshLegacyComparisonSyntax(paths: [path], revision: head, root: repo.root)
    for report in try reports(old, legacy) {
        #expect(report.selectedTests.contains(entry))
        #expect(!report.diagnostics.contains { $0.code == "incomplete_caller_locations" })
    }
    if form == "closure" {
        // Another changed file removes the builder's only location default at
        // head. A scope containing only the caller still needs base evidence.
        support = support.replacingOccurrences(of: "line: Int = #line", with: "line: Int = 0")
        try repo.write("Support.swift", support)
        let next = try repo.commit()
        let graph = try capture(after)
        let scoped = try XcodeHeadOnlySelector.scopedReports(current: graph, requests: .init(scopes: [.init(name: "caller", paths: [path])]),
            changes: GitChanges.readComparison(base: base, head: next, at: repo.root), baseRevision: base, headRevision: next,
            root: repo.root, mappingPath: "mapping.json", documentation: [], buildEvidenceFailure: nil)
        #expect(scoped.first?.report.selectedTests.contains(entry) == true)
    }
}

@Test func versionedPackageManifestsAreTrackedAsBuildInputs() throws {
    let repo = try SourceRepository()
    defer { try? FileManager.default.removeItem(at: repo.root) }
    try FileManager.default.createDirectory(at: repo.root.appendingPathComponent("Nested"), withIntermediateDirectories: true)
    let manifests: Set<String> = ["Package.swift", "Nested/Package.swift", "Nested/Package@swift-6.0.swift"]
    let implementations = ["Nested/PackageTools.swift", "Notes.swift"]
    let paths = manifests.union(implementations)
    for path in paths { try repo.write(path, "// base") }
    let base = try repo.commit()
    for path in paths { try repo.write(path, "// head") }
    let head = try repo.commit()
    let evidence = try HeadOnlyRuntimeSourceEvidence.read(head: head, root: repo.root, cache: XcodeBaseSourceCache(root: repo.root, base: base))
    #expect(evidence.buildInputPaths == manifests)
    let inputs = try XcodeBuildEvidence.repositoryInputFiles(root: repo.root, derived: repo.root.appendingPathComponent("DerivedData"))
    #expect(Set(inputs.keys) == manifests)
}

@Test(arguments: ["@Test", "@`Test`", "@Testing /* module */ .Test"])
func equivalentTestSpellingsSelectTheEditedBody(attribute: String) throws {
    let repo = try SourceRepository()
    defer { try? FileManager.default.removeItem(at: repo.root) }
    let path = "Cases.swift", key = "UI:" + path
    let entry = "UI/Suite/observes()", control = "UI/Control/unrelated()"
    let before = "import Testing\nstruct Suite { \(attribute) func observes() { let _ = false } }\nstruct Control { @Test func unrelated() {} }"
    let after = before.replacingOccurrences(of: "false", with: "true")
    try repo.write(path, after)
    let head = try repo.commit()
    let compiler = try CommandRunner.run("xcrun", ["--find", "swiftc"], at: repo.root).text.trimmingCharacters(in: .whitespacesAndNewlines)
    let plugins = URL(fileURLWithPath: compiler).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("lib/swift/host/plugins/testing")
    let fresh = try boundaryGraph([path: after], tests: [entry, control], root: repo.root, compilerArguments: ["-plugin-path", plugins.path], compiler: compiler)
    func selected(_ graph: XcodeTestGraph) -> [String] {
        XcodeHeadOnlySelector.select(current: graph, source: .init(base: [key: .parse(before, path: path, module: "UI")]),
                                     changes: [.init(path: path)], baseRevision: "base").selectedTests
    }
    #expect(selected(fresh) == [entry])
    if attribute != "@Test" {
        var legacy = fresh
        var file = try #require(legacy.sources[key])
        let index = try #require(file.units.firstIndex { $0.helperCallableName == "observes" })
        file.parserVersion = 27
        file.units[index].swiftTestingBodyCandidate = nil
        file.units[index].swiftTestingRegistrationDeclaration = nil
        legacy.sources[key] = file
        legacy = try GraphArchive.decode(GraphArchive.encode(legacy))
        #expect(Set(selected(legacy)) == [control, entry])
        try legacy.refreshLegacyComparisonSyntax(paths: [path], revision: head, root: repo.root)
        #expect(selected(legacy) == [entry])
    }
}

@Test(arguments: ["current", "legacy-parser", "missing-head", "archive-substitution"])
func headSyntaxReuseAuthenticatesFullGitDiffAndParser(scenario: String) throws {
    let repo = try SourceRepository()
    defer { try? FileManager.default.removeItem(at: repo.root) }
    let helper = "import XCTest\nextension XCUIElement { func waiting() -> Bool { exists } }"
    let caller = "import XCTest\nfunc call(_ element: XCUIElement) { _ = element.waiting() }\nfunc commit() -> String { \"$Format:%H$\" }"
    let old = ["Helper.swift": helper, "Caller.swift": caller, "Changed.swift": caller]
    for (path, text) in old { try repo.write(path, text) }
    if scenario == "archive-substitution" { try repo.write(".gitattributes", "Caller.swift export-subst\n") }
    let base = try repo.commit()
    var headFiles = old
    headFiles["Helper.swift"] = helper.replacingOccurrences(of: "exists", with: "isHittable")
    headFiles["Changed.swift"] = "func call() {}"
    for (path, text) in headFiles { try repo.write(path, text) }
    // A non-Swift edit forbids runtime isolation, but does not change the
    // source-only parse of an independently authenticated identical file.
    try repo.write("Config.xcconfig", "changed settings")
    let head = try repo.commit()
    if scenario == "archive-substitution" {
        let exported = repo.root.appendingPathComponent("exported")
        try GitChanges.export(base: head, from: repo.root, into: exported)
        headFiles["Caller.swift"] = try String(contentsOf: exported.appendingPathComponent("Caller.swift"), encoding: .utf8)
        #expect(headFiles["Caller.swift"]?.contains(head) == true)
        #expect(headFiles["Caller.swift"] != old["Caller.swift"])
    }
    var current = XcodeTestGraph(targets: [], tests: [])
    current.sources = Dictionary(uniqueKeysWithValues: headFiles.map { path, text in
        ("UI:" + path, SwiftSourceSnapshot.parse(text, path: path, module: "UI"))
    })
    if scenario == "legacy-parser" { current.sources["UI:Caller.swift"]?.parserVersion = nil }
    current.buildArtifact = .init(revision: scenario == "missing-head" ? "missing" : head, context: [:], toolchain: "fixture", buildLogDigest: "log", buildSettingsDigest: "settings", productsDirectory: repo.root.path, xctestrun: "fixture", products: [:])
    let cache = try XcodeBaseSourceCache(root: repo.root, base: base)
    let changes = [FileChange(path: "Helper.swift")]
    let result = try XcodeHeadOnlySources.read(current: current, changes: changes, base: base, root: repo.root, mappingPath: "mapping.json", cache: cache)
    let reference = try uncachedHeadOnlySources(current: current, changes: changes, base: base, root: repo.root, mappingPath: "mapping.json")
    #expect(cache.counts.headSyntaxReuse == (scenario == "current" ? 1 : 0))
    #expect(cache.counts.parses == (scenario == "current" ? 2 : 3))
    for key in result.base.keys {
        #expect(result.base[key]?.units.map(\.fingerprint) == reference.base[key]?.units.map(\.fingerprint))
    }
    #expect(result.base["UI:Changed.swift"]?.units.map(\.fingerprint) != current.sources["UI:Changed.swift"]?.units.map(\.fingerprint))
}

@Test func baseSourceCachePinsRevisionModuleAndLogicalPath() throws {
    let repo = try SourceRepository()
    defer { try? FileManager.default.removeItem(at: repo.root) }
    let text = "func location() -> String { #fileID }"
    try repo.write("One.swift", text); try repo.write("Two.swift", text); try repo.write("Late.swift", text)
    let base = try repo.commit()
    let cache = try XcodeBaseSourceCache(root: repo.root, base: "HEAD")
    let one = try #require(try cache.snapshot(path: "One.swift", module: "One"))
    let two = try #require(try cache.snapshot(path: "One.swift", module: "Two"))
    let moved = try #require(try cache.snapshot(path: "Two.swift", module: "One"))
    let unowned = try #require(try cache.snapshot(path: "One.swift", module: ""))
    #expect(one.units.map(\.key) != two.units.map(\.key))
    #expect(one.units.map(\.region.path) != moved.units.map(\.region.path))
    #expect(one.units.map(\.key) != unowned.units.map(\.key))
    #expect(cache.counts.blobReads == 2)
    #expect(cache.counts.parses == 4)
    try repo.write("One.swift", "struct Changed {}")
    try repo.write("Late.swift", "struct Changed {}")
    let head = try repo.commit()
    // Even a not-yet-read path is pinned to the initial commit.
    #expect(try cache.snapshot(path: "Late.swift", module: "One")?.units.map(\.fingerprint) == SwiftSourceSnapshot.parse(text, path: "Late.swift", module: "One").units.map(\.fingerprint))
    _ = try cache.snapshot(path: "One.swift", module: "One")
    #expect(cache.counts.parseHits == 1)
    let fresh = try XcodeBaseSourceCache(root: repo.root, base: "HEAD")
    #expect(try fresh.snapshot(path: "One.swift", module: "One")?.units.map(\.fingerprint) != one.units.map(\.fingerprint))
    #expect(throws: (any Error).self) { try cache.validate(root: repo.root, base: head) }
    #expect(throws: (any Error).self) { try cache.validate(root: repo.root.appendingPathComponent("other"), base: "HEAD") }
    // A stacked branch's merge base, not its newer base tip, owns the cache.
    _ = try repo.git(["checkout", "-qb", "stack", base])
    try repo.write("Stack.swift", "struct Stack {}")
    let stack = try repo.commit()
    let comparison = try RevisionComparison(base: head, head: stack, mergeBase: true, root: repo.root)
    #expect(comparison.base == base)
    let merged = try XcodeBaseSourceCache(root: repo.root, base: comparison.base)
    #expect(try merged.snapshot(path: "One.swift", module: "One")?.units.map(\.fingerprint) == one.units.map(\.fingerprint))
}

@Test(arguments: ["valid", "invalid-mapping", "missing-source", "invalid-utf8", "unowned-read-failure", "missing-revision"])
func baseSourceCachePreservesIndependentEvidence(scenario: String) throws {
    let repo = try SourceRepository()
    defer { try? FileManager.default.removeItem(at: repo.root) }
    let helper = "import XCTest\nextension XCUIElement { func waiting() -> Bool { exists } }"
    let caller = "import XCTest\nfunc oldCaller(_ element: XCUIElement) { _ = element.waiting() }"
    let files = ["Helper.swift": helper, "Caller.swift": caller, "Unowned.swift": caller,
                 "Deleted.swift": "struct Deleted {}", "Old.swift": "func moved() -> String { #fileID }"]
    for (path, text) in files { try repo.write(path, text) }
    if scenario == "invalid-utf8" { try Data([0xff]).write(to: repo.root.appendingPathComponent("Caller.swift")) }
    if scenario == "unowned-read-failure" { try Data([0xff]).write(to: repo.root.appendingPathComponent("Unowned.swift")) }
    if scenario == "missing-source" { try FileManager.default.removeItem(at: repo.root.appendingPathComponent("Caller.swift")) }
    try repo.write("mapping.json", scenario == "invalid-mapping" ? "{" : "{\"version\":1,\"features\":[]}")
    let revision = try repo.commit()
    let base = scenario == "missing-revision" ? "unavailable" : revision
    var current = XcodeTestGraph(targets: [.init(name: "UI", productType: "com.apple.product-type.bundle.ui-testing", sourceFiles: ["Helper.swift", "Caller.swift", "Added.swift", "New.swift"])], tests: ["UI/Tests/testOne()"])
    current.mappings = UIFeatureMappings(features: [.init(name: "changed", sources: ["Helper.swift"], tests: current.tests)])
    current.sources = [
        "UI:Helper.swift": .parse(helper.replacingOccurrences(of: "exists", with: "isHittable"), path: "Helper.swift", module: "UI"),
        "UI:Caller.swift": .parse("func oldCaller() {}", path: "Caller.swift", module: "UI"),
        "Other:Caller.swift": .parse("func oldCaller() {}", path: "Caller.swift", module: "Other"),
        "UI:Added.swift": .parse("struct Added {}", path: "Added.swift", module: "UI"),
        "UI:New.swift": .parse(files["Old.swift"]!, path: "New.swift", module: "UI")
    ]
    #expect(current.sources["UI:Helper.swift"]!.units.contains { $0.sdkTestHelper != nil })
    var move = FileChange(path: "New.swift"); move.previousPath = "Old.swift"; move.isPureMove = true
    let all = [FileChange(path: "Helper.swift"), .init(path: "Caller.swift"), .init(path: "Added.swift"), .init(path: "Deleted.swift"), .init(path: "mapping.json"), move]
    let cache = try XcodeBaseSourceCache(root: repo.root, base: base)
    let queries: [[FileChange]] = [all, [.init(path: "Helper.swift")], [], [.init(path: "Helper.swift"), move], [.init(path: "mapping.json")]]
    var initial: XcodeBaseSourceCache.Counts?
    for changes in queries {
        let cached = try XcodeHeadOnlySources.read(current: current, changes: changes, base: base, root: repo.root, mappingPath: "mapping.json", cache: cache)
        let original = try uncachedHeadOnlySources(current: current, changes: changes, base: base, root: repo.root, mappingPath: "mapping.json")
        #expect(cached.diagnostics == original.diagnostics)
        #expect(Set(cached.base.keys) == Set(original.base.keys))
        #expect(Set(cached.unownedBaseSources.keys) == Set(original.unownedBaseSources.keys))
        for key in cached.base.keys {
            #expect(cached.base[key]?.units.map(\.fingerprint) == original.base[key]?.units.map(\.fingerprint))
        }
        let report = XcodeHeadOnlySelector.select(current: current, source: cached, changes: changes, baseRevision: base)
        let reference = XcodeHeadOnlySelector.select(current: current, source: original, changes: changes, baseRevision: base)
        #expect(report.selectedTests == reference.selectedTests)
        #expect(try diagnosticJSON(report) == diagnosticJSON(reference))
        if let initial {
            #expect(cache.counts.blobReads == initial.blobReads)
            #expect(cache.counts.parses == initial.parses)
            #expect(cache.counts.treeReads == initial.treeReads)
        } else { initial = cache.counts }
        if changes.count == 1 && changes[0].path == "Helper.swift" && scenario == "valid" {
            #expect(cached.diagnostics.isEmpty)
            #expect(cached.base["UI:Added.swift"] == nil)
            #expect(cached.unownedBaseSources["Unowned.swift"] != nil)
            #expect(cached.base["UI:Caller.swift"]?.units.map(\.fingerprint) != current.sources["UI:Caller.swift"]?.units.map(\.fingerprint))
        }
    }
}

@Test func removedFunctionAuditsHistoricalCallersOutsideTheRequestedScope() throws {
    let repo = try SourceRepository()
    defer { try? FileManager.default.removeItem(at: repo.root) }
    try repo.write("Helper.swift", "func removed() {}")
    try repo.write("Caller.swift", "func caller() { removed() }")
    let base = try repo.commit()
    var current = XcodeTestGraph(targets: [], tests: [])
    current.sources = [
        "UI:Helper.swift": .parse("", path: "Helper.swift", module: "UI"),
        "UI:Caller.swift": .parse("func caller() {}", path: "Caller.swift", module: "UI")
    ]
    let source = try XcodeHeadOnlySources.read(current: current, changes: [.init(path: "Helper.swift")],
        base: base, root: repo.root, mappingPath: ".swift-test-selection.json")
    let oldCaller = try #require(source.base["UI:Caller.swift"])
    #expect(oldCaller.identifierNames?.contains("removed") == true)
}

@Test(arguments: [1, 2])
func ambiguousFunctionsUseBaseCallersOutsideTheScope(headAlternatives: Int) throws {
    let repo = try SourceRepository()
    defer { try? FileManager.default.removeItem(at: repo.root) }
    let before = "#if DEBUG\nfunc helper() { print(1) }\n#else\nfunc helper() { print(2) }\n#endif"
    let after = headAlternatives == 1 ? "func helper() { print(1) }" : before.replacingOccurrences(of: "print(2)", with: "print(3)")
    try repo.write("Helper.swift", before)
    try repo.write("Caller.swift", "func original() { helper() }\nfunc added() {}")
    let base = try repo.commit()
    var current = XcodeTestGraph(targets: [], tests: [])
    current.sources = [
        "UI:Helper.swift": .parse(after, path: "Helper.swift", module: "UI"),
        "UI:Caller.swift": .parse("func original() {}\nfunc added() { helper() }", path: "Caller.swift", module: "UI")
    ]
    let changes = [FileChange(path: "Helper.swift")]
    let source = try XcodeHeadOnlySources.read(current: current, changes: changes, base: base, root: repo.root, mappingPath: "mapping.json")
    let report = XcodeHeadOnlySelector.select(current: current, source: source, changes: changes, baseRevision: base)
    let ambiguous = try #require(report.headOnlyDeclarationChanges?.first { $0.change == "ambiguous" && $0.key.contains("helper") })
    let lines = ambiguous.historicalReferences.filter { $0.sourceKey == "UI:Caller.swift" }.flatMap(\.callerLines)
    #expect(Set(lines) == [1])
}

@Test func unchangedConditionalAlternativesKeepBaseReadsScoped() throws {
    let repo = try SourceRepository()
    defer { try? FileManager.default.removeItem(at: repo.root) }
    let before = "#if DEBUG\nfunc helper() { print(1) }\n#else\nfunc helper() { print(2) }\n#endif\nfunc touched() {}"
    try repo.write("Conditional.swift", before)
    try repo.write("Unowned.swift", "func unrelated() {}")
    let base = try repo.commit()
    var current = XcodeTestGraph(targets: [], tests: [])
    let after = before.replacingOccurrences(of: "touched() {}", with: "touched() { print(3) }")
    current.sources["UI:Conditional.swift"] = .parse(after, path: "Conditional.swift", module: "UI")
    let changes = [FileChange(path: "Conditional.swift")]
    let cache = try XcodeBaseSourceCache(root: repo.root, base: base)
    let source = try XcodeHeadOnlySources.read(current: current, changes: changes, base: base, root: repo.root, mappingPath: "mapping.json", cache: cache)
    #expect(cache.counts.parses == 1)
    #expect(cache.counts.treeReads == 0)
    let report = XcodeHeadOnlySelector.select(current: current, source: source, changes: changes, baseRevision: base)
    #expect(report.headOnlyDeclarationChanges?.isEmpty ?? true)
}

@Test func exchangingConditionalBodiesSelectsTheirCompiledCaller() throws {
    let repo = try SourceRepository()
    defer { try? FileManager.default.removeItem(at: repo.root) }
    func feature(first: Int, second: Int) -> String {
        """
        #if DEBUG
        #if ALTERNATE
        func reading() -> Int { 0 }
        #elseif TEST
        func reading() -> Int { \(first) }
        #else
        func reading() -> Int { \(second) }
        #endif
        #endif
        """
    }
    let caller = "import XCTest\nfinal class Cases: XCTestCase {\n    func testReading() { XCTAssertEqual(reading(), 1) }\n}"
    try repo.write("Feature.swift", feature(first: 1, second: 2))
    try repo.write("Tests.swift", caller)
    let base = try repo.commit()
    let entry = "UI/Cases/testReading()"
    let current = try boundaryGraph(["Feature.swift": feature(first: 2, second: 1), "Tests.swift": caller],
        tests: [entry], root: repo.root, compilerArguments: ["-D", "DEBUG", "-D", "TEST"])
    let changes = [FileChange(path: "Feature.swift")]
    let cache = try XcodeBaseSourceCache(root: repo.root, base: base)
    let source = try XcodeHeadOnlySources.read(current: current, changes: changes, base: base,
        root: repo.root, mappingPath: "mapping.json", cache: cache)
    #expect(cache.counts.treeReads == 1)
    let report = XcodeHeadOnlySelector.select(current: current, source: source, changes: changes, baseRevision: base)
    #expect(report.selectedTests == [entry])
    #expect(report.headOnlyDeclarationChanges?.contains { $0.change == "ambiguous" && $0.key.contains("reading") } == true)
}

@Test func legacyConditionalSnapshotsSelectWhenAnOverloadBecomesInactive() throws {
    let repo = try SourceRepository()
    defer { try? FileManager.default.removeItem(at: repo.root) }
    let overload = "func choose(_ value: Int) -> Int { 1 }"
    let generic = "func choose<T>(_ value: T) -> Int { 2 }"
    let before = "#if OPTIONAL\n#endif\n" + overload + "\n" + generic
    let after = "#if OPTIONAL\n" + overload + "\n#endif\n" + generic
    let caller = "import XCTest\nfinal class Cases: XCTestCase { func testValue() { XCTAssertEqual(choose(0), 1) } }"
    try repo.write("Feature.swift", before)
    try repo.write("Tests.swift", caller)
    let base = try repo.commit()
    let entry = "UI/Cases/testValue()"
    let previous = try boundaryGraph(["Feature.swift": before, "Tests.swift": caller], tests: [entry], root: repo.root)
    var current = try boundaryGraph(["Feature.swift": after, "Tests.swift": caller], tests: [entry], root: repo.root)
    var legacy = try #require(current.sources["UI:Feature.swift"])
    legacy.parserVersion = 4
    for index in legacy.units.indices { legacy.units[index].conditionalBranch = nil }
    current.sources["UI:Feature.swift"] = legacy
    let changes = [FileChange(path: "Feature.swift")]
    let source = try XcodeHeadOnlySources.read(current: current, changes: changes, base: base, root: repo.root, mappingPath: "mapping.json")
    let head = XcodeHeadOnlySelector.select(current: current, source: source, changes: changes, baseRevision: base)
    #expect(head.selectedTests == [entry])
    #expect(head.diagnostics.contains { $0.code == "head_only_conditional_metadata" })
    let dual = XcodeFineSelector.select(current: current, previous: previous, changes: changes, baseRevision: base)
    #expect(dual.selectedTests == [entry])
    #expect(dual.diagnostics.contains { $0.code == "incomplete_conditional_metadata" })
}

@Test func exchangedFilePrivateBodiesSelectOnlyTheirCompiledCallers() throws {
    let repo = try SourceRepository()
    defer { try? FileManager.default.removeItem(at: repo.root) }
    let entries = ["UI/Cases/testFirst()", "UI/Cases/testSecond()", "UI/Cases/testThird()"]
    func capture(_ values: [Int]) throws -> XcodeTestGraph {
        var files = ["Tests.swift": """
            import XCTest
            final class Cases: XCTestCase {
                func testFirst() { XCTAssertEqual(fromFirst(), 1) }
                func testSecond() { XCTAssertEqual(fromSecond(), 2) }
                func testThird() { XCTAssertEqual(fromThird(), 3) }
            }
            """]
        for (name, value) in zip(["First", "Second", "Third"], values) {
            files[name + ".swift"] = "#if DEBUG\nprivate func reading() -> Int { \(value) }\n#else\nprivate func reading() -> Int { 91 }\n#endif\nfunc from\(name)() -> Int { reading() }"
        }
        var graph = try boundaryGraph(files, tests: entries, root: repo.root, compilerArguments: ["-D", "DEBUG"])
        graph.targets = [.init(name: "UI", productType: "com.apple.product-type.bundle.unit-test", sourceFiles: Set(files.keys))]
        return graph
    }
    let previous = try capture([1, 2, 3])
    let current = try capture([2, 1, 3])
    let result = XcodeFineSelector.select(current: current, previous: previous,
        changes: [.init(path: "First.swift"), .init(path: "Second.swift")], baseRevision: "base")
    #expect(result.selectedTests == Array(entries.prefix(2)))
    #expect(result.diagnostics.isEmpty)
}

@Test func renamingAFileWithOnlyDuplicatedDeclarationKeysIgnoresTrivia() throws {
    let repo = try SourceRepository()
    defer { try? FileManager.default.removeItem(at: repo.root) }
    let entries = ["UI/Cases/testFirst()", "UI/Cases/testSecond()"]
    let first = "#if DEBUG\nfunc result() -> Int { 1 }\n#else\nprivate func shadow() {}\n#endif"
    func capture(path: String, source: String) throws -> XcodeTestGraph {
        let files = [
            path: source,
            "Second.swift": "#if DEBUG\nprivate func shadow() {}\n#else\nfunc result() -> Int { 2 }\n#endif",
            "Tests.swift": """
            import XCTest
            final class Cases: XCTestCase {
                func testFirst() { XCTAssertEqual(result(), 1) }
                func testSecond() { XCTAssertTrue(true) }
            }
            """
        ]
        var graph = try boundaryGraph(files, tests: entries, root: repo.root, compilerArguments: ["-D", "DEBUG"])
        graph.targets = [.init(name: "UI", productType: "com.apple.product-type.bundle.unit-test", sourceFiles: Set(files.keys))]
        return graph
    }
    let base = try capture(path: "First.swift", source: first)
    let head = try capture(path: "Renamed.swift", source: "// moved\n" + first)
    var rename = FileChange(path: "Renamed.swift")
    rename.previousPath = "First.swift"
    for changes in [[rename], [FileChange(path: "First.swift"), FileChange(path: "Renamed.swift")]] {
        let report = XcodeFineSelector.select(current: head, previous: base, changes: changes, baseRevision: "base")
        #expect(report.selectedTests.isEmpty)
        #expect(report.diagnostics.isEmpty)
    }
}

@Test func movingAFunctionBetweenFilesSelectsItsFilePrivateValueConsumer() throws {
    let repo = try SourceRepository()
    defer { try? FileManager.default.removeItem(at: repo.root) }
    let entries = ["UI/Cases/testReading()", "UI/Cases/testOther()"]
    func capture(implementationIn first: Bool) throws -> XcodeTestGraph {
        let function = "\nfunc reading() -> Int { value }"
        let files = [
            "First.swift": "private let value = 1" + (first ? function : ""),
            "Second.swift": "private let value = 2" + (first ? "" : function),
            "Tests.swift": """
            import XCTest
            final class Cases: XCTestCase {
                func testReading() { XCTAssertEqual(reading(), 1) }
                func testOther() { XCTAssertTrue(true) }
            }
            """
        ]
        var graph = try boundaryGraph(files, tests: entries, root: repo.root)
        graph.targets = [.init(name: "UI", productType: "com.apple.product-type.bundle.unit-test", sourceFiles: Set(files.keys))]
        return graph
    }
    let base = try capture(implementationIn: true)
    let head = try capture(implementationIn: false)
    let report = XcodeFineSelector.select(current: head, previous: base,
        changes: [.init(path: "First.swift"), .init(path: "Second.swift")], baseRevision: "base")
    #expect(report.selectedTests == [entries[0]])
    #expect(report.explanations.contains { $0.test == entries[0] && $0.kind == "dependency" })
}

@Test func reorderingConditionalEnumCasesSelectsRawValueConsumers() throws {
    let repo = try SourceRepository()
    defer { try? FileManager.default.removeItem(at: repo.root) }
    let entries = ["UI/Cases/testEncodedValue()", "UI/Cases/testRawValue()"]
    let caller = """
    import XCTest
    final class Cases: XCTestCase {
        func testRawValue() { XCTAssertEqual(Mode.enabled.rawValue, 0) }
        func testEncodedValue() throws { XCTAssertEqual(try encodeEnabled(), "0") }
    }
    """
    let conditional = "#if DEBUG\ncase enabled\n#endif"
    let encoder = "\nfunc encodeEnabled() throws -> String { String(decoding: try JSONEncoder().encode(Mode.enabled), as: UTF8.self) }"
    let before = "import Foundation\nenum Mode: Int, Codable {\n" + conditional + "\ncase disabled\n}" + encoder
    let after = "import Foundation\nenum Mode: Int, Codable {\ncase disabled\n" + conditional + "\n}" + encoder
    try repo.write("Mode.swift", before)
    try repo.write("Tests.swift", caller)
    let base = try repo.commit()
    func capture(_ text: String) throws -> XcodeTestGraph {
        let files = ["Mode.swift": text, "Tests.swift": caller]
        var graph = try boundaryGraph(files, tests: entries, root: repo.root, compilerArguments: ["-D", "DEBUG"])
        graph.targets = [.init(name: "UI", productType: "com.apple.product-type.bundle.unit-test", sourceFiles: Set(files.keys))]
        return graph
    }
    let old = try GraphArchive.decode(GraphArchive.encode(capture(before)))
    let head = try GraphArchive.decode(GraphArchive.encode(capture(after)))
    let changes = [FileChange(path: "Mode.swift")]
    let source = try XcodeHeadOnlySources.read(current: head, changes: changes, base: base, root: repo.root, mappingPath: "mapping.json")
    let reports = [XcodeFineSelector.select(current: head, previous: old, changes: changes, baseRevision: base),
                   XcodeHeadOnlySelector.select(current: head, source: source, changes: changes, baseRevision: base)]
    for report in reports {
        #expect(report.selectedTests == entries)
        #expect(!report.ignoredChanges.contains("Mode.swift"))
    }
}
