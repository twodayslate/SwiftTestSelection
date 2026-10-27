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


private func boundaryGraph(_ files: [String: String], tests: [String], root: URL) throws -> XcodeTestGraph {
    for (path, text) in files { try Data(text.utf8).write(to: root.appendingPathComponent(path)) }
    let platform = try CommandRunner.run("xcrun", ["--sdk", "macosx", "--show-sdk-platform-path"], at: root).text.trimmingCharacters(in: .whitespacesAndNewlines)
    let sil = root.appendingPathComponent("UI.sil")
    _ = try CommandRunner.run("xcrun", ["swiftc", "-emit-sil", "-whole-module-optimization", "-Onone", "-g", "-module-name", "UI",
        "-F", platform + "/Developer/Library/Frameworks", "-I", platform + "/Developer/usr/lib"] + files.keys.sorted().map { root.appendingPathComponent($0).path } + ["-o", sil.path], at: root)
    let parsed = try SILParser.parse(file: sil, module: "UI", sourceRoot: root)
    var graph = DependencyGraph(functions: parsed.functions)
    XcodeCompilerGraph.resolveDispatch(&graph, tables: parsed.dispatchTargets)
    var current = XcodeTestGraph(targets: [.init(name: "UI", productType: "com.apple.product-type.bundle.ui-testing", sourceFiles: Set(files.keys))], tests: tests)
    current.modules = ["UI": "UI"]
    current.sources = Dictionary(uniqueKeysWithValues: files.map { ("UI:" + $0.key, SwiftSourceSnapshot.parse($0.value, path: $0.key, module: "UI")) })
    XcodeCompilerGraph.bind(tests: tests, modules: current.modules, sources: current.sources, graph: &graph)
    try #require(tests.allSatisfy { graph.tests[$0]?.isEmpty == false && graph.testDiagnostics[$0]?.isEmpty ?? true })
    current.dependencies = graph
    current.mappings = UIFeatureMappings(features: [])
    current.mappings?.sourceLocationPolicy = .diagnosticLineColumn
    return current
}

@Test(arguments: ["deleted", "removedFromTarget", "unrelated"])
func sdkHelperScopesAuditBaseOnlySources(scenario: String) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("review57-deleted-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let tests = ["UI/Sharing/testChange()", "UI/Sharing/testAnother()", "UI/Notes/testUnrelated()"]
    let files = ["Waiting.swift": newSDKQuery, "Tests.swift": sdkQueryCallers]
    let current = try boundaryGraph(files, tests: tests, root: root)
    let relevant = "import XCTest\n@MainActor func oldRoute() { XCTAssertTrue(XCUIApplication().buttons[\"toggle\"].checkValue(\"1\")) }"
    let deleted = scenario == "unrelated" ? "struct Unrelated {}" : relevant
    let baseTests = sdkQueryCallers.replacingOccurrences(of: "func testUnrelated() { XCTAssertTrue(evaluate { true }) }", with: scenario == "unrelated" ? "func testUnrelated() { XCTAssertTrue(evaluate { true }) }" : "func testUnrelated() { oldRoute() }")
    for (path, text) in ["Waiting.swift": oldSDKQuery, "Tests.swift": baseTests, "Deleted.swift": deleted] {
        try Data(text.utf8).write(to: root.appendingPathComponent(path))
    }
    try JSONEncoder().encode(current.mappings).write(to: root.appendingPathComponent(".swift-test-selection.json"))
    _ = try CommandRunner.run("git", ["init", "-q"], at: root)
    _ = try CommandRunner.run("git", ["add", "Waiting.swift", "Tests.swift", "Deleted.swift", ".swift-test-selection.json"], at: root)
    _ = try CommandRunner.run("git", ["-c", "user.name=Tests", "-c", "user.email=tests@example.invalid", "commit", "-qm", "base"], at: root)
    for (path, text) in files { try Data(text.utf8).write(to: root.appendingPathComponent(path)) }
    if scenario != "removedFromTarget" { try FileManager.default.removeItem(at: root.appendingPathComponent("Deleted.swift")) }
    let source = try XcodeHeadOnlySources.read(current: current, changes: [.init(path: "Waiting.swift")], base: "HEAD", root: root, mappingPath: ".swift-test-selection.json")
    #expect(source.unownedBaseSources["Deleted.swift"] != nil)
    let scopes = try XcodeHeadOnlySelector.scopedReports(current: current,
        requests: .init(scopes: [.init(name: "waiting", paths: ["Waiting.swift"])]),
        changes: [.init(path: "Waiting.swift"), .init(path: "Tests.swift"), .init(path: "Deleted.swift")],
        baseRevision: "HEAD", headRevision: "head", root: root, mappingPath: ".swift-test-selection.json",
        documentation: [], buildEvidenceFailure: nil)
    let report = try #require(scopes.first?.report)
    if scenario == "unrelated" {
        #expect(report.selectedTests == tests.prefix(2).sorted())
        #expect(report.diagnostics.isEmpty)
    } else {
        #expect(report.selectedTests == tests.sorted())
        #expect(report.diagnostics.contains { $0.code == "head_only_sdk_helper_boundary" && $0.message.contains("Deleted.swift") })
    }
}

