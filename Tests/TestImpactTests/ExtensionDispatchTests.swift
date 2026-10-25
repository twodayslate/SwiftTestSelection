// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import Testing
@testable import TestImpact

@Test func importedExtensionsOwnTheirMembersButNotFrameworkInitializers() {
    let source = SwiftSourceSnapshot.parse("""
    extension XCTestCase { @objc func helper() {} }
    class LocalTests: XCTestCase { override func setUp() {} }
    """, path: "Tests.swift", module: "Tests")
    #expect(source.units.contains { $0.kind == "extension" && $0.scope == "XCTestCase" })
    #expect(source.dispatchMembers == ["XCTestCase.helper", "LocalTests.setUp"])
    var graph = DependencyGraph(functions: ["caller": FunctionNode(id: "caller", module: "Tests", name: "caller()",
        dynamicDeclarations: ["XCTestCase.init", "XCTestCase.helper", "LocalTests.missingCallback"])])
    XcodeCompilerGraph.bind(tests: [], modules: [:], sources: ["Tests:Tests.swift": source], graph: &graph)
    #expect(graph.functions["caller"]?.uncertainties == ["Unresolved project dispatch: XCTestCase.helper", "Unresolved project dispatch: LocalTests.missingCallback"])
}

@Test(arguments: [false, true])
func compiledXCTestExtensionKeepsHelperAndLifecycleSelectionPrecise(genericSuperclass: Bool) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("extension-dispatch-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let app = """
    func unrelatedProduction() -> Int { 1 }
    import Foundation
    extension NSObject { @objc func projectHelper() {} }
    class Parent\(genericSuperclass ? "<T>" : ""): Foundation.NSObject {}
    class Local: \(genericSuperclass ? "Fixture.Parent<[String: [Int]]>" : "Parent") { override func isEqual(_ object: Any?) -> Bool { false } }
    func compare(_ object: NSObject) -> Bool { object.isEqual(nil) }
    """
    let tests = """
    import XCTest
    extension XCTestCase {
        @objc func localHelper() {}
    }
    class HelperTests: XCTestCase {
        override func setUp() { super.setUp() }
        func testHelper() { localHelper() }
        func testOther() {}
    }
    class LifecycleTests: XCTestCase {
        override func setUp() { localHelper() }
        func testLifecycle() {}
    }
    class OverrideTests: XCTestCase {
        func testOverride() { XCTAssertFalse(compare(Local())) }
        func testUnrelated() {}
    }
    """
    for (name, text) in [("App.swift", app), ("Tests.swift", tests)] { try Data(text.utf8).write(to: root.appendingPathComponent(name)) }
    let platform = try CommandRunner.run("xcrun", ["--sdk", "macosx", "--show-sdk-platform-path"], at: root).text.trimmingCharacters(in: .whitespacesAndNewlines)
    let sil = root.appendingPathComponent("fixture.sil")
    _ = try CommandRunner.run("xcrun", ["swiftc", "-emit-sil", "-whole-module-optimization", "-Onone", "-g", "-module-name", "Fixture",
        "-F", platform + "/Developer/Library/Frameworks", "-I", platform + "/Developer/usr/lib",
        root.appendingPathComponent("App.swift").path, root.appendingPathComponent("Tests.swift").path, "-o", sil.path], at: root)
    let parsed = try SILParser.parse(file: sil, module: "Fixture", sourceRoot: root)
    var dependencies = DependencyGraph(functions: parsed.functions)
    XcodeCompilerGraph.resolveDispatch(&dependencies, tables: parsed.dispatchTargets)
    let ids = ["Tests/HelperTests/testHelper()", "Tests/HelperTests/testOther()", "Tests/LifecycleTests/testLifecycle()", "Tests/OverrideTests/testOverride()", "Tests/OverrideTests/testUnrelated()"]
    let sources = ["Fixture:App.swift": SwiftSourceSnapshot.parse(app, path: "App.swift", module: "Fixture"),
                   "Fixture:Tests.swift": SwiftSourceSnapshot.parse(tests, path: "Tests.swift", module: "Fixture")]
    XcodeCompilerGraph.bind(tests: ids, modules: ["Tests": "Fixture"], sources: sources, graph: &dependencies)
    #expect(dependencies.functions.values.contains { $0.dynamicDeclarations.contains("XCTestCase.init") })
    #expect(!dependencies.functions.values.contains { $0.uncertainties.contains("Unresolved project dispatch: XCTestCase.init") })
    var before = XcodeTestGraph(targets: [
        XcodeTarget(name: "App", productType: "com.apple.product-type.framework", sourceFiles: ["App.swift"]),
        XcodeTarget(name: "Tests", productType: "com.apple.product-type.bundle.unit-test", sourceFiles: ["Tests.swift"])
    ], tests: ids)
    before.modules = ["App": "Fixture", "Tests": "Fixture"]; before.sources = sources; before.dependencies = dependencies
    func edit(_ key: String, line: Int) throws -> ImpactReport {
        var after = before
        let index = try #require(after.sources[key]!.units.firstIndex { $0.kind == "function" && $0.region.startLine == line })
        after.sources[key]!.units[index].fingerprint += "edit"
        return XcodeFineSelector.select(current: after, previous: before,
            changes: [FileChange(path: after.sources[key]!.units[index].region.path)], baseRevision: "base")
    }
    #expect(try edit("Fixture:App.swift", line: 1).selectedTests.isEmpty)
    #expect(try edit("Fixture:Tests.swift", line: 3).selectedTests == [ids[0], ids[2]])
    #expect(try edit("Fixture:Tests.swift", line: 6).selectedTests == [ids[0], ids[1]])
    #expect(try edit("Fixture:App.swift", line: 5).selectedTests == [ids[3]])
    let overrides = Set(dependencies.functions.values.filter { $0.name == "Local.isEqual(_:)" }.map(\.id))
    let compare = try #require(dependencies.functions.values.first { $0.name == "compare(_:)" })
    #expect(dependencies.dependencyPath(from: [compare.id], to: overrides) != nil)
    #expect(!compare.uncertainties.contains { $0.hasPrefix("Unresolved project dispatch:") })
}

@Test func superclassNominalNamesPreserveQualificationAndEraseArguments() {
    #expect(SwiftSourceSnapshot.nominalTypeName("Parent<Int>") == "Parent")
    #expect(SwiftSourceSnapshot.nominalTypeName("Module.Outer<[String: Int]>.Inner<(Int) -> [String]>") == "Module.Outer.Inner")
    #expect(SwiftSourceSnapshot.nominalTypeName("Parent<Int") == nil)
    #expect(SwiftSourceSnapshot.nominalTypeName("any Protocol") == nil)
}

@Test func unresolvedOverrideAncestryRetainsExplicitFallback() {
    // Type aliases are valid Swift, but not resolved by the nominal source index.
    let source = SwiftSourceSnapshot.parse("""
    class Parent<T>: NSObject {}
    typealias ParentAlias = Parent<Int>
    class Child: ParentAlias {
        override func isEqual(_ object: Any?) -> Bool { false }
    }
    """, path: "App.swift", module: "App")
    var graph = DependencyGraph(functions: [
        "call": FunctionNode(id: "call", module: "Tests", name: "call()", dynamicDeclarations: ["NSObject.isEqual"]),
        "unrelated": FunctionNode(id: "unrelated", module: "Tests", name: "unrelated()", dynamicDeclarations: ["NSObject.init"]),
        "super": FunctionNode(id: "super", module: "App", name: "Direct.isEqual(_:)",
            uncertainties: ["Dynamic dispatch: objc_super_method NSObject.isEqual!foreign"], dynamicDeclarations: ["NSObject.isEqual"]),
        "override": FunctionNode(id: "override", module: "App", name: "Child.isEqual(_:)",
            regions: [.init(path: "App.swift", startLine: 4, endLine: 4)])
    ])
    XcodeCompilerGraph.bind(tests: [], modules: [:], sources: ["App:App.swift": source], graph: &graph)
    #expect(graph.functions["call"]?.uncertainties.contains("Unresolved project dispatch: NSObject.isEqual (incomplete override ancestry)") == true)
    #expect(graph.functions["unrelated"]?.uncertainties.isEmpty == true)
    #expect(graph.functions["super"]?.uncertainties.contains { $0.hasPrefix("Unresolved project dispatch:") } == false)
}

@Test func protocolConformancesDoNotMakeOverrideAncestryIncomplete() {
    let source = SwiftSourceSnapshot.parse("""
    protocol Marker {}
    class Child: NSObject, Marker {
        override func isEqual(_ object: Any?) -> Bool { false }
    }
    """, path: "App.swift", module: "App")
    #expect(source.superclasses?["App.Child"] == ["NSObject"])
    var graph = DependencyGraph(functions: [
        "unrelated": FunctionNode(id: "unrelated", module: "Tests", name: "unrelated()", dynamicDeclarations: ["Other.isEqual"])
    ])
    XcodeCompilerGraph.bind(tests: [], modules: [:], sources: ["App:App.swift": source], graph: &graph)
    #expect(graph.functions["unrelated"]?.uncertainties.isEmpty == true)
}

@Test func missingOverridesStayConservativeWithoutRedirectingSuperCalls() {
    let source = SwiftSourceSnapshot.parse("""
    class Parent: Foundation.NSObject {}
    class Child: Parent {
        override func isEqual(_ object: Any?) -> Bool { false }
        override init() { super.init() }
    }
    """, path: "App.swift", module: "App")
    #expect(source.dispatchOverrides == ["App.Child.isEqual", "App.Child.init"])
    var graph = DependencyGraph(functions: [
        "call": FunctionNode(id: "call", module: "Tests", name: "call()", dynamicDeclarations: ["NSObject.isEqual"]),
        "super": FunctionNode(id: "super", module: "App", name: "Child.init()",
            uncertainties: ["Dynamic dispatch: objc_super_method NSObject.init!initializer.foreign"], dynamicDeclarations: ["NSObject.init"])
    ])
    XcodeCompilerGraph.bind(tests: [], modules: [:], sources: ["App:App.swift": source], graph: &graph)
    #expect(graph.functions["call"]?.uncertainties.contains("Unresolved project dispatch: NSObject.isEqual") == true)
    #expect(graph.functions["super"]?.uncertainties.contains("Unresolved project dispatch: NSObject.init") == false)
    #expect(graph.functions["super"]?.dependencies.isEmpty == true)
}

/// Rebind a saved consumer graph after verifying its source fingerprints. This
/// isolates the XCTestCase initializer classification; it does not run tests.
@Test func consumerExtensionDispatchProbe() throws {
    let env = ProcessInfo.processInfo.environment
    guard let path = env["IMPACT_EXTENSION_GRAPH"], let sourcePath = env["IMPACT_EXTENSION_SOURCE"], let output = env["IMPACT_EXTENSION_OUTPUT"] else { return }
    let before = try GraphArchive.decode(Data(contentsOf: URL(fileURLWithPath: path)))
    var after = before
    for (key, old) in before.sources {
        guard let unit = old.units.first else { continue }
        let module = String(key.prefix { $0 != ":" })
        let file = URL(fileURLWithPath: sourcePath).appendingPathComponent(unit.region.path)
        let parsed = SwiftSourceSnapshot.parse(try String(contentsOf: file, encoding: .utf8), path: unit.region.path, module: module)
        try #require(parsed.units.map(\.key) == old.units.map(\.key) && parsed.units.map(\.fingerprint) == old.units.map(\.fingerprint), "Saved graph source does not match \(file.path)")
        after.sources[key] = parsed
    }
    var graph = try #require(after.dependencies)
    for id in graph.functions.keys { graph.functions[id]!.uncertainties.remove("Unresolved project dispatch: XCTestCase.init") }
    XcodeCompilerGraph.bind(tests: after.tests, modules: after.modules, sources: after.sources, graph: &graph)
    after.dependencies = graph
    let key = try #require(before.sources.keys.first { $0.hasSuffix("/NoteListSort.swift") })
    let index = try #require(before.sources[key]!.units.firstIndex { $0.fingerprint.contains("A to Z") })
    func selection(_ snapshot: XcodeTestGraph) -> ImpactReport {
        var head = snapshot
        head.sources[key]!.units[index].fingerprint += "probe-edit"
        return XcodeFineSelector.select(current: head, previous: snapshot, changes: [FileChange(path: snapshot.sources[key]!.units[index].region.path)], baseRevision: "probe")
    }
    let old = selection(before), new = selection(after)
    func initializerFallbacks(_ report: ImpactReport) -> Set<String> {
        Set(report.diagnostics.filter { $0.message.contains("Unresolved project dispatch: XCTestCase.init") }.flatMap(\.tests))
    }
    #expect(initializerFallbacks(new).isEmpty)
    let result: [String: Any] = ["beforeSelected": old.selectedTests.count, "afterSelected": new.selectedTests.count,
        "beforeInitializerFallbackTests": initializerFallbacks(old).count, "afterInitializerFallbackTests": initializerFallbacks(new).count,
        "added": Set(new.selectedTests).subtracting(old.selectedTests).sorted(), "removed": Set(old.selectedTests).subtracting(new.selectedTests).sorted(),
        "remainingDiagnostics": new.diagnostics.count, "sourceRevision": before.buildArtifact?.revision ?? "unknown"]
    try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: output))
    print("EXTENSION: \(old.selectedTests.count) -> \(new.selectedTests.count); initializer fallback tests \(initializerFallbacks(old).count) -> \(initializerFallbacks(new).count)")
}
