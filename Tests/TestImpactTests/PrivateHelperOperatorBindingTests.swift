// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation
import Testing
@testable import TestImpact

@Test(arguments: ["..<", "..."], [false, true])
func compiledPrivateHelperOperatorsRequireBothRevisionBindings(operation: String, transitive: Bool) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("helper-operator-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let before = """
    import XCTest
    func evaluate(_ body: () -> Void) { body() }
    @MainActor final class Suite: XCTestCase {
        func testConsumer() { candidate() }
        private func candidate() {
            \(transitive ? "iterate()\n    }\n    private func iterate() {" : "")
            for _ in 0\(operation)2 {
                let value = 1
                XCTAssertTrue(true)
            }
        }
    }
    @MainActor final class Other: XCTestCase {
        func testReader() { evaluate { XCTAssertFalse(UserDefaults.standard.bool(forKey: "shared")) } }
    }
    """
    let after = before.replacingOccurrences(of: "private func candidate() {", with: "private func candidate() { XCTAssertTrue(true)")
    let extra = """
    import XCTest
    func \(operation) (lhs: Int, rhs: Int) -> \(operation == "..<" ? "Range" : "ClosedRange")<Int> {
        UserDefaults.standard.set(true, forKey: "shared")
        return .init(uncheckedBounds: (lhs, rhs))
    }
    """
    let tests = ["UI/Suite/testConsumer()", "UI/Other/testReader()"]
    let old = try boundaryGraph(["UI.swift": before, "Extra.swift": extra], tests: tests, root: root)
    let current = try boundaryGraph(["UI.swift": after], tests: tests, root: root)
    let graph = try #require(old.dependencies)
    let custom = Set(graph.functions.filter { $0.value.regions.contains { $0.path == "Extra.swift" } }.keys)
    try #require(DependencyIndex(graph).paths(to: custom).path(from: graph.tests[tests[0]] ?? []) != nil)
    #expect(old.sources["UI:Extra.swift"]?.helperOperatorDeclarations == [operation])
    // Serialization must preserve the complete operator inventory and proof.
    let roundTripped = try GraphArchive.decode(GraphArchive.encode(current))
    for unowned in [false, true] {
        var source = XcodeHeadOnlySources(base: old.sources, mappings: current.mappings)
        if unowned {
            source.base.removeValue(forKey: "UI:Extra.swift")
            source.unownedBaseSources["Extra.swift"] = .parse(extra, path: "Extra.swift", module: "")
        }
        let report = XcodeHeadOnlySelector.select(current: roundTripped, source: source,
            changes: [.init(path: "UI.swift")], baseRevision: "base")
        #expect(report.selectedTests == tests.sorted(), "\(report.diagnostics)")
        #expect(report.diagnostics.contains { $0.code == "head_only_helper_callee_effects" && $0.message.contains("operator binding") })
    }
    let cleanBase = ["UI:UI.swift": SwiftSourceSnapshot.parse(before, path: "UI.swift", module: "UI")]
    let clean = XcodeHeadOnlySelector.select(current: current, source: .init(base: cleanBase, mappings: current.mappings),
        changes: [.init(path: "UI.swift")], baseRevision: "base")
    #expect(clean.selectedTests == [tests[0]])
    #expect(clean.diagnostics.isEmpty)
    // Missing evidence must not silently become an empty declaration/use set.
    for missing in ["headInventory", "baseInventory", "headProof", "baseProof"] {
        var broken = current, base = cleanBase
        if missing == "headInventory" { broken.sources["UI:UI.swift"]!.helperOperatorDeclarations = nil }
        if missing == "baseInventory" { base["UI:UI.swift"]!.helperOperatorDeclarations = nil }
        if missing == "headProof" {
            for i in broken.sources["UI:UI.swift"]!.units.indices { broken.sources["UI:UI.swift"]!.units[i].privateTestHelper?.effectOperators = nil }
        }
        if missing == "baseProof" {
            for i in base["UI:UI.swift"]!.units.indices { base["UI:UI.swift"]!.units[i].privateTestHelper?.effectOperators = nil }
        }
        let report = XcodeHeadOnlySelector.select(current: broken, source: .init(base: base, mappings: current.mappings),
            changes: [.init(path: "UI.swift")], baseRevision: "base")
        #expect(report.selectedTests == tests.sorted(), "\(missing): \(report.diagnostics)")
        #expect(report.diagnostics.contains { $0.message.contains("operator") })
    }
    // Head-only overloads and unchanged project overloads also cannot be trusted.
    let overloaded = try boundaryGraph(["UI.swift": after, "Extra.swift": extra], tests: tests, root: root)
    for base in [cleanBase, old.sources] {
        let report = XcodeHeadOnlySelector.select(current: overloaded, source: .init(base: base, mappings: current.mappings),
            changes: [.init(path: "UI.swift")], baseRevision: "base")
        #expect(report.selectedTests == tests.sorted())
        #expect(report.diagnostics.contains { $0.message.contains("operator binding") })
    }
}

@Test func privateHelperOperatorEvidenceIncludesEverySyntaxForm() throws {
    let source = SwiftSourceSnapshot.parse("""
    import XCTest
    final class Suite: XCTestCase {
        func testConsumer() { candidate() }
        private func candidate() { downstream() }
        private func downstream() {
            let negative = -1
            let sum = 1 + 2
            let product = sum * 2
            let custom = sum+++
            XCTAssertTrue(!false && sum == 3)
        }
    }
    #if CUSTOM_OPERATORS
    infix operator +: AdditionPrecedence
    prefix func - (_ value: Int) -> Int { value }
    struct Holder { static func * (lhs: Self, rhs: Self) -> Self { lhs } }
    extension Int { static postfix func +++ (_ value: Int) -> Int { value } }
    #endif
    """, path: "UI.swift", module: "UI")
    let proof = try #require(source.units.first { $0.privateTestHelper?.name == "candidate" }?.privateTestHelper)
    #expect(proof.effectOperators == ["-", "+", "*", "+++", "!", "&&", "=="])
    #expect(source.helperOperatorDeclarations == ["+", "-", "*", "+++"])
}

@Test func compiledPrivateHelperInterpolationAuditsHistoricalMembers() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("helper-interpolation-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let before = #"""
    import XCTest
    func evaluate(_ body: () -> Void) { body() }
    @MainActor final class Suite: XCTestCase {
        func testConsumer() { candidate() }
        private func candidate() {
            for _ in 0..<2 {
                let value = "value"
                let message = "prefix \(value) suffix"
                XCTAssertTrue(true, message)
            }
        }
    }
    @MainActor final class Other: XCTestCase {
        func testReader() { evaluate { XCTAssertFalse(UserDefaults.standard.bool(forKey: "shared")) } }
    }
    """#
    let after = before.replacingOccurrences(of: "private func candidate() {", with: "private func candidate() { XCTAssertTrue(true)")
    let extra = """
    import XCTest
    extension DefaultStringInterpolation {
        mutating func appendInterpolation(_ value: String) {
            UserDefaults.standard.set(true, forKey: "shared")
            appendLiteral(value)
        }
    }
    """
    let tests = ["UI/Suite/testConsumer()", "UI/Other/testReader()"]
    let old = try boundaryGraph(["UI.swift": before, "Extra.swift": extra], tests: tests, root: root)
    let current = try boundaryGraph(["UI.swift": after], tests: tests, root: root)
    let graph = try #require(old.dependencies)
    let custom = Set(graph.functions.filter { $0.value.regions.contains { $0.path == "Extra.swift" } }.keys)
    try #require(DependencyIndex(graph).paths(to: custom).path(from: graph.tests[tests[0]] ?? []) != nil)
    for unowned in [false, true] {
        var source = XcodeHeadOnlySources(base: old.sources, mappings: current.mappings)
        if unowned {
            source.base.removeValue(forKey: "UI:Extra.swift")
            source.unownedBaseSources["Extra.swift"] = .parse(extra, path: "Extra.swift", module: "")
        }
        let report = XcodeHeadOnlySelector.select(current: current, source: source,
            changes: [.init(path: "UI.swift")], baseRevision: "base")
        #expect(report.selectedTests == tests.sorted(), "\(report.diagnostics)")
        #expect(report.diagnostics.contains { $0.message.contains("appendInterpolation") })
    }
    let cleanBase = ["UI:UI.swift": SwiftSourceSnapshot.parse(before, path: "UI.swift", module: "UI")]
    let clean = XcodeHeadOnlySelector.select(current: current, source: .init(base: cleanBase, mappings: current.mappings),
        changes: [.init(path: "UI.swift")], baseRevision: "base")
    #expect(clean.selectedTests == [tests[0]], "\(clean.diagnostics)")
    #expect(clean.diagnostics.isEmpty)
}
