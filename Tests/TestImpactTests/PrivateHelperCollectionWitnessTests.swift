// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation
import Testing
@testable import TestImpact

@Test(arguments: ["startIndex", "endIndex", "subscript", "index", "formIndex", "equality"],
      ["explicitIterator", "sequence", "removed", "aliasedSequence", "nestedAliasSequence", "qualifiedRemoved"])
func compiledHistoricalCollectionWitnessesRequireEffects(witness: String, transition: String) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("helper-collection-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let worker = transition == "nestedAliasSequence" ? "Namespace.Worker" : transition == "qualifiedRemoved" ? "UI.Worker" : "Worker"
    let expression = transition.hasPrefix("property") ? "let value = Worker().isEmpty" : "for _ in \(worker)() {}"
    let before = """
    import XCTest
    func evaluate(_ body: () -> Void) { body() }
    @MainActor final class Suite: XCTestCase {
        func testConsumer() { \(expression); candidate() }
        private func candidate() {
            \(transition.hasPrefix("property") ? "if true" : "for _ in 0..<2") {
                let value = 1
                XCTAssertTrue(true)
            }
        }
    }
    @MainActor final class Other: XCTestCase {
        func testReader() { evaluate { XCTAssertTrue(UserDefaults.standard.bool(forKey: "shared")) } }
    }
    """
    var after = before.replacingOccurrences(of: "private func candidate() {", with: "private func candidate() { XCTAssertTrue(true)")
    if ["removed", "qualifiedRemoved"].contains(transition) { after = after.replacingOccurrences(of: expression, with: "_ = ()") }
    let effect = "UserDefaults.standard.set(true, forKey: \"shared\"); "
    func write(_ name: String) -> String { witness == name ? effect : "" }
    let indexType = witness == "equality" ? "Position" : "Int"
    var oldExtra = """
    import XCTest
    \(witness == "equality" ? """
    struct Position: Comparable {
        let value: Int
        static func == (lhs: Self, rhs: Self) -> Bool { \(effect)return lhs.value == rhs.value }
        static func < (lhs: Self, rhs: Self) -> Bool { lhs.value < rhs.value }
    }
    """ : "")
    struct Worker: Collection {
        var startIndex: \(indexType) { \(write("startIndex"))return \(witness == "equality" ? "Position(value: 0)" : "0") }
        var endIndex: \(indexType) { \(write("endIndex"))return \(witness == "equality" ? "Position(value: 1)" : "1") }
        func index(after i: \(indexType)) -> \(indexType) { \(write("index"))return \(witness == "equality" ? "Position(value: i.value + 1)" : "i + 1") }
        subscript(position: \(indexType)) -> Int { \(write("subscript"))return 1 }
        \(witness == "formIndex" ? "func formIndex(after i: inout Int) { \(effect)i += 1 }" : "")
    }
    """
    if transition == "aliasedSequence" {
        oldExtra = oldExtra.replacingOccurrences(of: "struct Worker:", with: "typealias Worker = OldWorker\nstruct OldWorker:")
    }
    if transition == "nestedAliasSequence" {
        oldExtra = oldExtra.replacingOccurrences(of: "struct Worker:", with: "enum Namespace { typealias Worker = OldWorker }\nstruct OldWorker:")
    }
    var cleanSequence = """
    import XCTest
    struct Worker: Sequence {
        func makeIterator() -> IndexingIterator<[Int]> { [1].makeIterator() }
    }
    """
    if transition.hasPrefix("property") { cleanSequence = "struct Worker { var isEmpty: Bool { false } }" }
    if transition == "nestedAliasSequence" {
        cleanSequence = cleanSequence.replacingOccurrences(of: "struct Worker:", with: "enum Namespace { struct Worker:") + "\n}"
    }
    if transition == "propertyExtension" {
        oldExtra = oldExtra.replacingOccurrences(of: "struct Worker: Collection", with: "struct Worker") + "\nextension Worker: Collection {}"
    }
    if transition == "propertyInherited" {
        oldExtra = oldExtra.replacingOccurrences(of: "struct Worker: Collection", with: "class Parent: Collection") + "\nclass Worker: Parent {}"
    }
    let cleanExtra: String
    if transition == "explicitIterator" {
        cleanExtra = oldExtra.replacingOccurrences(of: effect, with: "") + "\nextension Worker { func makeIterator() -> IndexingIterator<[Int]> { [1].makeIterator() } }"
    } else if transition.hasPrefix("property"), transition != "property" {
        cleanExtra = oldExtra.replacingOccurrences(of: effect, with: "") + "\nextension Worker { var isEmpty: Bool { false } }"
    } else { cleanExtra = cleanSequence }

    // The project's SIL graph may omit Swift's default implementation and its
    // witness edges. Execute the actual dispatch with a local sentinel, without
    // touching the machine's preferences or relying on that incomplete graph.
    let probe = root.appendingPathComponent("Probe.swift"), executable = root.appendingPathComponent("probe")
    let runtimeSource = "var reached = false\n" + oldExtra
        .replacingOccurrences(of: "import XCTest", with: "")
        .replacingOccurrences(of: effect, with: "reached = true; ") +
        "\n\(expression)\nprecondition(reached)\nprint(\"historical witness executed\")\n"
    try Data(runtimeSource.utf8).write(to: probe)
    _ = try CommandRunner.run("xcrun", ["swiftc", "-module-name", "UI", probe.path, "-o", executable.path], at: root)
    #expect(try CommandRunner.run(executable.path, [], at: root).text.contains("historical witness executed"))

    let tests = ["UI/Suite/testConsumer()", "UI/Other/testReader()"]
    let current = try GraphArchive.decode(GraphArchive.encode(boundaryGraph(["UI.swift": after, "Extra.swift": cleanExtra], tests: tests, root: root)))
    let base = ["UI:UI.swift": SwiftSourceSnapshot.parse(before, path: "UI.swift", module: "UI"),
                "UI:Extra.swift": SwiftSourceSnapshot.parse(oldExtra, path: "Extra.swift", module: "UI")]
    for unowned in [false, true] {
        var source = XcodeHeadOnlySources(base: base, mappings: current.mappings)
        if unowned {
            source.base.removeValue(forKey: "UI:Extra.swift")
            source.unownedBaseSources["Extra.swift"] = .parse(oldExtra, path: "Extra.swift", module: "")
        }
        let report = XcodeHeadOnlySelector.select(current: current, source: source,
            changes: [.init(path: "UI.swift")], baseRevision: "base")
        #expect(report.selectedTests == tests.sorted(), "witness=\(witness) transition=\(transition) unowned=\(unowned) diagnostics=\(report.diagnostics)")
        #expect(report.diagnostics.contains { $0.code == "head_only_helper_callee_effects" })
        var ordinary = current
        for i in ordinary.sources["UI:UI.swift"]!.units.indices { ordinary.sources["UI:UI.swift"]!.units[i].privateTestHelper = nil }
        #expect(XcodeHeadOnlySelector.select(current: ordinary, source: source,
            changes: [.init(path: "UI.swift")], baseRevision: "base").selectedTests == tests.sorted())
    }
    // A source-defined Collection is conservatively opaque without compiled
    // evidence for all its witnesses, even if head uses a custom iterator.
    // A Sequence with a checked iterator over SDK values remains supported.
    let cleanHead = try boundaryGraph(["UI.swift": after, "Extra.swift": cleanSequence], tests: tests, root: root)
    let cleanBase = ["UI:UI.swift": SwiftSourceSnapshot.parse(["removed", "qualifiedRemoved"].contains(transition) ? before.replacingOccurrences(of: expression, with: "_ = ()") : before, path: "UI.swift", module: "UI"),
                     "UI:Extra.swift": SwiftSourceSnapshot.parse(cleanSequence, path: "Extra.swift", module: "UI")]
    let control = XcodeHeadOnlySelector.select(current: cleanHead, source: .init(base: cleanBase, mappings: current.mappings),
        changes: [.init(path: "UI.swift")], baseRevision: "base")
    #expect(control.selectedTests == [tests[0]], "\(control.diagnostics)")
    #expect(control.diagnostics.isEmpty)
    if witness == "startIndex", transition == "sequence" {
        for revision in ["head", "base"] {
            var broken = cleanHead, base = cleanBase
            if revision == "head" {
                for i in broken.sources["UI:Extra.swift"]!.units.indices { broken.sources["UI:Extra.swift"]!.units[i].helperInheritedTypes = nil }
            } else {
                for i in base["UI:Extra.swift"]!.units.indices { base["UI:Extra.swift"]!.units[i].helperInheritedTypes = nil }
            }
            let report = XcodeHeadOnlySelector.select(current: broken, source: .init(base: base, mappings: current.mappings),
                changes: [.init(path: "UI.swift")], baseRevision: "base")
            #expect(report.selectedTests == tests.sorted())
            #expect(report.diagnostics.contains { $0.message.contains("conformance evidence") })
        }
    }
}

