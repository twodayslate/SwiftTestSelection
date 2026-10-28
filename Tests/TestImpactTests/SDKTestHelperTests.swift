// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation
import Testing
@testable import TestImpact

private let oldSDKQuery = """
import XCTest
@MainActor extension XCUIElement {
    func checkValue(_ expected: String, timeout: TimeInterval = 3) -> Bool {
        if value as? String == expected { return true }
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", expected), object: self)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }
}
"""
private let newSDKQuery = """
import XCTest
@MainActor extension XCUIElement {
    func checkValue(_ expected: String, timeout: TimeInterval = 3) -> Bool {
        let matches = NSPredicate { _, _ in self.exists && self.value as? String == expected }
        if matches.evaluate(with: self) { return true }
        let expectation = XCTNSPredicateExpectation(predicate: matches, object: self)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }
}
"""
private let sdkQueryCallers = """
import XCTest
@MainActor func openFeature(in app: XCUIApplication) {
    if app.exists { for _ in 0..<2 { XCTAssertTrue(app.buttons["toggle"].checkValue("1")) } }
}
@MainActor final class Sharing: XCTestCase {
    func testChange() { openFeature(in: XCUIApplication()) }
    func testAnother() {
        guard !XCUIApplication().buttons["toggle"].checkValue("0") else { return }
        XCTAssertTrue(true)
    }
}
@MainActor final class Notes: XCTestCase {
    func testUnrelated() { XCTAssertTrue(evaluate { true }) }
}
func evaluate(_ predicate: () -> Bool) -> Bool { predicate() }
"""

