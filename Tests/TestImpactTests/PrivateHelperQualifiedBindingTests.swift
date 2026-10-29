// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation
import Testing
@testable import TestImpact

@Test(arguments: [false, true])
func compiledQualifiedGlobalsRequireHistoricalEffects(removed: Bool) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("helper-qualified-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let before = """
    import XCTest
    func evaluate(_ body: () -> Void) { body() }
    @MainActor final class Suite: XCTestCase {
        func testConsumer() { UI.produce(); candidate() }
        private func candidate() {
            for _ in 0..<2 { let value = 1; XCTAssertTrue(true) }
        }
    }
    @MainActor final class Other: XCTestCase {
        func testReader() { evaluate { XCTAssertTrue(UserDefaults.standard.bool(forKey: "shared")) } }
    }
    """
    var after = before.replacingOccurrences(of: "private func candidate() {", with: "private func candidate() { XCTAssertTrue(true)")
    if removed { after = after.replacingOccurrences(of: "UI.produce()", with: "_ = ()") }
    let oldExtra = "import XCTest\nfunc produce() { UserDefaults.standard.set(true, forKey: \"shared\") }"
    let cleanExtra = "func produce() {}"
    let tests = ["UI/Suite/testConsumer()", "UI/Other/testReader()"]
    let old = try boundaryGraph(["UI.swift": before, "Extra.swift": oldExtra], tests: tests, root: root)
    let current = try GraphArchive.decode(GraphArchive.encode(boundaryGraph(["UI.swift": after, "Extra.swift": cleanExtra], tests: tests, root: root)))
    let graph = try #require(old.dependencies)
    let producers = Set(graph.functions.filter { $0.value.name.contains("produce") && $0.value.regions.contains { $0.path == "Extra.swift" } }.keys)
    try #require(!producers.isEmpty)
    try #require(DependencyIndex(graph).paths(to: producers).path(from: graph.tests[tests[0]] ?? []) != nil)
    for unowned in [false, true] {
        var source = XcodeHeadOnlySources(base: try GraphArchive.decode(GraphArchive.encode(old)).sources, mappings: current.mappings)
        if unowned {
            source.base.removeValue(forKey: "UI:Extra.swift")
            source.unownedBaseSources["Extra.swift"] = .parse(oldExtra, path: "Extra.swift", module: "")
        }
        let report = XcodeHeadOnlySelector.select(current: current, source: source,
            changes: [.init(path: "UI.swift")], baseRevision: "base")
        #expect(report.selectedTests == tests.sorted(), "removed=\(removed) unowned=\(unowned) diagnostics=\(report.diagnostics)")
        #expect(report.diagnostics.contains { $0.code == "head_only_helper_callee_effects" })
    }
    let cleanBefore = removed ? before.replacingOccurrences(of: "UI.produce()", with: "_ = ()") : before
    let cleanBase = ["UI:UI.swift": SwiftSourceSnapshot.parse(cleanBefore, path: "UI.swift", module: "UI"),
                     "UI:Extra.swift": SwiftSourceSnapshot.parse(cleanExtra, path: "Extra.swift", module: "UI")]
    let control = XcodeHeadOnlySelector.select(current: current, source: .init(base: cleanBase, mappings: current.mappings),
        changes: [.init(path: "UI.swift")], baseRevision: "base")
    #expect(control.selectedTests == [tests[0]], "\(control.diagnostics)")
    #expect(control.diagnostics.isEmpty)
    for revision in ["head", "base"] {
        var broken = current, base = cleanBase
        if revision == "head" {
            for i in broken.sources["UI:UI.swift"]!.units.indices { broken.sources["UI:UI.swift"]!.units[i].helperBindingUses?.qualifiedMembers = nil }
        } else {
            for i in base["UI:UI.swift"]!.units.indices { base["UI:UI.swift"]!.units[i].helperBindingUses?.qualifiedMembers = nil }
        }
        let report = XcodeHeadOnlySelector.select(current: broken, source: .init(base: base, mappings: current.mappings),
            changes: [.init(path: "UI.swift")], baseRevision: "base")
        #expect(report.selectedTests == tests.sorted())
        #expect(report.diagnostics.contains { $0.message.contains("expression bindings") })
    }
}

@Test func qualifiedCallerBindingsIncludeExpressionAndTypeMembers() throws {
    let snapshot = SwiftSourceSnapshot.parse("""
    func caller() {
        UI.produce()
        let function = UI.produce
        let value: UI.Namespace.Worker = .init()
        _ = UI.Namespace.Worker()
        object.method()
    }
    """, path: "UI.swift", module: "UI")
    let uses = try #require(snapshot.units.first { $0.helperCallableName == "caller" }?.helperBindingUses)
    #expect(uses.qualifiedMembers?["UI"] == ["produce", "Namespace"])
    #expect(uses.qualifiedMembers?["object"] == ["method"])
    #expect(uses.members.isSuperset(of: ["produce", "Namespace", "Worker", "init", "method"]))
}
