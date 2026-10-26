// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import Testing
@testable import TestImpact

@Test func retainedBuildOwnershipAndCompletionAreExplicit() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("retained-tests-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let cache = root.appendingPathComponent("cache")
    let bundle = try RetainedXcodeBuild.create(at: root.appendingPathComponent("bundle"), cache: cache)
    #expect(throws: ImpactError.self) { try RetainedXcodeBuild.create(at: bundle, cache: cache) }
    #expect(throws: ImpactError.self) { try RetainedXcodeBuild.create(at: cache.appendingPathComponent("bundle"), cache: cache) }
    #expect(throws: ImpactError.self) { try RetainedXcodeBuild.create(at: root, cache: cache) }
    #expect(throws: (any Error).self) { try RetainedXcodeBuild.load(from: bundle.appendingPathComponent("head-graph.json")) }
    let products = bundle.appendingPathComponent("DerivedData/Build/Products")
    try FileManager.default.createDirectory(at: products, withIntermediateDirectories: true)
    let plist: [String: Any] = ["__xctestrun_metadata__": ["FormatVersion": 2], "TestPlan": ["Name": "All"],
        "TestConfigurations": [["TestTargets": [["TestBundlePath": "__TESTROOT__/Test.xctest"]]]]]
    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: products.appendingPathComponent("All.xctestrun"))
    try Data("binary".utf8).write(to: products.appendingPathComponent("Test.xctest"))
    var graph = XcodeTestGraph(targets: [], tests: ["UI/Suite/testOne()"])
    graph.dependencies = DependencyGraph()
    let settings = Data(#"[{"buildSettings":{"CONFIGURATION":"Debug","SDK_NAME":"sdk","PLATFORM_NAME":"simulator","ARCHS":"arm64"}}]"#.utf8)
    try Data("build".utf8).write(to: bundle.appendingPathComponent("build.log"))
    let graphFile = try RetainedXcodeBuild.publish(graph: &graph, revision: "head", context: ["testPlan": "All"], toolchain: "swift",
        workspace: bundle, settings: settings, inputIdentity: ["revision": "head", "dependencyLock": "pin"])
    let loaded = try RetainedXcodeBuild.load(from: graphFile)
    #expect(loaded.buildArtifact?.revision == "head")
    #expect(loaded.buildArtifact?.products["Test.xctest"] != nil)
    #expect(!FileManager.default.fileExists(atPath: bundle.appendingPathComponent("state").path))
    let graphCache = try XcodeGraphCache(.init(directory: cache, context: "x"), progress: { _ in })
    try graphCache.resetWork(); try graphCache.prune()
    #expect(try RetainedXcodeBuild.load(from: graphFile).buildArtifact?.id == loaded.buildArtifact?.id)
    try Data("{}".utf8).write(to: graphFile)
    #expect(throws: ImpactError.self) { try RetainedXcodeBuild.load(from: graphFile) }
}

@Test(arguments: ["unchanged", "edit", "add", "delete", "log", "settings", "missingSeal"])
func retainedCapturePublicationRequiresOriginalProductSnapshot(change: String) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("retained-seal-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let bundle = try RetainedXcodeBuild.create(at: root.appendingPathComponent("bundle"), cache: root.appendingPathComponent("cache"))
    let products = bundle.appendingPathComponent("DerivedData/Build/Products")
    try FileManager.default.createDirectory(at: products, withIntermediateDirectories: true)
    let plist: [String: Any] = ["__xctestrun_metadata__": ["FormatVersion": 2], "TestPlan": ["Name": "All"],
        "TestConfigurations": [["TestTargets": [["TestBundlePath": "__TESTROOT__/Test.xctest"]]]]]
    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: products.appendingPathComponent("All.xctestrun"))
    try Data("binary".utf8).write(to: products.appendingPathComponent("Test.xctest"))
    let resource = products.appendingPathComponent("resource.txt")
    try Data("original resource".utf8).write(to: resource)
    let log = bundle.appendingPathComponent("build.log"), settingsFile = bundle.appendingPathComponent("build-settings.json")
    try Data("original log".utf8).write(to: log)
    var settings = Data("[]".utf8)
    try settings.write(to: settingsFile)
    var capture = CapturedSIL(modules: [:], fingerprints: [:], diagnostics: [])
    capture.buildSeal = (products, try ArtifactFiles.manifest(at: products), try ArtifactFiles.digest(log), try ArtifactFiles.digest(settingsFile))
    // Simulate mutation while the base build runs. Publication itself must reject
    // these, even without the caller's earlier validateFiles check.
    switch change {
    case "edit": try Data("changed".utf8).write(to: resource)
    case "add": try Data("new".utf8).write(to: products.appendingPathComponent("new.txt"))
    case "delete": try FileManager.default.removeItem(at: resource)
    case "log": try Data("changed log".utf8).write(to: log)
    case "settings": settings = Data("[ ]".utf8)
    case "missingSeal": capture.buildSeal = nil
    default: break
    }
    var graph = XcodeTestGraph(targets: [], tests: [])
    func publish() throws -> URL {
        try RetainedXcodeBuild.publish(graph: &graph, revision: "head", context: ["testPlan": "All"], toolchain: "swift",
            workspace: bundle, settings: settings, inputIdentity: [:], capture: capture)
    }
    if change == "unchanged" {
        _ = try publish()
        #expect(graph.buildArtifact?.products == capture.buildSeal?.products)
    } else {
        #expect(throws: (any Error).self) { try publish() }
        #expect(FileManager.default.fileExists(atPath: bundle.appendingPathComponent("state").path))
        #expect(!FileManager.default.fileExists(atPath: bundle.appendingPathComponent("complete.json").path))
        #expect(!FileManager.default.fileExists(atPath: bundle.appendingPathComponent("head-graph.json").path))
    }
}