@Test(arguments: ["startIndex", "endIndex", "equality"],
      ["property", "propertySameConformance", "propertyExtension", "propertyInherited"])
func compiledHistoricalCollectionPropertiesRequireEffects(witness: String, transition: String) throws {
    try compiledHistoricalCollectionWitnessesRequireEffects(witness: witness, transition: transition)
}

@Test func callerConformanceAndNestedAliasInventoriesAreComplete() throws {
    let source = SwiftSourceSnapshot.parse("""
    protocol Traversal: Collection {}
    struct Value: Traversal {}
    enum Choice: String { case item }
    extension Value: Sendable {}
    class Parent: NSObject, Traversal {}
    enum Namespace {
        typealias Worker = Value
        #if CUSTOM
        typealias Alternate = Parent
        #endif
    }
    """, path: "Extra.swift", module: "UI")
    for (scope, expected) in [("Traversal", ["Collection"]), ("Value", ["Traversal"]),
                              ("Choice", ["String"]), ("Parent", ["NSObject", "Traversal"])] {
        let unit = try #require(source.units.first { $0.kind == "type" && $0.scope == scope })
        #expect(unit.helperInheritedTypes == expected)
    }
    #expect(source.units.first { $0.kind == "extension" }?.helperInheritedTypes == ["Sendable"])
    #expect(source.dispatchMembers?.isSuperset(of: ["Namespace.Worker", "Namespace.Alternate"]) == true)
}
