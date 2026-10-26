// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation
import Testing
@testable import TestImpact

private func cacheFixture() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("impact-cache-tests-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func cacheGraph() -> XcodeTestGraph {
    var graph = XcodeTestGraph(targets: [], tests: ["UI/Suite/testOne()"])
    graph.dependencies = DependencyGraph(tests: ["UI/Suite/testOne()": ["entry"]])
    graph.mappings = UIFeatureMappings(features: [.init(name: "feature", sources: ["App.swift"], tests: graph.tests)], runtimeDependencyPolicy: .declared)
    graph.sources = ["App.swift": SwiftSourceSnapshot.parse("func example() {}", path: "App.swift", module: "App")]
    return graph
}

@Test func graphCacheRoundTripInvalidatesAllIdentityInputsAndCorruption() throws {
    let root = try cacheFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    var messages: [String] = []
    let cache = try XcodeGraphCache(.init(directory: root, context: "external"), progress: { messages.append($0) })
    let identity = ["revision": "head", "repository": "repo", "settings": "debug", "analyzer": "v1", "toolchain": "swift", "sdk": "ios", "destination": "sim", "plan": "all", "dependencies": "pin", "external": "env"]
    #expect(try cache.load(identity) == nil)
    try cache.store(cacheGraph(), identity: identity)
    let loaded = try #require(try cache.load(identity))
    #expect(loaded.tests == cacheGraph().tests)
    #expect(loaded.sources["App.swift"]?.units.count == 1)
    #expect(loaded.mappings?.runtimeDependencyPolicy == .declared)
    for field in identity.keys {
        var changed = identity; changed[field] = "changed"
        #expect(try cache.load(changed) == nil)
    }
    let key = try XcodeGraphCache.key(identity)
    let dataFile = root.appendingPathComponent(key + "/graph.bin")
    try Data("{}".utf8).write(to: dataFile)
    #expect(try cache.load(identity) == nil)
    #expect(messages.contains { $0.contains("checksum mismatch") })
    #expect(!FileManager.default.fileExists(atPath: dataFile.path))
    try cache.store(cacheGraph(), identity: identity)
    try FileManager.default.removeItem(at: root.appendingPathComponent(key + "/manifest.json"))
    #expect(try cache.load(identity) == nil)
}

@Test func graphCacheRecoversAbandonedWorkAndBoundsDiskUsage() throws {
    let root = try cacheFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let cache = try XcodeGraphCache(.init(directory: root, context: "external", maximumBytes: 2000), progress: { _ in })
    try cache.resetWork()
    try Data("partial".utf8).write(to: cache.work.appendingPathComponent("build"))
    let stage = root.appendingPathComponent("stage-abandoned")
    try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
    try cache.resetWork()
    #expect(!FileManager.default.fileExists(atPath: stage.path))
    #expect(!FileManager.default.fileExists(atPath: cache.work.appendingPathComponent("build").path))
    for revision in 0..<12 { try cache.store(cacheGraph(), identity: ["revision": String(revision)]) }
    #expect(try cache.load(["revision": "0"]) == nil)
    #expect(try cache.load(["revision": "11"]) != nil)
    let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey])!
    var total = 0
    for case let file as URL in files {
        if file.pathExtension == "json" { total += try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0 }
    }
    #expect(total <= 2000)
}

@Test func graphCacheRejectsIncompleteEntriesAndInvalidConfiguration() throws {
    let root = try cacheFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(throws: ImpactError.self) { try XcodeGraphCache(.init(directory: root, context: ""), progress: { _ in }) }
    #expect(throws: ImpactError.self) { try XcodeGraphCache(.init(directory: root, context: "x", maximumBytes: 0), progress: { _ in }) }
    let cache = try XcodeGraphCache(.init(directory: root, context: "x", maximumBytes: 1), progress: { _ in })
    try cache.store(cacheGraph(), identity: ["revision": "head"])
    #expect(try cache.load(["revision": "head"]) == nil) // Oversized entry bypasses persistence.
    #expect(throws: ImpactError.self) { try cache.store(XcodeTestGraph(targets: [], tests: []), identity: [:]) }
}

