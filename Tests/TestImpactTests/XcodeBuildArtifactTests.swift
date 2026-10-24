// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import Testing
@testable import TestImpact

private func artifactTemporary() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("artifact tests \(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url.standardizedFileURL.resolvingSymlinksInPath()
}

@Test func productManifestIsRelativeRelocatableAndDetectsChanges() throws {
    let root = try artifactTemporary()
    defer { try? FileManager.default.removeItem(at: root) }
    let products = root.appendingPathComponent("Products")
    let app = products.appendingPathComponent("Nested/App.app")
    try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
    try Data("binary".utf8).write(to: app.appendingPathComponent("App"))
    try Data("run".utf8).write(to: products.appendingPathComponent("Plan.xctestrun"))
    let before = try ArtifactFiles.manifest(at: products)
    #expect(Set(before.keys) == ["Nested/App.app/App", "Plan.xctestrun"])
    let moved = root.appendingPathComponent("Moved Products")
    try FileManager.default.copyItem(at: products, to: moved)
    #expect(try ArtifactFiles.manifest(at: moved) == before)
    try Data("modified".utf8).write(to: moved.appendingPathComponent("Plan.xctestrun"))
    #expect(try ArtifactFiles.manifest(at: moved) != before)
    try FileManager.default.removeItem(at: moved.appendingPathComponent("Plan.xctestrun"))
    #expect(try ArtifactFiles.manifest(at: moved) != before)
    try Data("run".utf8).write(to: moved.appendingPathComponent("Plan.xctestrun"))
    try Data("extra".utf8).write(to: moved.appendingPathComponent("extra"))
    #expect(try ArtifactFiles.manifest(at: moved) != before)
}

@Test func productManifestPreservesInternalLinksAndRejectsEscapes() throws {
    let root = try artifactTemporary()
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("binary".utf8).write(to: root.appendingPathComponent("binary"))
    try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("alias").path, withDestinationPath: "binary")
    #expect(try ArtifactFiles.manifest(at: root)["alias"] == "symlink:binary")
    try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("escape").path, withDestinationPath: "/etc/hosts")
    #expect(throws: ImpactError.self) { try ArtifactFiles.manifest(at: root) }
}

@Test func capturedExecutionUsesOnlyExistingProductsAndExactIDs() throws {
    let root = try artifactTemporary()
    defer { try? FileManager.default.removeItem(at: root) }
    let config = XcodeConfiguration(container: .project, path: root.appendingPathComponent("App.xcodeproj"), scheme: "App", destination: "platform=iOS Simulator,name=iPhone 17 Pro")
    let analysis = XcodeAnalysis(options: config)
    let args = try analysis.artifactExecutionArguments(tests: ["UI/Class/testOne()"], xctestrun: root.appendingPathComponent("Plan.xctestrun"), resultBundle: root.appendingPathComponent("Results.xcresult"))
    #expect(args.first == "test-without-building")
    #expect(!args.contains("-project") && !args.contains("-scheme") && !args.contains("build-for-testing"))
    #expect(args.last == "-only-testing:UI/Class/testOne()")
    #expect(throws: ImpactError.self) { try analysis.artifactExecutionArguments(tests: ["UI"], xctestrun: root, resultBundle: root) }
    #expect(throws: ImpactError.self) { try analysis.artifactExecutionArguments(tests: [], xctestrun: root, resultBundle: root) }
}

private func capturedGraph(_ text: String, revision: String, context: [String: String]) -> XcodeTestGraph {
    let snapshot = SwiftSourceSnapshot.parse(text, path: "Tests.swift", module: "UI")
    let test = "UI/Suite/testOne()"
    let node = FunctionNode(id: "entry", module: "UI", name: "Suite.testOne()", regions: [snapshot.units.first { $0.kind == "function" }!.region])
    var graph = XcodeTestGraph(targets: [XcodeTarget(name: "UI", productType: "com.apple.product-type.bundle.ui-testing", sourceFiles: ["Tests.swift"])], tests: [test])
    graph.sources = ["Tests.swift": snapshot]
    graph.modules = ["UI": "UI"]
    graph.dependencies = DependencyGraph(functions: ["entry": node], tests: [test: ["entry"]])
    graph.buildArtifact = XcodeBuildArtifact(revision: revision, context: context, toolchain: "toolchain",
        buildLogDigest: "log", buildSettingsDigest: "settings", productsDirectory: "/missing-products",
        xctestrun: "Plan.xctestrun", products: ["Plan.xctestrun": "digest"])
    return graph
}

