// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation
import Testing
@testable import TestImpact

@Test(arguments: ["direct", "scoped", "reexport"])
func compiledHistoricalCallerImportsRequireBindingProof(kind: String) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("helper-historical-import-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let foreign = root.appendingPathComponent("Foreign.swift")
    try Data("""
    import Foundation
    public func min(_ a: Int, _ b: Int) -> Int {
        UserDefaults.standard.set(true, forKey: "shared")
        return a
    }
    """.utf8).write(to: foreign)
    _ = try CommandRunner.run("xcrun", ["swiftc", "-emit-module", "-module-name", "Foreign", foreign.path,
        "-emit-module-path", root.appendingPathComponent("Foreign.swiftmodule").path], at: root)
    let before = """
    import XCTest
    func evaluate(_ body: () -> Void) { body() }
    @MainActor final class Suite: XCTestCase {
        func testConsumer() { let value = produce(); candidate() }
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
    let cleanExtra = "import Foundation\nfunc produce() -> Int { min(1, 2) }"
    let oldExtra = kind == "reexport" ? cleanExtra : cleanExtra.replacingOccurrences(of: "import Foundation",
        with: kind == "scoped" ? "import func Foreign.min" : "import Foreign")
    var oldFiles = ["UI.swift": before, "Extra.swift": oldExtra]
    if kind == "reexport" { oldFiles["Bridge.swift"] = "@_exported import Foreign" }
    let tests = ["UI/Suite/testConsumer()", "UI/Other/testReader()"]
    let old = try boundaryGraph(oldFiles, tests: tests, root: root, compilerArguments: ["-I", root.path])
    let current = try GraphArchive.decode(GraphArchive.encode(boundaryGraph(["UI.swift": after, "Extra.swift": cleanExtra], tests: tests, root: root)))
    let graph = try #require(old.dependencies)
    let foreignCalls = Set(graph.functions.values.flatMap(\.dependencies).filter { $0.contains("$s7Foreign3min") })
    try #require(!foreignCalls.isEmpty)
    try #require(DependencyIndex(graph).paths(to: foreignCalls).path(from: graph.tests[tests[0]] ?? []) != nil)
    for unowned in [false, true] {
        var source = XcodeHeadOnlySources(base: try GraphArchive.decode(GraphArchive.encode(old)).sources, mappings: current.mappings)
        if unowned {
            let path = kind == "reexport" ? "Bridge.swift" : "Extra.swift"
            source.base.removeValue(forKey: "UI:" + path)
            source.unownedBaseSources[path] = .parse(oldFiles[path]!, path: path, module: "")
        }
        let report = XcodeHeadOnlySelector.select(current: current, source: source,
            changes: [.init(path: "UI.swift")], baseRevision: "base")
        #expect(report.selectedTests == tests.sorted(), "unowned=\(unowned) diagnostics=\(report.diagnostics)")
        // A base-only re-export can also invalidate the module source inventory.
        #expect(!report.diagnostics.isEmpty)
        if kind != "reexport" {
            #expect(report.diagnostics.contains { $0.code == "head_only_helper_callee_effects" && $0.message.contains("imports") })
        }
        var ordinary = current
        for i in ordinary.sources["UI:UI.swift"]!.units.indices { ordinary.sources["UI:UI.swift"]!.units[i].privateTestHelper = nil }
        #expect(XcodeHeadOnlySelector.select(current: ordinary, source: source, changes: [.init(path: "UI.swift")], baseRevision: "base").selectedTests == tests.sorted())
    }
    let cleanBase = ["UI:UI.swift": SwiftSourceSnapshot.parse(before, path: "UI.swift", module: "UI"),
                     "UI:Extra.swift": SwiftSourceSnapshot.parse(cleanExtra, path: "Extra.swift", module: "UI")]
    let control = XcodeHeadOnlySelector.select(current: current, source: .init(base: cleanBase, mappings: current.mappings),
        changes: [.init(path: "UI.swift")], baseRevision: "base")
    #expect(control.selectedTests == [tests[0]], "\(control.diagnostics)")
    #expect(control.diagnostics.isEmpty)
    if kind == "direct" {
        for revision in ["head", "base"] {
            for field in ["localVisibility", "callerImports"] {
                var broken = current, source = cleanBase
                var snapshot = revision == "head" ? broken.sources["UI:Extra.swift"]! : source["UI:Extra.swift"]!
                if field == "localVisibility" { snapshot.helperImportsLocal = nil }
                else { for i in snapshot.units.indices { snapshot.units[i].receiverImportsSupported = nil } }
                if revision == "head" { broken.sources["UI:Extra.swift"] = snapshot }
                else { source["UI:Extra.swift"] = snapshot }
                let report = XcodeHeadOnlySelector.select(current: broken, source: .init(base: source, mappings: current.mappings),
                    changes: [.init(path: "UI.swift")], baseRevision: "base")
                #expect(report.selectedTests == tests.sorted())
            }
        }
        // An ordinary unused import in another file does not export bindings.
        var source = cleanBase
        source["UI:Unused.swift"] = .parse("import Foreign", path: "Unused.swift", module: "UI")
        #expect(XcodeHeadOnlySelector.select(current: current, source: .init(base: source, mappings: current.mappings),
            changes: [.init(path: "UI.swift")], baseRevision: "base").selectedTests == [tests[0]])
    }
}

@Test func callerImportVisibilityIncludesConditionalReexports() {
    for text in ["@_exported import Foreign", "#if FLAG\n@_exported import Foreign\n#endif"] {
        #expect(SwiftSourceSnapshot.parse(text, path: "Imports.swift", module: "UI").helperImportsLocal == false)
    }
    for text in ["import Foreign", "import Foundation", "import func Foreign.min", ""] {
        #expect(SwiftSourceSnapshot.parse(text, path: "Imports.swift", module: "UI").helperImportsLocal == true)
    }
}
