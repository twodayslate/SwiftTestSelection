// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation
import Testing
@testable import TestImpact

@Test(arguments: ["CGRect", "CGVector", "max"])
func compiledPrivateHelperActorNamesRequireBothRevisionBindings(name: String) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("helper-actor-binding-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let arguments = name == "CGRect" ? "x: 0, y: 0, width: 1, height: 1" : name == "CGVector" ? "dx: 1, dy: 1" : "0, 1"
    let parameters = name == "CGRect" ? "x: Double, y: Double, width: Double, height: Double" : name == "CGVector" ? "dx: Double, dy: Double" : "_ lhs: Int, _ rhs: Int"
    let before = """
    import XCTest
    func evaluate(_ body: () -> Void) { body() }
    @MainActor final class Suite: XCTestCase {
        func testConsumer() { candidate() }
        private func candidate() {
            for _ in 0..<2 {
                let value = \(name)(\(arguments))
                XCTAssertTrue(true)
            }
        }
    }
    @MainActor final class Other: XCTestCase {
        func testReader() { evaluate { XCTAssertFalse(UserDefaults.standard.bool(forKey: "shared")) } }
    }
    """
    let after = before.replacingOccurrences(of: "private func candidate() {", with: "private func candidate() { XCTAssertTrue(true)")
    let extra = """
    import XCTest
    actor \(name) {
        init(\(parameters)) {
            UserDefaults.standard.set(true, forKey: "shared")
        }
    }
    """
    let tests = ["UI/Suite/testConsumer()", "UI/Other/testReader()"]
    let old = try boundaryGraph(["UI.swift": before, "Extra.swift": extra], tests: tests, root: root)
    let current = try boundaryGraph(["UI.swift": after], tests: tests, root: root)
    let graph = try #require(old.dependencies)
    let custom = Set(graph.functions.filter { $0.value.regions.contains { $0.path == "Extra.swift" } }.keys)
    try #require(!custom.isEmpty)
    try #require(DependencyIndex(graph).paths(to: custom).path(from: graph.tests[tests[0]] ?? []) != nil)
    #expect(old.sources["UI:Extra.swift"]?.helperNamesUnshadowed == false)
    let archivedOld = try GraphArchive.decode(GraphArchive.encode(old))
    let archivedCurrent = try GraphArchive.decode(GraphArchive.encode(current))
    #expect(archivedOld.sources["UI:Extra.swift"]?.helperNamesUnshadowed == false)
    for unowned in [false, true] {
        var source = XcodeHeadOnlySources(base: archivedOld.sources, mappings: current.mappings)
        if unowned {
            source.base.removeValue(forKey: "UI:Extra.swift")
            source.unownedBaseSources["Extra.swift"] = .parse(extra, path: "Extra.swift", module: "")
        }
        let report = XcodeHeadOnlySelector.select(current: archivedCurrent, source: source,
            changes: [.init(path: "UI.swift")], baseRevision: "base")
        #expect(report.selectedTests == tests.sorted(), "\(report.diagnostics)")
        #expect(report.diagnostics.contains { $0.code == "head_only_helper_callee_effects" })
    }
    // The SDK-only control still isolates the helper's direct consumer.
    let cleanBase = ["UI:UI.swift": SwiftSourceSnapshot.parse(before, path: "UI.swift", module: "UI")]
    let clean = XcodeHeadOnlySelector.select(current: current, source: .init(base: cleanBase, mappings: current.mappings),
        changes: [.init(path: "UI.swift")], baseRevision: "base")
    #expect(clean.selectedTests == [tests[0]], "\(clean.diagnostics)")
    #expect(clean.diagnostics.isEmpty)
    // Actors added at head or unchanged across both revisions also cannot be
    // mistaken for a standard function/constructor with the same spelling.
    let shadowed = try boundaryGraph(["UI.swift": after, "Extra.swift": extra], tests: tests, root: root)
    for base in [cleanBase, old.sources] {
        let report = XcodeHeadOnlySelector.select(current: shadowed, source: .init(base: base, mappings: current.mappings),
            changes: [.init(path: "UI.swift")], baseRevision: "base")
        #expect(report.selectedTests == tests.sorted())
        #expect(report.diagnostics.contains { $0.code == "head_only_helper_callee_effects" })
    }
}

@Test func privateHelperReservedNamesIncludeEveryNominalDeclaration() {
    for name in PrivateTestHelperSyntax.reservedNames.sorted() {
        for kind in ["actor", "distributed actor", "class", "struct", "enum", "protocol"] {
            for declaration in ["\(kind) `\(name)` {}", "struct Holder { \(kind) `\(name)` {} }", "#if CUSTOM\n\(kind) `\(name)` {}\n#endif"] {
                let source = SwiftSourceSnapshot.parse(declaration, path: "Extra.swift", module: "UI")
                #expect(source.diagnostics.isEmpty, "\(declaration)")
                #expect(source.helperNamesUnshadowed == false, "\(declaration)")
            }
        }
    }
    let unrelated = SwiftSourceSnapshot.parse("actor Worker { func work() {} }", path: "Extra.swift", module: "UI")
    #expect(unrelated.helperNamesUnshadowed == true)
}
