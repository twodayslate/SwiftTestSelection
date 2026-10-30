// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation
import Testing
@testable import TestImpact

@Test(arguments: ["actor", "nestedBare", "nestedSelf", "nestedModule"])
func historicalNominalConstructorsRemainAudited(kind: String) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("helper-nominal-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let expression = "_ = \(kind == "nestedSelf" ? "Self.Worker" : kind == "nestedModule" ? "UI.Suite.Worker" : "Worker")()"
    let before = """
    import XCTest
    func evaluate(_ body: () -> Void) { body() }
    @MainActor final class Suite: XCTestCase {
        func testConsumer() { \(expression); candidate() }
        private func candidate() { for _ in 0..<2 { let value = 1; XCTAssertTrue(true) } }
    }
    @MainActor final class Other: XCTestCase {
        func testReader() { evaluate { XCTAssertTrue(UserDefaults.standard.bool(forKey: "shared")) } }
    }
    """
    var after = before.replacingOccurrences(of: "private func candidate() {", with: "private func candidate() { XCTAssertTrue(true);")
    if kind != "actor" { after = after.replacingOccurrences(of: expression, with: "_ = ()") }
    let effect = "UserDefaults.standard.set(true, forKey: \"shared\")"
    let oldExtra = "import XCTest\n" + (kind == "actor"
        ? "actor Worker { init() { \(effect) } }"
        : "extension Suite { struct Worker { init() { \(effect) } } }")
    let cleanExtra = kind == "actor" ? "struct Worker {}" : oldExtra.replacingOccurrences(of: effect, with: "")
    let tests = ["UI/Suite/testConsumer()", "UI/Other/testReader()"]
    let old = try boundaryGraph(["UI.swift": before, "Extra.swift": oldExtra], tests: tests, root: root)
    let current = try GraphArchive.decode(GraphArchive.encode(boundaryGraph(["UI.swift": after, "Extra.swift": cleanExtra], tests: tests, root: root)))
    let graph = try #require(old.dependencies)
    let initializers = Set(graph.functions.filter { $0.value.name.contains("Worker.init") && $0.value.regions.contains { $0.path == "Extra.swift" } }.keys)
    try #require(!initializers.isEmpty)
    try #require(DependencyIndex(graph).paths(to: initializers).path(from: graph.tests[tests[0]] ?? []) != nil)
    for unowned in [false, true] {
        var source = XcodeHeadOnlySources(base: old.sources, mappings: current.mappings)
        if unowned {
            source.base.removeValue(forKey: "UI:Extra.swift")
            source.unownedBaseSources["Extra.swift"] = .parse(oldExtra, path: "Extra.swift", module: "")
        }
        let report = XcodeHeadOnlySelector.select(current: current, source: source,
            changes: [.init(path: "UI.swift")], baseRevision: "base")
        #expect(report.selectedTests == tests.sorted(), "kind=\(kind) unowned=\(unowned) diagnostics=\(report.diagnostics)")
        #expect(report.diagnostics.contains { $0.code == "head_only_helper_callee_effects" })
    }
    let cleanBefore = kind == "actor" ? before : before.replacingOccurrences(of: expression, with: "_ = ()")
    let cleanBase = ["UI:UI.swift": SwiftSourceSnapshot.parse(cleanBefore, path: "UI.swift", module: "UI"),
                     "UI:Extra.swift": SwiftSourceSnapshot.parse(cleanExtra, path: "Extra.swift", module: "UI")]
    let control = XcodeHeadOnlySelector.select(current: current, source: .init(base: cleanBase, mappings: current.mappings),
        changes: [.init(path: "UI.swift")], baseRevision: "base")
    #expect(control.selectedTests == [tests[0]], "\(control.diagnostics)")
    #expect(control.diagnostics.isEmpty)
}

@Test func actorBindingsRemainOpaqueWithoutChangingSourceBoundaries() throws {
    let source = SwiftSourceSnapshot.parse("""
    actor Worker { init() {} }
    enum Namespace {
        actor Nested {}
        #if CUSTOM
        distributed actor Conditional {}
        #endif
    }
    """, path: "Extra.swift", module: "UI")
    #expect(source.helperGlobalDeclarations?["Worker"] == false)
    #expect(source.dispatchMembers?.isSuperset(of: ["Namespace.Nested", "Namespace.Conditional"]) == true)
    let actor = try #require(source.units.first { $0.fingerprint.hasPrefix("actorDecl[") })
    #expect(actor.kind == "declaration")
}
