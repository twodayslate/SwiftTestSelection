// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import Testing
@testable import TestImpact

@Test func compiledImportedConformancesResolveWithoutProjectWitnessCandidates() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("imported-conformance-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let text = """
    import Foundation
    struct Local: Equatable { let value: Int }
    func uuid(_ x: UUID?, _ y: UUID?) -> Bool { x == y }
    func date(_ x: Date?, _ y: Date?) -> Bool { x == y }
    func local(_ x: Local?, _ y: Local?) -> Bool { x == y }
    func generic<T: Equatable>(_ x: T, _ y: T) -> Bool { x == y }
    """
    let file = root.appendingPathComponent("Model.swift"), sil = root.appendingPathComponent("Model.sil")
    try text.write(to: file, atomically: true, encoding: .utf8)
    _ = try CommandRunner.run("xcrun", ["swiftc", "-emit-sil", "-whole-module-optimization", "-Onone", "-g", "-module-name", "Fixture", file.path, "-o", sil.path], at: root)
    let parsed = try SILParser.parse(file: sil, module: "Fixture", sourceRoot: root)
    #expect(parsed.externalWitnesses?["Fixture:Equatable@witness:UUID"]?.isEmpty == false)
    #expect(parsed.externalWitnesses?["Fixture:Equatable@witness:Date"]?.isEmpty == false)
    var graph = DependencyGraph(functions: parsed.functions)
    XcodeCompilerGraph.resolveDispatch(&graph, tables: parsed.dispatchTargets, externalWitnesses: parsed.externalWitnesses ?? [:])
    let projectCandidates = parsed.dispatchTargets["Equatable.\"==\"@witness:Local"] ?? []
    #expect(!projectCandidates.isEmpty)
    for (name, type) in [("uuid(_:_:)", "UUID"), ("date(_:_:)", "Date")] {
        let node = try #require(graph.functions.values.first { $0.name == name })
        #expect(node.resolvedDynamicDeclarations.contains("Equatable.\"==\"@witness:" + type))
        #expect(!node.uncertainties.contains { $0.hasPrefix("Unresolved project dispatch:") })
        #expect(node.dependencies.isDisjoint(with: projectCandidates))
    }
    let local = try #require(graph.functions.values.first { $0.name == "local(_:_:)" })
    let localImplementations = Set(graph.functions.values.filter { $0.name.contains("Local.__derived_struct_equals") }.map(\.id))
    #expect(!localImplementations.isEmpty)
    #expect(graph.dependencyPath(from: [local.id], to: localImplementations) != nil)
    let generic = try #require(graph.functions.values.first { $0.name.hasPrefix("generic") })
    #expect(projectCandidates.isSubset(of: generic.dependencies))
    let archived = try GraphArchive.decodeValue(SILModule.self, from: GraphArchive.encodeValue(parsed))
    #expect(archived.externalWitnesses == parsed.externalWitnesses)
}

@Test(arguments: ["missing", "project", "ambiguous", "unsupported"])
func importedWitnessProofFailsClosed(reason: String) {
    let declaration = "Equatable.\"==\"@witness:Value"
    var owners: Set<String> = ["SDK"]
    if reason == "missing" { owners = [] }
    if reason == "project" { owners = ["App"] }
    if reason == "ambiguous" { owners = ["SDK", "OtherSDK"] }
    let proofs = reason == "unsupported" ? ["App:Other@witness:Value": owners] : ["App:Equatable@witness:Value": owners]
    var graph = DependencyGraph(functions: ["caller": .init(id: "caller", module: "App", name: "call()",
        regions: [.init(path: "App.swift", startLine: 1, endLine: 1)], dynamicDeclarations: [declaration])])
    XcodeCompilerGraph.resolveDispatch(&graph, tables: ["Equatable.\"==\"": ["candidate"]], externalWitnesses: proofs)
    #expect(graph.functions["caller"]?.dependencies == ["candidate"])
    #expect(graph.functions["caller"]!.uncertainties.contains("Unresolved project dispatch: " + declaration))
}

@Test func importedWitnessProofDoesNotLeakBetweenCompilationUnits() {
    var graph = DependencyGraph(functions: ["caller": .init(id: "caller", module: "Other", name: "call()",
        regions: [.init(path: "Other.swift", startLine: 1, endLine: 1)], dynamicDeclarations: ["Equatable.\"==\"@witness:Value"])])
    XcodeCompilerGraph.resolveDispatch(&graph, tables: ["Equatable.\"==\"": ["candidate"]],
        externalWitnesses: ["App:Equatable@witness:Value": ["SDK"]])
    #expect(graph.functions["caller"]?.dependencies == ["candidate"])
    #expect(graph.functions["caller"]!.uncertainties.contains { $0.hasPrefix("Unresolved project dispatch:") })
}

@Test(arguments: ["NSObject", "AnyHashable", "UUID", "Date"], [true, false])
func importedConformanceOwnershipAloneDoesNotExcludeProjectBehavior(type: String, sourceBearing: Bool) {
    let path = "App.swift"
    var old = XcodeTestGraph(targets: [
        .init(name: "App", productType: "com.apple.product-type.framework", sourceFiles: [path]),
        .init(name: "Tests", productType: "com.apple.product-type.bundle.unit-test", sourceFiles: ["Tests.swift"])
    ], tests: ["Tests/Equality/testValue()"])
    old.modules = ["App": "App", "Tests": "Tests"]
    old.sources["App:App.swift"] = SwiftSourceSnapshot.parse("func projectEquality() -> Bool { true }", path: path, module: "App")
    let declaration = "Equatable.\"==\"@witness:" + type
    old.dependencies = DependencyGraph(functions: [
        "changed": .init(id: "changed", module: "App", name: "projectEquality()", regions: [.init(path: path, startLine: 1, endLine: 1)]),
        "test": .init(id: "test", module: "Tests", name: "Equality.testValue()", regions: [.init(path: "Tests.swift", startLine: 1, endLine: 1)], dynamicDeclarations: [declaration])
    ], tests: [old.tests[0]: ["test"]])
    XcodeCompilerGraph.resolveDispatch(&old.dependencies!, tables: [:], externalWitnesses: ["Tests:Equatable@witness:" + type: ["SDK"]])
    #expect(old.dependencies!.functions["test"]!.resolvedDynamicDeclarations.contains(declaration))
    if !sourceBearing {
        var helper = old.dependencies!.functions["test"]!
        helper.id = "sdk-helper"; helper.module = "SDK"; helper.regions = []
        old.dependencies!.functions[helper.id] = helper
        old.dependencies!.functions["test"]!.dependencies = [helper.id]
        old.dependencies!.functions["test"]!.uncertainties = []
        old.dependencies!.functions["test"]!.dynamicDeclarations = []
    }
    var head = old
    head.sources["App:App.swift"] = SwiftSourceSnapshot.parse("func projectEquality() -> Bool { false }", path: path, module: "App")
    let report = XcodeFineSelector.select(current: head, previous: old, changes: [.init(path: path)], baseRevision: "base")
    #expect(report.selectedTests == old.tests)
    #expect(report.diagnostics.contains { $0.code == "unresolved_dependency" && $0.message.contains("Imported conformance:") })
    let packageReport = StaticSelector.select(current: head.dependencies!, previous: old.dependencies!, changes: [.init(path: path)], baseRevision: "base")
    #expect(packageReport.selectedTests == old.tests)
    #expect(packageReport.fullRunReasons.isEmpty)
    #expect(packageReport.explanations.contains { $0.reason.hasPrefix("Conservative selection: Imported conformance:") })
}
