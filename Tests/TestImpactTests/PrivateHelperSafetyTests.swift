// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation
import Testing
@testable import TestImpact

@Test(arguments: ["operator", "operator-added", "subscript", "subscript-added", "removed-state", "rebound-state"])
func privateHelperIsolationRetainsEscapesAndRemovedState(kind: String) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("helper-safety-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let support: String
    var before: String
    let after: String
    let escaped = kind.hasPrefix("operator") || kind.hasPrefix("subscript")
    let added = kind.hasSuffix("-added")
    if escaped {
        support = """
        import XCTest
        @MainActor var callback: (() -> Bool)?
        infix operator ~>
        @MainActor func ~>(lhs: Bool, rhs: @autoclosure @escaping () -> Bool) { callback = rhs }
        @MainActor struct Recorder {
            subscript(_ rhs: @autoclosure @escaping () -> Bool) -> Bool { callback = rhs; return true }
        }
        @MainActor final class Other: XCTestCase {
            func testObserve() { XCTAssertTrue(callback?() ?? true) }
        }
        """
        before = """
        import XCTest
        @MainActor final class Suite: XCTestCase {
            func testRegister() { false ~> self.candidate() }
            private func candidate() -> Bool { false }
        }
        """
        if kind.hasPrefix("subscript") {
            before = before.replacingOccurrences(of: "false ~> self.candidate()", with: "_ = Recorder()[self.candidate()]")
        }
        after = before.replacingOccurrences(of: "-> Bool { false }", with: "-> Bool { true }")
        if added {
            before = before.components(separatedBy: "\n").filter { !$0.contains("private func candidate") }.joined(separator: "\n")
                .replacingOccurrences(of: "self.candidate()", with: "false")
        }
    } else {
        support = """
        import XCTest
        @MainActor var sharedFlag = false
        extension XCUIApplication {
            @MainActor func changeState() { sharedFlag = true }
        }
        extension NSPredicate {
            @MainActor func changeState() {}
        }
        @MainActor final class Other: XCTestCase {
            func testObserve() { XCTAssertTrue(sharedFlag) }
        }
        """
        before = """
        import XCTest
        @MainActor final class Suite: XCTestCase {
            func testRegister() { candidate(in: XCUIApplication()) }
            private func candidate(in app: XCUIApplication) { app.changeState() }
        }
        """
        if kind == "rebound-state" {
            before = before.replacingOccurrences(of: "{ app.changeState() }", with: "{ let target = app; target.changeState() }")
            after = before.replacingOccurrences(of: "let target = app;", with: "let target = NSPredicate(value: true);" )
        } else {
            after = before.replacingOccurrences(of: "{ app.changeState() }", with: "{ XCTAssertTrue(app.buttons[\"Content\"].exists) }")
        }
    }
    for (name, text) in ["Tests.swift": after, "Support.swift": support] {
        try Data(text.utf8).write(to: root.appendingPathComponent(name))
    }
    let platform = try CommandRunner.run("xcrun", ["--sdk", "macosx", "--show-sdk-platform-path"], at: root).text.trimmingCharacters(in: .whitespacesAndNewlines)
    let sil = root.appendingPathComponent("UI.sil")
    _ = try CommandRunner.run("xcrun", ["swiftc", "-emit-sil", "-whole-module-optimization", "-Onone", "-g", "-module-name", "UI", "-F", platform + "/Developer/Library/Frameworks", "-I", platform + "/Developer/usr/lib", root.appendingPathComponent("Tests.swift").path, root.appendingPathComponent("Support.swift").path, "-o", sil.path], at: root)
    let parsed = try SILParser.parse(file: sil, module: "UI", sourceRoot: root)
    var graph = DependencyGraph(functions: parsed.functions)
    XcodeCompilerGraph.resolveDispatch(&graph, tables: parsed.dispatchTargets)
    let tests = ["UI/Suite/testRegister()", "UI/Other/testObserve()"]
    var current = XcodeTestGraph(targets: [.init(name: "UI", productType: "com.apple.product-type.bundle.ui-testing", sourceFiles: ["Tests.swift", "Support.swift"])], tests: tests)
    current.modules = ["UI": "UI"]
    current.sources = ["UI:Tests.swift": .parse(after, path: "Tests.swift", module: "UI"), "UI:Support.swift": .parse(support, path: "Support.swift", module: "UI")]
    XcodeCompilerGraph.bind(tests: tests, modules: current.modules, sources: current.sources, graph: &graph)
    try #require(tests.allSatisfy { graph.tests[$0]?.isEmpty == false })
    try #require(graph.testDiagnostics.values.allSatisfy { $0.isEmpty })
    if escaped {
        #expect(current.sources["UI:Tests.swift"]!.units.compactMap(\.privateTestHelper).isEmpty)
    } else {
        #expect(current.sources["UI:Tests.swift"]!.units.compactMap(\.privateTestHelper).count == 1)
    }
    current.dependencies = graph
    var base = current.sources
    base["UI:Tests.swift"] = .parse(before, path: "Tests.swift", module: "UI")
    current.mappings = UIFeatureMappings(features: [])
    current.mappings?.sourceLocationPolicy = .diagnosticLineColumn
    let report = XcodeHeadOnlySelector.select(current: current, source: .init(base: base, mappings: current.mappings), changes: [.init(path: "Tests.swift")], baseRevision: "base")
    for i in current.sources["UI:Tests.swift"]!.units.indices {
        current.sources["UI:Tests.swift"]!.units[i].privateTestHelper = nil
    }
    let control = XcodeHeadOnlySelector.select(current: current, source: .init(base: base, mappings: current.mappings), changes: [.init(path: "Tests.swift")], baseRevision: "base")
    #expect(control.selectedTests.contains("UI/Other/testObserve()"))
    #expect(report.selectedTests == control.selectedTests)
    #expect(report.selectedTests == tests.sorted())
    #expect(report.diagnostics.contains { $0.code == (added ? "head_only_declaration_change" : "head_only_runtime_uncertainty") })
}

