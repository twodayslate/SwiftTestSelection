// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation
import Testing
@testable import TestImpact

@Test(arguments: ["statement", "closure", "branch", "defer"], [false, true])
func historicalCallerSDKWritesCannotDisappear(kind: String, added: Bool) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("helper-old-effects-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let write = "UserDefaults.standard.set(true, forKey: \"shared\")"
    let effect = kind == "closure" ? "evaluate { \(write) }" : kind == "branch" ? "if true { \(write) }"
        : kind == "defer" ? "defer { \(write) }" : write
    let helper = "private func candidate() { for _ in 0..<2 { let value = 1; XCTAssertTrue(true) } }"
    let before = """
    import XCTest
    func evaluate(_ body: () -> Void) { body() }
    @MainActor final class Suite: XCTestCase {
        func testConsumer() { \(effect); \(added ? "" : "candidate()") }
        \(added ? "" : helper)
    }
    @MainActor final class Other: XCTestCase {
        func testReader() { evaluate { XCTAssertTrue(UserDefaults.standard.bool(forKey: "shared")) } }
    }
    """
    let after = before.replacingOccurrences(of: effect, with: "XCTAssertTrue(true)")
        .replacingOccurrences(of: "func testConsumer() {", with: "func testConsumer() { candidate();")
        .replacingOccurrences(of: "@MainActor final class Suite: XCTestCase {", with: "@MainActor final class Suite: XCTestCase {\n" + (added ? helper : ""))
        .replacingOccurrences(of: "private func candidate() {", with: "private func candidate() { XCTAssertTrue(true);")
    let tests = ["UI/Suite/testConsumer()", "UI/Other/testReader()"]
    let old = try boundaryGraph(["UI.swift": before], tests: tests, root: root)
    let current = try GraphArchive.decode(GraphArchive.encode(boundaryGraph(["UI.swift": after], tests: tests, root: root)))
    let graph = try #require(old.dependencies)
    let writes = Set(graph.functions.filter { node in
        (node.value.dynamicCallSignatures ?? []).contains { $0.contains("UserDefaults.set") }
    }.keys)
    try #require(!writes.isEmpty)
    try #require(DependencyIndex(graph).paths(to: writes).path(from: graph.tests[tests[0]] ?? []) != nil)
    let report = XcodeHeadOnlySelector.select(current: current, source: .init(base: old.sources, mappings: current.mappings),
        changes: [.init(path: "UI.swift")], baseRevision: "base")
    #expect(report.selectedTests == tests.sorted(), "\(report.diagnostics)")
    #expect(report.diagnostics.contains { $0.message.contains("historical caller body effects") })
}

@Test(arguments: ["Worker", "UI.Worker", "`UI` /* module */ . `Worker`", "WorkerAlias", "UI.WorkerAlias"])
func qualifiedExtensionConformancesRequireHistoricalEffects(spelling: String) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("helper-qualified-conformance-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let before = """
    import XCTest
    func evaluate(_ body: () -> Void) { body() }
    @MainActor final class Suite: XCTestCase {
        func testConsumer() { for _ in Worker() {}; candidate() }
        private func candidate() { for _ in 0..<2 { let value = 1; XCTAssertTrue(true) } }
    }
    @MainActor final class Other: XCTestCase {
        func testReader() { evaluate { XCTAssertTrue(UserDefaults.standard.bool(forKey: "shared")) } }
    }
    """
    let after = before.replacingOccurrences(of: "private func candidate() {", with: "private func candidate() { XCTAssertTrue(true);")
    let effect = "UserDefaults.standard.set(true, forKey: \"shared\"); "
    let oldExtra = """
    import XCTest
    struct Worker {
        var startIndex: Int { \(effect)return 0 }
        var endIndex: Int { 1 }
        func index(after i: Int) -> Int { i + 1 }
        subscript(position: Int) -> Int { 1 }
    }
    """
    let conformance = (spelling.contains("Alias") ? "typealias WorkerAlias = Worker\n" : "") + "extension \(spelling): Collection {}"
    let newExtra = oldExtra.replacingOccurrences(of: effect, with: "") + "\nextension Worker { func makeIterator() -> IndexingIterator<[Int]> { [1].makeIterator() } }"
    let probe = root.appendingPathComponent("Probe.swift"), executable = root.appendingPathComponent("probe")
    let runtimeSource = "var reached = false\n" + oldExtra.replacingOccurrences(of: "import XCTest", with: "")
        .replacingOccurrences(of: effect, with: "reached = true; ") + "\n" + conformance + "\nfor _ in Worker() {}\nprecondition(reached)"
    try Data(runtimeSource.utf8).write(to: probe)
    _ = try CommandRunner.run("xcrun", ["swiftc", "-module-name", "UI", probe.path, "-o", executable.path], at: root)
    _ = try CommandRunner.run(executable.path, [], at: root)
    let tests = ["UI/Suite/testConsumer()", "UI/Other/testReader()"]
    let current = try GraphArchive.decode(GraphArchive.encode(boundaryGraph([
        "UI.swift": after, "Extra.swift": newExtra, "Conformance.swift": conformance], tests: tests, root: root)))
    let base = ["UI:UI.swift": SwiftSourceSnapshot.parse(before, path: "UI.swift", module: "UI"),
                "UI:Extra.swift": SwiftSourceSnapshot.parse(oldExtra, path: "Extra.swift", module: "UI"),
                "UI:Conformance.swift": SwiftSourceSnapshot.parse(conformance, path: "Conformance.swift", module: "UI")]
    for unowned in [[], ["Conformance.swift"], ["Extra.swift", "Conformance.swift"]] {
        var source = XcodeHeadOnlySources(base: base, mappings: current.mappings)
        for path in unowned {
            source.base.removeValue(forKey: "UI:" + path)
            source.unownedBaseSources[path] = .parse(path == "Extra.swift" ? oldExtra : conformance, path: path, module: "")
        }
        let report = XcodeHeadOnlySelector.select(current: current, source: source,
            changes: [.init(path: "UI.swift")], baseRevision: "base")
        #expect(report.selectedTests == tests.sorted(), "spelling=\(spelling) unowned=\(unowned) \(report.diagnostics)")
        #expect(report.diagnostics.contains { $0.code == "head_only_helper_callee_effects" })
    }
    // An exact, compiler-checked iterator remains supported through ordinary,
    // qualified and trivia-bearing extension scopes. Alias targets stay opaque.
    let cleanExtra = "struct Worker {}\nextension \(spelling.replacingOccurrences(of: "WorkerAlias", with: "Worker")): Sequence { func makeIterator() -> IndexingIterator<[Int]> { [1].makeIterator() } }"
    let clean = try boundaryGraph(["UI.swift": after, "Extra.swift": cleanExtra], tests: tests, root: root)
    let cleanBase = ["UI:UI.swift": SwiftSourceSnapshot.parse(before, path: "UI.swift", module: "UI"),
                     "UI:Extra.swift": SwiftSourceSnapshot.parse(cleanExtra, path: "Extra.swift", module: "UI")]
    let control = XcodeHeadOnlySelector.select(current: clean, source: .init(base: cleanBase, mappings: clean.mappings),
        changes: [.init(path: "UI.swift")], baseRevision: "base")
    #expect(control.selectedTests == [tests[0]], "\(control.diagnostics)")
    #expect(control.diagnostics.isEmpty)
}

@Test func historicalCallerAdditionsRequireUnchangedStatementPrefix() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("helper-append-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let before = """
    import XCTest
    func evaluate(_ body: () -> Void) { body() }
    @MainActor final class Suite: XCTestCase {
        func testConsumer() { let value = true; XCTAssertTrue(value); candidate() }
        private func candidate() { for _ in 0..<2 { let value = 1; XCTAssertTrue(true) } }
    }
    @MainActor final class Other: XCTestCase {
        func testReader() { evaluate { XCTAssertTrue(true) } }
    }
    """
    let after = before.replacingOccurrences(of: "candidate() }", with: "candidate(); XCTAssertTrue(true) }")
        .replacingOccurrences(of: "private func candidate() {", with: "private func candidate() { XCTAssertTrue(true);")
    let tests = ["UI/Suite/testConsumer()", "UI/Other/testReader()"]
    let current = try boundaryGraph(["UI.swift": after], tests: tests, root: root)
    let base = ["UI:UI.swift": SwiftSourceSnapshot.parse(before, path: "UI.swift", module: "UI")]
    let control = XcodeHeadOnlySelector.select(current: current, source: .init(base: base, mappings: current.mappings), changes: [.init(path: "UI.swift")], baseRevision: "base")
    #expect(control.selectedTests == [tests[0]], "\(control.diagnostics)")
    #expect(control.diagnostics.isEmpty)
    for revision in ["head", "base"] {
        var head = current, old = base
        if revision == "head" {
            for i in head.sources["UI:UI.swift"]!.units.indices where head.sources["UI:UI.swift"]!.units[i].helperCallableName == "testConsumer" {
                head.sources["UI:UI.swift"]!.units[i].helperCallerStatementSignatures = nil
            }
        } else {
            for i in old["UI:UI.swift"]!.units.indices where old["UI:UI.swift"]!.units[i].helperCallableName == "testConsumer" {
                old["UI:UI.swift"]!.units[i].helperCallerStatementSignatures = nil
            }
        }
        let report = XcodeHeadOnlySelector.select(current: head, source: .init(base: old, mappings: current.mappings), changes: [.init(path: "UI.swift")], baseRevision: "base")
        #expect(report.selectedTests == tests.sorted())
        #expect(report.diagnostics.contains { $0.message.contains("historical caller body effects") })
    }
    for text in ["func caller() { action(); func action() {} }", "func caller() { let value = Local(); struct Local {} }"] {
        let source = SwiftSourceSnapshot.parse(text, path: "UI.swift", module: "UI")
        #expect(source.units.first { $0.helperCallableName == "caller" }?.helperCallerStatementSignatures == nil)
    }
}

@Test func historicalConditionalCallerEffectsRequireAllBranches() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("helper-conditional-effects-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let before = """
    import XCTest
    func evaluate(_ body: () -> Void) { body() }
    @MainActor final class Suite: XCTestCase {
        func testConsumer() {
            #if HISTORICAL_EFFECT
            UserDefaults.standard.set(true, forKey: "shared")
            #endif
            candidate()
        }
        private func candidate() { for _ in 0..<2 { let value = 1; XCTAssertTrue(true) } }
    }
    @MainActor final class Other: XCTestCase {
        func testReader() { evaluate { XCTAssertTrue(UserDefaults.standard.bool(forKey: "shared")) } }
    }
    """
    let after = before.replacingOccurrences(of: "private func candidate() {", with: "private func candidate() { XCTAssertTrue(true);")
    let tests = ["UI/Suite/testConsumer()", "UI/Other/testReader()"]
    let old = try boundaryGraph(["UI.swift": before], tests: tests, root: root, compilerArguments: ["-D", "HISTORICAL_EFFECT"])
    let current = try boundaryGraph(["UI.swift": after], tests: tests, root: root)
    let graph = try #require(old.dependencies)
    let writes = Set(graph.functions.filter { node in
        (node.value.dynamicCallSignatures ?? []).contains { $0.contains("UserDefaults.set") }
    }.keys)
    try #require(!writes.isEmpty)
    try #require(DependencyIndex(graph).paths(to: writes).path(from: graph.tests[tests[0]] ?? []) != nil)
    let report = XcodeHeadOnlySelector.select(current: current, source: .init(base: old.sources, mappings: current.mappings), changes: [.init(path: "UI.swift")], baseRevision: "base")
    #expect(report.selectedTests == tests.sorted(), "\(report.diagnostics)")
    #expect(report.diagnostics.contains { $0.code == "head_only_helper_callee_effects" })
}
