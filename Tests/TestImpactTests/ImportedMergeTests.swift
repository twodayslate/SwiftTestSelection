// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
import Foundation
import Testing
@testable import TestImpact

@Test func importedBodiesMergeEffectsAndProvenanceInEitherOrder() throws {
    let body = SILParser.parse("""
    // Array.append(_:)
    sil public_external @append : $@convention(thin) () -> () {
      %0 = function_ref @callback : $@convention(thin) () -> ()
      %1 = function_ref @generic : $@convention(thin) <T> () -> ()
      %2 = apply %1<Int>() : $@convention(thin) <T> () -> ()
      %3 = global_addr @state : $*Int
    } // end sil function 'append'
    """, module: "App", sourceRoot: URL(fileURLWithPath: "/tmp")).functions["append"]!
    var stub = SILParser.parse("""
    // Array.append(_:)
    sil public_external @append : $@convention(thin) () -> () {
    } // end sil function 'append'
    """, module: "SnapshotTesting", sourceRoot: URL(fileURLWithPath: "/tmp")).functions["append"]!
    var baseline: FunctionNode?
    for nodes in [[stub, body], [body, stub], [stub, body, stub, body]] {
        var graph = DependencyGraph()
        for node in nodes { XcodeCompilerGraph.merge(node, into: &graph, isDefinition: false, existingIsDefinition: false) }
        let merged = try #require(graph.functions["append"])
        #expect(merged.dependencies == body.dependencies)
        #expect(merged.compilerReferences == body.compilerReferences)
        #expect(merged.stateAccesses == body.stateAccesses)
        #expect(merged.receiverGenericCalls == body.receiverGenericCalls)
        #expect(merged.uncertainties == body.uncertainties)
        #expect(merged.captureModules == ["App", "SnapshotTesting"])
        graph.functions["callback"] = .init(id: "callback", module: "App", name: "callback()", regions: [.init(path: "App.swift", startLine: 1, endLine: 2)])
        graph.tests = ["UI/Suite/test()": ["append"]]
        let report = StaticSelector.select(current: graph, previous: graph, changes: [.init(path: "App.swift", oldRegions: [.init(path: "App.swift", startLine: 1, endLine: 1)], newRegions: [.init(path: "App.swift", startLine: 1, endLine: 1)])], baseRevision: "base")
        #expect(report.selectedTests == ["UI/Suite/test()"])
        let restored = try GraphArchive.decodeValue(DependencyGraph.self, from: GraphArchive.encodeValue(graph))
        #expect(restored.functions["append"]?.captureModules == merged.captureModules)
        if let baseline {
            #expect(merged.module == baseline.module)
            #expect(merged.dynamicDeclarations == baseline.dynamicDeclarations)
            #expect(merged.receiverErrorEffects == baseline.receiverErrorEffects)
        }
        baseline = merged
    }
    // Legacy absence must never become complete effect proof by merging a stub.
    stub.compilerReferences = nil
    var unknown = body
    unknown.mergeEvidence(stub)
    #expect(unknown.compilerReferences == nil)
    #expect(unknown.dependencies == body.dependencies)
}

@Test func importedConformanceMergeRequiresEveryEmittingModulesEvidence() {
    var node = FunctionNode(id: "body", module: "A", name: "body", dynamicDeclarations: ["P.call@witness:Value"])
    node.captureModules = ["A", "B"]
    for complete in [false, true] {
        var graph = DependencyGraph(functions: ["body": node])
        var witnesses: [String: Set<String>] = ["A:P@witness:Value": ["SDK"]]
        if complete { witnesses["B:P@witness:Value"] = ["SDK"] }
        XcodeCompilerGraph.resolveDispatch(&graph, tables: [:], externalWitnesses: witnesses, projectModules: ["A", "B"])
        #expect(graph.functions["body"]!.uncertainties.contains { $0.hasPrefix(complete ? "Imported conformance:" : "Unresolved project dispatch:") })
        #expect(graph.functions["body"]!.hasOpaqueRuntimeDependency)
    }
}

