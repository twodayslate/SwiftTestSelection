// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation
import Testing
@testable import TestImpact

private func budgetInput() -> UIReachabilityInput {
    .init(revision: String(repeating: "a", count: 40), testIdentifier: "UI/Suite/testSave()",
          function: .init(name: "save", region: .init(path: "App.swift", startLine: 1, endLine: 1), source: "func save() {}", calls: []),
          test: .init(name: "testSave", region: .init(path: "UI.swift", startLine: 2, endLine: 2),
                      source: "func testSave() { /* " + String(repeating: "complete test body ", count: 300) + " */ }", calls: []),
          context: [], contextKind: "compiler-and-syntax-neighborhood", limitations: [])
}

@Test func aiBudgetSharesSpaceWithBroadMappingsAndLongCompilerEdges() throws {
    var input = budgetInput()
    input.context = [.init(name: "tap", region: .init(path: "App.swift", startLine: 2, endLine: 2),
                           source: "func tap() { save() }", calls: ["save"])]
    input.compilerEdges = (0..<64).map { i in
        .init(caller: "implicit closure \(i) " + String(repeating: "generated-signature ", count: 40), callee: "save()")
    }
    let condition = try JSONDecoder().decode(UIFeatureMappings.Condition.self,
        from: Data(#"{"all":[{"sourceChanged":"App.swift"},{"symbolChanged":"App.save()"}]}"#.utf8))
    let feature = UIFeatureMappings.Feature(name: "broad", sources: ["App.swift"] + (0..<200).map { "Other\($0).swift" },
        symbols: ["App.save()", "App.other()"], tests: ["UI/Suite"] + (0..<200).map { "UI/Other/test\($0)()" },
        fixtures: ["journey"], dependsOn: ["shared"], when: condition)
    let rule = UIReachabilityMappings.Rule(origin: "historical-json", location: ".swift-test-selection.json",
        binding: "declared-test-selectors", feature: feature, expandedTestSelectors: feature.tests!, matchesTestSelector: true,
        matchingFunctionSourcePatterns: ["App.swift"], matchingFunctionSymbolPatterns: ["App.save()"])
    input.mappings = .init(rules: [rule])
    let packed = try UIReachabilityContextBudget.pack(input)
    #expect(try UIReachabilityPrompt.render(packed).utf8.count <= UIReachabilityPromptTemplates.maximumPromptBytes)
    #expect(packed.function.source == input.function.source && packed.test.source == input.test.source)
    #expect(packed.context.count == 1)
    #expect((packed.compilerEdges?.count ?? 0) > 0)
    #expect(packed.contextBudget?.omittedCompilerEdges == 64 - (packed.compilerEdges?.count ?? 0))
    let retained = try #require(packed.mappings?.rules.first)
    #expect(retained.feature.sources == ["App.swift"] && retained.feature.symbols == ["App.save()"])
    #expect(retained.feature.tests == ["UI/Suite"] && retained.expandedTestSelectors == ["UI/Suite"])
    #expect(retained.feature.fixtures == ["journey"] && retained.feature.dependsOn == ["shared"])
    let conditionEncoder = JSONEncoder(); conditionEncoder.outputFormatting = [.sortedKeys]
    #expect(try conditionEncoder.encode(retained.feature.when) == conditionEncoder.encode(condition))
    #expect(retained.projection?.omittedAssociations["sources"] == 200)
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    #expect(retained.projection?.originalFeatureDigest == XcodeGraphCache.digest(try encoder.encode(feature)))
    #expect(try UIReachabilityPrompt.render(packed) == UIReachabilityPrompt.render(UIReachabilityContextBudget.pack(input)))
}

@Test func aiBudgetOversizedSubjectsStillAbstainWithoutModelCalls() async throws {
    var input = budgetInput()
    input.test.source += String(repeating: " x", count: 7_000)
    input.compilerEdges = [.init(caller: "tap()", callee: "save()")]
    let packed = try UIReachabilityContextBudget.pack(input)
    #expect(packed.contextBudget?.subjectsExceedBudget == true)
    #expect(packed.test.source == input.test.source && packed.function.source == input.function.source)
    #expect(packed.compilerEdges?.isEmpty == true)
    var calls = 0
    let report = try await UIReachabilityEvaluation.run(.init(cases: [
        .init(id: "oversized", input: packed, evidenceKind: .unlabeled, evidence: "budget regression")
    ]), provider: "test", availability: "available") { _ in
        calls += 1; return .init(confidencePercent: 0, reason: "must not run")
    }
    #expect(calls == 0)
    #expect(report.rows[0].prediction.error?.contains("Complete subject pair") == true)
    #expect(report.selection?.decisions.first?.retainedForUnknown == true)
}

@Test func aiBudgetDropsOversizedMetadataWithoutLosingOmissionCounts() throws {
    var input = budgetInput()
    input.mappings = .init(limitations: [String(repeating: "diagnostic ", count: 2_000)], omittedRuleCount: 7)
    input.compilerEdges = [.init(caller: "tap()", callee: "save()")]
    let packed = try UIReachabilityContextBudget.pack(input)
    #expect(try UIReachabilityPrompt.render(packed).utf8.count <= UIReachabilityPromptTemplates.maximumPromptBytes)
    #expect(packed.contextBudget?.subjectsExceedBudget == false)
    #expect(packed.contextBudget?.omittedMappingRules == 7)
    #expect(packed.mappings == nil)
    #expect(packed.compilerEdges?.count == 1)
}

@Test func aiCompilerBudgetPrioritizesCallbackRoutesAndCountsOmissions() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ai-budget-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try "func save() {}\nfunc tap() { save() }\n".write(to: root.appendingPathComponent("App.swift"), atomically: true, encoding: .utf8)
    try "class Suite {\n func testSave() {}\n}\n".write(to: root.appendingPathComponent("UI.swift"), atomically: true, encoding: .utf8)
    func git(_ args: [String]) throws { _ = try CommandRunner.run("git", args, at: root) }
    try git(["init", "-q"]); try git(["add", "."])
    try git(["-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-qm", "fixture"])
    let revision = try GitChanges.revision("HEAD", at: root)
    let spec = UIReachabilityCaseSpec(id: "routes", revision: revision, function: .init(path: "App.swift", line: 1),
        test: .init(path: "UI.swift", line: 2), testIdentifier: "UI/Suite/testSave()", evidenceKind: .unlabeled, evidence: "fixture")
    var graph = XcodeTestGraph(targets: [.init(name: "UI", productType: "com.apple.product-type.bundle.ui-testing", sourceFiles: ["UI.swift"])], tests: [spec.testIdentifier])
    graph.buildArtifact = XcodeBuildArtifact(revision: revision, context: [:], toolchain: "fixture", buildLogDigest: "fixture",
        buildSettingsDigest: "fixture", productsDirectory: "/unused", xctestrun: "unused", products: [:])
    var nodes: [String: FunctionNode] = [
        "save": .init(id: "save", module: "App", name: "save()", regions: [.init(path: "App.swift", startLine: 1, endLine: 1)]),
        "zz-tap": .init(id: "zz-tap", module: "App", name: "tap()", regions: [.init(path: "App.swift", startLine: 2, endLine: 2)], dependencies: ["save"]),
        "test": .init(id: "test", module: "UI", name: "Suite.testSave()", regions: [.init(path: "UI.swift", startLine: 2, endLine: 2)])
    ]
    for index in 0..<80 {
        let id = "a-assert-\(index)"
        nodes[id] = .init(id: id, module: "UI", name: "implicit closure \(index) " + String(repeating: "long-type-signature ", count: 40), regions: [], dependencies: ["test"])
    }
    graph.dependencies = DependencyGraph(functions: nodes)
    let input = try UIReachabilityPreparation.prepare([spec], repository: root, graph: graph).cases[0].input
    #expect(try UIReachabilityPrompt.render(input).utf8.count <= UIReachabilityPromptTemplates.maximumPromptBytes)
    #expect(input.compilerEdges?.first?.caller == "tap()")
    #expect(input.context.contains { $0.name == "tap" })
    #expect(input.contextBudget?.omittedCompilerEdges == 81 - (input.compilerEdges?.count ?? 0))
    #expect(input.contextBudget?.omittedCompilerSourceNodes == 80)
}