@Test func privateHelperBodyEvidencePreservesEvaluationContext() throws {
    func evidence(_ body: String) throws -> PrivateTestHelperSyntax {
        let source = """
        import XCTest
        final class Suite: XCTestCase {
            func testBody() { candidate(in: XCUIApplication()) }
            private func candidate(in app: XCUIApplication) { \(body) }
        }
        """
        return try #require(SwiftSourceSnapshot.parse(source, path: "Tests.swift", module: "UI").units.compactMap(\.privateTestHelper).first)
    }
    let body = "let target = app; target.observe(); target.inspect()"
    let old = try evidence(body)
    #expect(try evidence("XCTAssertTrue(true); " + body).preservesEffects(of: old))
    #expect(try evidence(body + "; XCTAssertFalse(false)").preservesEffects(of: old))
    #expect(try evidence(body.replacingOccurrences(of: "target.observe()", with: "target . observe( /* trivia */ )")).preservesEffects(of: old))
    for changed in [
        "let target = app; target.inspect()", // removed effect
        "let target = app; target.inspect(); target.observe()", // reordered effects
        "let target = NSPredicate(value: true); target.observe(); target.inspect()", // rebound receiver
        "return; " + body, // old calls remain in syntax but cannot execute
        "if false { " + body + " }" // changed control flow
    ] {
        // The existing syntax proof may already reject the changed form.
        let source = """
        import XCTest
        final class Suite: XCTestCase {
            func testBody() { candidate(in: XCUIApplication()) }
            private func candidate(in app: XCUIApplication) { \(changed) }
        }
        """
        let new = SwiftSourceSnapshot.parse(source, path: "Tests.swift", module: "UI").units.compactMap(\.privateTestHelper).first
        #expect(new?.preservesEffects(of: old) != true)
    }
}
