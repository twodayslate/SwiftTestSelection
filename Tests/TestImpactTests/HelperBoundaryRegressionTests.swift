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


private func boundaryGraph(_ files: [String: String], tests: [String], root: URL, compilerArguments: [String] = []) throws -> XcodeTestGraph {
    for (path, text) in files { try Data(text.utf8).write(to: root.appendingPathComponent(path)) }
    let platform = try CommandRunner.run("xcrun", ["--sdk", "macosx", "--show-sdk-platform-path"], at: root).text.trimmingCharacters(in: .whitespacesAndNewlines)
    let sil = root.appendingPathComponent("UI.sil")
    _ = try CommandRunner.run("xcrun", ["swiftc", "-emit-sil", "-whole-module-optimization", "-Onone", "-g", "-module-name", "UI",
        "-F", platform + "/Developer/Library/Frameworks", "-I", platform + "/Developer/usr/lib"] + compilerArguments + files.keys.sorted().map { root.appendingPathComponent($0).path } + ["-o", sil.path], at: root)
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

@Test(arguments: ["plain", "escaped", "generic"])
func sdkAssertionShadowCannotHideEscapingCaller(scenario: String) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("assertion-shadow-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    var callers = """
    import XCTest
    @MainActor var saved: (() -> Bool)?
    struct DeferredAssertion {
        @MainActor func callAsFunction(_ value: @autoclosure @escaping () -> Bool) { saved = value }
    }
    @MainActor func arm(_ app: XCUIApplication, XCTAssertTrue: DeferredAssertion) {
        XCTAssertTrue(app.buttons["toggle"].checkValue("1"))
    }
    @MainActor final class Suite: XCTestCase {
        func testArm() { arm(XCUIApplication(), XCTAssertTrue: DeferredAssertion()) }
        func testConsume() { XCTAssertTrue(saved?() ?? false) }
    }
    """
    if scenario == "escaped" {
        callers = callers.replacingOccurrences(of: "XCTAssertTrue: DeferredAssertion", with: "`XCTAssertTrue`: DeferredAssertion")
    } else if scenario == "generic" {
        callers = """
        import XCTest
        @MainActor var saved: (() -> Bool)?
        class DeferredAssertion {
            @MainActor required init(_ value: @autoclosure @escaping () -> Bool) { saved = value }
        }
        @MainActor func arm<XCTAssertTrue: DeferredAssertion>(_ app: XCUIApplication, assertion: XCTAssertTrue.Type) {
            XCTAssertTrue(app.buttons["toggle"].checkValue("1"))
        }
        @MainActor final class Suite: XCTestCase {
            func testArm() { arm(XCUIApplication(), assertion: DeferredAssertion.self) }
            func testConsume() { XCTAssertTrue(saved?() ?? false) }
        }
        """
    }
    let tests = ["UI/Suite/testArm()", "UI/Suite/testConsume()"]
    let current = try boundaryGraph(["Waiting.swift": newSDKQuery, "Tests.swift": callers], tests: tests, root: root)
    #expect(current.sources["UI:Tests.swift"]?.sdkHelperNamesUnshadowed == false)
    var base = current.sources
    base["UI:Waiting.swift"] = .parse(oldSDKQuery, path: "Waiting.swift", module: "UI")
    let report = XcodeHeadOnlySelector.select(current: current, source: .init(base: base, mappings: current.mappings), changes: [.init(path: "Waiting.swift")], baseRevision: "base")
    #expect(report.selectedTests == tests.sorted())
    #expect(report.diagnostics.contains { $0.code == "head_only_sdk_helper_boundary" })
    // Version 3 captures incorrectly marked these bindings safe. Do not reuse
    // that proof, even when the graph's other fields claim to be unshadowed.
    var legacy = current
    var legacyBase = base
    for key in legacy.sources.keys {
        legacy.sources[key]!.sdkHelperNamesUnshadowed = true
        legacy.sources[key]!.helperNamesUnshadowed = true
        legacyBase[key]!.sdkHelperNamesUnshadowed = true
        legacyBase[key]!.helperNamesUnshadowed = true
        for i in legacy.sources[key]!.units.indices { legacy.sources[key]!.units[i].sdkTestHelper?.version = 3 }
        for i in legacyBase[key]!.units.indices { legacyBase[key]!.units[i].sdkTestHelper?.version = 3 }
    }
    legacy = try JSONDecoder().decode(XcodeTestGraph.self, from: JSONEncoder().encode(legacy))
    let stale = XcodeHeadOnlySelector.select(current: legacy, source: .init(base: legacyBase, mappings: current.mappings),
        changes: [.init(path: "Waiting.swift")], baseRevision: "base")
    #expect(stale.selectedTests == tests.sorted())
    #expect(stale.diagnostics.contains { $0.code == "head_only_sdk_helper_boundary" && $0.message.contains("recapture") })
}

@Test(arguments: [
    "func f(XCTAssertTrue: Int) {}",
    "func f(_ `XCTAssertTrue`: Int) {}",
    "func f<XCTAssertTrue>(_ value: XCTAssertTrue) {}",
    "let body = { (XCTAssertTrue: Int) in XCTAssertTrue }",
    "let body = { XCTAssertTrue in XCTAssertTrue }",
    "let body = { [XCTAssertTrue = replacement] in XCTAssertTrue }",
    "protocol P { associatedtype XCTAssertTrue }"
])
func reservedSDKNamesRejectLexicalBindings(source: String) {
    let snapshot = SwiftSourceSnapshot.parse(source, path: "UI.swift", module: "UI")
    #expect(snapshot.diagnostics.isEmpty)
    #expect(snapshot.sdkHelperNamesUnshadowed == false)
    #expect(snapshot.helperNamesUnshadowed == false)
}

@Test func assertionArgumentLabelAloneDoesNotShadowSDKBinding() {
    let source = "func helper(XCTAssertTrue assertion: Int) { XCTAssertTrue(assertion > 0) }"
    let snapshot = SwiftSourceSnapshot.parse(source, path: "UI.swift", module: "UI")
    #expect(snapshot.diagnostics.isEmpty)
    #expect(snapshot.sdkHelperNamesUnshadowed == true)
    #expect(snapshot.helperNamesUnshadowed == true)
}

@Test(arguments: ["module", "scoped", "reexport", "baseOnly", "local", "direct"])
func sdkImportedAssertionCannotHideEscapingCaller(scenario: String) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("imported-assertion-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let external = """
    @MainActor public var saved: (() -> Bool)?
    @MainActor public func XCTAssertTrue(_ expression: @autoclosure @escaping () -> Bool) { saved = expression }
    """
    let externalPath = root.appendingPathComponent("DeferredAssertions.swift")
    try Data(external.utf8).write(to: externalPath)
    _ = try CommandRunner.run("xcrun", ["swiftc", "-emit-module", "-module-name", "DeferredAssertions", externalPath.path, "-emit-module-path", root.appendingPathComponent("DeferredAssertions.swiftmodule").path], at: root)
    let facade = root.appendingPathComponent("AssertionFacade.swift")
    try Data("@_exported import DeferredAssertions".utf8).write(to: facade)
    _ = try CommandRunner.run("xcrun", ["swiftc", "-emit-module", "-module-name", "AssertionFacade", "-I", root.path,
        facade.path, "-emit-module-path", root.appendingPathComponent("AssertionFacade.swiftmodule").path], at: root)
    var callers = """
    import XCTest
    import DeferredAssertions
    @MainActor func arm(_ app: XCUIApplication) {
        XCTAssertTrue(app.buttons["toggle"].checkValue("1"))
    }
    @MainActor final class Suite: XCTestCase {
        func testArm() { arm(XCUIApplication()) }
        func testConsume() { XCTAssertEqual(saved?() ?? false, true) }
    }
    """
    if scenario == "scoped" { callers = callers.replacingOccurrences(of: "import DeferredAssertions", with: "import DeferredAssertions\nimport func DeferredAssertions.XCTAssertTrue") }
    if scenario == "reexport" { callers = callers.replacingOccurrences(of: "import DeferredAssertions", with: "import AssertionFacade") }
    if scenario == "local" { callers = callers.replacingOccurrences(of: "XCTAssertTrue(app.buttons[\"toggle\"].checkValue(\"1\"))", with: "func query() -> Bool { app.buttons[\"toggle\"].checkValue(\"1\") }; XCTAssertTrue(query())") }
    if scenario == "direct" { callers = callers.replacingOccurrences(of: "XCTAssertTrue(app.buttons[\"toggle\"].checkValue(\"1\"))", with: "app.buttons[\"toggle\"].checkValue(\"1\")") }
    let oldCallers = callers
    if scenario == "baseOnly" {
        callers = callers.replacingOccurrences(of: "import DeferredAssertions", with: "")
            .replacingOccurrences(of: "saved?() ?? false", with: "true")
    }
    let tests = ["UI/Suite/testArm()", "UI/Suite/testConsume()"]
    _ = try boundaryGraph(["Waiting.swift": oldSDKQuery, "Tests.swift": oldCallers], tests: tests, root: root, compilerArguments: ["-I", root.path])
    var current = try boundaryGraph(["Waiting.swift": newSDKQuery, "Tests.swift": callers], tests: tests, root: root, compilerArguments: ["-I", root.path])
    current = try JSONDecoder().decode(XcodeTestGraph.self, from: JSONEncoder().encode(current))
    var base = current.sources
    base["UI:Waiting.swift"] = .parse(oldSDKQuery, path: "Waiting.swift", module: "UI")
    base["UI:Tests.swift"] = .parse(oldCallers, path: "Tests.swift", module: "UI")
    let report = XcodeHeadOnlySelector.select(current: current, source: .init(base: base, mappings: current.mappings), changes: [.init(path: "Waiting.swift")], baseRevision: "base")
    if scenario == "direct" {
        #expect(report.selectedTests == [tests[0]])
        #expect(report.diagnostics.isEmpty)
    } else {
        #expect(report.selectedTests == tests.sorted())
        #expect(report.diagnostics.contains { $0.code == "head_only_sdk_helper_boundary" && $0.message.contains("untrusted caller imports") })
    }
    // Simulate version 4, which marked imported wrappers as nonescaping. Its
    // source evidence must never bypass the new import check after a round trip.
    var legacy = current
    var legacyBase = base
    for key in legacy.sources.keys {
        for i in legacy.sources[key]!.units.indices { legacy.sources[key]!.units[i].sdkTestHelper?.version = 4 }
        for i in legacyBase[key]!.units.indices { legacyBase[key]!.units[i].sdkTestHelper?.version = 4 }
        for reference in legacy.sources[key]!.helperReferences!.keys {
            legacy.sources[key]!.helperReferences![reference]!.untrustedWrapperImports = nil
            legacy.sources[key]!.helperReferences![reference]!.unsupported = false
            legacy.sources[key]!.helperReferences![reference]!.unsupportedLines = []
        }
    }
    legacy = try JSONDecoder().decode(XcodeTestGraph.self, from: JSONEncoder().encode(legacy))
    let stale = XcodeHeadOnlySelector.select(current: legacy, source: .init(base: legacyBase, mappings: current.mappings),
        changes: [.init(path: "Waiting.swift")], baseRevision: "base")
    #expect(stale.selectedTests == tests.sorted())
    #expect(stale.diagnostics.contains { $0.code == "head_only_sdk_helper_boundary" && $0.message.contains("recapture") })
}

@Test(arguments: ["import UIKit", "import External", "import func External.XCTAssertTrue", "@testable import External", "@_exported import External"])
func sdkWrapperImportBoundaryIncludesNegation(imported: String) {
    let source = """
    import XCTest
    \(imported)
    func arm() { if !query() { return }; XCTAssertTrue(query()) }
    """
    let snapshot = SwiftSourceSnapshot.parse(source, path: "Caller.swift", module: "UI")
    #expect(snapshot.diagnostics.isEmpty)
    #expect(snapshot.helperReferences?["query"]?.unsupported == (imported != "import UIKit"))
    #expect((snapshot.helperReferences?["query"]?.untrustedWrapperImports == true) == (imported != "import UIKit"))
}

@Test func privateAttachmentRejectsImportedSDKName() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("imported-attachment-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let external = """
    import XCTest
    @MainActor public var savedFlag = false
    public struct XCTAttachment {
        @MainActor public init(screenshot: XCUIScreenshot) { savedFlag = true }
    }
    """
    let path = root.appendingPathComponent("AttachmentSupport.swift")
    try Data(external.utf8).write(to: path)
    let platform = try CommandRunner.run("xcrun", ["--sdk", "macosx", "--show-sdk-platform-path"], at: root).text.trimmingCharacters(in: .whitespacesAndNewlines)
    _ = try CommandRunner.run("xcrun", ["swiftc", "-emit-module", "-module-name", "AttachmentSupport", "-F", platform + "/Developer/Library/Frameworks", "-I", platform + "/Developer/usr/lib", path.path, "-emit-module-path", root.appendingPathComponent("AttachmentSupport.swiftmodule").path], at: root)
    let before = """
    import XCTest
    import AttachmentSupport
    import struct AttachmentSupport.XCTAttachment
    @MainActor final class Suite: XCTestCase {
        func testArm() { capture(XCUIApplication()) }
        private func capture(_ app: XCUIApplication) { XCTAssertTrue(true) }
        func testConsume() { XCTAssertTrue(XCUIApplication().exists && savedFlag) }
    }
    """
    let after = before.replacingOccurrences(of: "{ XCTAssertTrue(true) }", with: "{ XCTAssertTrue(true); XCTAssertNotNil(XCTAttachment(screenshot: app.screenshot())) }")
    let tests = ["UI/Suite/testArm()", "UI/Suite/testConsume()"]
    var current = try boundaryGraph(["Tests.swift": after], tests: tests, root: root, compilerArguments: ["-I", root.path])
    current = try JSONDecoder().decode(XcodeTestGraph.self, from: JSONEncoder().encode(current))
    let base = ["UI:Tests.swift": SwiftSourceSnapshot.parse(before, path: "Tests.swift", module: "UI")]
    let report = XcodeHeadOnlySelector.select(current: current, source: .init(base: base, mappings: current.mappings), changes: [.init(path: "Tests.swift")], baseRevision: "base")
    #expect(report.selectedTests == tests.sorted())
    #expect(report.diagnostics.contains { $0.code == "head_only_helper_callee_effects" })
    var stale = current
    var staleBase = base
    for key in stale.sources.keys {
        for i in stale.sources[key]!.units.indices {
            stale.sources[key]!.units[i].privateTestHelper?.proofVersion = 5
            stale.sources[key]!.units[i].privateTestHelper?.calleeEffectsSupported = true
        }
        for i in staleBase[key]!.units.indices {
            staleBase[key]!.units[i].privateTestHelper?.proofVersion = 5
            staleBase[key]!.units[i].privateTestHelper?.calleeEffectsSupported = true
        }
    }
    stale = try JSONDecoder().decode(XcodeTestGraph.self, from: JSONEncoder().encode(stale))
    let legacy = XcodeHeadOnlySelector.select(current: stale, source: .init(base: staleBase, mappings: current.mappings),
        changes: [.init(path: "Tests.swift")], baseRevision: "base")
    #expect(legacy.selectedTests == tests.sorted())
    #expect(legacy.diagnostics.contains { $0.code == "head_only_helper_proof_version" && $0.message.contains("recapture") })
}

@Test func untrustedReexportsInvalidatePrivateSDKNames() {
    let snapshot = SwiftSourceSnapshot.parse("@_exported import AttachmentSupport", path: "Exports.swift", module: "UI")
    #expect(snapshot.helperNamesUnshadowed == false)
}

@Test(arguments: ["initializer", "escaped", "alias", "deleted", "assertion", "transitive", "method", "member", "unrelated"])
func privateAttachmentAuditsHistoricalBindings(scenario: String) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("attachment-history-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    var before = """
    import XCTest
    @MainActor final class Suite: XCTestCase {
        func testCapture() { capture(XCUIApplication()) }
        private func capture(_ app: XCUIApplication) {
            let attachment = XCTAttachment(screenshot: app.screenshot())
            add(attachment)
        }
        func testConsume() { XCTAssertTrue(XCUIApplication().exists && sharedFlag) }
    }
    """
    if scenario == "assertion" {
        before = before.replacingOccurrences(of: "let attachment = XCTAttachment(screenshot: app.screenshot())\n        add(attachment)",
            with: "XCTAssertNotNil(XCTAttachment(screenshot: app.screenshot()))")
    }
    if scenario == "transitive" {
        before = before.replacingOccurrences(of: "private func capture(_ app: XCUIApplication) {",
            with: "private func capture(_ app: XCUIApplication) { record(app) }\n    private func record(_ app: XCUIApplication) {")
    }
    if scenario == "member" {
        before = before.replacingOccurrences(of: "add(attachment)", with: "add(attachment); XCTAssertTrue(attachment.isEqual(attachment))")
    }
    let after = before.replacingOccurrences(of: "private func capture(_ app: XCUIApplication) {",
        with: "private func capture(_ app: XCUIApplication) { XCTAssertTrue(app.exists);")
    var extra = """
    import XCTest
    @MainActor var sharedFlag = false
    extension XCTAttachment {
        @MainActor convenience init(screenshot: XCUIScreenshot) {
            self.init(data: Data(), uniformTypeIdentifier: "public.data")
            sharedFlag = true
        }
    }
    """
    if scenario == "escaped" { extra = extra.replacingOccurrences(of: "extension XCTAttachment", with: "extension `XCTAttachment`") }
    if scenario == "alias" { extra = extra.replacingOccurrences(of: "extension XCTAttachment", with: "typealias AttachmentAlias = XCTAttachment\nextension AttachmentAlias") }
    if scenario == "member" {
        extra = """
        import XCTest
        extension XCTAttachment {
            @MainActor func isEqual(_ other: XCTAttachment) -> Bool { sharedFlag = true; return true }
        }
        """
    }
    if scenario == "method" {
        extra = """
        import XCTest
        @MainActor var sharedFlag = false
        extension XCUIElement {
            @MainActor func screenshot() -> XCUIScreenshot {
                sharedFlag = true
                return XCUIScreen.main.screenshot()
            }
        }
        """
    }
    if scenario == "unrelated" {
        extra = """
        import XCTest
        @MainActor var sharedFlag = false
        class Unrelated: NSObject {
            required override init() { super.init() }
            @MainActor init(screenshot: XCUIScreenshot) { super.init(); sharedFlag = true }
        }
        """
    }
    // Keep state in a surviving file so a deleted overload remains compilable.
    extra = extra.replacingOccurrences(of: "@MainActor var sharedFlag = false", with: "")
    let state = "import XCTest\n@MainActor var sharedFlag = false"
    let tests = ["UI/Suite/testCapture()", "UI/Suite/testConsume()"]
    let old = try boundaryGraph(["Tests.swift": before, "Extra.swift": extra, "State.swift": state], tests: tests, root: root)
    let oldGraph = try #require(old.dependencies)
    let historicalEffects = Set(oldGraph.functions.values.filter { node in
        node.hasProjectRuntimeContext && node.uncertainties.contains("Global state access")
    }.map(\.id))
    let oldPath = DependencyIndex(oldGraph).paths(to: historicalEffects).path(from: oldGraph.tests[tests[0]] ?? [])
    if scenario == "unrelated" { #expect(oldPath == nil) }
    else {
        let path = try #require(oldPath)
        let callee = scenario == "method" ? "XCUIElement.screenshot()" : scenario == "member" ? "XCTAttachment.isEqual(_:)" : "XCTAttachment.init(screenshot:)"
        #expect(path.contains { oldGraph.functions[$0]!.name.contains(callee) })
    }
    try JSONEncoder().encode(old.mappings).write(to: root.appendingPathComponent(".swift-test-selection.json"))
    _ = try CommandRunner.run("git", ["init", "-q"], at: root)
    _ = try CommandRunner.run("git", ["add", "Tests.swift", "Extra.swift", "State.swift", ".swift-test-selection.json"], at: root)
    _ = try CommandRunner.run("git", ["-c", "user.name=Tests", "-c", "user.email=tests@example.invalid", "commit", "-qm", "base"], at: root)
    var files = ["Tests.swift": after, "State.swift": state]
    if scenario == "deleted" { try FileManager.default.removeItem(at: root.appendingPathComponent("Extra.swift")) }
    else { files["Extra.swift"] = "import XCTest" }
    var current = try boundaryGraph(files, tests: tests, root: root)
    current = try JSONDecoder().decode(XcodeTestGraph.self, from: JSONEncoder().encode(current))
    let proof = try #require(current.sources["UI:Tests.swift"]?.units.first { $0.privateTestHelper?.name == "capture" }?.privateTestHelper)
    #expect(proof.attachmentEffectMembers?.contains("init") == true)
    #expect(proof.attachmentEffectMembers?.contains("screenshot") == true)
    if scenario == "assertion" { #expect(proof.localAttachmentState == false) }
    let scopes = try XcodeHeadOnlySelector.scopedReports(current: current,
        requests: .init(scopes: [.init(name: "helper", paths: ["Tests.swift"])]),
        changes: [.init(path: "Tests.swift"), .init(path: "Extra.swift")],
        baseRevision: "HEAD", headRevision: "head", root: root, mappingPath: ".swift-test-selection.json",
        documentation: [], buildEvidenceFailure: nil)
    let report = try #require(scopes.first?.report)
    if scenario == "unrelated" {
        #expect(report.selectedTests == [tests[0]])
        #expect(report.diagnostics.isEmpty)
        var incomplete = current
        for i in incomplete.sources["UI:Tests.swift"]!.units.indices {
            incomplete.sources["UI:Tests.swift"]!.units[i].privateTestHelper?.sdkEffectMembers = nil
        }
        incomplete = try JSONDecoder().decode(XcodeTestGraph.self, from: JSONEncoder().encode(incomplete))
        let missing = XcodeHeadOnlySelector.select(current: incomplete, source: .init(base: old.sources, mappings: current.mappings),
            changes: [.init(path: "Tests.swift")], baseRevision: "base")
        #expect(missing.selectedTests == tests.sorted())
        #expect(missing.diagnostics.contains { $0.code == "head_only_helper_callee_effects" })
    } else {
        #expect(report.selectedTests == tests.sorted())
        #expect(report.diagnostics.contains { $0.code == "head_only_helper_callee_effects" })
    }
}

@Test func attachmentAuditDistinguishesProtocolRequirementsFromImplementations() {
    let requirement = SwiftSourceSnapshot.parse("protocol Recorder { func add(_ value: Int) }", path: "Protocol.swift", module: "Other")
    let implementation = SwiftSourceSnapshot.parse("extension Recorder { func add(_ value: Int) { store(value) } }", path: "Default.swift", module: "Other")
    let owners: Set<String> = ["XCTAttachment", "XCTestCase", "NSObject"]
    #expect(SDKTestHelperIsolation.memberBindingsUnshadowed(revisions: [[requirement]], members: ["add"], sdkOwners: owners))
    #expect(!SDKTestHelperIsolation.memberBindingsUnshadowed(revisions: [[requirement, implementation], [requirement]], members: ["add"], sdkOwners: owners))
    #expect(!SDKTestHelperIsolation.memberBindingsUnshadowed(revisions: [[requirement], [requirement, implementation]], members: ["add"], sdkOwners: owners))
    let externalOverride = SwiftSourceSnapshot.parse("import XCTest\nextension XCTAttachment { convenience init(screenshot: XCUIScreenshot) { fatalError() } }", path: "External.swift", module: "Other")
    #expect(!SDKTestHelperIsolation.memberBindingsUnshadowed(revisions: [[externalOverride], []], members: ["init"], sdkOwners: owners))
}

@Test(arguments: ["direct", "dynamic", "overload", "labels", "escapedLabels", "reference"])
func privateHelperRejectsCrossFileImportedEffect(kind: String) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("review57-import-history-" + UUID().uuidString)
    let externalRoot = FileManager.default.temporaryDirectory.appendingPathComponent("review57-external-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: externalRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: externalRoot) }
    let method = kind == "overload" ? "screenshot(_ value: Bool)" : ["labels", "escapedLabels", "reference"].contains(kind) ? "waitForExistence(harmful value: Double)" : "markReviewFlag()"
    var call = kind == "overload" ? "screenshot(true)" : kind == "labels" ? "waitForExistence(harmful: 1)" : "markReviewFlag()"
    if kind == "escapedLabels" { call = "`waitForExistence`(`harmful`: 1)" }
    if kind == "reference" { call = "waitForExistence(harmful:)(1)" }
    let external = """
    import XCTest
    extension XCUIElement {
        @MainActor \(kind == "direct" ? "" : "@objc dynamic") public func \(method) -> Bool {
            UserDefaults.standard.set(true, forKey: "review57-sharedFlag")
            return true
        }
    }
    """
    let source = externalRoot.appendingPathComponent("AttachmentSupport.swift")
    try Data(external.utf8).write(to: source)
    let platform = try CommandRunner.run("xcrun", ["--sdk", "macosx", "--show-sdk-platform-path"], at: root).text.trimmingCharacters(in: .whitespacesAndNewlines)
    _ = try CommandRunner.run("xcrun", ["swiftc", "-emit-module", "-module-name", "AttachmentSupport", "-F", platform + "/Developer/Library/Frameworks", "-I", platform + "/Developer/usr/lib", source.path, "-emit-module-path", externalRoot.appendingPathComponent("AttachmentSupport.swiftmodule").path], at: root)
    let before = """
    import XCTest
    @MainActor final class Suite: XCTestCase {
        func testCapture() { capture(XCUIApplication()) }
        private func capture(_ app: XCUIApplication) {
            let attachment = XCTAttachment(screenshot: app.screenshot())
            add(attachment)
        }
        func testConsume() { XCTAssertFalse(UserDefaults.standard.bool(forKey: "review57-sharedFlag")) }
    }
    """
    let after = before.replacingOccurrences(of: "add(attachment)", with: "add(attachment); XCTAssertTrue(app.\(call))")
    let tests = ["UI/Suite/testCapture()", "UI/Suite/testConsume()"]
    let old = try boundaryGraph(["Tests.swift": before, "Imports.swift": "import AttachmentSupport"], tests: tests, root: root, compilerArguments: ["-I", externalRoot.path])
    try JSONEncoder().encode(old.mappings).write(to: root.appendingPathComponent(".swift-test-selection.json"))
    _ = try CommandRunner.run("git", ["init", "-q"], at: root)
    _ = try CommandRunner.run("git", ["add", "Tests.swift", "Imports.swift", ".swift-test-selection.json"], at: root)
    _ = try CommandRunner.run("git", ["-c", "user.name=Tests", "-c", "user.email=tests@example.invalid", "commit", "-qm", "base"], at: root)
    let current = try boundaryGraph(["Tests.swift": after, "Imports.swift": "import AttachmentSupport"], tests: tests, root: root, compilerArguments: ["-I", externalRoot.path])
    let graph = try #require(current.dependencies)
    let importedReferences = Set(graph.functions.values.flatMap(\.dependencies).filter { $0.contains("AttachmentSupport") })
    let dynamicCallers = Set(graph.functions.values.filter { $0.dynamicDeclarations.contains(where: { $0.contains(kind == "overload" ? "screenshot" : ["labels", "escapedLabels", "reference"].contains(kind) ? "waitForExistence" : "markReviewFlag") }) }.map(\.id))
    #expect(kind == "direct" ? !importedReferences.isEmpty : !dynamicCallers.isEmpty)
    let effectCallers = Set(graph.functions.values.filter { !$0.dependencies.isDisjoint(with: importedReferences) }.map(\.id)).union(dynamicCallers)
    _ = try #require(DependencyIndex(graph).paths(to: effectCallers).path(from: graph.tests[tests[0]] ?? []))
    let scopes = try XcodeHeadOnlySelector.scopedReports(current: current,
        requests: .init(scopes: [.init(name: "helper", paths: ["Tests.swift"])]),
        changes: [.init(path: "Tests.swift"), .init(path: "Imports.swift")],
        baseRevision: "HEAD", headRevision: "head", root: root, mappingPath: ".swift-test-selection.json",
        documentation: [], buildEvidenceFailure: nil)
    let report = try #require(scopes.first?.report)
    #expect(report.selectedTests == tests.sorted())
    #expect(report.diagnostics.contains { $0.code == "head_only_helper_callee_effects" })
}

@Test(arguments: [false, true]) func privateHelperIgnoresUnrelatedPropertyOverrides(overrides: Bool) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("review57-unrelated-override-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let before = """
    import XCTest
    @MainActor final class Suite: XCTestCase {
        func testCapture() { capture(XCUIApplication()) }
        private func capture(_ app: XCUIApplication) {
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = "Menu"
            add(attachment)
        }
        func testOther() { XCTAssertTrue(XCUIApplication().exists) }
    }
    """
    let after = before.replacingOccurrences(of: "add(attachment)", with: "add(attachment); XCTAssertTrue(app.exists)")
    var support = """
    class Label {
        var name: String { "Label" }
    }
    class OtherLabel: Label {
        override var name: String { "Other" }
    }
    """
    if !overrides { support = support.replacingOccurrences(of: "override var name", with: "var otherName") }
    let tests = ["UI/Suite/testCapture()", "UI/Suite/testOther()"]
    let current = try boundaryGraph(["Tests.swift": after, "Support.swift": support], tests: tests, root: root)
    var base = current.sources
    base["UI:Tests.swift"] = .parse(before, path: "Tests.swift", module: "UI")
    let report = XcodeHeadOnlySelector.select(current: current, source: .init(base: base, mappings: current.mappings), changes: [.init(path: "Tests.swift")], baseRevision: "base")
    #expect(report.selectedTests == [tests[0]])
    #expect(report.diagnostics.isEmpty)
}

@Test(arguments: [false, true], [false, true])
func privateHelperRejectsNestedAliasOverride(shadow: Bool, attachment: Bool) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("review57-nested-alias-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    var before = """
    import XCTest
    @MainActor final class Suite: XCTestCase {
        func testCapture() { capture(Namespace.Child()) }
        private func capture(_ app: XCUIApplication) {
            let attachment = XCTAttachment(screenshot: app.screenshot())
            add(attachment)
        }
        func testConsume() { XCTAssertFalse(sharedFlag) }
    }
    """
    if !attachment {
        before = before.replacingOccurrences(of: "let attachment = XCTAttachment(screenshot: app.screenshot())", with: "let image = app.screenshot()")
            .replacingOccurrences(of: "add(attachment)", with: "XCTAssertNotNil(image)")
    }
    let statement = attachment ? "add(attachment)" : "XCTAssertNotNil(image)"
    let after = before.replacingOccurrences(of: statement, with: statement + "; XCTAssertTrue(app.exists)")
    let prefix = """
    import XCTest
    @MainActor var sharedFlag = false
    \(shadow ? "class Parent {}" : "")
    enum Namespace {
        typealias Parent = XCUIApplication
        @MainActor class Child: Parent {
    """
    let oldExtra = prefix + """
            override func screenshot() -> XCUIScreenshot { sharedFlag = true; return super.screenshot() }
        }
    }
    """
    let headExtra = prefix + "\n    }\n}"
    let tests = ["UI/Suite/testCapture()", "UI/Suite/testConsume()"]
    let old = try boundaryGraph(["Tests.swift": before, "Extra.swift": oldExtra], tests: tests, root: root)
    let oldGraph = try #require(old.dependencies)
    let effects = oldGraph.functions.values.filter { $0.id.contains("screenshot") }
    #expect(!effects.isEmpty)
    let sharedState = Set(oldGraph.functions.values.filter { $0.uncertainties.contains("Global state access") || $0.uncertainties.contains("Shared state access") }.map(\.id))
    let effectPath = try #require(DependencyIndex(oldGraph).paths(to: sharedState).path(from: Set(effects.map(\.id))))
    #expect(!effectPath.isEmpty)
    try JSONEncoder().encode(old.mappings).write(to: root.appendingPathComponent(".swift-test-selection.json"))
    _ = try CommandRunner.run("git", ["init", "-q"], at: root)
    _ = try CommandRunner.run("git", ["add", "Tests.swift", "Extra.swift", ".swift-test-selection.json"], at: root)
    _ = try CommandRunner.run("git", ["-c", "user.name=Tests", "-c", "user.email=tests@example.invalid", "commit", "-qm", "base"], at: root)
    let current = try boundaryGraph(["Tests.swift": after, "Extra.swift": headExtra], tests: tests, root: root)
    let scopes = try XcodeHeadOnlySelector.scopedReports(current: current,
        requests: .init(scopes: [.init(name: "helper", paths: ["Tests.swift"])]),
        changes: [.init(path: "Tests.swift"), .init(path: "Extra.swift")],
        baseRevision: "HEAD", headRevision: "head", root: root, mappingPath: ".swift-test-selection.json",
        documentation: [], buildEvidenceFailure: nil)
    let report = try #require(scopes.first?.report)
    #expect(report.selectedTests == tests.sorted())
    #expect(!report.diagnostics.isEmpty)
}

@Test(arguments: ["current", "legacy", "mutation", "nestedTap"])
func privateHelperRequiresCurrentDynamicEvidence(kind: String) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("dynamic-evidence-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let before = """
    import XCTest
    @MainActor final class Suite: XCTestCase {
        func testCapture() { capture(XCUIApplication()) }
        private func capture(_ app: XCUIApplication) {
            let attachment = XCTAttachment(screenshot: app.screenshot())
            add(attachment)
        }
        func testOther() { XCTAssertTrue(XCUIApplication().exists) }
    }
    """
    let after = before.replacingOccurrences(of: "add(attachment)", with:
        "add(attachment); " + (kind == "mutation" ? "XCTAssertNotNil(app.terminate())" : kind == "nestedTap" ? "XCTAssertNotNil(app.tap())" : "XCTAssertTrue(app.exists)"))
    let tests = ["UI/Suite/testCapture()", "UI/Suite/testOther()"]
    var current = try boundaryGraph(["Tests.swift": after], tests: tests, root: root)
    var base = current.sources
    base["UI:Tests.swift"] = .parse(before, path: "Tests.swift", module: "UI")
    if kind == "legacy" {
        for id in current.dependencies!.functions.keys { current.dependencies!.functions[id]!.dynamicCallSignatures = nil }
    }
    current = try GraphArchive.decode(GraphArchive.encode(current))
    let report = XcodeHeadOnlySelector.select(current: current, source: .init(base: base, mappings: current.mappings),
        changes: [.init(path: "Tests.swift")], baseRevision: "base")
    #expect(report.selectedTests == (kind == "current" ? [tests[0]] : tests.sorted()))
    #expect(kind == "current" ? report.diagnostics.isEmpty : report.diagnostics.contains { $0.code == "head_only_helper_callee_effects" })
}

@Test(arguments: ["sdk", "labeled", "escaped"]) func privateHelperValidatesDynamicSubscriptLabels(kind: String) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("review57-import-history-" + UUID().uuidString)
    let externalRoot = FileManager.default.temporaryDirectory.appendingPathComponent("review57-external-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: externalRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: externalRoot) }
    let externalCall = kind != "sdk"
    let call = kind == "escaped" ? "buttons[`tracking`: \"item\"].exists" : externalCall ? "buttons[tracking: \"item\"].exists" : "buttons[\"item\"].exists"
    let external = """
    import XCTest
    extension XCUIElementQuery {
        @MainActor @objc public dynamic subscript(tracking value: String) -> XCUIElement {
            @objc(reviewElementForIdentifier:) get {
                UserDefaults.standard.set(true, forKey: "review57-sharedFlag")
                return self[value]
            }
        }
    }
    """
    let source = externalRoot.appendingPathComponent("AttachmentSupport.swift")
    try Data(external.utf8).write(to: source)
    let platform = try CommandRunner.run("xcrun", ["--sdk", "macosx", "--show-sdk-platform-path"], at: root).text.trimmingCharacters(in: .whitespacesAndNewlines)
    _ = try CommandRunner.run("xcrun", ["swiftc", "-emit-module", "-module-name", "AttachmentSupport", "-F", platform + "/Developer/Library/Frameworks", "-I", platform + "/Developer/usr/lib", source.path, "-emit-module-path", externalRoot.appendingPathComponent("AttachmentSupport.swiftmodule").path], at: root)
    let before = """
    import XCTest
    @MainActor final class Suite: XCTestCase {
        func testCapture() { capture(XCUIApplication()) }
        private func capture(_ app: XCUIApplication) {
            let attachment = XCTAttachment(screenshot: app.screenshot())
            add(attachment)
        }
        func testConsume() { XCTAssertFalse(UserDefaults.standard.bool(forKey: "review57-sharedFlag")) }
    }
    """
    let after = before.replacingOccurrences(of: "add(attachment)", with: "add(attachment); XCTAssertTrue(app.\(call))")
    let tests = ["UI/Suite/testCapture()", "UI/Suite/testConsume()"]
    let old = try boundaryGraph(["Tests.swift": before, "Imports.swift": "import AttachmentSupport"], tests: tests, root: root, compilerArguments: ["-I", externalRoot.path])
    try JSONEncoder().encode(old.mappings).write(to: root.appendingPathComponent(".swift-test-selection.json"))
    _ = try CommandRunner.run("git", ["init", "-q"], at: root)
    _ = try CommandRunner.run("git", ["add", "Tests.swift", "Imports.swift", ".swift-test-selection.json"], at: root)
    _ = try CommandRunner.run("git", ["-c", "user.name=Tests", "-c", "user.email=tests@example.invalid", "commit", "-qm", "base"], at: root)
    let current = try boundaryGraph(["Tests.swift": after, "Imports.swift": "import AttachmentSupport"], tests: tests, root: root, compilerArguments: ["-I", externalRoot.path])
    let scopes = try XcodeHeadOnlySelector.scopedReports(current: current,
        requests: .init(scopes: [.init(name: "helper", paths: ["Tests.swift"])]),
        changes: [.init(path: "Tests.swift"), .init(path: "Imports.swift")],
        baseRevision: "HEAD", headRevision: "head", root: root, mappingPath: ".swift-test-selection.json",
        documentation: [], buildEvidenceFailure: nil)
    let report = try #require(scopes.first?.report)
    #expect(report.selectedTests == (externalCall ? tests.sorted() : [tests[0]]))
    #expect(externalCall ? report.diagnostics.contains { $0.code == "head_only_helper_callee_effects" } : report.diagnostics.isEmpty)
}


@Test(arguments: ["sdk", "predicate", "element", "external", "mixed", "reverse", "default"]) func privateHelperCouplesMatchingLabelsAndTypes(kind: String) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("review57-import-history-" + UUID().uuidString)
    let externalRoot = FileManager.default.temporaryDirectory.appendingPathComponent("review57-external-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: externalRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: externalRoot) }
    let externalCall = ["external", "mixed", "reverse", "default"].contains(kind)
    let call: String
    switch kind {
    case "predicate": call = "buttons.matching(NSPredicate(value: true)).firstMatch.exists"
    case "element": call = "buttons.matching(.button, identifier: nil).firstMatch.exists"
    case "default": call = "buttons.matching(.button).firstMatch.exists"
    case "reverse": call = "buttons.matching(identifier: NSPredicate(value: true)).firstMatch.exists"
    case "external", "mixed": call = "buttons.matching(\"item\").firstMatch.exists"
    default: call = "buttons.matching(identifier: \"item\").firstMatch.exists"
    }
    let external = """
    import XCTest
    extension XCUIElementQuery {
        @MainActor @objc(reviewMatching:) public dynamic func matching(_ value: String) -> XCUIElementQuery {
            UserDefaults.standard.set(true, forKey: "review57-sharedFlag")
            return self.matching(identifier: value)
        }
        @MainActor @objc(reviewMatchingType:tracking:) public dynamic func matching(_ value: XCUIElement.ElementType, tracking: String? = nil) -> XCUIElementQuery {
            UserDefaults.standard.set(true, forKey: "review57-sharedFlag")
            return self.matching(value, identifier: tracking)
        }
        @MainActor @objc(reviewMatchingPredicate:) public dynamic func matching(identifier value: NSPredicate) -> XCUIElementQuery {
            UserDefaults.standard.set(true, forKey: "review57-sharedFlag")
            return self.matching(value)
        }
    }
    """
    let source = externalRoot.appendingPathComponent("AttachmentSupport.swift")
    try Data(external.utf8).write(to: source)
    let platform = try CommandRunner.run("xcrun", ["--sdk", "macosx", "--show-sdk-platform-path"], at: root).text.trimmingCharacters(in: .whitespacesAndNewlines)
    _ = try CommandRunner.run("xcrun", ["swiftc", "-emit-module", "-module-name", "AttachmentSupport", "-F", platform + "/Developer/Library/Frameworks", "-I", platform + "/Developer/usr/lib", source.path, "-emit-module-path", externalRoot.appendingPathComponent("AttachmentSupport.swiftmodule").path], at: root)
    let before = """
    import XCTest
    @MainActor final class Suite: XCTestCase {
        func testCapture() { capture(XCUIApplication()) }
        private func capture(_ app: XCUIApplication) {
            let attachment = XCTAttachment(screenshot: app.screenshot())
            add(attachment)
        }
        func testConsume() { XCTAssertFalse(UserDefaults.standard.bool(forKey: "review57-sharedFlag")) }
    }
    """
    var after = before.replacingOccurrences(of: "add(attachment)", with: "add(attachment); XCTAssertTrue(app.\(call))")
    if kind == "mixed" {
        after = after.replacingOccurrences(of: "add(attachment);", with: "add(attachment); XCTAssertTrue(app.buttons.matching(identifier: \"safe\").firstMatch.exists);")
    }
    let tests = ["UI/Suite/testCapture()", "UI/Suite/testConsume()"]
    let old = try boundaryGraph(["Tests.swift": before, "Imports.swift": "import AttachmentSupport"], tests: tests, root: root, compilerArguments: ["-I", externalRoot.path])
    try JSONEncoder().encode(old.mappings).write(to: root.appendingPathComponent(".swift-test-selection.json"))
    _ = try CommandRunner.run("git", ["init", "-q"], at: root)
    _ = try CommandRunner.run("git", ["add", "Tests.swift", "Imports.swift", ".swift-test-selection.json"], at: root)
    _ = try CommandRunner.run("git", ["-c", "user.name=Tests", "-c", "user.email=tests@example.invalid", "commit", "-qm", "base"], at: root)
    let current = try boundaryGraph(["Tests.swift": after, "Imports.swift": "import AttachmentSupport"], tests: tests, root: root, compilerArguments: ["-I", externalRoot.path])
    let scopes = try XcodeHeadOnlySelector.scopedReports(current: current,
        requests: .init(scopes: [.init(name: "helper", paths: ["Tests.swift"])]),
        changes: [.init(path: "Tests.swift"), .init(path: "Imports.swift")],
        baseRevision: "HEAD", headRevision: "head", root: root, mappingPath: ".swift-test-selection.json",
        documentation: [], buildEvidenceFailure: nil)
    let report = try #require(scopes.first?.report)
    #expect(report.selectedTests == (externalCall ? tests.sorted() : [tests[0]]))
    #expect(externalCall ? report.diagnostics.contains { $0.code == "head_only_helper_callee_effects" } : report.diagnostics.isEmpty)
    if kind == "sdk" {
        let restored = try GraphArchive.decode(GraphArchive.encode(current))
        let precise = XcodeHeadOnlySelector.select(current: restored, source: .init(base: old.sources, mappings: current.mappings),
            changes: [.init(path: "Tests.swift")], baseRevision: "base")
        #expect(precise.selectedTests == [tests[0]])
        for atHead in [false, true] {
            var incomplete = atHead ? current : old
            for i in incomplete.sources["UI:Tests.swift"]!.units.indices {
                incomplete.sources["UI:Tests.swift"]!.units[i].privateTestHelper?.sdkCallShapes = nil
            }
            let fallback = XcodeHeadOnlySelector.select(current: atHead ? incomplete : current,
                source: .init(base: atHead ? old.sources : incomplete.sources, mappings: current.mappings),
                changes: [.init(path: "Tests.swift")], baseRevision: "base")
            #expect(fallback.selectedTests == tests.sorted())
            #expect(fallback.diagnostics.contains { $0.code == "head_only_helper_callee_effects" })
        }
    }
}

@Test(arguments: ["sdk", "native", "dynamic", "dynamicConcrete"], [false, true]) func helpersRejectOpaqueReceiverFactories(kind: String, sdkBoundary: Bool) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("review57-receiver-" + UUID().uuidString)
    let externalRoot = root.appendingPathComponent("External")
    try FileManager.default.createDirectory(at: externalRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let external = """
    import XCTest
    @MainActor public class StatefulApp: XCUIApplication {
        public override var exists: Bool {
            UserDefaults.standard.set(true, forKey: "review57-sharedFlag")
            return true
        }
    }
    """
    let factory = """
    extension XCUIApplication {
        @MainActor @objc public class func makeReviewApp() -> XCUIApplication { StatefulApp() }
        @MainActor @objc public class func makeConcreteApp() -> StatefulApp { StatefulApp() }
    }
    """
    let source = externalRoot.appendingPathComponent("AttachmentSupport.swift")
    try Data((external + "\n" + factory).utf8).write(to: source)
    let platform = try CommandRunner.run("xcrun", ["--sdk", "macosx", "--show-sdk-platform-path"], at: root).text.trimmingCharacters(in: .whitespacesAndNewlines)
    _ = try CommandRunner.run("xcrun", ["swiftc", "-emit-module", "-module-name", "AttachmentSupport", "-F", platform + "/Developer/Library/Frameworks", "-I", platform + "/Developer/usr/lib", source.path, "-emit-module-path", externalRoot.appendingPathComponent("AttachmentSupport.swiftmodule").path], at: root)
    var before = """
    import XCTest
    @MainActor final class Suite: XCTestCase {
        func testCapture() { capture(makeApp()) }
        private func capture(_ app: XCUIApplication) { XCTAssertNotNil(app) }
        func testConsume() { XCTAssertFalse(UserDefaults.standard.bool(forKey: "review57-sharedFlag")) }
    }
    """
    if sdkBoundary {
        before = """
        import XCTest
        @MainActor extension XCUIElement {
            func readiness() -> Bool { return waitForExistence(timeout: 1) }
        }
        @MainActor final class Suite: XCTestCase {
            func testCapture() { XCTAssertTrue(makeApp().readiness()) }
            func testConsume() { XCTAssertFalse(UserDefaults.standard.bool(forKey: "review57-sharedFlag")) }
        }
        """
    }
    var support = "import XCTest\nimport AttachmentSupport\n@MainActor func makeApp() -> XCUIApplication { StatefulApp() }"
    if kind == "sdk" { support = "import XCTest\n@MainActor func makeApp() -> XCUIApplication { XCUIApplication() }" }
    if kind == "dynamic" { support = "import XCTest\nimport AttachmentSupport\n@MainActor func makeApp() -> XCUIApplication { XCUIApplication.makeReviewApp() }" }
    if kind == "dynamicConcrete" { support = "import XCTest\nimport AttachmentSupport\n@MainActor func makeApp() -> XCUIApplication { XCUIApplication.makeConcreteApp() }" }
    let after = sdkBoundary ? before.replacingOccurrences(of: "return waitForExistence(timeout: 1)", with: "return waitForExistence(timeout: 1) && exists") : before.replacingOccurrences(of: "XCTAssertNotNil(app)", with: "XCTAssertNotNil(app); XCTAssertTrue(app.exists)")
    let tests = ["UI/Suite/testCapture()", "UI/Suite/testConsume()"]
    let old = try boundaryGraph(["Tests.swift": before, "Imports.swift": support], tests: tests, root: root, compilerArguments: ["-I", externalRoot.path])
    let current = try boundaryGraph(["Tests.swift": after, "Imports.swift": support], tests: tests, root: root, compilerArguments: ["-I", externalRoot.path])
    let report = XcodeHeadOnlySelector.select(current: current, source: .init(base: old.sources, mappings: current.mappings), changes: [.init(path: "Tests.swift")], baseRevision: "base")
    #expect(report.selectedTests == (kind == "sdk" ? [tests[0]] : tests.sorted()))
    #expect(kind == "sdk" ? report.diagnostics.isEmpty : report.diagnostics.contains { sdkBoundary ? $0.message.contains("receiver origin") : $0.code == "head_only_helper_callee_effects" })
}
