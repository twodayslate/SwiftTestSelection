// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation
import Testing
@testable import TestImpact

@Test(arguments: ["integer", "string", "alias", "sdkSignature"])
func compiledEnumArgumentContextsRequireHistoricalProof(kind: String) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("helper-enum-context-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let literal = kind == "string" ? "\"value\"" : "1"
    let sdkType = kind == "string" ? "String" : "Int"
    let protocolName = kind == "string" ? "ExpressibleByStringLiteral" : "ExpressibleByIntegerLiteral"
    let label = kind == "string" ? "stringLiteral" : "integerLiteral"
    let before = """
    import XCTest
    func evaluate(_ body: () -> Void) { body() }
    @MainActor final class Suite: XCTestCase {
        func testConsumer() { let worker = Worker.item(\(literal)); candidate() }
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
    let oldExtra = kind == "sdkSignature" ? "enum Worker { case item(Double) }" : """
    import XCTest
    struct Payload: \(protocolName) {
        init(\(label) value: \(sdkType)) { UserDefaults.standard.set(true, forKey: "shared") }
    }
    enum Worker {
        case item(Payload)
    }
    """
    let cleanExtra = (kind == "alias" ? "typealias Payload = Int\n" : "") + "enum Worker {\n    case item(\(kind == "alias" ? "Payload" : sdkType))\n}"
    let tests = ["UI/Suite/testConsumer()", "UI/Other/testReader()"]
    let old = try boundaryGraph(["UI.swift": before, "Extra.swift": oldExtra], tests: tests, root: root)
    let current = try GraphArchive.decode(GraphArchive.encode(boundaryGraph(["UI.swift": after, "Extra.swift": cleanExtra], tests: tests, root: root)))
    let graph = try #require(old.dependencies)
    let custom = Set(graph.functions.filter { $0.value.name.contains("Payload.init") && $0.value.regions.contains { $0.path == "Extra.swift" } }.keys)
    if kind != "sdkSignature" {
        try #require(!custom.isEmpty)
        try #require(DependencyIndex(graph).paths(to: custom).path(from: graph.tests[tests[0]] ?? []) != nil)
    }
    for unowned in [false, true] {
        var source = XcodeHeadOnlySources(base: try GraphArchive.decode(GraphArchive.encode(old)).sources, mappings: current.mappings)
        if unowned { source.unownedBaseSources["Extra.swift"] = source.base.removeValue(forKey: "UI:Extra.swift") }
        let report = XcodeHeadOnlySelector.select(current: current, source: source, changes: [.init(path: "UI.swift")], baseRevision: "base")
        #expect(report.selectedTests == tests.sorted())
        #expect(report.diagnostics.contains { $0.code == "head_only_helper_callee_effects" })
        var ordinary = current
        for i in ordinary.sources["UI:UI.swift"]!.units.indices { ordinary.sources["UI:UI.swift"]!.units[i].privateTestHelper = nil }
        #expect(XcodeHeadOnlySelector.select(current: ordinary, source: source, changes: [.init(path: "UI.swift")], baseRevision: "base").selectedTests == tests.sorted())
    }
    let cleanBase = ["UI:UI.swift": SwiftSourceSnapshot.parse(before, path: "UI.swift", module: "UI"),
                     "UI:Extra.swift": SwiftSourceSnapshot.parse(cleanExtra, path: "Extra.swift", module: "UI")]
    let control = XcodeHeadOnlySelector.select(current: current, source: .init(base: cleanBase, mappings: current.mappings), changes: [.init(path: "UI.swift")], baseRevision: "base")
    if kind == "alias" {
        // An unchanged source spelling is insufficient for a project alias.
        #expect(control.selectedTests == tests.sorted())
    } else {
        #expect(control.selectedTests == [tests[0]], "\(control.diagnostics)")
        #expect(control.diagnostics.isEmpty)
    }
}

@Test(arguments: ["setUp", "tearDown", "setUpWithError", "tearDownWithError"], [false, true])
func compiledInheritedLifecycleRequiresHistoricalEffects(hook: String, removed: Bool) throws {
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
    let oldHook = "override func \(hook)() \(hook.hasSuffix("WithError") ? "throws " : ""){ \(effect) }"
    let oldExtra = "import XCTest\n@MainActor class Base: XCTestCase {\n    \(oldHook)\n}"
    let cleanExtra = oldExtra.replacingOccurrences(of: removed ? oldHook : effect, with: removed ? "" : "_ = ()")
    let tests = ["UI/Suite/testConsumer()", "UI/Other/testReader()"]
    let old = try boundaryGraph(["UI.swift": before, "Extra.swift": oldExtra], tests: tests, root: root)
    let current = try GraphArchive.decode(GraphArchive.encode(boundaryGraph(["UI.swift": after, "Extra.swift": cleanExtra], tests: tests, root: root)))
    let graph = try #require(old.dependencies)
    let hooks = Set(graph.functions.filter { $0.value.name.contains("Base." + hook) }.keys)
    try #require(!hooks.isEmpty)
    try #require(DependencyIndex(graph).paths(to: hooks).path(from: graph.tests[tests[0]] ?? []) != nil)
    for unowned in [false, true] {
        var source = XcodeHeadOnlySources(base: try GraphArchive.decode(GraphArchive.encode(old)).sources, mappings: current.mappings)
        if unowned { source.unownedBaseSources["Extra.swift"] = source.base.removeValue(forKey: "UI:Extra.swift") }
        let report = XcodeHeadOnlySelector.select(current: current, source: source,
            changes: [.init(path: "UI.swift")], baseRevision: "base")
        #expect(report.selectedTests == tests.sorted())
        if !unowned {
            #expect(report.diagnostics.contains { $0.message.contains("historical caller lifecycle implementation") })
        }
    }
    let cleanBase = ["UI:UI.swift": SwiftSourceSnapshot.parse(before, path: "UI.swift", module: "UI"),
                     "UI:Extra.swift": SwiftSourceSnapshot.parse(cleanExtra, path: "Extra.swift", module: "UI")]
    let control = XcodeHeadOnlySelector.select(current: current, source: .init(base: cleanBase, mappings: current.mappings),
        changes: [.init(path: "UI.swift")], baseRevision: "base")
    #expect(control.selectedTests == [tests[0]], "\(control.diagnostics)")
    #expect(control.diagnostics.isEmpty)
}

@Test func enumCaseContextProofRequiresClosedValueArguments() throws {
    let source = SwiftSourceSnapshot.parse("""
    enum Worker {
        case scalar(Int)
        case collection([String])
        case qualified(Swift.Int)
        case project(Payload)
        case generic(T)
        case tuple((Int, Payload))
    }
    """, path: "Extra.swift", module: "UI")
    for name in ["scalar", "collection", "qualified", "project", "generic", "tuple"] {
        let unit = try #require(source.units.first { $0.helperDeclaredMembers?.contains(name) == true })
        #expect(unit.helperEnumCaseWithoutDefaults == true)
        #expect(unit.helperEnumCaseValueArguments == ["scalar", "collection", "qualified"].contains(name), "\(name)")
    }
}
