// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import XCTest
import Testing
@testable import Shop

final class CheckoutTests: XCTestCase {
    func testCheckout() {
        XCTAssertEqual(checkout(100), 110)
    }

    func testReceipt() {
        XCTAssertEqual(receipt(100), "Total: 110")
    }

    func testGreeting() {
        XCTAssertEqual(greeting(), "Hello")
    }
}

@Test func taxCalculation() {
    #expect(calculateTax(100) == 10)
}

@Suite struct Greetings {
    @Test func saysHello() {
        #expect(greeting() == "Hello")
    }
}
