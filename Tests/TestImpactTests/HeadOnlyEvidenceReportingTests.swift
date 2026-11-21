// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
import Foundation
import Testing
@testable import TestImpact

@Test func removedHelpersReportHistoricalReferencesWithoutGuessingRenames() throws {
    let before = """
    import XCTest
    final class Suite: XCTestCase {
        func testConsumer() { oldHelper() }
        private func oldHelper() { XCTAssertTrue(true) }
    }
    """
    let after = before.replacingOccurrences(of: "oldHelper", with: "newHelper")
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let current = try boundaryGraph(["UI.swift": after], tests: ["UI/Suite/testConsumer()"], root: root)
    let old = SwiftSourceSnapshot.parse(before, path: "UI.swift", module: "UI")
    let report = XcodeHeadOnlySelector.select(current: current, source: .init(base: ["UI:UI.swift": old], mappings: current.mappings), changes: [.init(path: "UI.swift")], baseRevision: "base")
    let removed = try #require(report.headOnlyDeclarationChanges?.first { $0.change == "removed" })
    #expect(removed.baseRegions.first?.startLine == 4)
    #expect(removed.headRegions.isEmpty)
    #expect(removed.historicalReferences.contains { $0.sourceKey == "UI:UI.swift" && $0.callerLines.contains(3) })
    #expect(removed.historicalReferences.flatMap { $0.possibleCallers ?? [] }.contains {
        $0.baseRegion.startLine == 3 && $0.survivingTestEntries == ["UI/Suite/testConsumer()"]
    })
    #expect(!removed.missingEvidence.isEmpty)
    #expect(report.selectedTests == current.tests)
    #expect(report.diagnostics.contains { $0.code == "head_only_declaration_change" })
}

@Test func historicalChainedAndEscapedUsesRetainOwnersWithoutGuessingRenamedEntries() throws {
    let before = """
    import XCTest
    final class Suite: XCTestCase {
        func testChained() { XCTAssertTrue(oldHelper().isEmpty) }
        func testEscaped() { let closure = oldHelper; XCTAssertTrue(closure().isEmpty) }
        private func oldHelper() -> String { "" }
    }
    """
    let after = """
    import XCTest
    final class Suite: XCTestCase {
        func testChained() { XCTAssertTrue(true) }
        func testReplacement() { XCTAssertTrue(true) }
    }
    """
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let tests = ["UI/Suite/testChained()", "UI/Suite/testReplacement()"]
    let current = try boundaryGraph(["UI.swift": after], tests: tests, root: root)
    let old = SwiftSourceSnapshot.parse(before, path: "UI.swift", module: "UI")
    let report = XcodeHeadOnlySelector.select(current: current, source: .init(base: ["UI:UI.swift": old]),
        changes: [.init(path: "UI.swift")], baseRevision: "base")
    let helper = try #require(report.headOnlyDeclarationChanges?.first { $0.key.contains("oldHelper") })
    let callers = helper.historicalReferences.flatMap { $0.possibleCallers ?? [] }
    #expect(callers.contains { $0.baseRegion.startLine == 3 && $0.survivingTestEntries == [tests[0]] })
    #expect(callers.contains { $0.baseRegion.startLine == 4 && $0.survivingTestEntries.isEmpty })
    #expect(helper.historicalReferences.contains { $0.incomplete })
    #expect(report.selectedTests == tests)
}

@Test func localFunctionBlockersNameTheMissingCaptureAndEffectProof() {
    let source = SwiftSourceSnapshot.parse("""
    import XCTest
    final class Suite: XCTestCase {
        func testConsumer() { helper() }
        private func helper() {
            func nested() { XCTAssertTrue(true) }
            let escaped = nested
            escaped()
        }
    }
    """, path: "UI.swift", module: "UI")
    let helper = source.units.first { $0.helperCallableName == "helper" }
    #expect(helper?.privateTestHelper == nil)
    #expect(helper?.privateTestHelperBlocker?.contains("Nested local function nested at line 5") == true)
    #expect(helper?.privateTestHelperBlocker?.contains("recursion and nonescaping caller evidence") == true)
    let factory = SwiftSourceSnapshot.parse("""
    import XCTest
    final class Suite: XCTestCase {
        func testConsumer() { helper() }
        private func helper() {
            let app = XCUIApplication.make()
            func nested() { XCTAssertTrue(app.exists) }
            nested()
        }
    }
    """, path: "UI.swift", module: "UI")
    #expect(factory.units.first { $0.helperCallableName == "helper" }?.privateTestHelperBlocker?
        .contains("Application construction/factory reference XCUIApplication at line 5") == true)
}

@Test func selectionIndexReusePreservesQueriesAndRejectsMutatedInputs() throws {
    var graph = DependencyGraph()
    for i in 0..<1_000 {
        graph.functions["f\(i)"] = FunctionNode(id: "f\(i)", module: "App", name: "f\(i)()",
            regions: [.init(path: "App.swift", startLine: i + 1, endLine: i + 1)], dependencies: i == 0 ? [] : ["f\(i - 1)"])
    }
    graph.tests = ["Tests/Suite/test()": ["f999"]]
    var current = XcodeTestGraph(targets: [], tests: Array(graph.tests.keys))
    current.dependencies = graph
    let cache = HelperBindingDigestCache(current: current)
    let fresh = DependencyIndex(graph)
    for targets: Set<String> in [[], ["f0"], ["f999"], ["f4", "f500"], ["absent"]] {
        let cached = try #require(cache.dependencyIndex(current))
        #expect(cached.paths(to: targets).path(from: ["f999"]) == fresh.paths(to: targets).path(from: ["f999"]))
    }
    #expect(cache.indexComputations == 1)
    current.dependencies?.tests["Tests/New/test()"] = ["new-root"]
    #expect(cache.dependencyIndex(current)?.ids["new-root"] != nil)
    #expect(cache.indexComputations == 2)
    current.dependencies?.functions["f999"]?.dependencies = []
    #expect(cache.dependencyIndex(current)?.paths(to: ["f0"]).path(from: ["f999"]) == nil)
    let measured = AnalysisMeasurement().event("child", revision: "head", parent: "selection")
    #expect(measured.parentPhase == "selection")
    #expect(measured.seconds >= 0)
    #expect(measured.analyzerCPUSeconds.map { $0 >= 0 } == true)
}