@Test func cachedSelectionChecksProvenanceAndNeedsNeitherProductsNorCleanWorktree() throws {
    let root = try artifactTemporary()
    defer { try? FileManager.default.removeItem(at: root) }
    @discardableResult func git(_ args: String...) throws -> String {
        try CommandRunner.run("git", args, at: root).text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    try git("init", "-q"); try git("config", "user.name", "Test"); try git("config", "user.email", "test@example.invalid")
    let before = "class Suite: XCTestCase {\n func testOne() { print(1) }\n}"
    let after = before.replacingOccurrences(of: "print(1)", with: "print(2)")
    let file = root.appendingPathComponent("Tests.swift")
    try before.write(to: file, atomically: true, encoding: .utf8)
    try git("add", "."); try git("commit", "-qm", "Base")
    let base = try git("rev-parse", "HEAD")
    try after.write(to: file, atomically: true, encoding: .utf8)
    try git("add", "."); try git("commit", "-qm", "Head")
    let head = try git("rev-parse", "HEAD")
    try "invalid Swift".write(to: file, atomically: true, encoding: .utf8)
    let config = XcodeConfiguration(container: .project, path: root.appendingPathComponent("App.xcodeproj"), scheme: "App", destination: "simulator")
    let analysis = XcodeAnalysis(options: config)
    var context = try analysis.artifactContext(root: root)
    context["sdkAndArchitecture"] = "Debug|sdk|simulator|arm64"
    let old = capturedGraph(before, revision: base, context: context)
    let new = capturedGraph(after, revision: head, context: context)
    let report = try analysis.select(base: base, baseGraph: old, headGraph: new)
    #expect(report.selectedTests == new.tests && report.headRevision == head && report.diagnostics.isEmpty)
    #expect(report.buildArtifactID == new.buildArtifact!.id)
    let empty = try analysis.select(base: head, baseGraph: new, headGraph: new)
    #expect(empty.selectedTests.isEmpty)
    #expect(try analysis.run(empty, using: new) == 0)
    #expect(try analysis.select(base: head, fullSuite: true, baseGraph: new, headGraph: new).selectedTests == new.tests)
    #expect(throws: ImpactError.self) { try analysis.select(base: head, baseGraph: old, headGraph: new) }
    for variation in ["legacy", "schema", "toolchain", "runtimes", "scheme", "sdk", "revision"] {
        var bad = new
        switch variation {
        case "legacy": bad.buildArtifact = nil
        case "schema": bad.buildArtifact!.schemaVersion = 42
        case "toolchain": bad.buildArtifact!.toolchain = "different"
        case "runtimes": bad.buildArtifact!.simulatorRuntimes = "different"
        case "scheme": bad.buildArtifact!.context["scheme"] = "Other"
        case "sdk": bad.buildArtifact!.context["sdkAndArchitecture"] = "other SDK"
        default: bad.buildArtifact!.revision = base
        }
        #expect(throws: ImpactError.self) { try analysis.select(base: base, baseGraph: old, headGraph: bad) }
    }
    var foreignReport = report
    foreignReport.headRevision = base
    #expect(throws: ImpactError.self) { try analysis.run(foreignReport, using: new) }
    #expect(throws: ImpactError.self) { try analysis.run(report, using: new) }
    foreignReport = report
    foreignReport.buildArtifactID = old.buildArtifact!.id
    #expect(throws: ImpactError.self) { try analysis.run(foreignReport, using: new) }
}

@Test func captureRequiresCleanCorrectRevisionAndFreshInputs() throws {
    let root = try artifactTemporary()
    defer { try? FileManager.default.removeItem(at: root) }
    @discardableResult func git(_ args: String...) throws -> String {
        try CommandRunner.run("git", args, at: root).text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    try git("init", "-q"); try git("config", "user.name", "Test"); try git("config", "user.email", "test@example.invalid")
    let source = root.appendingPathComponent("Code.swift"), log = root.appendingPathComponent("build.log")
    try "build.log\n".write(to: root.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
    try "func value() {}".write(to: source, atomically: true, encoding: .utf8)
    try git("add", "."); try git("commit", "-qm", "Base")
    let revision = try git("rev-parse", "HEAD")
    try "log".write(to: log, atomically: true, encoding: .utf8)
    try ArtifactFiles.validateCheckout(root: root, revision: revision, buildLog: log)
    #expect(throws: ImpactError.self) { try ArtifactFiles.validateCheckout(root: root, revision: "wrong", buildLog: log) }
    try "dirty".write(to: source, atomically: true, encoding: .utf8)
    #expect(throws: ImpactError.self) { try ArtifactFiles.validateCheckout(root: root, revision: revision, buildLog: log) }
    try git("restore", ".")
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: log.path)
    #expect(throws: ImpactError.self) { try ArtifactFiles.validateCheckout(root: root, revision: revision, buildLog: log) }
}

@Test func capturedTestRunRejectsWrongPlansAndEscapingProductPaths() throws {
    let root = try artifactTemporary()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("Plan.xctestrun")
    func write(path: String, version: Int = 2) throws {
        let value: [String: Any] = ["__xctestrun_metadata__": ["FormatVersion": version], "TestPlan": ["Name": "All"], "ContainerInfo": ["SchemeName": "App"],
            "TestConfigurations": [["TestTargets": [["TestBundlePath": path]]]]]
        try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0).write(to: file)
    }
    try write(path: "__TESTROOT__/Tests.xctest")
    try ArtifactFiles.validateTestRun(file, plan: "All", scheme: "App")
    #expect(throws: ImpactError.self) { try ArtifactFiles.validateTestRun(file, plan: "All", scheme: "Other") }
    #expect(throws: ImpactError.self) { try ArtifactFiles.validateTestRun(file, plan: "Other") }
    for path in ["/other/Tests.xctest", "__TESTROOT__/../Tests.xctest"] {
        try write(path: path)
        #expect(throws: ImpactError.self) { try ArtifactFiles.validateTestRun(file, plan: "All") }
    }
    try write(path: "__TESTROOT__/Tests.xctest", version: 42)
    #expect(throws: ImpactError.self) { try ArtifactFiles.validateTestRun(file, plan: "All") }
}

@Test func savedGraphsRemainDecodableWithoutArtifactMetadata() throws {
    var graph = capturedGraph("class Suite: XCTestCase { func testOne() {} }", revision: "old", context: [:])
    graph.buildArtifact = nil
    let decoded = try JSONDecoder().decode(XcodeTestGraph.self, from: JSONEncoder().encode(graph))
    #expect(decoded.buildArtifact == nil && decoded.tests == graph.tests)
}

@Test func captureLogAndSettingsMustMatchRequestedBuild() throws {
    let root = try artifactTemporary()
    defer { try? FileManager.default.removeItem(at: root) }
    let project = root.appendingPathComponent("App.xcodeproj"), derived = root.appendingPathComponent("DerivedData")
    let config = XcodeConfiguration(container: .project, path: project, scheme: "App", destination: "platform=iOS Simulator,name=iPhone", configuration: "Debug")
    let log = """
    Command line invocation:
        /Xcode/xcodebuild build-for-testing -project "\(project.path)" -scheme App -destination "\(config.destination)" -derivedDataPath "\(derived.path)"
    ** TEST BUILD SUCCEEDED **
    """
    try ArtifactFiles.validateBuildLog(log, options: config, root: root, derived: derived)
    for bad in [log.replacingOccurrences(of: "-scheme App", with: "-scheme Other"), log + "\n" + log, "filtered output"] {
        #expect(throws: ImpactError.self) { try ArtifactFiles.validateBuildLog(bad, options: config, root: root, derived: derived) }
    }
    let values = ["SRCROOT": root.path, "TARGET_TEMP_DIR": derived.appendingPathComponent("Build/Intermediates.noindex/App").path,
                  "CONFIGURATION": "Debug", "SDK_NAME": "iphonesimulator26.5", "PLATFORM_NAME": "iphonesimulator", "ARCHS": "arm64"]
    try ArtifactFiles.validateSettings([XcodeBuildSettings(buildSettings: values)], options: config, root: root, derived: derived)
    let releaseLog = log.replacingOccurrences(of: "-scheme App", with: "-scheme App -configuration Release")
    #expect(throws: ImpactError.self) { try ArtifactFiles.validateBuildLog(releaseLog, options: config, root: root, derived: derived, settings: [XcodeBuildSettings(buildSettings: values)]) }
    var incomplete = values; incomplete.removeValue(forKey: "ARCHS")
    #expect(throws: ImpactError.self) { try ArtifactFiles.validateSettings([XcodeBuildSettings(buildSettings: incomplete)], options: config, root: root, derived: derived) }
    for field in ["SRCROOT", "TARGET_TEMP_DIR", "CONFIGURATION"] {
        var bad = values; bad[field] = "/unrelated"
        #expect(throws: ImpactError.self) { try ArtifactFiles.validateSettings([XcodeBuildSettings(buildSettings: bad)], options: config, root: root, derived: derived) }
    }
}
