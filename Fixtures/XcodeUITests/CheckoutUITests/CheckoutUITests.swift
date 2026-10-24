// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: AGPL-3.0-only
import XCTest

final class CheckoutUITests: XCTestCase {
    @MainActor func testCheckoutScreen() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.staticTexts["welcome"].waitForExistence(timeout: 5))
    }
}
