// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation
import Testing
@testable import TestImpact

@Test(arguments: ["assert", "precondition", "debug", "release", "unchecked", "stdlib"], ["caller", "producer", "lifecycle"])
func historicalAssertionConfigurationEffectsRequireFallback(kind: String, site: String) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("helper-assert-config-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let oldConfig = kind == "release" || kind == "precondition" ? "Release" : kind == "unchecked" ? "Unchecked" : "Debug"
    let newConfig = kind == "precondition" ? "Unchecked" : oldConfig == "Debug" ? "Release" : "Debug"
    let write = "UserDefaults.standard.set(true, forKey: \"shared\")"
    let expression: String
    switch kind {
    case "assert", "precondition": expression = "Swift.\(kind)({ \(write); return true }())"
    case "debug": expression = "if _isDebugAssertConfiguration() { \(write) }"
    case "release": expression = "if Swift._isReleaseAssertConfiguration() { \(write) }"
    case "unchecked": expression = "if _isFastAssertConfiguration() { \(write) }"
    default: expression = "let configuration = Swift._isStdlibDebugChecksEnabled; if configuration() { \(write) }"
    }
    // Runtime evidence uses a local sentinel, not the user's preferences. Check
    // both directions: forcing Debug for replay would miss Release-only effects.
    if site == "caller" {
        let probe = root.appendingPathComponent("Probe.swift"), executable = root.appendingPathComponent("probe")
        try Data(("var reached = false\n" + expression.replacingOccurrences(of: write, with: "reached = true") + "\nprint(reached)").utf8).write(to: probe)
        for (configuration, expected) in [(oldConfig, "true"), (newConfig, "false")] {
            _ = try CommandRunner.run("xcrun", ["swiftc", "-Onone", "-assert-config", configuration, probe.path, "-o", executable.path], at: root)
            #expect(try CommandRunner.run(executable.path, [], at: root).text.trimmingCharacters(in: .whitespacesAndNewlines) == expected)
        }
    }
    let before = """
    import XCTest
    func evaluate(_ body: () -> Void) { body() }
    \(site == "producer" ? "func produce() { " + expression + " }" : "")
    @MainActor final class Suite: XCTestCase {
        \(site == "lifecycle" ? "override func setUp() { " + expression + " }" : "")
        func testConsumer() { \(site == "caller" ? expression + "; " : site == "producer" ? "produce(); " : "")candidate() }
        private func candidate() { for _ in 0..<2 { let value = 1; XCTAssertTrue(true) } }
    }
    @MainActor final class Other: XCTestCase {
        func testReader() { evaluate { XCTAssertTrue(UserDefaults.standard.bool(forKey: "shared")) } }
    }
    """
    let after = before.replacingOccurrences(of: "private func candidate() {", with: "private func candidate() { XCTAssertTrue(true);")
    let tests = ["UI/Suite/testConsumer()", "UI/Other/testReader()"]
    let old = try boundaryGraph(["UI.swift": before], tests: tests, root: root, compilerArguments: ["-assert-config", oldConfig])
    let current = try GraphArchive.decode(GraphArchive.encode(boundaryGraph(["UI.swift": after], tests: tests, root: root, compilerArguments: ["-assert-config", newConfig])))
    let graph = try #require(old.dependencies)
    let writes = Set(graph.functions.filter { ($0.value.dynamicCallSignatures ?? []).contains { $0.contains("UserDefaults.set") } }.keys)
    try #require(!writes.isEmpty)
    try #require(DependencyIndex(graph).paths(to: writes).path(from: graph.tests[tests[0]] ?? []) != nil)
    for unowned in [false, true] {
        var source = XcodeHeadOnlySources(base: old.sources, mappings: current.mappings)
        if unowned {
            source.base.removeValue(forKey: "UI:UI.swift")
            source.unownedBaseSources["UI.swift"] = .parse(before, path: "UI.swift", module: "")
        }
        let report = XcodeHeadOnlySelector.select(current: current, source: source,
            changes: [.init(path: "UI.swift")], baseRevision: "base")
        #expect(report.selectedTests == tests.sorted(), "\(report.diagnostics)")
        if unowned {
            // Losing the changed file's owner independently invalidates the
            // helper proof before its caller effects can be inspected.
            #expect(report.diagnostics.contains { $0.code == "head_only_declaration_change" })
        } else {
            #expect(report.diagnostics.contains { $0.message.contains("declaration-body effects") })
        }
        var ordinary = current
        for index in ordinary.sources["UI:UI.swift"]!.units.indices { ordinary.sources["UI:UI.swift"]!.units[index].privateTestHelper = nil }
        #expect(XcodeHeadOnlySelector.select(current: ordinary, source: source,
            changes: [.init(path: "UI.swift")], baseRevision: "base").selectedTests == tests.sorted())
    }
}

@Test func assertionConfigurationInventoryCoversReferencesAndNestedBodies() throws {
    for name in ["assert", "assertionFailure", "precondition", "preconditionFailure", "fatalError",
                 "_isDebugAssertConfiguration", "_isReleaseAssertConfiguration", "_isFastAssertConfiguration", "_isStdlibDebugChecksEnabled"] {
        for reference in [name, "Swift." + name, "`" + name + "`"] {
            for body in ["let operation = " + reference, "evaluate { " + reference + "() }", "defer { " + reference + "() }"] {
                let source = SwiftSourceSnapshot.parse("func caller() { " + body + " }", path: "UI.swift", module: "UI")
                #expect(try #require(source.units.first { $0.helperCallableName == "caller" }).helperRegionEffectsComplete == false)
            }
        }
    }
    for body in ["XCTAssertTrue(true)", "let assertionFailure = true", "let text = \"assert\"", "/* precondition(false) */ return"] {
        let source = SwiftSourceSnapshot.parse("func caller() { " + body + " }", path: "UI.swift", module: "UI")
        #expect(try #require(source.units.first { $0.helperCallableName == "caller" }).helperRegionEffectsComplete == true)
    }
}

@Test(arguments: ["Debug", "Release", "Unchecked"])
func unrelatedAssertionsPreserveFocusedSelection(configuration: String) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("helper-unused-assert-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let before = """
    import XCTest
    func evaluate(_ body: () -> Void) { body() }
    func unrelated() { assert({ UserDefaults.standard.set(true, forKey: "shared"); return true }()) }
    @MainActor final class Suite: XCTestCase {
        func testConsumer() { XCTAssertTrue(true); candidate() }
        private func candidate() { for _ in 0..<2 { let value = 1; XCTAssertTrue(true) } }
    }
    @MainActor final class Other: XCTestCase {
        func testReader() { evaluate { XCTAssertTrue(UserDefaults.standard.bool(forKey: "shared")) } }
    }
    """
    let after = before.replacingOccurrences(of: "private func candidate() {", with: "private func candidate() { XCTAssertTrue(true);")
    let tests = ["UI/Suite/testConsumer()", "UI/Other/testReader()"]
    let current = try boundaryGraph(["UI.swift": after], tests: tests, root: root, compilerArguments: ["-assert-config", configuration])
    let base = ["UI:UI.swift": SwiftSourceSnapshot.parse(before, path: "UI.swift", module: "UI")]
    let report = XcodeHeadOnlySelector.select(current: current, source: .init(base: base, mappings: current.mappings),
        changes: [.init(path: "UI.swift")], baseRevision: "base")
    #expect(report.selectedTests == [tests[0]], "\(report.diagnostics)")
    #expect(report.diagnostics.isEmpty)
}
