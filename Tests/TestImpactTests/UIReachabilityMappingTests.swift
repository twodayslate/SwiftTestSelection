// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation
import Testing
@testable import TestImpact

private let mappingTestSource = """
import XCTest
// swift-test-selection: {"sources":["App.swift"]}
class Suite: XCTestCase {
    /// swift-test-selection: {"when":{"all":[{"sourceChanged":"App.swift"},{"symbolChanged":"App.save()"}]}}
    func testSave() {}
    // swift-test-selection: {"symbols":["App.other()"]}
    func testOther() {}
}
// swift-test-selection: {"sources":["NotThisTest.swift"]}
class OtherSuite: XCTestCase { func testSave() {} }
"""

private func withAIMappingRepository(_ body: (URL, UIReachabilityCaseSpec) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ai-mappings-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try "func save() {}\n".write(to: root.appendingPathComponent("App.swift"), atomically: true, encoding: .utf8)
    try mappingTestSource.write(to: root.appendingPathComponent("UI.swift"), atomically: true, encoding: .utf8)
    _ = try CommandRunner.run("git", ["init", "-q"], at: root)
    _ = try CommandRunner.run("git", ["add", "."], at: root)
    _ = try CommandRunner.run("git", ["-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-qm", "fixture"], at: root)
    let revision = try GitChanges.revision("HEAD", at: root)
    let spec = UIReachabilityCaseSpec(id: "mapping", revision: revision, function: .init(path: "App.swift", line: 1),
        test: .init(path: "UI.swift", line: 5), testIdentifier: "UI/Suite/testSave()", evidenceKind: .unlabeled, evidence: "fixture")
    try body(root, spec)
}

@Test func aiInlineMappingScopeAndConditionsArePreserved() throws {
    try withAIMappingRepository { root, spec in
        let item = try UIReachabilityPreparation.prepare([spec], repository: root).cases[0]
        let mappings = try #require(item.input.mappings)
        #expect(mappings.rules.count == 2)
        #expect(mappings.rules.allSatisfy { $0.origin == "inline-comment" && $0.binding.hasPrefix("syntax-candidate:") })
        #expect(mappings.rules.contains { $0.matchingFunctionSourcePatterns == ["App.swift"] })
        #expect(mappings.rules.contains { $0.feature.when?.operation == "all" })
        #expect(mappings.rules.allSatisfy { $0.matchingFunctionSymbolPatterns == nil })
        let prompt = try UIReachabilityPrompt.render(item.input)
        #expect(!prompt.contains("App.other()") && !prompt.contains("NotThisTest.swift"))
        #expect(mappings.limitations.contains { $0.contains("No .swift-test-selection.json") })
        #expect(throws: ImpactError.self) {
            try UIReachabilityPreparation.prepare([spec], repository: root, mappingsPath: "missing.json")
        }
    }
}

@Test func aiJSONMappingsUseHistoricalFixturesAndDependencyClosure() throws {
    try withAIMappingRepository { root, original in
        let mappings = UIFeatureMappings(fixtures: ["journey": ["UI/Suite"]], features: [
            .init(name: "save", sources: ["App.swift"], fixtures: ["journey"], dependsOn: ["shared"]),
            .init(name: "shared", symbols: ["App.persist()"], dependsOn: ["save"]),
            .init(name: "unrelated", sources: ["Other.swift"], tests: ["UI/OtherSuite"])
        ], runtimeDependencyPolicy: .declared)
        let file = root.appendingPathComponent("custom.json")
        try JSONEncoder().encode(mappings).write(to: file)
        _ = try CommandRunner.run("git", ["add", "custom.json"], at: root)
        _ = try CommandRunner.run("git", ["-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-qm", "mapping"], at: root)
        var spec = original
        spec.revision = try GitChanges.revision("HEAD", at: root)
        try "DIRTY_MAPPING_SENTINEL".write(to: file, atomically: true, encoding: .utf8)
        let input = try UIReachabilityPreparation.prepare([spec], repository: root, mappingsPath: "custom.json").cases[0].input
        let evidence = try #require(input.mappings)
        let jsonRules = evidence.rules.filter { $0.origin == "historical-json" }
        #expect(Set(jsonRules.map { $0.feature.name }) == ["save", "shared"])
        #expect(jsonRules.first { $0.feature.name == "save" }?.expandedTestSelectors == ["UI/Suite"])
        #expect(jsonRules.first { $0.feature.name == "save" }?.matchesTestSelector == true)
        #expect(evidence.runtimeDependencyPolicy == .declared)
        #expect(!((try UIReachabilityPrompt.render(input)).contains("DIRTY_MAPPING_SENTINEL")))
        #expect(throws: ImpactError.self) {
            try UIReachabilityPreparation.prepare([original], repository: root, mappingsPath: "custom.json")
        }
        for path in ["../custom.json", "/custom.json", "./custom.json"] {
            #expect(throws: ImpactError.self) {
                try UIReachabilityPreparation.prepare([spec], repository: root, mappingsPath: path)
            }
        }
    }
}

