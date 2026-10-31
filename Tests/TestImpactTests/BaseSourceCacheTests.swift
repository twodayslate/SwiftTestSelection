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
