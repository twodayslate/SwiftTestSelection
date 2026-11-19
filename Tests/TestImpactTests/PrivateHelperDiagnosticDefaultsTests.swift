// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
import Foundation
import Testing
@testable import TestImpact

private let diagnosticHelperSource = """
import XCTest
@MainActor final class Suite: XCTestCase {
    func testDefault() { check(true) }
    func testExplicit() { check(true, file: #filePath, line: #line) }
    private func check(_ value: Bool, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(value, file: file, line: line)
    }
}
func evaluate(_ body: () -> Bool) -> Bool { body() }
@MainActor final class Other: XCTestCase {
    func testUnrelated() { XCTAssertTrue(evaluate { true }) }
}
"""

@Test func compiledDiagnosticDefaultsPreserveExactConsumersAndFileIdentity() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let before = diagnosticHelperSource
    let after = before.replacingOccurrences(of: "XCTAssertTrue(value, file: file, line: line)",
        with: "XCTAssertTrue(value, file: file, line: line); XCTAssertFalse(false, file: file, line: line)")
    let tests = ["UI/Suite/testDefault()", "UI/Suite/testExplicit()", "UI/Other/testUnrelated()"]
    let current = try boundaryGraph(["UI.swift": after], tests: tests, root: root)
    let old = SwiftSourceSnapshot.parse(before, path: "UI.swift", module: "UI")
    let helper = try #require(current.sources["UI:UI.swift"]?.units.first { $0.helperCallableName == "check" })
    #expect(helper.privateTestHelper?.calleeEffectsSupported == true)
    let report = XcodeHeadOnlySelector.select(current: current, source: .init(base: ["UI:UI.swift": old], mappings: current.mappings),
        changes: [.init(path: "UI.swift")], baseRevision: "base")
    #expect(report.selectedTests == tests.prefix(2).sorted(), "\(report.diagnostics)")
    #expect(report.diagnostics.isEmpty)
    #expect(report.explanations.allSatisfy { $0.kind == "dependency" && $0.reason.contains("private helper isolation") })
    // The diagnosticLineColumn policy must still distinguish caller files.
    let moved = SwiftSourceSnapshot.parse(after, path: "Moved.swift", module: "UI")
    let originalCaller = try #require(current.sources["UI:UI.swift"]?.units.first { $0.helperCallableName == "testDefault" })
    let movedCaller = try #require(moved.units.first { $0.helperCallableName == "testDefault" })
    #expect(originalCaller.callerLocations?["filePath"] != movedCaller.callerLocations?["filePath"])
}

@Test(arguments: [
    "return file", "let saved = file", "let saved = line", "if line > 0 { XCTAssertTrue(true) }",
    "unknown(file: file, line: line)", "XCTAssertTrue(file == file)",
    "let file: StaticString = #filePath; XCTAssertTrue(value, file: file, line: line)",
    "let callback = { file }; _ = callback", "shared = file"
])
func diagnosticParametersCannotBecomeGeneralValues(body: String) {
    let source = diagnosticHelperSource.replacingOccurrences(of: "XCTAssertTrue(value, file: file, line: line)", with: body)
    let snapshot = SwiftSourceSnapshot.parse(source, path: "UI.swift", module: "UI")
    #expect(snapshot.units.first { $0.helperCallableName == "check" }?.privateTestHelper == nil)
}

@Test(arguments: ["(#filePath)", "makeFile()", "#filePath()", "#function"])
func diagnosticDefaultsRejectUnsupportedExpressions(expression: String) {
    let source = diagnosticHelperSource.replacingOccurrences(of: "= #filePath", with: "= " + expression)
    let snapshot = SwiftSourceSnapshot.parse(source, path: "UI.swift", module: "UI")
    #expect(snapshot.units.first { $0.helperCallableName == "check" }?.privateTestHelper == nil)
}
