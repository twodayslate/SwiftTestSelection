// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
import LabelApp
import XCTest

final class AppCase: XCTestCase {
    @objc func testLabel() { XCTAssertFalse(label().isEmpty) }
}
let suite = XCTestSuite(forTestCaseClass: AppCase.self)
suite.run()
precondition(suite.testRun?.executionCount == 1 && suite.testRun?.failureCount == 0)
print("Executed 1 test; verified zero failures")
