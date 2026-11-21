// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
import Foundation
import Testing
@testable import TestImpact

@Test(arguments: ["CGRect", "CoreGraphics.CGRect"])
func compiledGeometryHelperRetainsValueAndMemberBindingChecks(type: String) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let before = """
    import XCTest
    import CoreGraphics
    @MainActor final class Suite: XCTestCase {
        func testConsumer() { check(XCUIApplication().frame) }
        private func check(_ frame: \(type), file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertFalse(frame.isEmpty, file: file, line: line)
        }
    }
    func evaluate(_ body: () -> Bool) -> Bool { body() }
    final class Other: XCTestCase {
        func testUnrelated() { XCTAssertTrue(evaluate { true }) }
    }
    """
    let after = before.replacingOccurrences(of: "XCTAssertFalse(frame.isEmpty, file: file, line: line)",
        with: "XCTAssertFalse(frame.isEmpty, file: file, line: line); XCTAssertTrue(true)")
    let tests = ["UI/Suite/testConsumer()", "UI/Other/testUnrelated()"]
    let current = try boundaryGraph(["UI.swift": after], tests: tests, root: root)
    let old = SwiftSourceSnapshot.parse(before, path: "UI.swift", module: "UI")
    let report = XcodeHeadOnlySelector.select(current: current, source: .init(base: ["UI:UI.swift": old]),
        changes: [.init(path: "UI.swift")], baseRevision: "base")
    #expect(report.selectedTests == [tests[0]], "\(report.diagnostics)")
    for shadow in ["typealias CGRect = OtherRect", "enum CoreGraphics {}",
                   "extension CGRect { var isEmpty: Bool { UserDefaults.standard.set(true, forKey: \"shared\"); return false } }"] {
        var base = ["UI:UI.swift": old]
        base["UI:Historical.swift"] = .parse(shadow, path: "Historical.swift", module: "UI")
        let rejected = XcodeHeadOnlySelector.select(current: current, source: .init(base: base), changes: [.init(path: "UI.swift")], baseRevision: "base")
        #expect(rejected.selectedTests == tests.sorted(), "\(shadow): \(rejected.diagnostics)")
    }
    // Geometry support grants no callback, mutation, app-factory or escape proof.
    for body in ["frame.origin.x = 1", "consume { frame.isEmpty }", "shared = frame", "let app = XCUIApplication(); app.launch()"] {
        let text = before.replacingOccurrences(of: "XCTAssertFalse(frame.isEmpty, file: file, line: line)", with: body)
        #expect(SwiftSourceSnapshot.parse(text, path: "UI.swift", module: "UI").units.first { $0.helperCallableName == "check" }?.privateTestHelper == nil)
    }
    let callback = before.replacingOccurrences(of: "XCTAssertFalse(frame.isEmpty, file: file, line: line)",
        with: "waitForAllConditions([{ frame.isEmpty }], timeout: 1)")
    let unsupported = SwiftSourceSnapshot.parse(callback, path: "UI.swift", module: "UI").units.first { $0.helperCallableName == "check" }
    #expect(unsupported?.privateTestHelper == nil)
    #expect(unsupported?.privateTestHelperBlocker?.contains("Callback passed to waitForAllConditions at line 6") == true)
}
