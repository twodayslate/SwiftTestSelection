// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation
import Testing
@testable import TestImpact

@Test(arguments: ["annotation", "cast", "actor"])
func compiledPrivateHelperNamespaceAliasesRequireBothRevisionBindings(kind: String) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("helper-namespace-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    // The helper's own imports remain trusted. A different source imports the
    // foreign module and exposes its types through an apparently SDK spelling.
    let library = root.appendingPathComponent("Foreign.swift")
    try Data("""
    import Foundation
    public enum Types {
        public struct Int: ExpressibleByIntegerLiteral {
            public init(integerLiteral value: Swift.Int) {
                UserDefaults.standard.set(true, forKey: "shared")
            }
        }
    }
    @globalActor public actor ForeignActor {
        public static let shared: ForeignActor = {
            UserDefaults.standard.set(true, forKey: "shared")
            return ForeignActor()
        }()
    }
    """.utf8).write(to: library)
    _ = try CommandRunner.run("xcrun", ["swiftc", "-emit-module", "-module-name", "Foreign", library.path,
        "-emit-module-path", root.appendingPathComponent("Foreign.swiftmodule").path], at: root)
    let local = kind == "annotation" ? "let value: Swift.Int = 1" : kind == "cast" ? "let value = 1 as Swift.Int" : "let value = 1"
    let before = """
    import XCTest
    func evaluate(_ body: () -> Void) { body() }
    @MainActor final class Suite: XCTestCase {
        func testConsumer() \(kind == "actor" ? "async " : ""){ candidate() }
        private func candidate() {
            for _ in 0..<2 {
                \(local)
                XCTAssertTrue(true)
            }
        }
    }
    @MainActor final class Other: XCTestCase {
        func testReader() { evaluate { XCTAssertFalse(UserDefaults.standard.bool(forKey: "shared")) } }
    }
    """
    let after = before.replacingOccurrences(of: "private func candidate() {", with: "private func candidate() { XCTAssertTrue(true)")
    let extra = "import Foreign\ntypealias " + (kind == "actor" ? "MainActor = ForeignActor" : "Swift = Types")
    let tests = ["UI/Suite/testConsumer()", "UI/Other/testReader()"]
    let arguments = ["-I", root.path]
    let old = try boundaryGraph(["UI.swift": before, "Extra.swift": extra], tests: tests, root: root, compilerArguments: arguments)
    let current = try boundaryGraph(["UI.swift": after], tests: tests, root: root)
    // Unknown external symbols remain vertices in the dependency index. Prove
    // the base test reaches the foreign initializer/actor, not merely an alias.
    let graph = try #require(old.dependencies)
    let index = DependencyIndex(graph)
    let foreign = Set(index.symbols.filter { $0.contains(kind == "actor" ? "7Foreign0A5ActorC6shared" : "7Foreign5TypesO3IntV14integerLiteral") })
    try #require(!foreign.isEmpty)
    try #require(index.paths(to: foreign).path(from: graph.tests[tests[0]] ?? []) != nil)
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
    let cleanBase = ["UI:UI.swift": SwiftSourceSnapshot.parse(before, path: "UI.swift", module: "UI")]
    let clean = XcodeHeadOnlySelector.select(current: current, source: .init(base: cleanBase, mappings: current.mappings),
        changes: [.init(path: "UI.swift")], baseRevision: "base")
    #expect(clean.selectedTests == [tests[0]], "\(clean.diagnostics)")
    #expect(clean.diagnostics.isEmpty)
    let aliased = try boundaryGraph(["UI.swift": after, "Extra.swift": extra], tests: tests, root: root, compilerArguments: arguments)
    for base in [cleanBase, old.sources] {
        let report = XcodeHeadOnlySelector.select(current: aliased, source: .init(base: base, mappings: current.mappings),
            changes: [.init(path: "UI.swift")], baseRevision: "base")
        #expect(report.selectedTests == tests.sorted())
        #expect(report.diagnostics.contains { $0.code == "head_only_helper_callee_effects" })
    }
}

@Test func privateHelperAuditsTrustedNamespaceAndAnnotationAliases() {
    for name in ["Swift", "XCTest", "Foundation", "UIKit", "CoreGraphics", "MainActor"] {
        #expect(PrivateTestHelperSyntax.reservedNames.contains(name))
        for declaration in ["typealias \(name) = Foreign.Types", "typealias `\(name)` = Foreign.Types",
                            "struct Holder { typealias \(name) = Foreign.Types }",
                            "#if CUSTOM\ntypealias \(name) = Foreign.Types\n#endif"] {
            let source = SwiftSourceSnapshot.parse("import Foreign\n" + declaration, path: "Extra.swift", module: "UI")
            #expect(source.diagnostics.isEmpty)
            #expect(source.helperNamesUnshadowed == false, "\(declaration)")
        }
    }
    let imports = SwiftSourceSnapshot.parse("import XCTest\nimport Foundation\nimport Swift", path: "UI.swift", module: "UI")
    #expect(imports.helperNamesUnshadowed == true)
}