@Test func cacheIdentityIgnoresInventoryOrderingButNotValues() throws {
    let a = Data(#"{"runtimes":[{"id":"a","archs":["a","b"]},{"id":"b"}]}"#.utf8)
    let b = Data(#"{"runtimes":[{"id":"b"},{"archs":["b","a"],"id":"a"}]}"#.utf8)
    let changed = Data(#"{"runtimes":[{"id":"c"}]}"#.utf8)
    #expect(try XcodeGraphCache.canonicalInventory(a) == XcodeGraphCache.canonicalInventory(b))
    #expect(try XcodeGraphCache.canonicalInventory(a) != XcodeGraphCache.canonicalInventory(changed))
}

@Test func runtimeUsageDoesNotInvalidateCacheButRuntimeBuildDoes() throws {
    let first = Data(#"{"runtimes":[{"identifier":"ios","buildversion":"123","lastUsage":{"arm64":"yesterday"}}]}"#.utf8)
    let used = Data(#"{"runtimes":[{"identifier":"ios","buildversion":"123","lastUsage":{"arm64":"today"}}]}"#.utf8)
    let upgraded = Data(#"{"runtimes":[{"identifier":"ios","buildversion":"124"}]}"#.utf8)
    #expect(try XcodeGraphCache.runtimeFingerprint(first) == XcodeGraphCache.runtimeFingerprint(used))
    #expect(try XcodeGraphCache.runtimeFingerprint(first) != XcodeGraphCache.runtimeFingerprint(upgraded))
}

@Test func buildSettingPathsCanBeNormalizedAcrossIsolatedWorkDirectories() throws {
    let first = Data(#"[{"buildSettings":{"SRCROOT":"/tmp/work-first/source"}}]"#.utf8)
    let next = Data(#"[{"buildSettings":{"SRCROOT":"/tmp/work-next/source"}}]"#.utf8)
    let a = String(decoding: try XcodeGraphCache.normalizedSettings(first, workspace: URL(fileURLWithPath: "/tmp/work-first")), as: UTF8.self)
    let b = String(decoding: try XcodeGraphCache.normalizedSettings(next, workspace: URL(fileURLWithPath: "/tmp/work-next")), as: UTF8.self)
    #expect(a == b)
    #expect(a.contains("<CACHE-WORK>/source"))
}

@Test func settingsNormalizeExactWorkspaceAliasesWithoutDroppingSemanticPaths() throws {
    let root = URL(fileURLWithPath: "/tmp/settings-alias-" + UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let actual = root.appendingPathComponent("real parent")
    let alias = root.appendingPathComponent("linked parent")
    try FileManager.default.createDirectory(at: actual, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: actual)
    func settings(_ workspace: URL, external: String = "/external/SDK", flag: String = "DEBUG") throws -> Data {
        try JSONSerialization.data(withJSONObject: [["buildSettings": [
            "SRCROOT": workspace.appendingPathComponent("source").path,
            "PATH": workspace.path + "/bin:/usr/bin:" + external,
            "OTHER_SWIFT_FLAGS": "-I\"\(workspace.path)/Includes\" -F\(workspace.path)/Frameworks -D" + flag,
            "EXTERNAL": external
        ]]])
    }
    let first = actual.appendingPathComponent("first bundle")
    let second = actual.appendingPathComponent("second bundle")
    for path in [first, second] { try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true) }
    let linked = alias.appendingPathComponent("first bundle")
    let privatePath = URL(fileURLWithPath: "/private" + first.path)
    let expected = try XcodeGraphCache.normalizedSettings(settings(second), workspace: second)
    for spelling in [first, linked, privatePath] {
        #expect(try XcodeGraphCache.normalizedSettings(settings(spelling), workspace: first, aliases: [linked]) == expected)
    }
    #expect(try XcodeGraphCache.normalizedSettings(settings(first, external: "/other/SDK"), workspace: first) != expected)
    #expect(try XcodeGraphCache.normalizedSettings(settings(first, flag: "RELEASE"), workspace: first) != expected)
    let neighbors = [first.path + "-unrelated", first.path + " unrelated", "/external" + first.path, "/other/SDK"]
    let data = try JSONSerialization.data(withJSONObject: neighbors)
    #expect(try XcodeGraphCache.normalizedSettings(data, workspace: first, aliases: [URL(fileURLWithPath: "/other/SDK")]) == XcodeGraphCache.canonicalInventory(data))
}

@Test func compactCacheStillReadsLegacyJSONEntries() throws {
    let root = try cacheFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let cache = try XcodeGraphCache(.init(directory: root, context: "legacy"), progress: { _ in })
    let identity = ["revision": "legacy"]
    let entry = root.appendingPathComponent(try XcodeGraphCache.key(identity))
    try FileManager.default.createDirectory(at: entry, withIntermediateDirectories: true)
    let data = try JSONEncoder().encode(cacheGraph())
    try data.write(to: entry.appendingPathComponent("graph.json"))
    try JSONSerialization.data(withJSONObject: ["identity": identity, "digest": XcodeGraphCache.digest(data)]).write(to: entry.appendingPathComponent("manifest.json"))
    #expect(try cache.load(identity)?.tests == cacheGraph().tests)
}

@Test func cacheOnlyLookupReportsMissingIncompatibleAndCorruptEntries() throws {
    let root = try cacheFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let cache = try XcodeGraphCache(.init(directory: root, context: "context"), progress: { _ in })
    let identity = ["revision": "base", "repository": "repo", "settings": "locked pins", "toolchain": "xcode",
                    "simulatorRuntimes": "runtime", "destination": "simulator", "externalInputs": "context",
                    "analyzerExecutable": "analyzer", "buildTimeSIL": "capture"]
    var reason = ""
    #expect(try cache.load(identity, onMiss: { reason = $0 }) == nil)
    #expect(reason.contains("absent, evicted or incompatible"))
    try cache.store(cacheGraph(), identity: identity)
    for field in identity.keys {
        var changed = identity; changed[field] = "different"
        reason = ""
        #expect(try cache.load(changed, onMiss: { reason = $0 }) == nil)
        #expect(!reason.isEmpty)
    }
    reason = ""
    #expect(try cache.load(identity, onMiss: { reason = $0 }) != nil)
    #expect(reason.isEmpty)
    let entry = root.appendingPathComponent(try XcodeGraphCache.key(identity))
    try Data("corrupt".utf8).write(to: entry.appendingPathComponent("graph.bin"))
    #expect(try cache.load(identity, onMiss: { reason = $0 }) == nil)
    #expect(reason.contains("checksum mismatch"))
    let error = XcodeCachedBaseUnavailable(revision: "resolved-sha", reason: reason)
    let decoded = try JSONDecoder().decode(XcodeCachedBaseUnavailable.self, from: JSONEncoder().encode(error))
    #expect(decoded.code == "cached_base_unavailable")
    #expect(decoded.revision == "resolved-sha")
    #expect(decoded.reason == reason)
}

@Test func cachedBasePolicyRequiresExplicitCacheBeforeAnalysis() throws {
    let analysis = XcodeAnalysis(options: XcodeConfiguration(container: .project,
        path: URL(fileURLWithPath: "/nonexistent/App.xcodeproj"), scheme: "App", destination: "simulator"))
    for policy in [XcodeCachedBasePolicy.require, .fullSuite] {
        do {
            _ = try analysis.select(base: "base", head: "head", cachedBasePolicy: policy)
            Issue.record("Expected a missing-cache error")
        } catch {
            #expect(String(describing: error).contains("explicit analysis cache and context"))
        }
    }
}

@Test func headOnlyRequiresHeadCaptureAndRetentionBeforeAnalysis() throws {
    var options = XcodeConfiguration(container: .project,
        path: URL(fileURLWithPath: "/nonexistent/App.xcodeproj"), scheme: "App", destination: "simulator")
    for stage in 0..<3 {
        if stage > 0 { options.buildTimeSILHelper = URL(fileURLWithPath: "/nonexistent/helper.py") }
        do {
            _ = try XcodeAnalysis(options: options).select(base: "base", head: stage == 2 ? nil : "head", headOnly: true)
            Issue.record("Expected early argument rejection")
        } catch {
            #expect(String(describing: error).contains("Head-only analysis requires"))
        }
    }
    do {
        _ = try XcodeAnalysis(options: options).select(base: "base", head: "head", retainingBuildAt: URL(fileURLWithPath: "/nonexistent/bundle"), cachedBasePolicy: .fullSuite, headOnly: true)
        Issue.record("Expected conflicting policy rejection")
    } catch { #expect(String(describing: error).contains("Head-only analysis requires")) }
}
