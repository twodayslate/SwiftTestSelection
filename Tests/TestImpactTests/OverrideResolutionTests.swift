// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import Testing
@testable import TestImpact

@Test(arguments: [false, true])
func compiledNestedSuperclassLookupRespectsLexicalShadowing(qualified: Bool) throws {
    try assertOverrideSelection(app: """
    import Foundation
    extension NSObject { @objc func projectHelper() {} }
    class Parent { func isEqual(_ object: Any?) -> Bool { true } }
    enum Scope {
        class Parent: NSObject {}
        class Local: \(qualified ? "Scope.Parent" : "Parent") {
            override func isEqual(_ object: Any?) -> Bool { false }
        }
    }
    func compare(_ value: NSObject) -> Bool { value.isEqual(nil) }
    """, call: "_ = compare(Scope.Local())", scope: "Scope.Local", kind: "function",
        caller: "compare(_:)", implementation: "Scope.Local.isEqual(_:)")
}

@Test func compiledInheritedNestedSuperclassRetainsConservativeSelection() throws {
    try assertOverrideSelection(app: """
    import Foundation
    extension NSObject { @objc func projectHelper() {} }
    enum Container { class Parent { func isEqual(_ object: Any?) -> Bool { true } } }
    class RealContainer { class Parent: NSObject {} }
    enum Scope {
        class Container: RealContainer {}
        class Local: Container.Parent {
            override func isEqual(_ object: Any?) -> Bool { false }
        }
    }
    func compare(_ value: NSObject) -> Bool { value.isEqual(nil) }
    """, call: "_ = compare(Scope.Local())", scope: "Scope.Local", kind: "function",
        caller: "compare(_:)", implementation: "Scope.Local.isEqual(_:)",
        unresolvedDeclaration: "NSObject.isEqual")
}

@Test func compiledRequiredInitializersReachSubclassThroughMetatype() throws {
    try assertOverrideSelection(app: """
    import Foundation
    extension Formatter { @objc func projectHelper() {} }
    class Parent: Formatter {
        required init?(coder: NSCoder) { super.init(coder: coder) }
    }
    class Local: Parent {
        required init?(coder: NSCoder) { super.init(coder: coder) }
    }
    func make(_ type: Parent.Type, _ coder: NSCoder) -> Parent? { type.init(coder: coder) }
    """, call: "_ = make(Local.self, NSCoder())", scope: "Local", kind: "state",
        caller: "make(_:_:)", implementation: "Local.init(coder:)")
}

@Test(arguments: [false, true])
func nestedAliasShadowsModuleClassWithoutGuessingItsSuperclass(qualified: Bool) {
    let text = qualified ? """
    enum Container { class Parent {} }
    enum RealContainer { class Parent: NSObject {} }
    enum Scope {
        typealias Container = RealContainer
        class Local: Container.Parent { override func isEqual(_ value: Any?) -> Bool { false } }
    }
    """ : """
    class Parent {}
    enum Scope {
        typealias Parent = NSObject
        class Local: Parent { override func isEqual(_ value: Any?) -> Bool { false } }
    }
    """
    let source = SwiftSourceSnapshot.parse(text, path: "App.swift", module: "App")
    #expect(source.typeAliases == [qualified ? "App.Scope.Container" : "App.Scope.Parent"])
    var graph = DependencyGraph(functions: [
        "call": FunctionNode(id: "call", module: "App", name: "call()", dynamicDeclarations: ["NSObject.isEqual"])
    ])
    XcodeCompilerGraph.bind(tests: [], modules: [:], sources: ["App:App.swift": source], graph: &graph)
    #expect(graph.functions["call"]?.uncertainties.contains("Unresolved project dispatch: NSObject.isEqual (incomplete override ancestry)") == true)
}

private func assertOverrideSelection(app: String, call: String, scope: String, kind: String,
                                     caller: String, implementation: String,
                                     unresolvedDeclaration: String? = nil) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("override-resolution-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let tests = """
    import Foundation
    import XCTest
    class Suite: XCTestCase {
        func testOverride() { \(call) }
        func testUnrelated() {}
    }
    """
    for (name, contents) in [("App.swift", app), ("Tests.swift", tests)] {
        try contents.write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
    let platform = try CommandRunner.run("xcrun", ["--sdk", "macosx", "--show-sdk-platform-path"], at: root).text.trimmingCharacters(in: .whitespacesAndNewlines)
    let sil = root.appendingPathComponent("fixture.sil")
    _ = try CommandRunner.run("xcrun", ["swiftc", "-emit-sil", "-whole-module-optimization", "-Onone", "-g", "-module-name", "Fixture",
        "-F", platform + "/Developer/Library/Frameworks", "-I", platform + "/Developer/usr/lib",
        root.appendingPathComponent("App.swift").path, root.appendingPathComponent("Tests.swift").path, "-o", sil.path], at: root)
    let parsed = try SILParser.parse(file: sil, module: "Fixture", sourceRoot: root)
    let sources = ["Fixture:App.swift": SwiftSourceSnapshot.parse(app, path: "App.swift", module: "Fixture"),
                   "Fixture:Tests.swift": SwiftSourceSnapshot.parse(tests, path: "Tests.swift", module: "Fixture")]
    let testsIDs = ["Tests/Suite/testOverride()", "Tests/Suite/testUnrelated()"]
    var graph = DependencyGraph(functions: parsed.functions)
    XcodeCompilerGraph.resolveDispatch(&graph, tables: parsed.dispatchTargets)
    XcodeCompilerGraph.bind(tests: testsIDs, modules: ["Tests": "Fixture"], sources: sources, graph: &graph)
    let entry = try #require(graph.functions.values.first { $0.name == caller })
    let implementations = Set(graph.functions.values.filter { $0.name == implementation }.map(\.id))
    #expect(!implementations.isEmpty)
    if let unresolvedDeclaration {
        #expect(entry.uncertainties.contains("Unresolved project dispatch: " + unresolvedDeclaration + " (incomplete override ancestry)"))
    } else {
        #expect(graph.dependencyPath(from: [entry.id], to: implementations) != nil)
        #expect(!entry.uncertainties.contains { $0.contains("incomplete override ancestry") })
    }
    var before = XcodeTestGraph(targets: [
        .init(name: "App", productType: "com.apple.product-type.framework", sourceFiles: ["App.swift"]),
        .init(name: "Tests", productType: "com.apple.product-type.bundle.unit-test", sourceFiles: ["Tests.swift"])
    ], tests: testsIDs)
    before.modules = ["App": "Fixture", "Tests": "Fixture"]; before.sources = sources; before.dependencies = graph
    var after = before
    let unit = try #require(after.sources["Fixture:App.swift"]!.units.firstIndex { $0.scope == scope && $0.kind == kind })
    after.sources["Fixture:App.swift"]!.units[unit].fingerprint += "edit"
    let report = XcodeFineSelector.select(current: after, previous: before, changes: [FileChange(path: "App.swift")], baseRevision: "base")
    #expect(report.selectedTests == [testsIDs[0]])
    if let unresolvedDeclaration {
        #expect(report.explanations.contains {
            $0.test == testsIDs[0] && $0.kind == "fallback" &&
                $0.reason.contains("Unresolved project dispatch: " + unresolvedDeclaration + " (incomplete override ancestry)")
        })
    } else {
        #expect(report.explanations.contains { $0.test == testsIDs[0] && $0.kind == "dependency" })
    }
}
