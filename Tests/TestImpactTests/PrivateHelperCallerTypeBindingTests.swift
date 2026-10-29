// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation
import Testing
@testable import TestImpact

@Test(arguments: ["UInt", "URL"])
func compiledPrivateHelperCallerTypesRequireBothRevisionBindings(kind: String) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("helper-callertype-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let library = root.appendingPathComponent("Foreign.swift")
    try Data("""
    import Foundation
    public struct ForeignScalar: ExpressibleByIntegerLiteral {
        public init(integerLiteral value: Swift.Int) {
            UserDefaults.standard.set(true, forKey: "shared")
        }
    }
    public struct ForeignURL {
        public init(string: Swift.String) {
            UserDefaults.standard.set(true, forKey: "shared")
        }
    }
    """.utf8).write(to: library)
    _ = try CommandRunner.run("xcrun", ["swiftc", "-emit-module", "-module-name", "Foreign", library.path,
        "-emit-module-path", root.appendingPathComponent("Foreign.swiftmodule").path], at: root)
    let expression = kind == "UInt" ? "let value: UInt = 1" : "let value = URL(string: \"https://example.invalid\")"
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
    let after = before.replacingOccurrences(of: "private func candidate() {", with: "private func candidate() { XCTAssertTrue(true)")
    let extra = """
    import Foreign
    typealias \(kind) = \(kind == "UInt" ? "ForeignScalar" : "ForeignURL")
    """
    let tests = ["UI/Suite/testConsumer()", "UI/Other/testReader()"]
    let old = try boundaryGraph(["UI.swift": before, "Extra.swift": extra], tests: tests, root: root, compilerArguments: ["-I", root.path])
    let current = try boundaryGraph(["UI.swift": after], tests: tests, root: root)
    let graph = try #require(old.dependencies)
    let custom = Set(DependencyIndex(graph).symbols.filter { $0.contains(kind == "UInt" ? "7Foreign0A6Scalar" : "7Foreign0A3URL") })
    try #require(!custom.isEmpty)
    try #require(DependencyIndex(graph).paths(to: custom).path(from: graph.tests[tests[0]] ?? []) != nil)
    #expect(old.sources["UI:Extra.swift"]?.helperNamesUnshadowed == false)
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
    let cleanBase = ["UI:UI.swift": SwiftSourceSnapshot.parse(before, path: "UI.swift", module: "UI")]
    let clean = XcodeHeadOnlySelector.select(current: current, source: .init(base: cleanBase, mappings: current.mappings),
        changes: [.init(path: "UI.swift")], baseRevision: "base")
    #expect(clean.selectedTests == [tests[0]], "\(clean.diagnostics)")
    #expect(clean.diagnostics.isEmpty)
    let aliased = try boundaryGraph(["UI.swift": after, "Extra.swift": extra], tests: tests, root: root, compilerArguments: ["-I", root.path])
    for base in [cleanBase, old.sources] {
        let report = XcodeHeadOnlySelector.select(current: aliased, source: .init(base: base, mappings: current.mappings),
            changes: [.init(path: "UI.swift")], baseRevision: "base")
        #expect(report.selectedTests == tests.sorted())
        #expect(report.diagnostics.contains { $0.code == "head_only_helper_callee_effects" })
    }
}

@Test func privateHelperAuditsAllCallerTypeNames() {
    // Derive from the contracts so additions cannot silently bypass the
    // historical alias audit. Include nested and inactive aliases too.
    for name in SDKReceiverContracts.bindingNames {
        #expect(PrivateTestHelperSyntax.reservedNames.contains(name))
        for declaration in ["typealias `\(name)` = Foreign.Type",
                            "struct Holder { typealias `\(name)` = Foreign.Type }",
                            "#if CUSTOM\ntypealias `\(name)` = Foreign.Type\n#endif"] {
            let source = SwiftSourceSnapshot.parse("import Foreign\n" + declaration, path: "Extra.swift", module: "UI")
            #expect(source.diagnostics.isEmpty)
            #expect(source.helperNamesUnshadowed == false, "\(declaration)")
        }
    }
}

@Test func privateHelperAuditsQualifiedCallerTypesInExtensions() {
    for name in SDKReceiverContracts.nestedBindingNames {
        for owner in ["XCUIApplication", "XCTest.XCUIApplication", "Alias"] {
            let source = SwiftSourceSnapshot.parse("extension \(owner) { typealias `\(name)` = Foreign.Type }", path: "Extra.swift", module: "UI")
            #expect(source.diagnostics.isEmpty)
            #expect(source.helperNamesUnshadowed == false)
        }
        let unrelated = SwiftSourceSnapshot.parse("struct Custom { struct `\(name)` {} }", path: "Extra.swift", module: "UI")
        #expect(unrelated.helperNamesUnshadowed == true)
    }
}