@Test(arguments: ["plain", "storedMethod", "escapingCall", "storedPredicate", "mutation", "dynamic", "lifecycle", "removedCall", "localFunction", "escapingLocal", "overload", "inherited", "throwing", "mixedQueries", "sameLineQueries", "escapedQueries", "nonthrowingPredicate", "nonthrowingPredicateNestedError"])
func compiledSDKQueryHelperBoundary(safety: String) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("sdk-query-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    var before = oldSDKQuery, after = newSDKQuery, callers = sdkQueryCallers
    let beforeCallers = callers
    switch safety {
    case "mixedQueries", "sameLineQueries", "escapedQueries":
        let name = safety == "escapedQueries" ? "`matching`" : "matching"
        let separator = safety == "sameLineQueries" ? "; " : "\n"
        callers = callers.replacingOccurrences(of: "func testChange() { openFeature(in: XCUIApplication()) }", with: """
        func testChange() {
            let app = XCUIApplication()
            XCTAssertTrue(app.buttons.\(name)(identifier: "α").firstMatch.exists)\(separator)XCTAssertTrue(app.buttons.\(name)(NSPredicate(value: true)).firstMatch.exists)
            openFeature(in: app)
        }
        """)
    case "nonthrowingPredicate", "nonthrowingPredicateNestedError":
        callers = callers.replacingOccurrences(of: "openFeature(in: XCUIApplication())", with: "XCTAssertTrue(allReady([{ true }])); openFeature(in: XCUIApplication())")
        if safety == "nonthrowingPredicateNestedError" {
            callers = callers.replacingOccurrences(of: "allReady([{ true }])", with: "allReady([{ predicate() }])")
            callers += "\nstruct Failure: Error {}\nfunc fail() throws -> Bool { throw Failure() }\nfunc predicate() -> Bool { XCTAssertTrue(try fail()); return true }\n"
        }
        callers += "\nfunc allReady(_ conditions: [() -> Bool]) -> Bool { conditions.allSatisfy { $0() } }\n"
    case "throwing": callers = callers.replacingOccurrences(of: "func openFeature(in app: XCUIApplication) {", with: "func openFeature(in app: XCUIApplication) throws {").replacingOccurrences(of: "func testChange() { openFeature(in:", with: "func testChange() throws { try openFeature(in:")
    case "inherited": callers = callers.replacingOccurrences(of: "@MainActor func openFeature(in app: XCUIApplication) {", with: "@MainActor class FeatureBase: XCTestCase { func openFeature(in app: XCUIApplication) {").replacingOccurrences(of: "@MainActor final class Sharing: XCTestCase", with: "}\n@MainActor final class Sharing: FeatureBase")
    case "overload": callers += "\n@MainActor func openFeature(_ app: XCUIApplication) {}\n@MainActor func other() { openFeature(XCUIApplication()) }\n"
    case "localFunction": callers = callers.replacingOccurrences(of: "func testChange() { openFeature(in: XCUIApplication()) }", with: "func testChange() { func step() { openFeature(in: XCUIApplication()) }; func nested() { step() }; nested() }")
    case "escapingLocal": callers = callers.replacingOccurrences(of: "func testChange() { openFeature(in: XCUIApplication()) }", with: "func testChange() { func step() { openFeature(in: XCUIApplication()) }; let callback = step; callback() }")
    case "storedMethod": callers = callers.replacingOccurrences(of: "func testChange() { openFeature(in: XCUIApplication()) }", with: "func testChange() { let callback = XCUIApplication().buttons[\"toggle\"].checkValue; XCTAssertTrue(callback(\"1\", 3)) }")
    case "escapingCall": callers = callers.replacingOccurrences(of: "func testChange() { openFeature(in: XCUIApplication()) }", with: "func testChange() { Task { openFeature(in: XCUIApplication()) } }")
    case "storedPredicate": after = "@MainActor var stored: NSPredicate?\n" + after.replacingOccurrences(of: "if matches.evaluate", with: "stored = matches\n        if matches.evaluate")
    case "mutation": after = "@MainActor var shared = false\n" + after.replacingOccurrences(of: "self.exists && self.value as? String == expected", with: "shared = true; return self.exists")
    case "dynamic": before = before.replacingOccurrences(of: "func checkValue", with: "@objc func checkValue"); after = after.replacingOccurrences(of: "func checkValue", with: "@objc func checkValue")
    case "lifecycle": callers = callers.replacingOccurrences(of: "func testChange()", with: "override func setUp()")
    case "removedCall": callers = callers.replacingOccurrences(of: "XCTAssertTrue(app.buttons[\"toggle\"].checkValue(\"1\"))", with: "XCTAssertTrue(true)")
    default: break
    }
    let files = ["Waiting.swift": after, "Tests.swift": callers]
    for (path, text) in files { try Data(text.utf8).write(to: root.appendingPathComponent(path)) }
    let platform = try CommandRunner.run("xcrun", ["--sdk", "macosx", "--show-sdk-platform-path"], at: root).text.trimmingCharacters(in: .whitespacesAndNewlines)
    let sil = root.appendingPathComponent("UI.sil")
    _ = try CommandRunner.run("xcrun", ["swiftc", "-emit-sil", "-whole-module-optimization", "-Onone", "-g", "-module-name", "UI",
        "-F", platform + "/Developer/Library/Frameworks", "-I", platform + "/Developer/usr/lib",
        root.appendingPathComponent("Waiting.swift").path, root.appendingPathComponent("Tests.swift").path, "-o", sil.path], at: root)
    let parsed = try SILParser.parse(file: sil, module: "UI", sourceRoot: root)
    var graph = DependencyGraph(functions: parsed.functions)
    XcodeCompilerGraph.resolveDispatch(&graph, tables: parsed.dispatchTargets)
    let tests = ["UI/Sharing/testChange()", "UI/Sharing/testAnother()", "UI/Notes/testUnrelated()"].filter { safety != "lifecycle" || !$0.contains("testChange") }
    var current = XcodeTestGraph(targets: [.init(name: "UI", productType: "com.apple.product-type.bundle.ui-testing", sourceFiles: Set(files.keys))], tests: tests)
    current.modules = ["UI": "UI"]
    current.sources = Dictionary(uniqueKeysWithValues: files.map { ("UI:" + $0.key, SwiftSourceSnapshot.parse($0.value, path: $0.key, module: "UI")) })
    XcodeCompilerGraph.bind(tests: tests, modules: current.modules, sources: current.sources, graph: &graph)
    try #require(tests.allSatisfy { graph.tests[$0]?.isEmpty == false && graph.testDiagnostics[$0]?.isEmpty ?? true })
    current.dependencies = graph
    current = try JSONDecoder().decode(XcodeTestGraph.self, from: JSONEncoder().encode(current))
    current.mappings = UIFeatureMappings(features: [])
    current.mappings?.sourceLocationPolicy = .diagnosticLineColumn
    var base = current.sources
    base["UI:Waiting.swift"] = .parse(before, path: "Waiting.swift", module: "UI")
    if safety == "removedCall" { base["UI:Tests.swift"] = .parse(beforeCallers, path: "Tests.swift", module: "UI") }
    func select(_ current: XcodeTestGraph) -> ImpactReport {
        XcodeHeadOnlySelector.select(current: current, source: .init(base: base, mappings: current.mappings), changes: [.init(path: "Waiting.swift")], baseRevision: "base")
    }
    let report = select(current)
    if ["plain", "removedCall"].contains(safety) {
        // Read both revisions through the public scoped path. A removed caller
        // outside the requested helper-file scope must not be replaced by head.
        try Data(before.utf8).write(to: root.appendingPathComponent("Waiting.swift"))
        try Data(beforeCallers.utf8).write(to: root.appendingPathComponent("Tests.swift"))
        try JSONEncoder().encode(current.mappings).write(to: root.appendingPathComponent(".swift-test-selection.json"))
        _ = try CommandRunner.run("git", ["init", "-q"], at: root)
        _ = try CommandRunner.run("git", ["add", "Waiting.swift", "Tests.swift", ".swift-test-selection.json"], at: root)
        _ = try CommandRunner.run("git", ["-c", "user.name=Tests", "-c", "user.email=tests@example.invalid", "commit", "-qm", "base"], at: root)
        for (path, text) in files { try Data(text.utf8).write(to: root.appendingPathComponent(path)) }
        let scopes = try XcodeHeadOnlySelector.scopedReports(current: current,
            requests: .init(scopes: [.init(name: "waiting", paths: ["Waiting.swift"])]),
            changes: [.init(path: "Waiting.swift"), .init(path: "Tests.swift")], baseRevision: "HEAD", headRevision: "head",
            root: root, mappingPath: ".swift-test-selection.json", documentation: [], buildEvidenceFailure: nil)
        #expect(scopes.first?.report.selectedTests == report.selectedTests)
        #expect(scopes.first?.report.diagnostics.contains(where: { $0.code == "head_only_sdk_helper_boundary" }) == (safety != "plain"))
    }
    if !["plain", "localFunction", "overload", "inherited", "throwing", "mixedQueries", "sameLineQueries", "escapedQueries", "nonthrowingPredicate"].contains(safety) {
        #expect(report.selectedTests == tests.sorted())
        #expect(report.diagnostics.contains { $0.code == "head_only_sdk_helper_boundary" })
        return
    }
    #expect(report.selectedTests == tests.prefix(2).sorted(), "\(report.diagnostics)")
    #expect(report.diagnostics.isEmpty)
    #expect(report.explanations.allSatisfy { $0.kind == "dependency" && $0.reason.contains("SDK test helper") })
    for fault in ["binding", "legacy", "effect", "externalShadow", "sdkSubclass", "aliasedSubclass", "oldEffect", "future", "import", "exportedImport", "sdkModule", "unknownConsumer"] {
        var broken = current
        switch fault {
        case "import": broken.sources["UI:Waiting.swift"] = .parse("import ShadowSDK\n" + after, path: "Waiting.swift", module: "UI")
        case "exportedImport": broken.sources["UI:Tests.swift"] = .parse("@_exported import ShadowSDK\n" + callers, path: "Tests.swift", module: "UI")
        case "sdkModule": broken.modules["Fake"] = "XCTest"
        case "future": for i in broken.sources["UI:Waiting.swift"]!.units.indices { broken.sources["UI:Waiting.swift"]!.units[i].sdkTestHelper?.version = 999 }
        case "oldEffect":
            var dirtyBase = base
            dirtyBase["UI:Waiting.swift"] = .parse(before.replacingOccurrences(of: "if value as? String", with: "print(expected); if value as? String"), path: "Waiting.swift", module: "UI")
            let rejected = XcodeHeadOnlySelector.select(current: current, source: .init(base: dirtyBase, mappings: current.mappings), changes: [.init(path: "Waiting.swift")], baseRevision: "base")
            #expect(rejected.selectedTests == tests.sorted())
            continue
        case "aliasedSubclass": broken.sources["UI:Tests.swift"] = .parse(callers + "\ntypealias Element = XCUIElement\nclass CustomElement: Element { override var value: Any? { nil } }", path: "Tests.swift", module: "UI")
        case "externalShadow": broken.sources["Other:Shadow.swift"] = .parse("typealias String = Int", path: "Shadow.swift", module: "Other")
        case "sdkSubclass": broken.sources["UI:Tests.swift"] = .parse(callers + "\nclass CustomElement: XCUIElement {}", path: "Tests.swift", module: "UI")
        case "binding": broken.dependencies!.tests[tests[2]] = []
        case "legacy": broken.sources["UI:Tests.swift"]!.helperReferences = nil
        case "effect":
            for id in graph.functions.keys where graph.functions[id]!.name.contains(".checkValue(") { broken.dependencies!.functions[id]!.uncertainties.insert("Shared state access") }
        default:
            let helper = try #require(graph.functions.values.first { $0.name.contains(".checkValue(") })
            broken.dependencies!.functions[graph.tests[tests[2]]!.first!]!.dependencies.insert(helper.id)
        }
        #expect(select(broken).selectedTests == tests.sorted(), "\(fault)")
    }
}
