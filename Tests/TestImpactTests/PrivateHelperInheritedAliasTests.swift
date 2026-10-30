// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation
import Testing
@testable import TestImpact

@Test(arguments: ["ParentAlias", "UI.ParentAlias", "`UI` /* module */ . `ParentAlias`", "Namespace.ParentAlias", "NamespaceAlias.Parent", "indirect", "extension"])
func historicalInheritedAliasesCannotHideDefaultWitnesses(spelling: String) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("helper-inherited-alias-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let before = """
    import XCTest
    func evaluate(_ body: () -> Void) { body() }
    @MainActor final class Suite: XCTestCase {
        func testConsumer() { _ = Worker.value.isEmpty; candidate() }
        private func candidate() { for _ in 0..<2 { let value = 1; XCTAssertTrue(true) } }
    }
    @MainActor final class Other: XCTestCase {
        func testReader() { evaluate { XCTAssertTrue(UserDefaults.standard.bool(forKey: "shared")) } }
    }
    """
    let after = before.replacingOccurrences(of: "private func candidate() {", with: "private func candidate() { XCTAssertTrue(true);")
    let write = "UserDefaults.standard.set(true, forKey: \"shared\")"
    let protocols = """
    import XCTest
    protocol EffectProtocol: Collection where Index == Int, Element == Int {}
    extension EffectProtocol {
        var startIndex: Int { \(write); return 0 }
        var endIndex: Int { 1 }
        func index(after i: Int) -> Int { i + 1 }
        subscript(position: Int) -> Int { 1 }
    }
    protocol PureProtocol {}
    extension PureProtocol { var isEmpty: Bool { false } }
    """
    let aliases: String
    if spelling == "Namespace.ParentAlias" {
        aliases = "enum Namespace { typealias ParentAlias = EffectProtocol }"
    } else if spelling == "NamespaceAlias.Parent" {
        aliases = "enum Namespace { typealias Parent = EffectProtocol }; typealias NamespaceAlias = Namespace"
    } else {
        aliases = "typealias ParentAlias = EffectProtocol"
    }
    let nominal: String
    if spelling == "indirect" {
        nominal = "protocol Bridge: ParentAlias {}; enum Worker: Bridge { case value }"
    } else if spelling == "extension" {
        nominal = "enum Worker { case value }; extension Worker: ParentAlias {}"
    } else {
        nominal = "enum Worker: \(spelling) { case value }"
    }
    let headAliases = aliases.replacingOccurrences(of: "= EffectProtocol", with: "= PureProtocol")
    let probe = root.appendingPathComponent("Probe.swift"), executable = root.appendingPathComponent("probe")
    let runtime = "var reached = false\n" + protocols.replacingOccurrences(of: "import XCTest", with: "")
        .replacingOccurrences(of: write, with: "reached = true") + "\n" + aliases + "\n" + nominal
        + "\n_ = Worker.value.isEmpty\nprecondition(reached)"
    try Data(runtime.utf8).write(to: probe)
    _ = try CommandRunner.run("xcrun", ["swiftc", "-module-name", "UI", probe.path, "-o", executable.path], at: root)
    _ = try CommandRunner.run(executable.path, [], at: root)
    let tests = ["UI/Suite/testConsumer()", "UI/Other/testReader()"]
    let oldFiles = ["UI.swift": before, "Protocols.swift": protocols, "Aliases.swift": aliases, "Worker.swift": nominal]
    let old = try boundaryGraph(oldFiles, tests: tests, root: root)
    let current = try GraphArchive.decode(GraphArchive.encode(boundaryGraph([
        "UI.swift": after, "Protocols.swift": protocols, "Aliases.swift": headAliases, "Worker.swift": nominal], tests: tests, root: root)))
    for unowned in [[], ["Aliases.swift"], ["Aliases.swift", "Protocols.swift", "Worker.swift"]] {
        var source = XcodeHeadOnlySources(base: old.sources, mappings: current.mappings)
        for path in unowned {
            source.base.removeValue(forKey: "UI:" + path)
            source.unownedBaseSources[path] = .parse(oldFiles[path]!, path: path, module: "")
        }
        let report = XcodeHeadOnlySelector.select(current: current, source: source,
            changes: [.init(path: "UI.swift")], baseRevision: "base")
        #expect(report.selectedTests == tests.sorted(), "spelling=\(spelling) unowned=\(unowned) \(report.diagnostics)")
        #expect(report.diagnostics.contains { $0.message.contains("historical caller inherited type alias") })
    }
    var ordinary = current
    for index in ordinary.sources["UI:UI.swift"]!.units.indices {
        ordinary.sources["UI:UI.swift"]!.units[index].privateTestHelper = nil
    }
    let control = XcodeHeadOnlySelector.select(current: ordinary, source: .init(base: old.sources, mappings: current.mappings),
        changes: [.init(path: "UI.swift")], baseRevision: "base")
    #expect(control.selectedTests == tests.sorted())

    // Unused aliases must not invalidate a direct, checked conformance.
    let cleanNominal = "enum Worker: PureProtocol { case value }"
    let clean = try boundaryGraph(["UI.swift": after, "Protocols.swift": protocols,
        "Aliases.swift": aliases, "Worker.swift": cleanNominal], tests: tests, root: root)
    var cleanBase = clean.sources
    cleanBase["UI:UI.swift"] = .parse(before, path: "UI.swift", module: "UI")
    let focused = XcodeHeadOnlySelector.select(current: clean, source: .init(base: cleanBase, mappings: clean.mappings),
        changes: [.init(path: "UI.swift")], baseRevision: "base")
    #expect(focused.selectedTests == [tests[0]], "\(focused.diagnostics)")
    #expect(focused.diagnostics.isEmpty)
    for evidence in ["aliases", "requirements"] {
        for revision in ["base", "head"] {
            var head = clean, base = cleanBase
            if evidence == "aliases" {
                if revision == "base" { base["UI:Aliases.swift"]!.typeAliases = nil }
                else { head.sources["UI:Aliases.swift"]!.typeAliases = nil }
            } else if revision == "base" {
                for i in base["UI:Worker.swift"]!.units.indices { base["UI:Worker.swift"]!.units[i].helperGenericRequirements = nil }
            } else {
                for i in head.sources["UI:Worker.swift"]!.units.indices { head.sources["UI:Worker.swift"]!.units[i].helperGenericRequirements = nil }
            }
            let missing = XcodeHeadOnlySelector.select(current: head, source: .init(base: base, mappings: clean.mappings),
                changes: [.init(path: "UI.swift")], baseRevision: "base")
            #expect(missing.selectedTests == tests.sorted())
            #expect(!missing.diagnostics.isEmpty)
        }
    }
}

@Test(arguments: ["protocol", "concrete", "qualified", "trivia", "whereChanged", "whereUnchanged"])
func historicalOpaqueConformanceContextsRequireEffects(context: String) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("helper-conformance-context-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let before = """
    import XCTest
    func evaluate(_ body: () -> Void) { body() }
    @MainActor final class Suite: XCTestCase {
        func testConsumer() { _ = Worker.value.isEmpty; candidate() }
        private func candidate() { for _ in 0..<2 { let value = 1; XCTAssertTrue(true) } }
    }
    @MainActor final class Other: XCTestCase {
        func testReader() { evaluate { XCTAssertTrue(UserDefaults.standard.bool(forKey: "shared")) } }
    }
    """
    let after = before.replacingOccurrences(of: "private func candidate() {", with: "private func candidate() { XCTAssertTrue(true);")
    let oldExtra = """
    import XCTest
    protocol EffectProtocol: Collection {}
    \(context.hasPrefix("where") ? "" : "typealias WitnessAlias = " + (context == "concrete" ? "Worker" : "EffectProtocol"))
    extension \(context.hasPrefix("where") ? "EffectProtocol" : context == "qualified" ? "UI.WitnessAlias" : context == "trivia" ? "`UI` /* module */ . `WitnessAlias`" : "WitnessAlias") {
        var startIndex: Int { UserDefaults.standard.set(true, forKey: "shared"); return 0 }
        var endIndex: Int { 1 }
        func index(after i: Int) -> Int { i + 1 }
        subscript(position: Int) -> Int { 1 }
    }

    \(context.hasPrefix("where") ? "protocol Bridge where Self: EffectProtocol {}" : "")
    enum Worker: \(context.hasPrefix("where") ? "Bridge" : "EffectProtocol") { case value }
    """
    let newExtra = context == "whereChanged"
        ? oldExtra.replacingOccurrences(of: "Self: EffectProtocol", with: "Self: PureProtocol") + "\nprotocol PureProtocol {}; extension PureProtocol { var isEmpty: Bool { false } }"
        : oldExtra + "\nextension Worker { var isEmpty: Bool { false } }"
    let probe = root.appendingPathComponent("probe.swift"), executable = root.appendingPathComponent("probe")
    let runtime = "var reached = false\n" + oldExtra.replacingOccurrences(of: "import XCTest", with: "").replacingOccurrences(of: "UserDefaults.standard.set(true, forKey: \"shared\")", with: "reached = true") + "\n_ = Worker.value.isEmpty\nprecondition(reached)"
    try Data(runtime.utf8).write(to: probe)
    _ = try CommandRunner.run("xcrun", ["swiftc", "-module-name", "UI", probe.path, "-o", executable.path], at: root)
    _ = try CommandRunner.run(executable.path, [], at: root)
    let tests = ["UI/Suite/testConsumer()", "UI/Other/testReader()"]
    let old = try boundaryGraph(["UI.swift": before, "Extra.swift": oldExtra], tests: tests, root: root)
    let current = try GraphArchive.decode(GraphArchive.encode(boundaryGraph(["UI.swift": after, "Extra.swift": newExtra], tests: tests, root: root)))
    for unowned in [false, true] {
        var source = XcodeHeadOnlySources(base: old.sources, mappings: current.mappings)
        if unowned {
            source.base.removeValue(forKey: "UI:Extra.swift")
            source.unownedBaseSources["Extra.swift"] = .parse(oldExtra, path: "Extra.swift", module: "")
        }
        let report = XcodeHeadOnlySelector.select(current: current, source: source, changes: [.init(path: "UI.swift")], baseRevision: "base")
        #expect(report.selectedTests == tests.sorted(), "context=\(context) unowned=\(unowned) \(report.diagnostics)")
        #expect(report.diagnostics.contains { $0.message.contains(context.hasPrefix("where") ? "generic requirements" : "extension through a type alias") })
        var ordinary = current
        for i in ordinary.sources["UI:UI.swift"]!.units.indices { ordinary.sources["UI:UI.swift"]!.units[i].privateTestHelper = nil }
        let control = XcodeHeadOnlySelector.select(current: ordinary, source: source, changes: [.init(path: "UI.swift")], baseRevision: "base")
        #expect(control.selectedTests == tests.sorted())
    }
}

@Test func historicalConformanceRequirementInventoryCoversNominalsAndExtensions() throws {
    let source = SwiftSourceSnapshot.parse("""
    protocol Parent {}
    protocol Child where Self: Parent {}
    struct Value<T> where T: Parent {}
    enum Choice<T> where T: Parent {}
    class Owner<T> where T: Parent {}
    extension Value where T == Int {}
    #if CUSTOM
    protocol Conditional where Self: Parent {}
    #endif
    """, path: "Extra.swift", module: "UI")
    for (scope, expected) in [("Parent", []), ("Child", ["Self: Parent"]),
        ("Value", ["T: Parent"]), ("Choice", ["T: Parent"]), ("Owner", ["T: Parent"]),
        ("Conditional", ["Self: Parent"])] {
        let unit = try #require(source.units.first { $0.kind == "type" && $0.scope == scope })
        #expect(unit.helperGenericRequirements == expected)
    }
    #expect(source.units.first { $0.kind == "extension" }?.helperGenericRequirements == ["T == Int"])
}
