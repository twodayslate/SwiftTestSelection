// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: AGPL-3.0-only
import Core
import Foundation
import XCTest

class ParentCase: XCTestCase {
    override func setUp() { sharedValue = 3 }
}
final class CoreCase: ParentCase {
    @objc func testIndependent() {
        XCTAssertTrue(compare(UUID(uuidString: "00000000-0000-0000-0000-000000000000"), Date(timeIntervalSince1970: 0)))
        XCTAssertEqual(escapedCallback(), 3)
        let object: ProjectBase = ProjectOverride()
        XCTAssertEqual(object.value(), 3)
        XCTAssertEqual(NSObject().importedExtension(), 3)
        XCTAssertEqual(ProjectValue(3), ProjectValue(3))
    }
}
let suite = XCTestSuite(forTestCaseClass: CoreCase.self)
suite.run()
precondition(suite.testRun?.executionCount == 1 && suite.testRun?.failureCount == 0)
print("Executed 1 test; verified zero failures")
