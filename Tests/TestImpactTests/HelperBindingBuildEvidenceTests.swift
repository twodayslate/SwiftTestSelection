// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
import Foundation
import Testing
@testable import TestImpact

@Test func bindingBuildEvidenceRequiresProductsAndExactImportedBytes() throws {
    let artifact = XcodeBuildArtifact(revision: "head", context: [:], toolchain: "compiler", buildLogDigest: "log", buildSettingsDigest: "settings", productsDirectory: "/tmp/products", xctestrun: "Tests.xctestrun", products: ["Dependency": "binary"])
    let valid = HelperBindingBuildEvidence(sourceInputs: "sources", inputFiles: ["SDK.swiftmodule": "sdk-bytes", "Dependency.swiftmodule": "dependency-bytes"], importedModules: ["UI": ["Swift", "Dependency"]], buildLogDigest: "log", buildSettingsDigest: "settings", productsDigest: try XcodeGraphCache.key(artifact.products))
    #expect(valid.matches(artifact))
    let archived = try JSONDecoder().decode(HelperBindingBuildEvidence.self, from: JSONEncoder().encode(valid))
    #expect(archived.fingerprint == valid.fingerprint)
    var changed = valid
    changed.inputFiles["Dependency.swiftmodule"] = "changed-export"
    #expect(changed.fingerprint != valid.fingerprint)
    changed = valid; changed.importedModules["UI"]!.append("Foreign")
    #expect(changed.fingerprint != valid.fingerprint)
    var otherArtifact = artifact
    otherArtifact.products["Dependency"] = "other-binary"
    #expect(!valid.matches(otherArtifact))
    for item in ["version", "sources", "imports", "files", "log", "settings"] {
        changed = valid
        switch item {
        case "version": changed.version += 1
        case "sources": changed.sourceInputs = ""
        case "imports": changed.importedModules = [:]
        case "files": changed.inputFiles = [:]
        case "log": changed.buildLogDigest = "stale"
        default: changed.buildSettingsDigest = "stale"
        }
        #expect(!changed.matches(artifact), "\(item)")
    }
}

@Test func bindingBuildCaptureRejectsUnknownMissingAndCustomInputs() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("binding-capture-" + UUID().uuidString)
    let bin = root.appendingPathComponent("bin"), plugins = root.appendingPathComponent("lib/swift/host/plugins")
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: plugins, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    for (name, text) in ["bin/swiftc": "compiler", "lib/swift/host/plugins/plugin": "sdk-plugin", "UI.swift": "func test() {}", "Dependency.swiftmodule": "dependency-bytes"] {
        try Data(text.utf8).write(to: root.appendingPathComponent(name))
    }
    let list = root.appendingPathComponent("UI.SwiftFileList"), map = root.appendingPathComponent("UI-dependencies-1.json")
    try Data(root.appendingPathComponent("UI.swift").path.utf8).write(to: list)
    let entry = ["moduleName": "Dependency", "modulePath": root.appendingPathComponent("Dependency.swiftmodule").path]
    try JSONSerialization.data(withJSONObject: [entry]).write(to: map)
    let log = "builtin-SwiftDriver -- \(bin.path)/swiftc -module-name UI -explicit-module-build @\(list.path)"
    let artifact = XcodeBuildArtifact(revision: "head", context: [:], toolchain: "compiler", buildLogDigest: XcodeGraphCache.digest(Data(log.utf8)), buildSettingsDigest: "settings", productsDirectory: root.path, xctestrun: "Tests.xctestrun", products: [:])
    let inputs = try ArtifactFiles.sourceInputs(log: log, directory: root)
    let valid = try HelperBindingBuildEvidence.capture(log: log, source: root, sourceInputs: inputs, artifact: artifact)
    #expect(valid.matches(artifact))
    #expect(valid.importedModules == ["UI": ["Dependency"]])
    #expect(valid.inputFiles[root.appendingPathComponent("Dependency.swiftmodule").resolvingSymlinksInPath().path] != nil)
    // The one-build retained path constructs its own artifact; exercise that
    // publication path as well as importing an existing build.
    let retained = root.appendingPathComponent("retained"), products = retained.appendingPathComponent("DerivedData/Build/Products")
    try FileManager.default.createDirectory(at: products, withIntermediateDirectories: true)
    try Data("incomplete".utf8).write(to: retained.appendingPathComponent("state"))
    let plist: [String: Any] = ["__xctestrun_metadata__": ["FormatVersion": 2], "TestPlan": ["Name": "All"],
        "TestConfigurations": [["TestTargets": [["TestBundlePath": "__TESTROOT__/Test.xctest"]]]]]
    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: products.appendingPathComponent("All.xctestrun"))
    try Data("binary".utf8).write(to: products.appendingPathComponent("Test.xctest"))
    try Data(log.utf8).write(to: retained.appendingPathComponent("build.log"))
    var graph = XcodeTestGraph(targets: [], tests: [])
    let settings = Data(#"[{"buildSettings":{"CONFIGURATION":"Debug","SDK_NAME":"sdk","PLATFORM_NAME":"simulator","ARCHS":"arm64"}}]"#.utf8)
    let published = try RetainedXcodeBuild.publish(graph: &graph, revision: "head", context: ["testPlan": "All"], toolchain: "fixture", workspace: retained, settings: settings, inputIdentity: [:])
    let archived = try #require(RetainedXcodeBuild.load(from: published).buildArtifact)
    #expect(archived.helperBindingBuild?.matches(archived) == true, "\(archived.helperBindingBuildFailure ?? "no failure")")
    #expect(archived.helperBindingInputs == archived.helperBindingBuild?.fingerprint)
    for flag in ["-load-plugin-executable", "-load-plugin-library", "-external-plugin-path", "-plugin-path"] {
        for separator in [" ", "="] {
            let customLog = log + " " + flag + separator + "/unbounded/custom/plugin"
            var customArtifact = artifact
            customArtifact.buildLogDigest = XcodeGraphCache.digest(Data(customLog.utf8))
            #expect(throws: (any Error).self) {
                try HelperBindingBuildEvidence.capture(log: customLog, source: root, sourceInputs: inputs, artifact: customArtifact)
            }
        }
    }
    let pluginLink = plugins.appendingPathComponent("external-plugin")
    try FileManager.default.createSymbolicLink(at: pluginLink, withDestinationURL: root.appendingPathComponent("Dependency.swiftmodule"))
    #expect(throws: (any Error).self) { try HelperBindingBuildEvidence.capture(log: log, source: root, sourceInputs: inputs, artifact: artifact) }
    try FileManager.default.removeItem(at: pluginLink)
    try Data("changed-module-exports".utf8).write(to: root.appendingPathComponent("Dependency.swiftmodule"))
    let changed = try HelperBindingBuildEvidence.capture(log: log, source: root, sourceInputs: inputs, artifact: artifact)
    #expect(changed.fingerprint != valid.fingerprint)
    var unknown = entry; unknown["futureResourceInputs"] = "unaccounted"
    try JSONSerialization.data(withJSONObject: [unknown]).write(to: map)
    #expect(throws: (any Error).self) { try HelperBindingBuildEvidence.capture(log: log, source: root, sourceInputs: inputs, artifact: artifact) }
    try JSONSerialization.data(withJSONObject: [entry]).write(to: map)
    try FileManager.default.removeItem(at: root.appendingPathComponent("Dependency.swiftmodule"))
    #expect(throws: (any Error).self) { try HelperBindingBuildEvidence.capture(log: log, source: root, sourceInputs: inputs, artifact: artifact) }
}