@Test(arguments: ["mutation", "transitive", "safe", "recursive", "caller"])
func privateHelperAssertionsValidateCalleeEffects(scenario: String) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("review57-effects-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    var before = """
    import XCTest
    @MainActor final class Suite: XCTestCase {
        func testCaller() { candidate() }
        private func candidate() {
            XCTAssertTrue(true)
        }
        private func mutateSDKState() -> Bool {
            UserDefaults.standard.set(true, forKey: "shared-fixture-mode")
            return true
        }
    }
    @MainActor final class Other: XCTestCase {
        func testObserve() { XCTAssertFalse(UserDefaults.standard.bool(forKey: "shared-fixture-mode")) }
    }
    """
    if scenario == "safe" {
        before = before.replacingOccurrences(of: "UserDefaults.standard.set(true, forKey: \"shared-fixture-mode\")", with: "")
    }
    if scenario == "transitive" {
        before = before.replacingOccurrences(of: "private func mutateSDKState() -> Bool {", with: "private func mutateSDKState() -> Bool { return nestedMutation() }\n    private func nestedMutation() -> Bool {")
    }
    if scenario == "recursive" {
        before = before.replacingOccurrences(of: "UserDefaults.standard.set(true, forKey: \"shared-fixture-mode\")", with: "return mutateSDKState()")
    }
    if scenario == "caller" {
        before = before.replacingOccurrences(of: "func testCaller() { candidate() }", with: "func testCaller() { wrapper() }\n    private func wrapper() { candidate(); mutateSDKState() }")
    }
    let after = before.replacingOccurrences(of: "XCTAssertTrue(true)", with: scenario == "caller" ? "XCTAssertTrue(true); XCTAssertFalse(false)" : "XCTAssertTrue(true); XCTAssertTrue(mutateSDKState())")
    let tests = ["UI/Suite/testCaller()", "UI/Other/testObserve()"]
    let current = try boundaryGraph(["UI.swift": after], tests: tests, root: root)
    let base = ["UI:UI.swift": SwiftSourceSnapshot.parse(before, path: "UI.swift", module: "UI")]
    let report = XcodeHeadOnlySelector.select(current: current, source: .init(base: base, mappings: current.mappings), changes: [.init(path: "UI.swift")], baseRevision: "base")
    if scenario == "safe" {
        #expect(report.selectedTests == [tests[0]])
        #expect(report.diagnostics.isEmpty)
    } else {
        #expect(report.selectedTests == tests.sorted())
        #expect(report.diagnostics.contains { $0.code == "head_only_helper_callee_effects" })
    }
}
