// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: AGPL-3.0-only
import XCTest
import UIKit

class ConcreteTests: XCTestCase {
    func testState() { XCTAssertTrue(concrete(.active)) }
    func testComparison() { XCTAssertTrue(concreteContainer([.orderedSame], .orderedSame)) }
}
class GenericTests: XCTestCase {
    func testNestedGeneric() { XCTAssertTrue(nestedGeneric(Rows(values: [[1]]), Rows(values: [[1]]))) }
    func testFirst() { XCTAssertTrue(generic(First(value: 1), First(value: 1))) }
    func testSecond() { XCTAssertTrue(generic(Second(value: 1), Second(value: 1))) }
    func testAssociated() { XCTAssertTrue(associated([First(value: 1)])) }
}
class DispatchTests: XCTestCase {
    func testProtocol() { XCTAssertEqual(protocolCall(Child()), 3) }
    func testClass() { XCTAssertEqual(classCall(Child()), 3) }
    func testObjC() { XCTAssertEqual(objcCall(Child()), 2) }
    func testEscaped() { XCTAssertEqual(callbackCall(escape()), 1) }
    func testShared() { XCTAssertGreaterThanOrEqual(sharedState(), 0) }
}
class LifecycleBase: XCTestCase {
    override func setUp() { shared += 1 }
}
class InheritedTests: LifecycleBase {
    func testInheritedSetup() {}
}
