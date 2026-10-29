// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation
import Testing
@testable import TestImpact

private let callerPatterns = [
    "switch": "switch 1 { case 1: break; default: break }",
    "if": "if case 1 = 1 {}",
    "guard": "guard case 1 = 1 else { return }",
    "while": "while case 1 = 1 { break }",
    "for": "for case 1 in [1] {}",
    "tuple": "switch (1, 2) { case (1, _): break; default: break }",
    "optional": "switch Optional(1) { case 1?: break; default: break }",
    "range": "switch 1 { case 0...2: break; default: break }"
]

@Test(arguments: ["switch", "if", "guard", "while", "for", "tuple", "optional", "range"], ["caller", "producer", "lifecycle"])
func historicalPatternOperatorsRequireBindings(pattern: String, site: String) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("helper-pattern-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let expression = try #require(callerPatterns[pattern])
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
    let write = "UserDefaults.standard.set(true, forKey: \"shared\")"
    let matcher = "func ~= (lhs: \(pattern == "range" ? "ClosedRange<Int>" : "Int"), rhs: Int) -> Bool { \(write); return true }"
    // Both global and static project overloads can replace Swift's matcher.
    let extra = "import XCTest\n" + (site == "producer" || pattern == "range" ? matcher : "extension Int { static " + matcher + " }")
    let probe = root.appendingPathComponent("Probe.swift"), executable = root.appendingPathComponent("probe")
    let runtime = "var reached = false\n" + extra.replacingOccurrences(of: "import XCTest", with: "")
        .replacingOccurrences(of: write, with: "reached = true") + "\nfunc probe() { " + expression + " }\nprobe()\nprecondition(reached)"
    try Data(runtime.utf8).write(to: probe)
    _ = try CommandRunner.run("xcrun", ["swiftc", probe.path, "-o", executable.path], at: root)
    _ = try CommandRunner.run(executable.path, [], at: root)
    let tests = ["UI/Suite/testConsumer()", "UI/Other/testReader()"]
    let old = try GraphArchive.decode(GraphArchive.encode(boundaryGraph(["UI.swift": before, "Extra.swift": extra], tests: tests, root: root)))
    let current = try GraphArchive.decode(GraphArchive.encode(boundaryGraph(["UI.swift": after], tests: tests, root: root)))
    let graph = try #require(old.dependencies)
    let matchers = Set(graph.functions.filter { $0.value.regions.contains { $0.path == "Extra.swift" } }.keys)
    try #require(!matchers.isEmpty)
    try #require(DependencyIndex(graph).paths(to: matchers).path(from: graph.tests[tests[0]] ?? []) != nil)
    for unowned in [false, true] {
        var source = XcodeHeadOnlySources(base: old.sources, mappings: current.mappings)
        if unowned {
            source.base.removeValue(forKey: "UI:Extra.swift")
            source.unownedBaseSources["Extra.swift"] = .parse(extra, path: "Extra.swift", module: "")
        }
        let report = XcodeHeadOnlySelector.select(current: current, source: source,
            changes: [.init(path: "UI.swift")], baseRevision: "base")
        #expect(report.selectedTests == tests.sorted(), "pattern=\(pattern) site=\(site) unowned=\(unowned) \(report.diagnostics)")
        #expect(report.diagnostics.contains {
            $0.message.contains(pattern == "range" ? "Unproven receiver metatype: literal:ClosedRange<Int>" : "operator binding at base or head: ~=")
        })
        var ordinary = current
        for index in ordinary.sources["UI:UI.swift"]!.units.indices { ordinary.sources["UI:UI.swift"]!.units[index].privateTestHelper = nil }
        #expect(XcodeHeadOnlySelector.select(current: ordinary, source: source,
            changes: [.init(path: "UI.swift")], baseRevision: "base").selectedTests == tests.sorted())
    }
    let cleanBase = ["UI:UI.swift": SwiftSourceSnapshot.parse(before, path: "UI.swift", module: "UI")]
    let clean = XcodeHeadOnlySelector.select(current: current, source: .init(base: cleanBase, mappings: current.mappings),
        changes: [.init(path: "UI.swift")], baseRevision: "base")
    if pattern == "range" {
        // This receiver is already outside the supported head contract. Keep
        // that independent boundary rather than expanding it for this fix.
        #expect(clean.selectedTests == tests.sorted())
        #expect(clean.diagnostics.contains { $0.message.contains("Unproven receiver metatype: literal:ClosedRange<Int>") })
    } else {
        #expect(clean.selectedTests == [tests[0]], "\(clean.diagnostics)")
        #expect(clean.diagnostics.isEmpty)
    }
    if pattern == "switch" {
        for revision in ["head", "base"] {
            var head = current, base = cleanBase
            if revision == "head" {
                for index in head.sources["UI:UI.swift"]!.units.indices { head.sources["UI:UI.swift"]!.units[index].helperBindingUses?.implicitOperators = nil }
            } else {
                for index in base["UI:UI.swift"]!.units.indices { base["UI:UI.swift"]!.units[index].helperBindingUses?.implicitOperators = nil }
            }
            let report = XcodeHeadOnlySelector.select(current: head, source: .init(base: base, mappings: current.mappings),
                changes: [.init(path: "UI.swift")], baseRevision: "base")
            #expect(report.selectedTests == tests.sorted())
            #expect(report.diagnostics.contains { $0.message.contains("caller expression bindings") })
        }
    }
}