@Test func aiMappingInputRejectsMalformedAndSymlinkFiles() throws {
    try withAIMappingRepository { root, original in
        try "{}".write(to: root.appendingPathComponent("bad.json"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("link.json").path, withDestinationPath: "bad.json")
        _ = try CommandRunner.run("git", ["add", "."], at: root)
        _ = try CommandRunner.run("git", ["-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-qm", "invalid mappings"], at: root)
        var spec = original
        spec.revision = try GitChanges.revision("HEAD", at: root)
        for path in ["bad.json", "link.json"] {
            #expect(throws: (any Error).self) {
                try UIReachabilityPreparation.prepare([spec], repository: root, mappingsPath: path)
            }
        }
    }
}

@Test func aiMappingBudgetReportsOmissionsWithoutTruncatingRules() throws {
    try withAIMappingRepository { root, original in
        let mappings = UIFeatureMappings(features: (0..<20).map {
            .init(name: "feature-\($0)", sources: ["App.swift"], tests: ["UI/Suite"])
        })
        try JSONEncoder().encode(mappings).write(to: root.appendingPathComponent(".swift-test-selection.json"))
        _ = try CommandRunner.run("git", ["add", "."], at: root)
        _ = try CommandRunner.run("git", ["-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-qm", "many mappings"], at: root)
        var spec = original
        spec.revision = try GitChanges.revision("HEAD", at: root)
        let input = try UIReachabilityPreparation.prepare([spec], repository: root).cases[0].input
        let evidence = try #require(input.mappings)
        #expect(evidence.rules.count + evidence.omittedRuleCount == 22)
        #expect(evidence.omittedRuleCount >= 6)
        #expect(input.function.source == "func save() {}")
        #expect(input.test.source.contains("func testSave() {}"))
        #expect(try UIReachabilityPrompt.render(input).utf8.count < UIReachabilityPrompt.maximumInputBytes)
    }
}

@Test func aiCompilerBoundInlineMappingsAndSymbolIdentity() throws {
    let ui = SwiftSourceSnapshot.parse(mappingTestSource, path: "UI.swift", module: "UI")
    let app = SwiftSourceSnapshot.parse("func save() {}", path: "App.swift", module: "App")
    var graph = XcodeTestGraph(targets: [
        .init(name: "UI", productType: "com.apple.product-type.bundle.ui-testing", sourceFiles: ["UI.swift"]),
        .init(name: "App", productType: "com.apple.product-type.application", sourceFiles: ["App.swift"])
    ], tests: ["UI/Suite/testSave()"])
    graph.modules = ["UI": "UI", "App": "App"]
    graph.sources = ["UI:UI.swift": ui, "App:App.swift": app]
    var dependencies = DependencyGraph()
    dependencies.compilerImplicitImports = ["UI": [], "App": []]
    let declaration = try #require(ui.inlineMappings?.declarations.first { $0.scope == "Suite" && $0.method == "testSave()" })
    dependencies.functions["test"] = .init(id: "test", module: "UI", name: "Suite.testSave()", regions: [declaration.region])
    dependencies.functions["test"]!.nominalTypeContext = "UI.Suite"
    dependencies.functions["save"] = .init(id: "save", module: "App", name: "save()", regions: [app.units[0].region])
    XcodeCompilerGraph.bind(tests: graph.tests, modules: graph.modules, sources: graph.sources, graph: &dependencies)
    graph.dependencies = dependencies
    let result = UIReachabilityMappingPreparation.collect(
        function: .init(name: "save", region: app.units[0].region, source: "func save() {}", calls: []),
        test: .init(name: "testSave", region: declaration.region, source: "func testSave() {}", calls: [], scope: "Suite"),
        testIdentifier: "UI/Suite/testSave()", syntax: ui.inlineMappings, mappings: nil,
        mappingPath: ".swift-test-selection.json", graph: graph)
    #expect(result.rules.count == 2)
    #expect(result.rules.allSatisfy { $0.binding == "compiler-resolved-test" })
    #expect(result.rules.contains { $0.matchingFunctionSymbolPatterns == ["App.save()"] })
}
