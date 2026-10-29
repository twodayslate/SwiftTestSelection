// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation
import Testing
@testable import TestImpact

@Test(arguments: ["property", "methodValue"], [false, true])
func compiledBareCallerMembersRequireHistoricalEffects(kind: String, explicit: Bool) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("helper-bare-member-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let expression = kind == "property" ? "let result = \(explicit ? "self." : "")value" : "let action = \(explicit ? "self." : "")perform; action()"
    let before = """
    import XCTest
    func evaluate(_ body: () -> Void) { body() }
    struct Worker {
        func invoke() { \(expression) }
    }
    @MainActor final class Suite: XCTestCase {
        func testConsumer() { Worker().invoke(); candidate() }
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
    let cleanExtra = "import XCTest\nextension Worker { " + (kind == "property" ? "var value: Int { return 1 }" : "func perform() {}") + " }"
    let oldExtra = cleanExtra.replacingOccurrences(of: kind == "property" ? "return 1" : "func perform() {", with: kind == "property" ? "UserDefaults.standard.set(true, forKey: \"shared\"); return 1" : "func perform() { UserDefaults.standard.set(true, forKey: \"shared\");")
    let tests = ["UI/Suite/testConsumer()", "UI/Other/testReader()"]
    let old = try boundaryGraph(["UI.swift": before, "Extra.swift": oldExtra], tests: tests, root: root)
    let current = try GraphArchive.decode(GraphArchive.encode(boundaryGraph(["UI.swift": after, "Extra.swift": cleanExtra], tests: tests, root: root)))
    let cleanBase = ["UI:UI.swift": SwiftSourceSnapshot.parse(before, path: "UI.swift", module: "UI"),
                     "UI:Extra.swift": SwiftSourceSnapshot.parse(cleanExtra, path: "Extra.swift", module: "UI")]
    let clean = XcodeHeadOnlySelector.select(current: current, source: .init(base: cleanBase, mappings: current.mappings),
        changes: [.init(path: "UI.swift")], baseRevision: "base")
    #expect(clean.selectedTests == [tests[0]], "\(clean.diagnostics)")
    #expect(clean.diagnostics.isEmpty)
    let graph = try #require(old.dependencies)
    let custom = Set(graph.functions.filter { $0.value.regions.contains { $0.path == "Extra.swift" } }.keys)
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
}

@Test(arguments: ["changed", "deleted"], [false, true])
func compiledStoredInitializersRequireHistoricalEffects(change: String, removedUse: Bool) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("helper-stored-init-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let before = """
    import XCTest
    func evaluate(_ body: () -> Void) { body() }
    @MainActor final class Suite: XCTestCase {
        func testConsumer() { let worker = Worker(); candidate() }
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
    if removedUse { after = after.replacingOccurrences(of: "let worker = Worker();", with: "") }
    let cleanExtra = "import XCTest\nstruct Worker {\n    \(change == "changed" ? "var value: Int = 1" : "")\n}"
    let oldExtra = "import XCTest\nstruct Worker {\n    var value: Int = { UserDefaults.standard.set(true, forKey: \"shared\"); return 1 }()\n}"
    let tests = ["UI/Suite/testConsumer()", "UI/Other/testReader()"]
    let old = try boundaryGraph(["UI.swift": before, "Extra.swift": oldExtra], tests: tests, root: root)
    let current = try GraphArchive.decode(GraphArchive.encode(boundaryGraph(["UI.swift": after, "Extra.swift": cleanExtra], tests: tests, root: root)))
    let cleanBefore = removedUse ? before.replacingOccurrences(of: "let worker = Worker();", with: "") : before
    let cleanBase = ["UI:UI.swift": SwiftSourceSnapshot.parse(cleanBefore, path: "UI.swift", module: "UI"),
                     "UI:Extra.swift": SwiftSourceSnapshot.parse(cleanExtra, path: "Extra.swift", module: "UI")]
    let clean = XcodeHeadOnlySelector.select(current: current, source: .init(base: cleanBase, mappings: current.mappings),
        changes: [.init(path: "UI.swift")], baseRevision: "base")
    #expect(clean.selectedTests == [tests[0]], "\(clean.diagnostics)")
    #expect(clean.diagnostics.isEmpty)
    var unrelated = XcodeHeadOnlySources(base: cleanBase, mappings: current.mappings)
    unrelated.unownedBaseSources["Unused.swift"] = .parse("import Foundation\nstruct Unrelated { let value = { UserDefaults.standard.set(true, forKey: \"shared\"); return 1 }() }",
        path: "Unused.swift", module: "")
    #expect(XcodeHeadOnlySelector.select(current: current, source: unrelated, changes: [.init(path: "UI.swift")], baseRevision: "base").selectedTests == [tests[0]])
    if !removedUse && change == "changed" {
        for revision in ["head", "base"] {
            var broken = current, source = cleanBase
            if revision == "head" {
                for i in broken.sources["UI:Extra.swift"]!.units.indices {
                    broken.sources["UI:Extra.swift"]!.units[i].helperStoredInitializer = nil
                }
            } else {
                for i in source["UI:Extra.swift"]!.units.indices {
                    source["UI:Extra.swift"]!.units[i].helperStoredInitializer = nil
                }
            }
            let report = XcodeHeadOnlySelector.select(current: broken, source: .init(base: source, mappings: current.mappings),
                changes: [.init(path: "UI.swift")], baseRevision: "base")
            #expect(report.selectedTests == tests.sorted())
            #expect(report.diagnostics.contains { $0.message.contains("storage initializer evidence") })
        }
    }
    let graph = try #require(old.dependencies)
    let custom = Set(graph.functions.filter { $0.value.regions.contains { $0.path == "Extra.swift" } }.keys)
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
}

@Test func callerStoredInitializerInventoryDistinguishesComputedProperties() throws {
    let source = SwiftSourceSnapshot.parse("""
    struct Worker {
        let stored = 1
        var observed = 1 { didSet {} }
        var computed: Int { 1 }
        static let shared = 1
        init() {}
    }
    """, path: "Extra.swift", module: "UI")
    for name in ["stored", "observed", "shared"] {
        let unit = try #require(source.units.first { $0.helperDeclaredMembers?.contains(name) == true })
        #expect(unit.helperStoredInitializer == true)
    }
    for name in ["computed", "init"] {
        let unit = try #require(source.units.first { $0.helperDeclaredMembers?.contains(name) == true })
        #expect(unit.helperStoredInitializer == false)
    }
}
