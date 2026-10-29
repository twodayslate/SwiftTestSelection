// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation
import Testing
@testable import TestImpact

@Test(arguments: ["explicit", "callable", "unqualified", "initializer", "subscript"], [false, true])
func compiledCallerProjectMembersRequireHistoricalImplementations(kind: String, removedUse: Bool) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("caller-projectmembers-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let name = kind == "callable" ? "callAsFunction" : "perform"
    let expression: String
    let declaration: String
    let overload: String
    switch kind {
    case "initializer":
        expression = "let worker = Worker(1)"
        declaration = "init(_ value: Int, extra: Int = 0) {}"
        overload = "init(_ value: Int) { UserDefaults.standard.set(true, forKey: \"shared\") }"
    case "subscript":
        expression = "let value = Worker()[review: 1]"
        declaration = "subscript(review value: Int, extra: Int = 0) -> Int { value }"
        overload = "subscript(review value: Int) -> Int { UserDefaults.standard.set(true, forKey: \"shared\"); return value }"
    default:
        expression = kind == "explicit" ? "Worker().perform(1)" : kind == "unqualified" ? "Worker().invoke()" : "let worker = Worker(); worker(1)"
        declaration = "func \(name)(_ value: Int, extra: Int = 0) {}" + (kind == "unqualified" ? "\nfunc invoke() { perform(1) }" : "")
        overload = "func \(name)(_ value: Int) { UserDefaults.standard.set(true, forKey: \"shared\") }"
    }
    let before = """
    import XCTest
    func evaluate(_ body: () -> Void) { body() }
    struct Worker {
        \(declaration)
    }
    @MainActor final class Suite: XCTestCase {
        func testConsumer() { \(expression); candidate() }
        private func candidate() {
            for _ in 0..<2 {
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
    if removedUse { after = after.replacingOccurrences(of: expression, with: "_ = ()") }
    let extra = """
    import XCTest
    extension Worker {
        \(overload)
    }
    """
    let tests = ["UI/Suite/testConsumer()", "UI/Other/testReader()"]
    let old = try boundaryGraph(["UI.swift": before, "Extra.swift": extra], tests: tests, root: root)
    let current = try boundaryGraph(["UI.swift": after], tests: tests, root: root)
    let graph = try #require(old.dependencies)
    let custom = Set(graph.functions.filter { $0.value.regions.contains { $0.path == "Extra.swift" } }.keys)
    try #require(!custom.isEmpty)
    try #require(DependencyIndex(graph).paths(to: custom).path(from: graph.tests[tests[0]] ?? []) != nil)
    let archivedOld = try GraphArchive.decode(GraphArchive.encode(old))
    let archivedCurrent = try GraphArchive.decode(GraphArchive.encode(current))
    for unowned in [false, true] {
        var source = XcodeHeadOnlySources(base: archivedOld.sources, mappings: current.mappings)
        if unowned { source.unownedBaseSources["Extra.swift"] = source.base.removeValue(forKey: "UI:Extra.swift") }
        let report = XcodeHeadOnlySelector.select(current: archivedCurrent, source: source,
            changes: [.init(path: "UI.swift")], baseRevision: "base")
        #expect(report.diagnostics.contains { $0.code == "head_only_helper_callee_effects" })
        #expect(report.selectedTests == tests.sorted())
    }
    let cleanBefore = removedUse ? before.replacingOccurrences(of: expression, with: "_ = ()") : before
    let cleanBase = ["UI:UI.swift": SwiftSourceSnapshot.parse(cleanBefore, path: "UI.swift", module: "UI")]
    let clean = XcodeHeadOnlySelector.select(current: current, source: .init(base: cleanBase, mappings: current.mappings),
        changes: [.init(path: "UI.swift")], baseRevision: "base")
    #expect(clean.selectedTests == [tests[0]], "\(clean.diagnostics)")
    #expect(clean.diagnostics.isEmpty)
    let overloaded = try boundaryGraph(["UI.swift": after, "Extra.swift": extra], tests: tests, root: root)
    for (index, base) in [cleanBase, old.sources].enumerated() {
        let report = XcodeHeadOnlySelector.select(current: overloaded, source: .init(base: base, mappings: current.mappings),
            changes: [.init(path: "UI.swift")], baseRevision: "base")
        if removedUse && index == 0 {
            #expect(report.selectedTests == [tests[0]], "\(report.diagnostics)")
            #expect(report.diagnostics.isEmpty)
        } else {
            #expect(report.selectedTests == tests.sorted())
            #expect(report.diagnostics.contains { $0.code == "head_only_helper_callee_effects" })
        }
    }
    if !removedUse {
        for revision in ["base", "head"] {
            var broken = current, base = cleanBase
            if revision == "base" {
                for i in base["UI:UI.swift"]!.units.indices { base["UI:UI.swift"]!.units[i].helperDeclaredMembers = nil }
            } else {
                for i in broken.sources["UI:UI.swift"]!.units.indices { broken.sources["UI:UI.swift"]!.units[i].helperDeclaredMembers = nil }
            }
            let report = XcodeHeadOnlySelector.select(current: broken, source: .init(base: base, mappings: current.mappings),
                changes: [.init(path: "UI.swift")], baseRevision: "base")
            #expect(report.selectedTests == tests.sorted())
            #expect(report.diagnostics.contains { $0.code == "head_only_helper_callee_effects" })
        }
    }
}
