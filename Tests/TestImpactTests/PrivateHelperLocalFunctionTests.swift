// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
import Foundation
import Testing
@testable import TestImpact

private func localFunctionFixture(_ body: String) -> String {
    """
    import XCTest
    @MainActor final class Suite: XCTestCase {
        func testConsumer() { helper(XCUIApplication()) }
        private func helper(_ app: XCUIApplication) {
            \(body)
        }
    }
    func evaluate(_ body: () -> Bool) -> Bool { body() }
    @MainActor final class Other: XCTestCase {
        func testUnrelated() { XCTAssertTrue(evaluate { true }) }
    }
    """
}

@Test func compiledLocalFunctionsRetainCapturesAndExcludeUnrelatedOpaqueTests() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let body = """
    let button = app.buttons["Close"]
    func check() { XCTAssertTrue(button.exists) }
    func close() { check(); button.tap() }
    close()
    """
    let before = localFunctionFixture(body)
    let after = localFunctionFixture(body + "\nXCTAssertTrue(app.exists)")
    let tests = ["UI/Suite/testConsumer()", "UI/Other/testUnrelated()"]
    let current = try boundaryGraph(["UI.swift": after], tests: tests, root: root)
    let old = SwiftSourceSnapshot.parse(before, path: "UI.swift", module: "UI")
    let helper = try #require(current.sources["UI:UI.swift"]?.units.first { $0.helperCallableName == "helper" })
    #expect(helper.privateTestHelper?.calleeEffectsSupported == true)
    let report = XcodeHeadOnlySelector.select(current: current, source: .init(base: ["UI:UI.swift": old], mappings: current.mappings),
        changes: [.init(path: "UI.swift")], baseRevision: "base")
    #expect(report.selectedTests == [tests[0]], "\(report.diagnostics)")
    #expect(report.diagnostics.isEmpty)
    // A changed local body is an effect change, even when its name survives.
    let changed = try boundaryGraph(["UI.swift": after.replacingOccurrences(of: "button.tap()", with: "button.doubleTap()")], tests: tests, root: root)
    let fallback = XcodeHeadOnlySelector.select(current: changed, source: .init(base: ["UI:UI.swift": old], mappings: changed.mappings),
        changes: [.init(path: "UI.swift")], baseRevision: "base")
    #expect(fallback.selectedTests == tests.sorted())
    #expect(!fallback.diagnostics.isEmpty)
}

@Test(arguments: [
    "func step() { step() }; step()",
    "func first() { second() }; func second() { first() }; first()",
    "func step() { XCTAssertTrue(app.exists) }; let callback = step; callback()",
    "func step() { XCTAssertTrue(app.exists) }; consume(step)",
    "func step() { XCTAssertTrue(app.exists) }; consume(step())",
    "func step() { shared = app }; step()",
    "var state = false; func step() { state = true }; step()",
    "func step() { app = XCUIApplication() }; step()",
    "func step() { Task { app.tap() } }; step()",
    "func step() { later.tap() }; let later = app; step()",
    "@MainActor func step() { app.tap() }; step()",
    "func step() async { app.tap() }; step()",
    "func step(_ value: Bool = true) { XCTAssertTrue(value) }; step()",
    "func step() { app.tap() }; func step() { app.doubleTap() }; step()",
    "func step() { app.tap() }; let step = app; step.tap()",
    "func step() { app.tap() }; if true { func step() { app.doubleTap() }; step() }"
])
func localFunctionEffectsRejectEscapesRecursionMutationAndShadowing(body: String) {
    let source = SwiftSourceSnapshot.parse(localFunctionFixture(body), path: "UI.swift", module: "UI")
    #expect(source.units.first { $0.helperCallableName == "helper" }?.privateTestHelper == nil)
}
