// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation
import Testing
@testable import TestImpact

private func sameBinding(_ lhs: DependencyGraph, _ rhs: DependencyGraph) -> Bool {
    guard lhs.tests == rhs.tests, lhs.testDiagnostics.mapValues({ $0.sorted() }) == rhs.testDiagnostics.mapValues({ $0.sorted() }),
          lhs.diagnostics.sorted() == rhs.diagnostics.sorted(), lhs.functions.keys.sorted() == rhs.functions.keys.sorted() else { return false }
    return lhs.functions.allSatisfy { id, a in
        let b = rhs.functions[id]!
        return a.id == b.id && a.module == b.module && a.name == b.name && a.regions == b.regions &&
            a.dependencies == b.dependencies && a.uncertainties == b.uncertainties &&
            a.dynamicDeclarations == b.dynamicDeclarations && a.resolvedDynamicDeclarations == b.resolvedDynamicDeclarations
    }
}

@Test func indexedBindingMatchesLegacyAcrossModulesAndLifecycleKinds() {
    let sources = [
        "child": SwiftSourceSnapshot.parse("class Child: Support.Base, Missing { func testOne() {} }", path: "Child.swift", module: "UI"),
        "base": SwiftSourceSnapshot.parse("class Base: XCTestCase {}", path: "Base.swift", module: "Support"),
        "other": SwiftSourceSnapshot.parse("class Child: XCTestCase {}", path: "Other.swift", module: "Other")
    ]
    var graph = DependencyGraph()
    for (module, names) in ["UI": ["Child.testOne()", "Child.testOne()", "Child.parameters(a:)", "freeTest()", "Child.setUp()", "static Child.setUp()", "Child.init()", "Child.__allocating_init()", "Child.deinit", "Child.__deallocating_deinit", "variable initialization expression of Child.value", "Child.helper()"],
                            "Support": ["Base.testInherited()", "Base.setUpWithError()", "Base.tearDown()", "static Base.tearDownWithError()"],
                            "Other": ["Child.testOne()", "Child.setUp()"]] {
        for (offset, name) in names.enumerated() {
            let id = module + String(offset)
            graph.functions[id] = FunctionNode(id: id, module: module, name: name, regions: [.init(path: "Tests.swift", startLine: 1, endLine: 1)])
        }
    }
    graph.functions["imported"] = FunctionNode(id: "imported", module: "UI", name: "Child.testOne()")
    graph.functions["caller"] = FunctionNode(id: "caller", module: "UI", name: "caller", dynamicDeclarations: ["Child.helper", "Child.absent"])
    let tests = ["Target/Child/testOne", "Target/Child/testInherited()", "Target/Child/parameters(a:)", "Target/freeTest()", "Target/Child/missing()", "OtherTarget/Child/testOne()", "Unknown/Suite/test()", "invalid"]
    let modules = ["Target": "UI", "OtherTarget": "Other"]
    var expected = graph
    ReferenceXcodeBinding.bind(tests: tests, modules: modules, sources: sources, graph: &expected)
    XcodeCompilerGraph.bind(tests: tests, modules: modules, sources: sources, graph: &graph)
    #expect(sameBinding(graph, expected))
    #expect(graph.tests["Target/Child/missing()"] == [])
    #expect(graph.testDiagnostics["Target/Child/testOne"]?.count == 1)
    #expect(graph.testDiagnostics["Target/Child/testInherited()"]?.count == 1)
}

/// Opt-in release benchmark: decoding, parity checks and JSON output are outside
/// the measured binding intervals. Each iteration starts from the same graph.
@Test func bindingBenchmarkOnSavedGraph() throws {
    let environment = ProcessInfo.processInfo.environment
    guard let path = environment["IMPACT_BINDING_GRAPH"], let output = environment["IMPACT_BINDING_RESULTS"] else { return }
    let snapshot = try JSONDecoder().decode(XcodeTestGraph.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    let original = try #require(snapshot.dependencies)
    var reference = original
    var results: [[String: Any]] = []
    for mode in ["reference", "indexed"] {
        for iteration in 1...3 {
            var graph = original
            let memory = AnalysisMeasurement()
            let start = ContinuousClock.now
            if mode == "reference" { ReferenceXcodeBinding.bind(tests: snapshot.tests, modules: snapshot.modules, sources: snapshot.sources, graph: &graph) }
            else { XcodeCompilerGraph.bind(tests: snapshot.tests, modules: snapshot.modules, sources: snapshot.sources, graph: &graph) }
            let elapsed = start.duration(to: .now).components
            let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
            let measurement = memory.report(mode)
            print("BINDING \(mode) \(iteration): \(measurement)")
            if mode == "reference" && iteration == 1 { reference = graph }
            else { #expect(sameBinding(graph, reference)) }
            results.append(["mode": mode, "iteration": iteration, "seconds": seconds, "memory": measurement])
        }
    }
    let value: [String: Any] = ["input": path, "functions": original.functions.count, "tests": snapshot.tests.count, "measurements": results]
    try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: output))
}
