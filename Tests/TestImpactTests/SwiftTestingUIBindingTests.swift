// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
import Foundation
import Testing
@testable import TestImpact

@Test func compiledSwiftTestingUIEntriesPreserveNestedAndStaticIdentifiers() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let text = """
    import Testing
    import XCUIAutomation
    import XCTest
    func argumentValues() -> [Bool] { [true, false] }
    func testEnabled() -> Bool { true }
    func suiteEnabled() -> Bool { true }
    func runtimeHook() {}
    struct RuntimeTrait: TestTrait {
        func prepare(for test: Testing.Test) async throws { runtimeHook() }
    }
    @Test @MainActor func topLevel() { let app = XCUIApplication(); #expect(app.exists) }
    @Suite(.enabled(if: suiteEnabled()))
    struct Outer {
        struct Inner {
            @Test @MainActor func instance() { let app = XCUIApplication(); #expect(app.exists) }
            @Test @MainActor static func typeTest() { let app = XCUIApplication(); #expect(app.exists) }
            @Test(RuntimeTrait(), .enabled(if: testEnabled()), arguments: argumentValues()) func arguments(value: Bool) { #expect(value || !value) }
        }
    }
    final class XCTestSuite: XCTestCase {
        func testOrdinary() { XCTAssertTrue(true) }
    }
    """
    let tests = ["UI/topLevel()", "UI/Outer/Inner/instance()", "UI/Outer/Inner/typeTest()", "UI/Outer/Inner/arguments(value:)", "UI/XCTestSuite/testOrdinary()"]
    try Data(text.utf8).write(to: root.appendingPathComponent("Tests.swift"))
    let platform = try CommandRunner.run("xcrun", ["--sdk", "macosx", "--show-sdk-platform-path"], at: root).text.trimmingCharacters(in: .whitespacesAndNewlines)
    let sil = root.appendingPathComponent("UI.sil")
    let compiler = try CommandRunner.run("xcrun", ["--find", "swiftc"], at: root).text.trimmingCharacters(in: .whitespacesAndNewlines)
    let plugins = URL(fileURLWithPath: compiler).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("lib/swift/host/plugins/testing")
    _ = try CommandRunner.run("xcrun", ["swiftc", "-module-name", "UI", "-g", "-Onone", "-emit-sil", "-whole-module-optimization",
        "-plugin-path", plugins.path,
        "-F", platform + "/Developer/Library/Frameworks", "-I", platform + "/Developer/usr/lib", root.appendingPathComponent("Tests.swift").path, "-o", sil.path], at: root)
    let parsed = try SILParser.parse(file: sil, module: "UI", sourceRoot: root)
    var graph = DependencyGraph(functions: parsed.functions)
    let source = SwiftSourceSnapshot.parse(text, path: "Tests.swift", module: "UI")
    XcodeCompilerGraph.bind(tests: tests, modules: ["UI": "UI"], sources: ["UI:Tests.swift": source], graph: &graph)
    for test in tests { #expect(graph.tests[test]?.isEmpty == false, "\(test)") }
    #expect(graph.testDiagnostics[tests[3]]?.contains(SwiftTestingDiscoveryRoots.runtimeEvidence) == true)
    #expect(graph.testDiagnostics[tests[4]]?.isEmpty ?? true)
    let index = DependencyIndex(graph)
    let runtimeHook = try #require(graph.functions.values.first { $0.name == "runtimeHook()" }?.id)
    // The runtime invokes prepare through TestTrait, independently of the
    // constructor. This missing path is why factory evidence cannot clear the
    // test diagnostic and authorize exclusions.
    #expect(index.paths(to: [runtimeHook]).path(from: graph.tests[tests[3]] ?? []) == nil)
    for name in ["argumentValues()", "testEnabled()", "suiteEnabled()"] {
        let symbol = try #require(graph.functions.values.first { $0.name == name }?.id)
        #expect(index.paths(to: [symbol]).path(from: graph.tests[tests[3]] ?? []) != nil, "\(name)")
        if name != "suiteEnabled()" {
            #expect(index.paths(to: [symbol]).path(from: graph.tests[tests[0]] ?? []) == nil, "\(name)")
        }
    }
    let testFactories = Set(graph.functions.values.filter {
        $0.compilerReferences?.contains { $0.hasPrefix("$s7Testing4TestV10__function") } == true
    }.map(\.id))
    let suiteFactories = Set(graph.functions.values.filter {
        $0.compilerReferences?.contains { $0.hasPrefix("$s7Testing4TestV6__type") } == true
    }.map(\.id))
    #expect(!suiteFactories.isEmpty)
    for missing in [testFactories, suiteFactories] {
        var incomplete = DependencyGraph(functions: parsed.functions.filter { !missing.contains($0.key) })
        XcodeCompilerGraph.bind(tests: tests, modules: ["UI": "UI"], sources: ["UI:Tests.swift": source], graph: &incomplete)
        #expect(incomplete.testDiagnostics[tests[3]]?.contains(SwiftTestingDiscoveryRoots.missingEvidence) == true)
    }
    let factoryID = try #require(testFactories.intersection(graph.tests[tests[3]] ?? []).first)
    let factory = try #require(parsed.functions[factoryID])
    var duplicate = factory; duplicate.id += "-ambiguous"
    var ambiguous = DependencyGraph(functions: parsed.functions)
    ambiguous.functions[duplicate.id] = duplicate
    XcodeCompilerGraph.bind(tests: tests, modules: ["UI": "UI"], sources: ["UI:Tests.swift": source], graph: &ambiguous)
    #expect(ambiguous.testDiagnostics[tests[3]]?.contains(SwiftTestingDiscoveryRoots.missingEvidence) == true)
    let argumentThunk = try #require(factory.compilerReferences?.first { id in
        parsed.functions[id]?.compilerReferences?.contains { parsed.functions[$0]?.name == "argumentValues()" } == true
    })
    var missingArgument = DependencyGraph(functions: parsed.functions.filter { $0.key != argumentThunk })
    XcodeCompilerGraph.bind(tests: tests, modules: ["UI": "UI"], sources: ["UI:Tests.swift": source], graph: &missingArgument)
    #expect(missingArgument.testDiagnostics[tests[3]]?.contains(SwiftTestingDiscoveryRoots.missingEvidence) == true)
    var legacySource = source; legacySource.parserVersion = nil
    var legacy = DependencyGraph(functions: parsed.functions)
    XcodeCompilerGraph.bind(tests: tests, modules: ["UI": "UI"], sources: ["UI:Tests.swift": legacySource], graph: &legacy)
    #expect(legacy.testDiagnostics[tests[3]]?.contains(SwiftTestingDiscoveryRoots.missingEvidence) == true)
    let enumeration = try JSONSerialization.data(withJSONObject: ["errors": [], "values": [["enabledTests": tests.map { ["identifier": $0] }]]])
    #expect(try XcodeTestEnumeration.parse(enumeration) == tests.sorted())
    let options = XcodeConfiguration(container: .project, path: root.appendingPathComponent("App.xcodeproj"), scheme: "App", destination: "platform=macOS")
    let arguments = try options.executionArguments(tests: tests, derivedData: root, resultBundle: root.appendingPathComponent("Results.xcresult"))
    for test in tests { #expect(arguments.contains("-only-testing:" + test)) }
    // Compilation and binding are exercised here, not UI execution on Xcode 27.3.
    // Unauthenticated Testing macros remain outside head-only body isolation.
    #expect(source.units.filter { $0.swiftTestingRole == "test" }.allSatisfy { $0.headOnlyBodySupported == false })
}
