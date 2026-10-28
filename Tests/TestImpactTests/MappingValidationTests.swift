// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation
import Testing
@testable import TestImpact

private func mappingGraph(symbols: [String], sources: [String] = []) -> XcodeTestGraph {
    var graph = XcodeTestGraph(targets: [], tests: [])
    let node = FunctionNode(id: "existing", module: "App", name: "stillExists()",
                            regions: [.init(path: "App.swift", startLine: 1, endLine: 1)])
    graph.dependencies = DependencyGraph(functions: [node.id: node])
    graph.mappings = UIFeatureMappings(features: [.init(name: "checkout", sources: sources, symbols: symbols)])
    return graph
}

private func validate(_ graph: XcodeTestGraph) throws {
    try graph.validateMappingSymbols(mappingFile: "Config/ui.json", revision: "head-sha",
                                     buildContext: ["scheme": "App", "configuration": "Release", "destination": "platform=macOS"])
}

@Test(arguments: [
    (["App.wasDeleted()"], [String]()),
    (["App.stillExists()", "App.wasDeleted()"], [String]()),
    (["App.wasDeleted()"], ["App.swift"]),
    (["App.stillExists()", "App.deleted*"], ["App.swift"])
]) func strictMappingsRejectEachUnresolvedSymbol(symbols: [String], sources: [String]) throws {
    let graph = mappingGraph(symbols: symbols, sources: sources)
    do {
        try validate(graph)
        Issue.record("Unresolved symbol should fail")
    } catch let error as MappingValidationError {
        let diagnostic = try #require(error.diagnostics.first)
        #expect(error.code == "strict_mapping_validation_failed")
        #expect(error.diagnostics.count == 1)
        #expect(diagnostic.code == "unresolved_mapping_symbol")
        #expect(diagnostic.mappingFile == "Config/ui.json")
        #expect(diagnostic.feature == "checkout")
        #expect(diagnostic.pattern == symbols.last)
        #expect(diagnostic.revision == "head-sha")
        #expect(diagnostic.buildContext["configuration"] == "Release")
        #expect(diagnostic.message.contains("did not resolve in this build"))
        let decoded = try JSONDecoder().decode(MappingValidationError.self, from: JSONEncoder().encode(error))
        #expect(decoded.diagnostics.first?.pattern == diagnostic.pattern)
    }
}

@Test func strictMappingResolutionUsesTheSameRootsAsSelection() throws {
    let graph = mappingGraph(symbols: ["App.still*", "App.*", "App.stillExists()"], sources: ["missing.swift"])
    try validate(graph)
    let dependencies = try #require(graph.dependencies)
    let index = MappingIndex(try #require(graph.mappings), snapshot: graph, graph: dependencies, index: DependencyIndex(dependencies))
    #expect(index.roots["checkout"] == ["existing"])
    // This policy is limited to symbol entries; unmatched sources/selectors keep
    // their existing conservative semantics.
    try validate(mappingGraph(symbols: [], sources: ["missing.swift"]))
}

@Test func strictMappingsPermitHeadRepairsAndWildcardSurvivors() throws {
    var graph = mappingGraph(symbols: ["App.stillExists()"])
    graph.dependencies!.functions["existing"]!.name = "renamed()"
    #expect(throws: MappingValidationError.self) { try validate(graph) }
    graph.mappings!.features[0].symbols = ["App.renamed()"]
    try validate(graph)
    graph.dependencies!.functions.removeAll()
    #expect(throws: MappingValidationError.self) { try validate(graph) }
    graph.mappings!.features[0].symbols = []
    try validate(graph)
    graph.mappings = nil
    try validate(graph)
    graph = mappingGraph(symbols: ["App.*"])
    graph.dependencies!.functions["deleted"] = FunctionNode(id: "deleted", module: "App", name: "wasDeleted()")
    try validate(graph)
    graph.dependencies!.functions.removeValue(forKey: "deleted")
    try validate(graph)
}

@Test func strictMappingsCannotValidateLegacyGraphsWithoutCompilerData() throws {
    var graph = mappingGraph(symbols: ["App.stillExists()"])
    graph.dependencies = nil
    do {
        try validate(graph)
        Issue.record("Missing compiler graph should fail")
    } catch let error as MappingValidationError {
        #expect(error.diagnostics.map(\.code) == ["mapping_symbol_graph_unavailable"])
    }
}

@Test func strictMappingsAreOptInAndIndependentOfSelectionChanges() throws {
    let graph = mappingGraph(symbols: ["App.wasDeleted()"])
    var options = XcodeConfiguration(container: .project, path: URL(fileURLWithPath: "/App.xcodeproj"),
                                     scheme: "App", destination: "platform=macOS")
    try XcodeAnalysis(options: options).validateMappings(in: graph, revision: "head")
    options.strictMappings = true
    #expect(throws: MappingValidationError.self) {
        try XcodeAnalysis(options: options).validateMappings(in: graph, revision: "head")
    }
    // No test inventory or changed production source is required for validation.
    #expect(graph.tests.isEmpty)
}

@Test func strictMappingsRetainFileErrorsAcrossGraphArchives() throws {
    var graph = mappingGraph(symbols: [])
    graph.mappings = nil
    graph.mappingLoadError = "Unknown fixture missing in UI feature checkout"
    graph.diagnostics = ["Invalid UI mappings: " + graph.mappingLoadError!]
    let json = try JSONDecoder().decode(XcodeTestGraph.self, from: JSONEncoder().encode(graph))
    let binary = try GraphArchive.decode(GraphArchive.encode(graph))
    var legacy = graph
    legacy.mappingLoadError = nil
    // Old snapshots have only the existing diagnostic, with no new field.
    legacy = try JSONDecoder().decode(XcodeTestGraph.self, from: JSONEncoder().encode(legacy))
    for snapshot in [graph, json, binary, legacy] {
        do {
            try validate(snapshot)
            Issue.record("A discarded invalid mapping must not pass strict validation")
        } catch let error as MappingValidationError {
            let diagnostic = try #require(error.diagnostics.first)
            #expect(diagnostic.code == "invalid_mapping_file")
            #expect(diagnostic.mappingFile == "Config/ui.json")
            #expect(diagnostic.revision == "head-sha")
            #expect(diagnostic.feature == nil && diagnostic.pattern == nil)
            #expect(diagnostic.message.contains("Unknown fixture missing"))
        }
        let options = XcodeConfiguration(container: .project, path: URL(fileURLWithPath: "/App.xcodeproj"),
                                         scheme: "App", destination: "platform=macOS")
        try XcodeAnalysis(options: options).validateMappings(in: snapshot, revision: "head")
    }
}

@Test func strictMappingsReportStructuralErrorsForInMemoryMappings() throws {
    var graph = mappingGraph(symbols: ["App.wasDeleted()"])
    graph.mappings!.features[0].fixtures = ["missing"]
    do {
        try validate(graph)
        Issue.record("Invalid in-memory mappings must return a structured error")
    } catch let error as MappingValidationError {
        #expect(error.diagnostics.first?.code == "invalid_mapping_file")
    }
}
