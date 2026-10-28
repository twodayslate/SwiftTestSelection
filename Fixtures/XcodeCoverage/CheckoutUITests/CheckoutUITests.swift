// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import XCTest

final class SharingUITests: XCTestCase {
    @MainActor func testSharingScreen() {
        let app = XCUIApplication()
        app.launch()
        app.buttons["sharingButton"].tap()
        XCTAssertTrue(app.staticTexts["screenTitle"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["screenTitle"].label, "Sharing")
        app.terminate()
    }
}

final class NotesUITests: XCTestCase {
    @MainActor func testNotesScreen() {
        let app = XCUIApplication()
        app.launch()
        app.buttons["notesButton"].tap()
        XCTAssertTrue(app.staticTexts["screenTitle"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["screenTitle"].label, "Notes")
        app.terminate()
    }
}
