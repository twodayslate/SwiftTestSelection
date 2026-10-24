// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: AGPL-3.0-only

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
