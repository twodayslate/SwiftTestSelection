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

@Test(arguments: ["sameFile", "otherFile", "baseOnly"])
func privateHelperRejectsInheritedOverloadBinding(scenario: String) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("review57-binding-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    var before = """
    import XCTest
    @MainActor class Base: XCTestCase {
        func action(_ value: Int) -> Bool {
            UserDefaults.standard.set(true, forKey: "shared-mode")
            return true
        }
    }
    @MainActor final class Suite: Base {
        func testCaller() { candidate() }
        private func candidate() {
            XCTAssertTrue(true)
        }
        private func action(_ value: String) -> Bool { return true }
    }
    @MainActor final class Other: XCTestCase {
        func testObserve() { XCTAssertFalse(UserDefaults.standard.bool(forKey: "shared-mode")) }
    }
    """
    let inherited = """
    @MainActor class Base: XCTestCase {
        func action(_ value: Int) -> Bool {
            UserDefaults.standard.set(true, forKey: "shared-mode")
            return true
        }
    }
    """
    if scenario == "baseOnly" {
        before = before.replacingOccurrences(of: "XCTAssertTrue(true)", with: "XCTAssertTrue(action(\"value\"))")
    }
    var after = scenario == "baseOnly"
        ? before.replacingOccurrences(of: inherited, with: "@MainActor class Base: XCTestCase {}")
            .replacingOccurrences(of: "XCTAssertTrue(action(\"value\"))", with: "XCTAssertTrue(action(\"value\")); XCTAssertTrue(true)")
        : before.replacingOccurrences(of: "XCTAssertTrue(true)", with: "XCTAssertTrue(true); XCTAssertTrue(action(1))")
    var files: [String: String] = [:], base: [String: SwiftSourceSnapshot] = [:]
    if scenario == "otherFile" {
        before = before.replacingOccurrences(of: inherited, with: "")
        after = after.replacingOccurrences(of: inherited, with: "")
        files["Base.swift"] = "import XCTest\n" + inherited
        base["UI:Base.swift"] = .parse(files["Base.swift"]!, path: "Base.swift", module: "UI")
    }
    files["UI.swift"] = after
    let tests = ["UI/Suite/testCaller()", "UI/Other/testObserve()"]
    let current = try boundaryGraph(files, tests: tests, root: root)
    base["UI:UI.swift"] = .parse(before, path: "UI.swift", module: "UI")
    let report = XcodeHeadOnlySelector.select(current: current, source: .init(base: base, mappings: current.mappings), changes: [.init(path: "UI.swift")], baseRevision: "base")
    let graph = current.dependencies!
    let effect = Set(graph.functions.values.filter { $0.name.contains("Base.action(") }.map(\.id))
    if scenario != "baseOnly" { #expect(DependencyIndex(graph).paths(to: effect).path(from: graph.tests[tests[0]]!) != nil) }
    #expect(report.selectedTests == tests.sorted())
    #expect(report.diagnostics.contains { $0.code == "head_only_helper_callee_effects" })
}

@Test func sdkHelperScopesAuditSourcesMovedToAnotherTarget() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("review57-target-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let tests = ["UI/Sharing/testChange()", "UI/Sharing/testAnother()", "UI/Notes/testUnrelated()"]
    let files = ["Waiting.swift": newSDKQuery, "Tests.swift": sdkQueryCallers]
    var current = try boundaryGraph(files, tests: tests, root: root)
    let movedHead = "func unrelated() {}"
    try Data(movedHead.utf8).write(to: root.appendingPathComponent("Moved.swift"))
    let sil = root.appendingPathComponent("Other.sil")
    _ = try CommandRunner.run("xcrun", ["swiftc", "-emit-sil", "-whole-module-optimization", "-Onone", "-g", "-module-name", "Other", root.appendingPathComponent("Moved.swift").path, "-o", sil.path], at: root)
    let parsed = try SILParser.parse(file: sil, module: "Other", sourceRoot: root)
    current.dependencies!.functions.merge(parsed.functions) { _, new in new }
    current.targets.append(.init(name: "Other", productType: "com.apple.product-type.framework", sourceFiles: ["Moved.swift"]))
    current.modules["Other"] = "Other"
    current.sources["Other:Moved.swift"] = .parse(movedHead, path: "Moved.swift", module: "Other")
    let movedBase = "import XCTest\n@MainActor func oldRoute() { XCTAssertTrue(XCUIApplication().buttons[\"toggle\"].checkValue(\"1\")) }"
    let baseTests = sdkQueryCallers.replacingOccurrences(of: "func testUnrelated() { XCTAssertTrue(evaluate { true }) }", with: "func testUnrelated() { oldRoute() }")
    for (path, text) in ["Waiting.swift": oldSDKQuery, "Tests.swift": baseTests, "Moved.swift": movedBase] {
        try Data(text.utf8).write(to: root.appendingPathComponent(path))
    }
    try JSONEncoder().encode(current.mappings).write(to: root.appendingPathComponent(".swift-test-selection.json"))
    _ = try CommandRunner.run("git", ["init", "-q"], at: root)
    _ = try CommandRunner.run("git", ["add", "Waiting.swift", "Tests.swift", "Moved.swift", ".swift-test-selection.json"], at: root)
    _ = try CommandRunner.run("git", ["-c", "user.name=Tests", "-c", "user.email=tests@example.invalid", "commit", "-qm", "base"], at: root)
    for (path, text) in files.merging(["Moved.swift": movedHead], uniquingKeysWith: { _, new in new }) {
        try Data(text.utf8).write(to: root.appendingPathComponent(path))
    }
    let source = try XcodeHeadOnlySources.read(current: current, changes: [.init(path: "Waiting.swift")], base: "HEAD", root: root, mappingPath: ".swift-test-selection.json")
    #expect(source.base["Other:Moved.swift"]?.identifierNames?.contains("checkValue") == true)
    let scopes = try XcodeHeadOnlySelector.scopedReports(current: current,
        requests: .init(scopes: [.init(name: "waiting", paths: ["Waiting.swift"])]),
        changes: [.init(path: "Waiting.swift"), .init(path: "Tests.swift"), .init(path: "Moved.swift")],
        baseRevision: "HEAD", headRevision: "head", root: root, mappingPath: ".swift-test-selection.json",
        documentation: [], buildEvidenceFailure: nil)
    let report = try #require(scopes.first?.report)
    #expect(report.selectedTests == tests.sorted())
    #expect(report.diagnostics.contains { $0.code == "head_only_sdk_helper_boundary" })
}

@Test func privateHelperRejectsUnprovenCompiledCallee() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("helper-compiled-effects-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let before = """
    import XCTest
    @MainActor final class Suite: XCTestCase {
        func testCaller() { candidate(XCUIApplication().buttons["toggle"]) }
        private func candidate(_ element: XCUIElement) {
            XCTAssertTrue(true)
        }
    }
    @MainActor extension XCUIElement {
        func changeMode() -> Bool {
            UserDefaults.standard.set(true, forKey: "shared-mode")
            return true
        }
    }
    @MainActor final class Other: XCTestCase {
        func testObserve() { XCTAssertFalse(UserDefaults.standard.bool(forKey: "shared-mode")) }
    }
    """
    let after = before.replacingOccurrences(of: "XCTAssertTrue(true)", with: "XCTAssertTrue(true); XCTAssertTrue(element.changeMode())")
    let tests = ["UI/Suite/testCaller()", "UI/Other/testObserve()"]
    var current = try boundaryGraph(["UI.swift": after], tests: tests, root: root)
    current = try JSONDecoder().decode(XcodeTestGraph.self, from: JSONEncoder().encode(current))
    let base = ["UI:UI.swift": SwiftSourceSnapshot.parse(before, path: "UI.swift", module: "UI")]
    let report = XcodeHeadOnlySelector.select(current: current, source: .init(base: base, mappings: current.mappings), changes: [.init(path: "UI.swift")], baseRevision: "base")
    #expect(report.selectedTests == tests.sorted())
    #expect(report.diagnostics.contains { $0.code == "head_only_helper_callee_effects" })
}

@Test(arguments: ["plain", "name", "label"])
func privateSDKCalleeRejectsHistoricalOverload(escaping: String) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("review57-sdk-binding-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let before = """
    import XCTest
    @MainActor final class Suite: XCTestCase {
        func testCaller() { candidate(XCUIApplication().buttons["toggle"]) }
        private func candidate(_ element: XCUIElement) {
            XCTAssertTrue(element.ready(timeout: 1))
        }
    }
    @MainActor final class Other: XCTestCase {
        func testObserve() { XCTAssertFalse(UserDefaults.standard.bool(forKey: "shared-mode")) }
    }
    """
    let after = before.replacingOccurrences(of: "XCTAssertTrue(element.ready(timeout: 1))", with: "XCTAssertTrue(element.ready(timeout: 1)); XCTAssertTrue(true)")
    let headSDK = """
    import XCTest
    @MainActor extension XCUIElement {
        func ready(timeout: TimeInterval) -> Bool { waitForExistence(timeout: timeout) }
    }
    """
    let oldSDK = headSDK + """

    @MainActor extension XCUIElement {
        func \(escaping == "name" ? "`ready`" : "ready")(\(escaping == "label" ? "`timeout`" : "timeout"): Int) -> Bool {
            UserDefaults.standard.set(true, forKey: "shared-mode")
            return true
        }
    }
    """
    let tests = ["UI/Suite/testCaller()", "UI/Other/testObserve()"]
    var old = try boundaryGraph(["UI.swift": before, "SDK.swift": oldSDK], tests: tests, root: root)
    let current = try boundaryGraph(["UI.swift": after, "SDK.swift": headSDK], tests: tests, root: root)
    let oldGraph = old.dependencies!
    let matches = oldGraph.functions.values.filter { $0.name.contains("ready") }
    let effect = Set(matches.filter { $0.id.contains("Si") }.map(\.id))
    #expect(!effect.isEmpty)
    #expect(DependencyIndex(oldGraph).paths(to: effect).path(from: oldGraph.tests[tests[0]]!) != nil)
    // Model a saved pre-normalization snapshot, where signatures retained raw
    // name/label spelling. Selection must normalize these without recapture.
    if escaping != "plain" {
        for i in old.sources["UI:SDK.swift"]!.units.indices {
            if old.sources["UI:SDK.swift"]!.units[i].fingerprint.contains("`ready`") ||
                old.sources["UI:SDK.swift"]!.units[i].fingerprint.contains("`timeout`") {
                old.sources["UI:SDK.swift"]!.units[i].helperReferenceSignature = escaping == "name" ? "`ready`(timeout:)" : "ready(`timeout`:)"
            }
        }
    }
    #expect(old.sources["UI:SDK.swift"]!.units.filter { $0.helperReferenceSignature?.contains("`") == true }.count == (escaping == "plain" ? 0 : 1))
    old = try JSONDecoder().decode(XcodeTestGraph.self, from: JSONEncoder().encode(old))
    let report = XcodeHeadOnlySelector.select(current: current, source: .init(base: old.sources, mappings: current.mappings), changes: [.init(path: "UI.swift")], baseRevision: "base")
    #expect(report.selectedTests == tests.sorted())
    #expect(report.diagnostics.contains { $0.code == "head_only_helper_callee_effects" })
}

@Test func sdkWaitRejectsInheritedProjectOverload() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("review57-sdk-wait-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let before = """
    import XCTest
    @MainActor extension XCUIElement {
        func checkWait() -> Bool { waitForExistence(timeout: 1.0) }
    }
    """
    let after = before.replacingOccurrences(of: "timeout: 1.0", with: "timeout: 1")
    let support = """
    import XCTest
    @MainActor extension NSObject {
        func waitForExistence(timeout: Int) -> Bool {
            UserDefaults.standard.set(true, forKey: "shared-mode")
            return true
        }
    }
    @MainActor final class Suite: XCTestCase {
        func testCaller() { XCTAssertTrue(XCUIApplication().buttons["toggle"].checkWait()) }
    }
    @MainActor final class Other: XCTestCase {
        func testObserve() { XCTAssertFalse(UserDefaults.standard.bool(forKey: "shared-mode")) }
    }
    """
    let tests = ["UI/Suite/testCaller()", "UI/Other/testObserve()"]
    let old = try boundaryGraph(["Waiting.swift": before, "Tests.swift": support], tests: tests, root: root)
    let current = try boundaryGraph(["Waiting.swift": after, "Tests.swift": support], tests: tests, root: root)
    let graph = current.dependencies!
    let ids = Set(graph.functions.values.filter { $0.name == "NSObject.waitForExistence(timeout:)" }.map(\.id))
    #expect(!ids.isEmpty)
    #expect(DependencyIndex(graph).paths(to: ids).path(from: graph.tests[tests[0]]!) != nil)
    #expect(DependencyIndex(old.dependencies!).paths(to: ids).path(from: old.dependencies!.tests[tests[0]]!) == nil)
    let helper = try #require(current.sources["UI:Waiting.swift"]?.units.first { $0.sdkTestHelper != nil })
    let oldHelper = try #require(old.sources["UI:Waiting.swift"]?.units.first { $0.sdkTestHelper != nil })
    #expect(SDKTestHelperIsolation.compilerEffectBlocker(oldHelper, graph: old.dependencies!, index: DependencyIndex(old.dependencies!)) == nil)
    #expect(SDKTestHelperIsolation.compilerEffectBlocker(helper, graph: graph, index: DependencyIndex(graph))?.contains("Project implementation") == true)
    let report = XcodeHeadOnlySelector.select(current: current, source: .init(base: old.sources, mappings: current.mappings), changes: [.init(path: "Waiting.swift")], baseRevision: "base")
    #expect(report.selectedTests == tests.sorted())
    #expect(report.diagnostics.contains { $0.code == "head_only_sdk_helper_boundary" })
}

@Test(arguments: [false, true])
func sdkPredicateRejectsHistoricalInheritedOverload(escaped: Bool) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("review57-predicate-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let before = newSDKQuery.replacingOccurrences(of: "self.exists && self.value", with: "self.value")
    let support = """
    import XCTest
    @MainActor extension NSObject {
        func \(escaped ? "`evaluate`" : "evaluate")(with element: XCUIElement) -> Bool {
            UserDefaults.standard.set(true, forKey: "shared-mode")
            return true
        }
    }
    """
    let callers = """
    import XCTest
    @MainActor final class Suite: XCTestCase {
        func testCaller() { XCTAssertTrue(XCUIApplication().buttons["toggle"].checkValue("1")) }
    }
    @MainActor final class Other: XCTestCase {
        func testObserve() { XCTAssertFalse(UserDefaults.standard.bool(forKey: "shared-mode")) }
    }
    """
    let tests = ["UI/Suite/testCaller()", "UI/Other/testObserve()"]
    let old = try boundaryGraph(["Waiting.swift": before, "Tests.swift": callers, "Support.swift": support], tests: tests, root: root)
    let captured = try boundaryGraph(["Waiting.swift": newSDKQuery, "Tests.swift": callers, "Support.swift": "import XCTest"], tests: tests, root: root)
    let current = try JSONDecoder().decode(XcodeTestGraph.self, from: JSONEncoder().encode(captured))
    let oldGraph = old.dependencies!
    let ids = Set(oldGraph.functions.values.filter { $0.name == "NSObject.evaluate(with:)" }.map(\.id))
    #expect(!ids.isEmpty)
    #expect(DependencyIndex(oldGraph).paths(to: ids).path(from: oldGraph.tests[tests[0]]!) != nil)
    #expect(DependencyIndex(current.dependencies!).paths(to: ids).path(from: current.dependencies!.tests[tests[0]]!) == nil)
    let report = XcodeHeadOnlySelector.select(current: current, source: .init(base: old.sources, mappings: current.mappings), changes: [.init(path: "Waiting.swift")], baseRevision: "base")
    #expect(report.selectedTests == tests.sorted())
    #expect(report.diagnostics.contains { $0.code == "head_only_sdk_helper_boundary" })
}

@Test(arguments: [50, 100], [false, true])
func sdkHelperCallerDepthUsesWorkQueue(depth: Int, cycle: Bool) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("review57-sdk-depth-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let routes = (0..<depth).map { i in
        let call = i == depth - 1 ? "XCTAssertTrue(app.buttons[\"toggle\"].checkValue(\"1\"))" : "step\(i+1)(app)"
        return "@MainActor func step\(i)(_ app: XCUIApplication) { \(call)\(cycle && i == depth - 1 ? "; step0(app)" : "") }"
    }.joined(separator: "\n")
    // A shared upstream caller exercises completed-node reuse as well as
    // deep traversal; the optional back edge must still reject cycles.
    let callers = "import XCTest\n" + routes + """

    @MainActor func left(_ app: XCUIApplication) { step0(app) }
    @MainActor func right(_ app: XCUIApplication) { step0(app) }
    @MainActor func shared(_ app: XCUIApplication) { left(app); right(app) }
    @MainActor final class Suite: XCTestCase {
        func testCaller() { shared(XCUIApplication()) }
        func testUnrelated() { XCTAssertTrue(true) }
    }
    """
    let tests = ["UI/Suite/testCaller()", "UI/Suite/testUnrelated()"]
    let current = try boundaryGraph(["Waiting.swift": newSDKQuery, "Tests.swift": callers], tests: tests, root: root)
    var base = current.sources
    base["UI:Waiting.swift"] = .parse(oldSDKQuery, path: "Waiting.swift", module: "UI")
    let report = XcodeHeadOnlySelector.select(current: current, source: .init(base: base, mappings: current.mappings), changes: [.init(path: "Waiting.swift")], baseRevision: "base")
    if cycle {
        #expect(report.selectedTests == tests)
        #expect(report.diagnostics.contains { $0.code == "head_only_sdk_helper_boundary" })
    } else {
        #expect(report.selectedTests == [tests[0]])
        #expect(report.diagnostics.isEmpty, "\(report.diagnostics)")
    }
}

@Test(arguments: ["exists", "value", "isEnabled", "isHittable", "isSelected", "evaluate", "wait", "waitForExistence", "waitForNonExistence", "init"], ["head", "base", "unownedBase"])
func sdkQueryMemberAuditIncludesHistoricalAndAliasedOwners(member: String, location: String) {
    for owner in ["NSObject", "`NSObject`", "Alias", "`Alias`"] {
        let spelling = owner.hasPrefix("`") ? "`\(member)`" : member
        let declaration = member == "init" ? "convenience init(custom: Int) { self.init() }" : "var \(spelling): Bool { true }"
        let source = "import XCTest\ntypealias Alias = NSObject\nextension \(owner) { \(declaration) }"
        let snapshot = SwiftSourceSnapshot.parse(source, path: "Support.swift", module: "UI")
        var current = XcodeTestGraph(targets: [], tests: [])
        current.modules = ["UI": "UI"]
        if location == "head" { current.sources = ["UI:Support.swift": snapshot] }
        let reason = SDKTestHelperIsolation.environmentBlocker(current: current,
            base: location == "base" ? ["UI:Support.swift": snapshot] : [:],
            unownedBase: location == "unownedBase" ? ["Support.swift": snapshot] : [:], queriedMembers: [member])
        #expect(reason == "Project member can replace a trusted SDK query at base or head")
    }
}

@Test(arguments: ["struct", "class", "enum", "protocol", "extension"])
func sdkQueryMemberAuditDistinguishesConcreteOwners(kind: String) {
    for owner in ["Other", "`Other`"] {
        let member = kind == "protocol" ? "var value: Bool { get }" : "var value: Bool { true }"
        let snapshot = SwiftSourceSnapshot.parse("\(kind) \(owner) { \(member) }", path: "Other.swift", module: "UI")
        var current = XcodeTestGraph(targets: [], tests: [])
        current.sources = ["UI:Other.swift": snapshot]
        let reason = SDKTestHelperIsolation.environmentBlocker(current: current, base: [:], queriedMembers: ["value"])
        #expect((reason == nil) == ["struct", "class", "enum"].contains(kind))
    }
}

@Test func sdkQueryMemberAuditKeepsNominalEvidenceRevisionLocal() {
    let path = "Owner.swift"
    var current = XcodeTestGraph(targets: [], tests: [])
    current.sources = ["UI:" + path: .parse("struct Owner { var value: Bool { true } }", path: path, module: "UI")]
    let base = ["UI:" + path: SwiftSourceSnapshot.parse("protocol Owner { var value: Bool { get } }", path: path, module: "UI")]
    #expect(SDKTestHelperIsolation.environmentBlocker(current: current, base: base, queriedMembers: ["value"]) != nil)
    let conditional = """
    #if FLAG
    struct Owner { var value: Bool { true } }
    #else
    protocol Owner { var value: Bool { get } }
    #endif
    """
    current.sources = ["UI:" + path: .parse(conditional, path: path, module: "UI")]
    #expect(SDKTestHelperIsolation.environmentBlocker(current: current, base: [:], queriedMembers: ["value"]) != nil)
}

@Test(arguments: ["fresh", "saved", "removedCaller"])
func sdkCallerSignaturesNormalizeEscapedNamesAndLabels(scenario: String) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("sdk-signatures-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let before = """
    import XCTest
    @MainActor extension XCUIElement {
        func checkWait(timeout: TimeInterval) -> Bool { waitForExistence(timeout: timeout) }
    }
    """
    let after = before.replacingOccurrences(of: "{ waitForExistence", with: "{ exists && waitForExistence")
    let callers = """
    import XCTest
    @MainActor final class Suite: XCTestCase {
        func testPlain() { XCTAssertTrue(XCUIApplication().buttons["toggle"].checkWait(timeout: 1)) }
        func testEscaped() { XCTAssertTrue(XCUIApplication().buttons["toggle"].`checkWait`(`timeout`: 2)) }
        func testUnrelated() { XCTAssertTrue(true) }
    }
    """
    let headCallers = scenario == "removedCaller" ? callers.replacingOccurrences(
        of: "XCTAssertTrue(XCUIApplication().buttons[\"toggle\"].`checkWait`(`timeout`: 2))", with: "XCTAssertTrue(true)") : callers
    let tests = ["UI/Suite/testPlain()", "UI/Suite/testEscaped()", "UI/Suite/testUnrelated()"]
    var old = try boundaryGraph(["Waiting.swift": before, "Tests.swift": callers], tests: tests, root: root)
    var current = try boundaryGraph(["Waiting.swift": after, "Tests.swift": headCallers], tests: tests, root: root)
    #expect(old.sources["UI:Tests.swift"]?.helperReferences?["checkWait(timeout:)"]?.callers.count == 2)
    #expect(old.sources["UI:Tests.swift"]?.helperReferences?["`checkWait`(`timeout`:)"] == nil)
    if scenario != "fresh" {
        // Older captures split callers among raw keys. Preserve the aggregate
        // name entry but partition signature entries exactly as those captures did.
        func legacy(_ snapshot: SwiftSourceSnapshot) throws -> SwiftSourceSnapshot {
            var snapshot = snapshot
            let line = try #require(snapshot.units.first { $0.helperCallableName == "testEscaped" }?.region.startLine)
            var plain = try #require(snapshot.helperReferences?["checkWait(timeout:)"])
            var escaped = plain
            escaped.callers.formIntersection([line])
            plain.callers.remove(line)
            snapshot.helperReferences!["checkWait(timeout:)"] = plain
            snapshot.helperReferences!["`checkWait`(`timeout`:)"] = escaped
            return snapshot
        }
        old.sources["UI:Tests.swift"] = try legacy(old.sources["UI:Tests.swift"]!)
        current.sources["UI:Tests.swift"] = try legacy(current.sources["UI:Tests.swift"]!)
        old = try JSONDecoder().decode(XcodeTestGraph.self, from: JSONEncoder().encode(old))
        current = try JSONDecoder().decode(XcodeTestGraph.self, from: JSONEncoder().encode(current))
    }
    let report = XcodeHeadOnlySelector.select(current: current, source: .init(base: old.sources, mappings: current.mappings),
        changes: [.init(path: "Waiting.swift")], baseRevision: "base")
    if scenario == "removedCaller" {
        #expect(report.selectedTests == tests.sorted())
        #expect(report.diagnostics.contains { $0.code == "head_only_sdk_helper_boundary" })
    } else {
        #expect(report.selectedTests == tests.prefix(2).sorted())
        #expect(report.diagnostics.isEmpty, "\(report.diagnostics)")
    }
}

@Test func canonicalSDKReferencesMergeAllEvidence() {
    var plain = SDKTestHelperSyntax.References()
    plain.declarations = [2]; plain.callers = [5]
    var escaped = SDKTestHelperSyntax.References()
    escaped.declarations = [8]; escaped.callers = [11]
    escaped.unsupported = true; escaped.unsupportedLines = [14]
    let merged = SDKTestHelperSyntax.canonicalReferences(["ready(timeout:)": plain, "`ready`(`timeout`:)": escaped])
    #expect(merged.count == 1)
    #expect(merged["ready(timeout:)"]?.declarations == [2, 8])
    #expect(merged["ready(timeout:)"]?.callers == [5, 11])
    #expect(merged["ready(timeout:)"]?.unsupported == true)
    #expect(merged["ready(timeout:)"]?.unsupportedLines == [14])
}