@Test func implicitPatternInventoryCoversEveryMatchingContext() throws {
    let expressions = Array(callerPatterns.values) + [
        "do { try action() } catch errorPattern {} catch {}",
        "switch value { case (1, 2?), 3: break; default: break }",
        "if case (1, _) = value {}",
        "#if CUSTOM\nswitch 1 { case 1: break; default: break }\n#endif"
    ]
    for expression in expressions {
        let source = SwiftSourceSnapshot.parse("func caller() { " + expression + "\n}", path: "UI.swift", module: "UI")
        let uses = try #require(source.units.first { $0.helperCallableName == "caller" }?.helperBindingUses)
        #expect(uses.implicitOperators == ["~="], "\(expression)")
    }
    for expression in ["switch value { case _: break }", "switch value { case (_, _): break }", "if case let value = input {}", "for value in input {}", "let (a, b) = value"] {
        let source = SwiftSourceSnapshot.parse("func caller() { " + expression + " }", path: "UI.swift", module: "UI")
        let uses = try #require(source.units.first { $0.helperCallableName == "caller" }?.helperBindingUses)
        #expect(uses.implicitOperators == [], "\(expression)")
    }
    let legacy = try JSONDecoder().decode(HelperBindingUses.self, from: Data(#"{"operators":[],"members":[],"globals":[],"qualifiedMembers":{}}"#.utf8))
    #expect(legacy.implicitOperators == nil)
}

@Test(arguments: ["switch 1 { case _: break }", "switch (1, 2) { case (_, _): break }", "if case let value = 1 { _ = value }"])
func unusedPatternMatchersPreserveFocusedSelection(expression: String) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("helper-unused-matcher-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let before = """
    import XCTest
    func evaluate(_ body: () -> Void) { body() }
    @MainActor final class Suite: XCTestCase {
        func testConsumer() { \(expression); candidate() }
        private func candidate() { for _ in 0..<2 { let value = 1; XCTAssertTrue(true) } }
    }
    @MainActor final class Other: XCTestCase {
        func testReader() { evaluate { XCTAssertTrue(UserDefaults.standard.bool(forKey: "shared")) } }
    }
    """
    let after = before.replacingOccurrences(of: "private func candidate() {", with: "private func candidate() { XCTAssertTrue(true);")
    let extra = "import XCTest\nextension Int { static func ~= (lhs: Int, rhs: Int) -> Bool { UserDefaults.standard.set(true, forKey: \"shared\"); return true } }"
    let tests = ["UI/Suite/testConsumer()", "UI/Other/testReader()"]
    let current = try boundaryGraph(["UI.swift": after, "Extra.swift": extra], tests: tests, root: root)
    let base = ["UI:UI.swift": SwiftSourceSnapshot.parse(before, path: "UI.swift", module: "UI"),
                "UI:Extra.swift": SwiftSourceSnapshot.parse(extra, path: "Extra.swift", module: "UI")]
    let report = XcodeHeadOnlySelector.select(current: current, source: .init(base: base, mappings: current.mappings),
        changes: [.init(path: "UI.swift")], baseRevision: "base")
    #expect(report.selectedTests == [tests[0]], "\(report.diagnostics)")
    #expect(report.diagnostics.isEmpty)
}
