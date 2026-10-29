// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation
import Testing
@testable import TestImpact

@Test(arguments: ["defaultArgument", "memberwiseDefault", "accessor"])
func historicalCallerRegionsRequireAllExecutionBodies(kind: String) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("helper-region-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let effect = "UserDefaults.standard.set(true, forKey: \"shared\")"
    let beforeUse = kind == "defaultArgument" ? "Worker().perform()" : kind == "memberwiseDefault" ? "_ = Worker()" : "var worker = Worker(); worker.value = 1"
    let afterUse = kind == "defaultArgument" ? "Worker().perform(1)" : kind == "memberwiseDefault" ? "_ = Worker(value: 1)" : "let worker = Worker(); _ = worker.value"
    let before = """
    import XCTest
    func evaluate(_ body: () -> Void) { body() }
    @MainActor final class Suite: XCTestCase {
        func testConsumer() { \(beforeUse); candidate() }
        private func candidate() {
            for _ in 0..<2 { let value = 1; XCTAssertTrue(true) }
        }
    }
    @MainActor final class Other: XCTestCase {
        func testReader() { evaluate { XCTAssertTrue(UserDefaults.standard.bool(forKey: "shared")) } }
    }
    """
    let after = before.replacingOccurrences(of: beforeUse, with: afterUse)
        .replacingOccurrences(of: "private func candidate() {", with: "private func candidate() { XCTAssertTrue(true)")
    let extra = "import XCTest\n" + (kind == "defaultArgument"
        ? "struct Worker { func perform(_ value: Int = { \(effect); return 1 }()) {} }"
        : kind == "memberwiseDefault" ? "struct Worker { var value: Int = { \(effect); return 1 }() }"
        : "struct Worker { var value: Int { get { 1 } set { \(effect) } } }")
    let tests = ["UI/Suite/testConsumer()", "UI/Other/testReader()"]
    let old = try boundaryGraph(["UI.swift": before, "Extra.swift": extra], tests: tests, root: root)
    let current = try GraphArchive.decode(GraphArchive.encode(boundaryGraph(["UI.swift": after, "Extra.swift": extra], tests: tests, root: root)))
    let graph = try #require(old.dependencies)
    let targets = Set(graph.functions.filter {
        (kind == "memberwiseDefault" ? $0.value.name.contains("variable initialization") : $0.value.name.contains(kind == "defaultArgument" ? "default argument" : "value.setter")) &&
        $0.value.regions.contains { $0.path == "Extra.swift" }
    }.keys)
    try #require(!targets.isEmpty)
    try #require(DependencyIndex(graph).paths(to: targets).path(from: graph.tests[tests[0]] ?? []) != nil)
    for unowned in [false, true] {
        var source = XcodeHeadOnlySources(base: old.sources, mappings: current.mappings)
        if unowned {
            source.base.removeValue(forKey: "UI:Extra.swift")
            source.unownedBaseSources["Extra.swift"] = .parse(extra, path: "Extra.swift", module: "")
        }
        let report = XcodeHeadOnlySelector.select(current: current, source: source,
            changes: [.init(path: "UI.swift")], baseRevision: "base")
        #expect(report.selectedTests == tests.sorted(), "kind=\(kind) unowned=\(unowned) diagnostics=\(report.diagnostics)")
        #expect(report.diagnostics.contains { $0.code == "head_only_helper_callee_effects" })
    }
    let cleanExtra = kind == "accessor" ? "struct Worker { var value: Int { 1 } }"
        : extra.replacingOccurrences(of: "{ \(effect); return 1 }()", with: "1")
    let clean = try boundaryGraph(["UI.swift": after, "Extra.swift": cleanExtra], tests: tests, root: root)
    let base = ["UI:UI.swift": SwiftSourceSnapshot.parse(before.replacingOccurrences(of: beforeUse, with: afterUse), path: "UI.swift", module: "UI"),
                "UI:Extra.swift": SwiftSourceSnapshot.parse(cleanExtra, path: "Extra.swift", module: "UI")]
    let control = XcodeHeadOnlySelector.select(current: clean, source: .init(base: base, mappings: clean.mappings),
        changes: [.init(path: "UI.swift")], baseRevision: "base")
    #expect(control.selectedTests == [tests[0]], "\(control.diagnostics)")
    #expect(control.diagnostics.isEmpty)
    for revision in ["head", "base"] {
        var broken = clean, old = base
        if revision == "head" {
            for i in broken.sources["UI:Extra.swift"]!.units.indices { broken.sources["UI:Extra.swift"]!.units[i].helperRegionEffectsComplete = nil }
        } else {
            for i in old["UI:Extra.swift"]!.units.indices { old["UI:Extra.swift"]!.units[i].helperRegionEffectsComplete = nil }
        }
        let report = XcodeHeadOnlySelector.select(current: broken, source: .init(base: old, mappings: clean.mappings),
            changes: [.init(path: "UI.swift")], baseRevision: "base")
        #expect(report.selectedTests == tests.sorted())
        #expect(report.diagnostics.contains { $0.message.contains("declaration-body effects") })
    }
}

@Test func callerRegionEvidenceDistinguishesIndependentExecutionBodies() throws {
    let source = SwiftSourceSnapshot.parse("""
    struct Worker {
        func primitive(_ value: Int = 1) {}
        func opaque(_ value: Int = produce()) {}
        var stored = 1
        var initialized = produce()
        lazy var lazyValue = produce()
        var observed = 1 { didSet { effect() } }
        var getter: Int { get { 1 } }
        var mutable: Int { get { 1 } set { effect() } }
        subscript(_ index: Int = produce()) -> Int { 1 }
    }
    """, path: "Extra.swift", module: "UI")
    for (name, expected) in [("primitive", true), ("opaque", false), ("stored", true),
                             ("initialized", false), ("lazyValue", false), ("observed", false),
                             ("getter", true), ("mutable", false), ("subscript", false)] {
        let unit = try #require(source.units.first { $0.helperDeclaredMembers?.contains(name) == true })
        #expect(unit.helperRegionEffectsComplete == expected)
    }
}
