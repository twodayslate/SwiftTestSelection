// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation
import Testing
@testable import TestImpact

@Test(arguments: ["operator", "interpolation", "global"], ["caller", "lifecycle", "producer", "oldCaller", "oldLifecycle", "oldProducer"])
func compiledPrivateHelperCallerExpressionsRequireHistoricalBindings(kind: String, site: String) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("helper-callerexpressions-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let expression = kind == "operator" ? "let value = 0...2" : kind == "global" ? "let value = min(1, 2)" : #"let input = "hello"; let value = "prefix \(input) suffix""#
    let historicalOnly = site.hasPrefix("old")
    let location = historicalOnly ? String(site.dropFirst(3)).lowercased() : site
    let caller = location == "caller" ? expression + "; candidate()" : location == "producer" ? "produce(); candidate()" : "candidate()"
    let before = """
    import XCTest
    func evaluate(_ body: () -> Void) { body() }
    \(location == "producer" ? "func produce() { " + expression + " }" : "")
    @MainActor final class Suite: XCTestCase {
        \(location == "lifecycle" ? "override func setUp() { " + expression + " }" : "")
        func testConsumer() { \(caller) }
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
    var after = before.replacingOccurrences(of: "private func candidate() {", with: "private func candidate() { XCTAssertTrue(true)")
    if historicalOnly { after = after.replacingOccurrences(of: expression, with: "_ = ()") }
    let extra = kind == "operator" ? """
    import XCTest
    func ... (lhs: Int, rhs: Int) -> ClosedRange<Int> {
        UserDefaults.standard.set(true, forKey: "shared")
        return .init(uncheckedBounds: (lhs, rhs))
    }
    """ : kind == "global" ? """
    import XCTest
    func min(_ lhs: Int, _ rhs: Int) -> Int {
        UserDefaults.standard.set(true, forKey: "shared")
        return lhs
    }
    """ : """
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
    try #require(!custom.isEmpty)
    try #require(DependencyIndex(graph).paths(to: custom).path(from: graph.tests[tests[0]] ?? []) != nil)
    let archivedOld = try GraphArchive.decode(GraphArchive.encode(old))
    let archivedCurrent = try GraphArchive.decode(GraphArchive.encode(current))
    for unowned in [false, true] {
        var source = XcodeHeadOnlySources(base: archivedOld.sources, mappings: current.mappings)
        if unowned { source.unownedBaseSources["Extra.swift"] = source.base.removeValue(forKey: "UI:Extra.swift") }
        let report = XcodeHeadOnlySelector.select(current: archivedCurrent, source: source,
            changes: [.init(path: "UI.swift")], baseRevision: "base")
        #expect(report.diagnostics.contains { $0.code == "head_only_helper_callee_effects" })
        #expect(report.selectedTests == tests.sorted())
    }
    let cleanBefore = historicalOnly ? before.replacingOccurrences(of: expression, with: "_ = ()") : before
    let cleanBase = ["UI:UI.swift": SwiftSourceSnapshot.parse(cleanBefore, path: "UI.swift", module: "UI")]
    let clean = XcodeHeadOnlySelector.select(current: current, source: .init(base: cleanBase, mappings: current.mappings),
        changes: [.init(path: "UI.swift")], baseRevision: "base")
    #expect(clean.selectedTests == [tests[0]], "\(clean.diagnostics)")
    #expect(clean.diagnostics.isEmpty)
    for revision in ["head", "base"] {
        var broken = current, base = cleanBase
        if revision == "head" {
            for i in broken.sources["UI:UI.swift"]!.units.indices { broken.sources["UI:UI.swift"]!.units[i].helperBindingUses = nil }
        } else {
            for i in base["UI:UI.swift"]!.units.indices { base["UI:UI.swift"]!.units[i].helperBindingUses = nil }
        }
        let report = XcodeHeadOnlySelector.select(current: broken, source: .init(base: base, mappings: current.mappings),
            changes: [.init(path: "UI.swift")], baseRevision: "base")
        #expect(report.selectedTests == tests.sorted())
        #expect(report.diagnostics.contains { $0.message.contains("caller expression bindings") })
    }
    let overloaded = try boundaryGraph(["UI.swift": after, "Extra.swift": extra], tests: tests, root: root)
    for (index, base) in [cleanBase, old.sources].enumerated() {
        let report = XcodeHeadOnlySelector.select(current: overloaded, source: .init(base: base, mappings: current.mappings),
            changes: [.init(path: "UI.swift")], baseRevision: "base")
        if historicalOnly && index == 0 {
            // No consumer uses the competing overload at either revision.
            #expect(report.selectedTests == [tests[0]])
            #expect(report.diagnostics.isEmpty)
        } else {
            #expect(report.selectedTests == tests.sorted())
            #expect(report.diagnostics.contains { $0.code == "head_only_helper_callee_effects" })
        }
    }
}

@Test func callerExpressionBindingsIncludeImplicitAndExplicitUses() throws {
    let source = SwiftSourceSnapshot.parse(#"""
    func caller() {
        let value = -1 + 2
        let text = "value \(value)"
        let item = values[0]
        item.method()
        let factory = item.method
        let instance = Factory()
        if !false { _ = value+++ }
    }
    func unrelated() { _ = 0...1; other.action() }
    func trailingConstructor() { Factory {} }
    """#, path: "UI.swift", module: "UI")
    let uses = try #require(source.units.first { $0.helperCallableName == "caller" }?.helperBindingUses)
    #expect(uses.operators == ["-", "+", "!", "+++"])
    #expect(uses.members == ["init", "appendLiteral", "appendInterpolation", "subscript", "method"])
    let trailing = try #require(source.units.first { $0.helperCallableName == "trailingConstructor" }?.helperBindingUses)
    #expect(trailing.members == ["init"])
    let mixed = SwiftSourceSnapshot.parse("""
    #if CUSTOM
    let min = makeCallable()
    #else
    func min(_ x: Int, _ y: Int) -> Int { x }
    #endif
    typealias Alias = Foreign.Type
    func producer() {}
    """, path: "Extra.swift", module: "UI")
    #expect(mixed.helperGlobalDeclarations == ["min": false, "Alias": false, "producer": true])
}
