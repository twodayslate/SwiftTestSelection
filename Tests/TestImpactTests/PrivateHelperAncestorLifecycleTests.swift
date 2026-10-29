// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation
import Testing
@testable import TestImpact

@Test(arguments: ["destructor", "ancestor", "deepAncestor", "ancestorStorage", "ancestorDestructor"], [false, true])
func compiledHistoricalDestructorsAndAncestorsRequireEffects(kind: String, removed: Bool) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("helper-lifecycle-body-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let before = """
    import XCTest
    func evaluate(_ body: () -> Void) { body() }
    @MainActor final class Suite: Base {
        func testConsumer() { candidate() }
        private func candidate() {
            for _ in 0..<2 {
                let value = 1
                XCTAssertTrue(true)
            }
        }
    }
    @MainActor final class Other: XCTestCase {
        func testReader() { evaluate { XCTAssertTrue(UserDefaults.standard.bool(forKey: "shared")) } }
    }
    """
    let after = before.replacingOccurrences(of: "private func candidate() {", with: "private func candidate() { XCTAssertTrue(true)")
    let effect = "UserDefaults.standard.set(true, forKey: \"shared\")"
    let oldHook: String
    switch kind {
    case "destructor", "ancestorDestructor": oldHook = "deinit { \(effect) }"
    case "ancestorStorage": oldHook = "let marker: Int = { \(effect); return 1 }()"
    default: oldHook = "override func setUp() { \(effect) }"
    }
    let ancestors = "@MainActor class OldRoot: XCTestCase {\n    \(oldHook)\n}\n" +
        (kind == "deepAncestor" ? "@MainActor class Middle: UI.OldRoot {}\n" : "")
    let oldExtra = "import XCTest\n" + (kind == "destructor"
        ? "@MainActor class Base: XCTestCase {\n    \(oldHook)\n}"
        : ancestors + "@MainActor class Base: \(kind == "deepAncestor" ? "UI.Middle" : "OldRoot") {}")
    let cleanExtra = kind == "destructor"
        ? oldExtra.replacingOccurrences(of: removed ? oldHook : effect, with: removed ? "" : "_ = ()")
        : "import XCTest\n" + (removed ? "" : ancestors) + "@MainActor class Base: XCTestCase {}"
    let tests = ["UI/Suite/testConsumer()", "UI/Other/testReader()"]
    let old = try boundaryGraph(["UI.swift": before, "Extra.swift": oldExtra], tests: tests, root: root)
    let current = try GraphArchive.decode(GraphArchive.encode(boundaryGraph(["UI.swift": after, "Extra.swift": cleanExtra], tests: tests, root: root)))
    let graph = try #require(old.dependencies)
    let target: String
    switch kind {
    case "destructor": target = "Base.__deallocating_deinit"
    case "ancestorDestructor": target = "OldRoot.__deallocating_deinit"
    case "ancestorStorage": target = "variable initialization expression of OldRoot.marker"
    default: target = "OldRoot.setUp"
    }
    let hooks = Set(graph.functions.filter { $0.value.name.contains(target) }.keys)
    try #require(!hooks.isEmpty)
    try #require(DependencyIndex(graph).paths(to: hooks).path(from: graph.tests[tests[0]] ?? []) != nil)
    for unowned in [false, true] {
        var source = XcodeHeadOnlySources(base: try GraphArchive.decode(GraphArchive.encode(old)).sources, mappings: current.mappings)
        if unowned { source.unownedBaseSources["Extra.swift"] = source.base.removeValue(forKey: "UI:Extra.swift") }
        let report = XcodeHeadOnlySelector.select(current: current, source: source,
            changes: [.init(path: "UI.swift")], baseRevision: "base")
        #expect(report.selectedTests == tests.sorted(), "kind=\(kind) removed=\(removed) unowned=\(unowned) selected=\(report.selectedTests) diagnostics=\(report.diagnostics)")
        if !unowned {
            #expect(report.diagnostics.contains { $0.code == "head_only_helper_callee_effects" })
        }
        var ordinary = current
        for i in ordinary.sources["UI:UI.swift"]!.units.indices { ordinary.sources["UI:UI.swift"]!.units[i].privateTestHelper = nil }
        #expect(XcodeHeadOnlySelector.select(current: ordinary, source: source, changes: [.init(path: "UI.swift")], baseRevision: "base").selectedTests == tests.sorted())
    }
    let cleanBase = ["UI:UI.swift": SwiftSourceSnapshot.parse(before, path: "UI.swift", module: "UI"),
                     "UI:Extra.swift": SwiftSourceSnapshot.parse(cleanExtra, path: "Extra.swift", module: "UI")]
    let control = XcodeHeadOnlySelector.select(current: current, source: .init(base: cleanBase, mappings: current.mappings),
        changes: [.init(path: "UI.swift")], baseRevision: "base")
    #expect(control.selectedTests == [tests[0]], "\(control.diagnostics)")
    #expect(control.diagnostics.isEmpty)
    if kind == "destructor" && !removed {
        for revision in ["head", "base"] {
            for inventory in ["superclasses", "members"] {
                var broken = current, source = cleanBase
                var snapshot = revision == "head" ? broken.sources["UI:Extra.swift"]! : source["UI:Extra.swift"]!
                if inventory == "superclasses" { snapshot.superclasses = nil }
                else { for i in snapshot.units.indices { snapshot.units[i].helperDeclaredMembers = nil } }
                if revision == "head" { broken.sources["UI:Extra.swift"] = snapshot }
                else { source["UI:Extra.swift"] = snapshot }
                let report = XcodeHeadOnlySelector.select(current: broken, source: .init(base: source, mappings: current.mappings),
                    changes: [.init(path: "UI.swift")], baseRevision: "base")
                #expect(report.selectedTests == tests.sorted())
                #expect(report.diagnostics.contains { $0.message.contains("evidence") })
            }
        }
    }
}