@Test func importedWitnessProvenanceExcludesEmptyStubsAndRetainsConflicts() throws {
    let declaration = "P.call@witness:Value"
    var body = FunctionNode(id: "body", module: "A", name: "body", dynamicDeclarations: [declaration])
    body.captureModules = ["A"]
    body.dynamicDeclarationModules = [declaration: ["A"]]
    var stub = FunctionNode(id: "body", module: "Z", name: "body")
    stub.captureModules = ["Z"]; stub.dynamicDeclarationModules = [:]
    for fragments in [[stub, body], [body, stub]] {
        var graph = DependencyGraph()
        for fragment in fragments { XcodeCompilerGraph.merge(fragment, into: &graph, isDefinition: false, existingIsDefinition: false) }
        graph = try GraphArchive.decodeValue(DependencyGraph.self, from: GraphArchive.encodeValue(graph))
        #expect(graph.functions["body"]?.dynamicDeclarationModules == [declaration: ["A"]])
        XcodeCompilerGraph.resolveDispatch(&graph, tables: [:], externalWitnesses: ["A:P@witness:Value": ["SDK"]], projectModules: ["A", "Z"])
        #expect(graph.functions["body"]?.resolvedDynamicDeclarations == [declaration])
        #expect(graph.functions["body"]?.hasOpaqueRuntimeDependency == true)
    }
    var conflicting = body
    conflicting.module = "B"; conflicting.captureModules = ["B"]
    conflicting.dynamicDeclarationModules = [declaration: ["B"]]
    body.mergeEvidence(conflicting)
    var graph = DependencyGraph(functions: ["body": body])
    XcodeCompilerGraph.resolveDispatch(&graph, tables: [:], externalWitnesses: ["A:P@witness:Value": ["SDK"], "B:P@witness:Value": ["OtherSDK"]], projectModules: ["A", "B"])
    #expect(graph.functions["body"]?.resolvedDynamicDeclarations.isEmpty == true)
    #expect(graph.functions["body"]?.hasOpaqueRuntimeDependency == true)
}

@Test func importedMergePreservesCompiledCallbackDependenciesAcrossUnrelatedComments() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("merge-callback-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("Library.swift")
    try Data("func leaf() -> Int { 1 }\nfunc call(_ body: () -> Int) -> Int { body() }\nfunc bridge() -> Int { call(leaf) }\n".utf8).write(to: source)
    var expected: Set<String>?
    for comment in ["// ordinary UI comment", "// swift-test-selection: {\"symbols\":[\"App.feature()\"]}"] {
        let ui = root.appendingPathComponent("UI.swift")
        try Data(comment.utf8).write(to: ui)
        let sil = root.appendingPathComponent("capture.sil")
        _ = try CommandRunner.run("xcrun", ["swiftc", "-emit-sil", "-g", "-Onone", "-whole-module-optimization", "-module-name", "Library", source.path, ui.path, "-o", sil.path], at: root)
        let parsed = try SILParser.parse(file: sil, module: "Library", sourceRoot: root)
        var body = try #require(parsed.functions.values.first { $0.name == "bridge()" })
        let leaf = try #require(parsed.functions.values.first { $0.name == "leaf()" })
        #expect(body.compilerReferences?.contains(leaf.id) == true)
        // Imported generic/SDK bodies may have no source regions. Their
        // compiler-derived callback references remain evidence nonetheless.
        body.regions = []
        var stub = body
        stub.module = "Other"; stub.captureModules = ["Other"]
        stub.dependencies = []; stub.compilerReferences = []; stub.receiverGenericCalls = []
        stub.uncertainties = []; stub.dynamicDeclarations = []
        for fragments in [[stub, body], [body, stub]] {
            var graph = DependencyGraph(functions: parsed.functions)
            graph.functions.removeValue(forKey: body.id)
            for fragment in fragments { XcodeCompilerGraph.merge(fragment, into: &graph, isDefinition: false, existingIsDefinition: false) }
            graph.tests = ["UI/Suite/testCallback()": [body.id]]
            let changes = [FileChange(path: "Library.swift", oldRegions: leaf.regions, newRegions: leaf.regions)]
            let report = StaticSelector.select(current: graph, previous: graph, changes: changes, baseRevision: "base")
            #expect(report.selectedTests == ["UI/Suite/testCallback()"])
            #expect(report.explanations.contains { $0.path.contains(leaf.module + "." + leaf.name) })
            let references = try #require(graph.functions[body.id]?.compilerReferences)
            if let expected { #expect(references == expected) }
            expected = references
        }
    }
}
