// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation
import Testing
@testable import TestImpact

// Also called with an actual compiler-generated actor adapter by the compiled
// ownership regression, so persisted uncertainty must affect selection, not just
// remain present on a graph node.
func checkGeneratedAdapterSelection(_ adapter: FunctionNode) throws {
    #expect(adapter.regions.isEmpty)
    let callback = "Tests/Callbacks/testCallback()"
    let independent = "Tests/Independent/testIndependent()"
    let feature = "UI/Features/testCallback()"
    let changedFeature = "UI/Features/testChanged()"
    func model(_ value: Int) -> XcodeTestGraph {
        let inputs = ["App": ("App.swift", "func changed() { print(\(value)) }"),
                      adapter.module: ("Adapter.swift", "func bridge() {}"),
                      "Tests": ("Tests.swift", "class Callbacks { func testCallback() {} }\nclass Independent { func testIndependent() {} }"),
                      "UI": ("UI.swift", "class Features { func testCallback() {}\nfunc testChanged() {} }")]
        var graph = XcodeTestGraph(targets: inputs.map { module, input in
            XcodeTarget(name: module, productType: module == "Tests" ? "com.apple.product-type.bundle.unit-test" :
                module == "UI" ? "com.apple.product-type.bundle.ui-testing" : "com.apple.product-type.framework", sourceFiles: [input.0])
        }, tests: [callback, independent, feature, changedFeature].sorted())
        for (module, input) in inputs {
            graph.modules[module] = module
            graph.sources[module + ":" + input.0] = SwiftSourceSnapshot.parse(input.1, path: input.0, module: module)
        }
        func node(_ id: String, _ module: String, _ name: String, _ line: Int = 1, _ dependencies: Set<String> = []) -> FunctionNode {
            var node = FunctionNode(id: id, module: module, name: name,
                regions: [.init(path: inputs[module]!.0, startLine: line, endLine: line)], dependencies: dependencies)
            node.compilerReferences = dependencies
            return node
        }
        graph.dependencies = DependencyGraph(functions: [
            adapter.id: adapter,
            "changed": node("changed", "App", "changed()"),
            "bridge": node("bridge", adapter.module, "bridge()", 1, [adapter.id]),
            "test": node("test", "Tests", "Callbacks.testCallback()", 1, [adapter.id]),
            "independent": node("independent", "Tests", "Independent.testIndependent()", 2),
            "ui": node("ui", "UI", "Features.testCallback()"),
            "changedUI": node("changedUI", "UI", "Features.testChanged()", 2)
        ], tests: [callback: ["test"], independent: ["independent"], feature: ["ui"], changedFeature: ["changedUI"]])
        graph.mappings = UIFeatureMappings(features: [
            .init(name: "callback", sources: ["Adapter.swift"], tests: [feature]),
            .init(name: "changed", sources: ["App.swift"], tests: [changedFeature])
        ])
        graph.runtimeInventory = .init(imports: ["App": [], adapter.module: [], "Tests": [adapter.module], "UI": []],
            hosts: ["Tests": ["Tests"], "UI": ["UI"]])
        return graph
    }
    func select(_ head: XcodeTestGraph, _ base: XcodeTestGraph) -> ImpactReport {
        XcodeFineSelector.select(current: head, previous: base, changes: [.init(path: "App.swift")], baseRevision: "base")
    }
    for format in ["memory", "json", "compact"] {
        func roundTrip(_ graph: XcodeTestGraph) throws -> XcodeTestGraph {
            switch format {
            case "json": return try GraphArchive.decode(JSONEncoder().encode(graph))
            case "compact": return try GraphArchive.decode(GraphArchive.encode(graph))
            default: return graph
            }
        }
        var base = try roundTrip(model(1)), head = try roundTrip(model(2))
        let report = select(head, base)
        #expect(report.selectedTests == [callback, feature, changedFeature].sorted())
        #expect(report.diagnostics.contains { $0.code == "unresolved_dependency" && $0.tests == [callback] })
        #expect(report.diagnostics.contains { $0.code == "unresolved_feature_dependency" && $0.tests == [feature] })
        #expect(report.uiMappingCoverage?.unmappedTests.isEmpty == true)
        #expect((report.runtimeBoundaryDecisions ?? []).isEmpty)
        #expect(XcodeFineSelector.select(current: base, previous: base, changes: [], baseRevision: "base").selectedTests.isEmpty)

        // Existing, validated contracts still narrow uncertainty. Merely having
        // an emitted adapter must never create an implicit runtime exemption.
        base.mappings!.runtimeDependencyPolicy = .declared
        head.mappings!.runtimeDependencyPolicy = .declared
        #expect(select(head, base).selectedTests == [callback, changedFeature].sorted())
        let boundary = TestRuntimeBoundary(target: "Tests", modules: ["Tests", adapter.module], rationale: "Hostless tests only load the adapter module.")
        base.mappings!.testRuntimeBoundaries = [boundary]
        head.mappings!.testRuntimeBoundaries = [boundary]
        let bounded = select(head, base)
        #expect(bounded.selectedTests == [changedFeature])
        #expect(bounded.runtimeBoundaryDecisions?.count == 2)
        #expect(bounded.runtimeBoundaryDecisions?.allSatisfy { $0.boundedUncertaintyTests == [callback] } == true)
        head.runtimeInventory = nil
        #expect(select(head, base).selectedTests.contains(callback))
    }
    // The generic selector also accepts these graph nodes through the public API.
    let base = model(1).dependencies!, head = model(2).dependencies!
    let region = SourceRegion(path: "App.swift", startLine: 1, endLine: 1)
    #expect(StaticSelector.select(current: head, previous: base,
        changes: [.init(path: "App.swift", oldRegions: [region], newRegions: [region])], baseRevision: "base").selectedTests == [callback])
}

@Test func generatedAdapterUncertaintySurvivesArchivedSelection() throws {
    for uncertainty in ["Indirect function invocation", "Raw pointer operation", "Global state access", "Unresolved project dispatch: Callback.run"] {
        let node = FunctionNode(id: "$sAdapter@emitted:Adapter", module: "Adapter", name: "adapter", uncertainties: [uncertainty])
        try checkGeneratedAdapterSelection(node)
        // A regionless SDK body is not made project-owned, and a suffix claiming
        // some other emitter is not accepted as this node's provenance.
        var external = node
        external.id = "$sAdapter"
        #expect(!external.hasOpaqueRuntimeDependency)
        external.id += "@emitted:Other"
        #expect(!external.hasOpaqueRuntimeDependency)
    }
}
