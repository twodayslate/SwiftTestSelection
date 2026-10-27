// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation
import Testing
@testable import TestImpact

@Test(arguments: ["record", "legacy", "inherited", "escaped", "name", "perform", "observer", "registration", "alias", "missing", "ordinary", "lifecycle", "unrelated"])
func callbackIsolationAuditsBothRevisionsAndUnownedSources(kind: String) {
    let declarations: String
    switch kind {
    case "record": declarations = "class Base: XCTestCase { override func record(_ issue: XCTIssue) {} }"
    case "legacy": declarations = "class Base: XCTestCase { override func recordFailure(withDescription d: String, inFile f: String, atLine l: Int, expected e: Bool) {} }"
    case "inherited": declarations = "class Base: XCTestCase {}; class Child: Base { override func record(_ issue: XCTIssue) {} }"
    case "escaped": declarations = "class Base: XCTestCase { override func `record`(_ issue: XCTIssue) {} }"
    case "name": declarations = "class Base: XCTestCase { override var name: String { \"custom\" } }"
    case "perform": declarations = "class Base: XCTestCase { override func perform(_ run: XCTestRun) {} }"
    case "observer": declarations = "class Observer: NSObject, XCTestObservation {}"
    case "registration": declarations = "func install() { center.`addTestObserver`(observer) }"
    case "alias": declarations = "typealias Parent = XCTestCase; class Base: Parent { override func record(_ issue: XCTIssue) {} }"
    case "ordinary": declarations = "class Base: XCTestCase { private func record(_ value: String) {} }"
    case "lifecycle": declarations = "class Base: XCTestCase { override func setUp() {} }"
    case "unrelated": declarations = "class Logger { func record(_ value: String) {} }; class Child: Logger { override func record(_ value: String) {} }"
    default: declarations = "class Base: XCTestCase {}"
    }
    var snapshot = SwiftSourceSnapshot.parse("import XCTest\n" + declarations, path: "Hooks.swift", module: "UI")
    if kind == "missing" { snapshot.dispatchOverrides = nil }
    let empty = SwiftSourceSnapshot.parse("import XCTest", path: "Hooks.swift", module: "UI")
    for placement in 0..<3 {
        var current = XcodeTestGraph(targets: [], tests: [])
        current.sources = ["UI:Hooks.swift": placement == 0 ? snapshot : empty]
        let base = ["UI:Hooks.swift": placement == 1 ? snapshot : empty]
        let unowned = placement == 2 ? ["Removed.swift": snapshot] : [:]
        let blocker = XCTestCallbackIsolation.blocker(current: current, base: base, unownedBase: unowned)
        #expect((blocker == nil) == ["ordinary", "lifecycle", "unrelated"].contains(kind))
    }
}
