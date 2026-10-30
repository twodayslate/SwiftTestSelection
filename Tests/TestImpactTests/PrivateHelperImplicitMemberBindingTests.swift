// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation
import Testing
@testable import TestImpact

@Test(arguments: ["enumDefault", "iterator", "iteratorFactory"], [false, true])
func compiledImplicitCallerMembersRequireHistoricalEffects(kind: String, removed: Bool) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("helper-implicit-member-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let expression = kind == "enumDefault" ? "let worker = Worker.item()" : "for _ in Worker() {}"
    let before = """
    import XCTest
    func evaluate(_ body: () -> Void) { body() }
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
    if removed { after = after.replacingOccurrences(of: expression, with: "_ = ()") }
    let cleanExtra = kind == "enumDefault" ? """
    import XCTest
    enum Worker {
        case item(Int = 1)
    }
    """ : """
    import XCTest
    struct Worker: Sequence, IteratorProtocol {
        typealias Element = Int
        mutating func next() -> Int? { return nil }
        func makeIterator() -> Worker { self }
    }
    """
    let oldExtra = kind == "iteratorFactory" ? cleanExtra.replacingOccurrences(of: "{ self }", with: "{ UserDefaults.standard.set(true, forKey: \"shared\"); return self }") : cleanExtra.replacingOccurrences(of: kind == "enumDefault" ? "Int = 1" : "return nil", with: kind == "enumDefault" ? "Int = { UserDefaults.standard.set(true, forKey: \"shared\"); return 1 }()" : "UserDefaults.standard.set(true, forKey: \"shared\"); return nil")
    let tests = ["UI/Suite/testConsumer()", "UI/Other/testReader()"]
    let old = try boundaryGraph(["UI.swift": before, "Extra.swift": oldExtra], tests: tests, root: root)
    let current = try GraphArchive.decode(GraphArchive.encode(boundaryGraph(["UI.swift": after, "Extra.swift": cleanExtra], tests: tests, root: root)))
    let graph = try #require(old.dependencies)
    let custom = Set(graph.functions.filter { (kind == "enumDefault" || $0.value.name.contains(kind == "iteratorFactory" ? "makeIterator" : "next")) && $0.value.regions.contains { $0.path == "Extra.swift" } }.keys)
    try #require(!custom.isEmpty)
    try #require(DependencyIndex(graph).paths(to: custom).path(from: graph.tests[tests[0]] ?? []) != nil)
    for unowned in [false, true] {
        var source = XcodeHeadOnlySources(base: try GraphArchive.decode(GraphArchive.encode(old)).sources, mappings: current.mappings)
        if unowned {
            source.base.removeValue(forKey: "UI:Extra.swift")
            source.unownedBaseSources["Extra.swift"] = .parse(oldExtra, path: "Extra.swift", module: "")
        }
        let report = XcodeHeadOnlySelector.select(current: current, source: source, changes: [.init(path: "UI.swift")], baseRevision: "base")
        #expect(report.selectedTests == tests.sorted())
        #expect(report.diagnostics.contains { $0.code == "head_only_helper_callee_effects" })
    }
    let cleanBefore = removed ? before.replacingOccurrences(of: expression, with: "_ = ()") : before
    let cleanBase = ["UI:UI.swift": SwiftSourceSnapshot.parse(cleanBefore, path: "UI.swift", module: "UI"),
                     "UI:Extra.swift": SwiftSourceSnapshot.parse(cleanExtra, path: "Extra.swift", module: "UI")]
    let control = XcodeHeadOnlySelector.select(current: current, source: .init(base: cleanBase, mappings: current.mappings), changes: [.init(path: "UI.swift")], baseRevision: "base")
    #expect(control.selectedTests == [tests[0]], "\(control.diagnostics)")
    #expect(control.diagnostics.isEmpty)
    let effectfulHead = try boundaryGraph(["UI.swift": after, "Extra.swift": oldExtra], tests: tests, root: root)
    for (index, base) in [cleanBase, old.sources].enumerated() {
        let report = XcodeHeadOnlySelector.select(current: effectfulHead, source: .init(base: base, mappings: current.mappings),
            changes: [.init(path: "UI.swift")], baseRevision: "base")
        if removed && index == 0 {
            #expect(report.selectedTests == [tests[0]], "\(report.diagnostics)")
            #expect(report.diagnostics.isEmpty)
        } else {
            #expect(report.selectedTests == tests.sorted())
            #expect(report.diagnostics.contains { $0.code == "head_only_helper_callee_effects" })
        }
    }
}

@Test func implicitIterationAndEnumCaseInventoriesAreComplete() throws {
    let source = SwiftSourceSnapshot.parse("""
    func iterate() { for _ in Worker() {} }
    func iterateAsync() async { for await _ in Worker() {} }
    enum Worker {
        case plain, payload(Int)
        case defaulted(Int = 1), mixed
        #if CUSTOM
        case conditional(Int = foreign())
        #endif
    }
    """, path: "Extra.swift", module: "UI")
    let sync = try #require(source.units.first { $0.helperCallableName == "iterate" }?.helperBindingUses)
    #expect(sync.members.isSuperset(of: ["makeIterator", "next"]))
    let async = try #require(source.units.first { $0.helperCallableName == "iterateAsync" }?.helperBindingUses)
    #expect(async.members.isSuperset(of: ["makeAsyncIterator", "next"]))
    for name in ["plain", "payload", "defaulted", "mixed", "conditional"] {
        #expect(source.dispatchMembers?.contains("Worker." + name) == true)
        let unit = try #require(source.units.first { $0.helperDeclaredMembers?.contains(name) == true })
        #expect(unit.helperEnumCaseWithoutDefaults == ["plain", "payload"].contains(name))
    }
}

@Test(arguments: [false, true])
func compiledEnumCasesWithoutDefaultsPreserveIsolation(payload: Bool) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("helper-plain-enum-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let before = """
    import XCTest
    func evaluate(_ body: () -> Void) { body() }
    @MainActor final class Suite: XCTestCase {
        func testConsumer() { let worker = Worker.item\(payload ? "(1)" : ""); candidate() }
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
    let after = before.replacingOccurrences(of: "private func candidate() {", with: "private func candidate() { XCTAssertTrue(true)")
    let extra = "enum Worker {\n    case item\(payload ? "(Int)" : "")\n}"
    let tests = ["UI/Suite/testConsumer()", "UI/Other/testReader()"]
    let current = try GraphArchive.decode(GraphArchive.encode(boundaryGraph(["UI.swift": after, "Extra.swift": extra], tests: tests, root: root)))
    let base = ["UI:UI.swift": SwiftSourceSnapshot.parse(before, path: "UI.swift", module: "UI"),
                "UI:Extra.swift": SwiftSourceSnapshot.parse(extra, path: "Extra.swift", module: "UI")]
    let report = XcodeHeadOnlySelector.select(current: current, source: .init(base: base, mappings: current.mappings),
        changes: [.init(path: "UI.swift")], baseRevision: "base")
    #expect(report.selectedTests == [tests[0]], "\(report.diagnostics)")
    #expect(report.diagnostics.isEmpty)
    for (revision, field) in [("head", "defaults"), ("base", "defaults"), ("head", "arguments"), ("base", "arguments")] {
        var broken = current, old = base
        if revision == "head" {
            for i in broken.sources["UI:Extra.swift"]!.units.indices {
                if field == "defaults" { broken.sources["UI:Extra.swift"]!.units[i].helperEnumCaseWithoutDefaults = nil }
                else { broken.sources["UI:Extra.swift"]!.units[i].helperEnumCaseValueArguments = nil }
            }
        } else {
            for i in old["UI:Extra.swift"]!.units.indices {
                if field == "defaults" { old["UI:Extra.swift"]!.units[i].helperEnumCaseWithoutDefaults = nil }
                else { old["UI:Extra.swift"]!.units[i].helperEnumCaseValueArguments = nil }
            }
        }
        let report = XcodeHeadOnlySelector.select(current: broken, source: .init(base: old, mappings: current.mappings),
            changes: [.init(path: "UI.swift")], baseRevision: "base")
        #expect(report.selectedTests == tests.sorted())
        #expect(report.diagnostics.contains { $0.code == "head_only_helper_callee_effects" })
    }
}
