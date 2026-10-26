// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import XCTest
@testable import ImpactDemo

final class ProductionTests: XCTestCase {
    func testSharing() {
        XCTAssertEqual(sharingTitle(), "Sharing")
    }
    func testNotes() {
        XCTAssertEqual(notesTitle(), "Notes")
    }
}
