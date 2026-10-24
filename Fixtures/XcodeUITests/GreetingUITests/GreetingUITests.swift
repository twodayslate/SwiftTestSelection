// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: AGPL-3.0-only
import XCTest

final class GreetingUITests: XCTestCase {
    @MainActor func testGreetingScreen() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.staticTexts["welcome"].waitForExistence(timeout: 5))
    }
}
