// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: AGPL-3.0-only

import XCTest

final class SharingUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }
    @MainActor func testShareSheet() {
        assertSharingScreen(timeout: 5)
    }
    @MainActor func testShareLink() {
        assertSharingScreen(timeout: 5)
    }
    @MainActor func testShareCopy() {
        assertSharingScreen(timeout: 5)
    }
    @MainActor func testStandalone() {
        XCTAssertEqual(2 + 2, 4)
    }
    @MainActor private func assertSharingScreen(timeout: TimeInterval) {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.staticTexts["welcome"].waitForExistence(timeout: timeout))
    }
}

final class NotesUITests: XCTestCase {
    func testNotes() {
        XCTAssertEqual(3 + 3, 6)
    }
}

class SharedFixture: XCTestCase {
    override func setUpWithError() throws {
        XCTAssertEqual(inheritedValue(), 1)
    }
    func inheritedValue() -> Int {
        1
    }
}

final class InheritedUITests: SharedFixture {
    func testInheritedOne() {
        XCTAssertEqual(inheritedValue(), 1)
    }
    func testInheritedTwo() {
        XCTAssertEqual(inheritedValue(), 1)
    }
}
