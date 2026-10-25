// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import Testing
@testable import TestImpact

@Test func reverseQueriesMatchSortedBFSWithCyclesAndDanglingSymbols() {
    var seed: UInt64 = 91
    func random(_ n: Int) -> Int { seed = seed &* 6364136223846793005 &+ 1; return Int(seed >> 32) % n }
    for _ in 0..<35 {
        var graph = DependencyGraph()
        for i in 0..<45 {
            let id = "f\(i)"
            graph.functions[id] = FunctionNode(id: id, module: "M", name: id, dependencies: Set((0..<random(6)).map { _ in "f\(random(50))" }))
        }
        graph.tests["dangling"] = ["f49"]
        let index = DependencyIndex(graph)
        for _ in 0..<30 {
            let targets = Set((0..<random(6)).map { _ in "f\(random(50))" })
            let paths = index.paths(to: targets)
            for _ in 0..<5 {
                let roots = Set((0..<random(5)).map { _ in "f\(random(50))" })
                #expect(paths.path(from: roots) == graph.dependencyPath(from: roots, to: targets))
            }
        }
    }
}

@Test func compactArchivePreservesEveryGraphFieldAndRejectsCorruption() throws {
    var graph = XcodeTestGraph(targets: [], tests: ["Tests/C/test"], diagnostics: ["diagnostic"])
    var node = FunctionNode(id: "a", module: "M", name: "日本語()", regions: [.init(path: "é.swift", startLine: 3, endLine: 6)], dependencies: ["missing", "a"], uncertainties: ["uncertainty"], dynamicDeclarations: ["D"])
    node.resolvedDynamicDeclarations = ["D"]
    graph.dependencies = DependencyGraph(functions: ["a": node], tests: ["Tests/C/test": ["a", "missing"]])
    graph.dependencies!.testDiagnostics = ["Tests/C/test": ["inherited"]]
    let data = try GraphArchive.encode(graph)
    let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
    let roundTrip = try GraphArchive.decode(data)
    #expect(roundTrip.dependencies?.functions["a"]?.dependencies == node.dependencies)
    #expect(roundTrip.dependencies?.functions["a"]?.uncertainties == node.uncertainties)
    #expect(roundTrip.dependencies?.functions["a"]?.resolvedDynamicDeclarations == ["D"])
    #expect(roundTrip.dependencies?.functions["a"]?.regions == node.regions)
    #expect(roundTrip.dependencies?.testDiagnostics == graph.dependencies?.testDiagnostics)
    #expect(roundTrip.tests == graph.tests && roundTrip.diagnostics == graph.diagnostics)
    #expect(try GraphArchive.decode(encoder.encode(graph)).tests == graph.tests)
    var broken = data; broken[broken.count - 1] ^= 1
    #expect(throws: (any Error).self) { try GraphArchive.decode(broken) }
}

@Test func concreteWitnessKeepsOnlyItsConformanceAndUnknownReceiverFallsBack() {
    let text = """
    // equal(), loc "/tmp/model.swift":1:1
    sil hidden @equal : $@convention(thin) () -> () {
      %0 = witness_method $UIApplication.State, #Equatable."==" : $@convention(witness_method: Equatable) () -> ()
    } // end sil function
    // generic(), loc "/tmp/model.swift":2:1
    sil hidden @generic : $@convention(thin) () -> () {
      %0 = witness_method $τ_0_0, #Equatable."==" : $@convention(witness_method: Equatable) () -> ()
    } // end sil function
    // missing(), loc "/tmp/model.swift":3:1
    sil hidden @missing : $@convention(thin) () -> () {
      %0 = witness_method $Missing, #Equatable."==" : $@convention(witness_method: Equatable) () -> ()
    } // end sil function
    sil_witness_table shared UIApplication.State: Equatable module UIKit {
      method #Equatable."==": <Self where Self : Equatable> (Self.Type) -> (Self, Self) -> Bool : @stateEquality
    }
    sil_witness_table hidden Unrelated: Equatable module App {
      method #Equatable."==": <Self where Self : Equatable> (Self.Type) -> (Self, Self) -> Bool : @unrelatedEquality
    }
    """
    let module = SILParser.parse(text, module: "App", sourceRoot: URL(fileURLWithPath: "/tmp"))
    var graph = DependencyGraph(functions: module.functions)
    XcodeCompilerGraph.resolveDispatch(&graph, tables: module.dispatchTargets)
    #expect(graph.functions["equal"]?.dependencies == ["stateEquality"])
    #expect(graph.functions["generic"]?.dependencies == ["stateEquality", "unrelatedEquality"])
    #expect(graph.functions["missing"]?.dependencies == ["stateEquality", "unrelatedEquality"])
    #expect(graph.functions["missing"]!.uncertainties.contains { $0.hasPrefix("Unresolved project dispatch:") })
}

@Test func consumerWitnessPrecisionProbe() throws {
    guard let path = ProcessInfo.processInfo.environment["IMPACT_WITNESS_SIL"] else { return }
    let parsed = try SILParser.parse(file: URL(fileURLWithPath: path), module: "ChainOfCustody", sourceRoot: URL(fileURLWithPath: "/tmp/issue11-consumer"))
    var graph = DependencyGraph(functions: parsed.functions)
    XcodeCompilerGraph.resolveDispatch(&graph, tables: parsed.dispatchTargets)
    let node = try #require(graph.functions.values.first { $0.name == "ChainOfCustodyApp.init()" })
    let broad = parsed.dispatchTargets["Equatable.\"==\""] ?? []
    let concrete = try #require(parsed.dispatchTargets["Equatable.\"==\"@witness:UIApplication.State"])
    #expect(!concrete.isEmpty && concrete.count < broad.count)
    #expect(node.dependencies.intersection(broad) == concrete)
    print("WITNESS: \(broad.count) broad candidates -> \(concrete.count) receiver candidates")
}

@Test func compactGraphStoresRepeatedSymbolsOnceAtScale() throws {
    var dependency = DependencyGraph()
    for i in 0..<4000 {
        let id = "long_compiler_symbol_module_function_\(i)"
        dependency.functions[id] = FunctionNode(id: id, module: "Example", name: "function\(i)()",
            regions: [.init(path: "Sources/LargeModule.swift", startLine: i + 1, endLine: i + 1)],
            dependencies: Set(["long_compiler_symbol_module_function_\((i + 1) % 4000)", "long_compiler_symbol_module_function_\((i + 7) % 4000)"]))
    }
    var graph = XcodeTestGraph(targets: [], tests: [])
    graph.dependencies = dependency
    let compact = try GraphArchive.encode(graph)
    #expect(try compact.count < JSONEncoder().encode(graph).count)
    let decoded = try #require(GraphArchive.decode(compact).dependencies)
    let indexed = DependencyIndex(decoded).paths(to: ["long_compiler_symbol_module_function_3999"])
    #expect(indexed.path(from: ["long_compiler_symbol_module_function_0"]) == dependency.dependencyPath(from: ["long_compiler_symbol_module_function_0"], to: ["long_compiler_symbol_module_function_3999"]))
}
