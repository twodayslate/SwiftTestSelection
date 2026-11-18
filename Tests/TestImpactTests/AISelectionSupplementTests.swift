// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation
import Testing
@testable import TestImpact

private func withAISupplementFixture(commentOnly: Bool = false,
                                    _ body: (URL, XcodeTestGraph, ImpactReport) async throws -> Void) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ai-supplement-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let names = ["testHigh", "testLow", "testMapped", "testUnknown"]
    let ui = "import XCTest\nclass Suite: XCTestCase {\n" + names.map { "func \($0)() {}" }.joined(separator: "\n") + "\n}\n"
    try "func save() -> Int { 1 }\n".write(to: root.appendingPathComponent("App.swift"), atomically: true, encoding: .utf8)
    try ui.write(to: root.appendingPathComponent("UI.swift"), atomically: true, encoding: .utf8)
    let mappings = UIFeatureMappings(features: [.init(name: "save", sources: ["App.swift"], tests: ["UI/Suite/testMapped()"])] )
    try JSONEncoder().encode(mappings).write(to: root.appendingPathComponent(".swift-test-selection.json"))
    func git(_ args: [String]) throws { _ = try CommandRunner.run("git", args, at: root) }
    try git(["init", "-q"]); try git(["add", "."])
    try git(["-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-qm", "base"])
    let base = try GitChanges.revision("HEAD", at: root)
    let app = commentOnly ? "// Documentation only\nfunc save() -> Int { 1 }\n" : "func save() -> Int { 2 }\n"
    try app.write(to: root.appendingPathComponent("App.swift"), atomically: true, encoding: .utf8)
    try git(["add", "."])
    try git(["-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-qm", "head"])
    let head = try GitChanges.revision("HEAD", at: root)
    var graph = XcodeTestGraph(targets: [
        .init(name: "App", productType: "com.apple.product-type.application", sourceFiles: ["App.swift"]),
        .init(name: "UI", productType: "com.apple.product-type.bundle.ui-testing", sourceFiles: ["UI.swift"]),
        .init(name: "Unit", productType: "com.apple.product-type.bundle.unit-test", sourceFiles: [])
    ], tests: names.map { "UI/Suite/\($0)()" } + ["Unit/Suite/testStatic()"])
    graph.modules = ["App": "App", "UI": "UI"]
    graph.sources = ["App:App.swift": .parse(app, path: "App.swift", module: "App"),
                     "UI:UI.swift": .parse(ui, path: "UI.swift", module: "UI")]
    graph.mappings = mappings
    var dependencies = DependencyGraph()
    dependencies.compilerImplicitImports = ["App": [], "UI": []]
    let save = try #require(graph.sources["App:App.swift"]?.units.first { $0.helperCallableName == "save" })
    dependencies.functions["save"] = .init(id: "save", module: "App", name: "save()", regions: [save.region])
    for name in names {
        let method = try #require(graph.sources["UI:UI.swift"]?.units.first { $0.helperCallableName == name })
        dependencies.functions[name] = .init(id: name, module: "UI", name: "Suite.\(name)()", regions: [method.region])
        dependencies.functions[name]!.nominalTypeContext = "UI.Suite"
        dependencies.tests["UI/Suite/\(name)()"] = [name]
    }
    graph.dependencies = dependencies
    let selected = ["UI/Suite/testMapped()", "Unit/Suite/testStatic()"]
    var report = ImpactReport(baseRevision: base, totalTests: graph.tests.count, selectedTests: selected,
        explanations: [.init(test: selected[0], reason: "Declared mapping", revision: "head", path: [], kind: "mapping")],
        fullRunReasons: [], changedFiles: ["App.swift"], unreferencedChanges: [], limitations: [])
    report.headRevision = head
    report.buildArtifactID = "preserved-build-binding"
    report.onlyTestingArguments = selected.map { "-only-testing:" + $0 }
    try await body(root, graph, report)
}

@Test func aiSupplementPreservesBaselineAndAddsThresholdAndUnknownTests() async throws {
    try await withAISupplementFixture { root, graph, baseline in
        var seen: [String] = []
        let result = try await AISelectionSupport.supplement(baseline, current: graph, repository: root,
            configuration: .init(), availability: { "available" }) { input, rendered in
            seen.append(input.testIdentifier)
            #expect(input.function.name == "save")
            #expect(rendered.prompt.contains("App.swift"))
            let score: Int? = input.testIdentifier.contains("testHigh") ? 75 : input.testIdentifier.contains("testLow") ? 74 : nil
            return .init(confidencePercent: score, reason: "fixture")
        }
        #expect(seen.count == 3 && !seen.contains("UI/Suite/testMapped()"))
        #expect(Set(result.selectedTests) == Set(baseline.selectedTests + ["UI/Suite/testHigh()", "UI/Suite/testUnknown()"]))
        #expect(result.buildArtifactID == baseline.buildArtifactID)
        #expect(result.explanations.first?.kind == "mapping")
        #expect(result.onlyTestingArguments == result.selectedTests.map { "-only-testing:" + $0 })
        #expect(result.aiSelection?.evaluation?.rows.count == 3)
        #expect(result.aiSelection?.evaluation?.advisoryOnly == false)
        #expect(result.aiSelection?.retainedUnknownTests == ["UI/Suite/testUnknown()"])
        let saved = try JSONDecoder().decode(ImpactReport.self, from: JSONEncoder().encode(result))
        #expect(saved.aiSelection?.addedTests == result.aiSelection?.addedTests)
    }
}

@Test func aiSupplementUnavailableRetainsUIWithoutRemovingStaticTests() async throws {
    try await withAISupplementFixture { root, graph, baseline in
        var calls = 0
        let result = try await AISelectionSupport.supplement(baseline, current: graph, repository: root,
            configuration: .init(), availability: { "unavailable: modelNotReady" }) { _, _ in
            calls += 1; return .init(confidencePercent: 0, reason: "should not run")
        }
        #expect(calls == 0 && Set(result.selectedTests) == Set(graph.tests))
        #expect(result.aiSelection?.status == "unavailable")
        #expect(result.aiSelection?.retainedUnknownTests.count == 3)
    }
}

@Test func aiSupplementNormalizesMappingPathsWithoutRetainingAllCandidates() async throws {
    try await withAISupplementFixture { root, originalGraph, originalReport in
        var graph = originalGraph, baseline = originalReport
        // Both a committed default mapping and an absent optional default must
        // behave identically for every spelling accepted by normal selection.
        for present in [true, false] {
            if !present {
                _ = try CommandRunner.run("git", ["rm", ".swift-test-selection.json"], at: root)
                _ = try CommandRunner.run("git", ["-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-qm", "remove optional mapping"], at: root)
                baseline.headRevision = try GitChanges.revision("HEAD", at: root)
                graph.mappings = nil
            }
            for path in [".swift-test-selection.json", "./.swift-test-selection.json", "config//../.swift-test-selection.json"] {
                var calls = 0
                let result = try await AISelectionSupport.supplement(baseline, current: graph, repository: root,
                    mappingsPath: path, configuration: .init(), availability: { "available" }) { input, _ in
                    calls += 1
                    #expect(input.mappings?.rules.contains { $0.origin == "historical-json" } == present)
                    return .init(confidencePercent: 0, reason: "fixture")
                }
                #expect(calls == 3)
                #expect(result.selectedTests == baseline.selectedTests)
                #expect(result.aiSelection?.status == "completed")
                #expect(result.aiSelection?.retainedUnknownTests.isEmpty == true)
            }
        }
    }
}

@Test func aiSupplementBudgetAndUnresolvedSourceRetainUnevaluatedTests() async throws {
    try await withAISupplementFixture { root, graph, baseline in
        var calls = 0
        var missing = graph
        missing.dependencies?.tests.removeValue(forKey: "UI/Suite/testUnknown()")
        let result = try await AISelectionSupport.supplement(baseline, current: missing, repository: root,
            configuration: .init(maximumPairs: 1), availability: { "available" }) { _, _ in
            calls += 1; return .init(confidencePercent: 0, reason: "fixture")
        }
        #expect(calls == 1)
        #expect(result.aiSelection?.retainedUnknownTests == ["UI/Suite/testLow()", "UI/Suite/testUnknown()"])
        #expect(!result.selectedTests.contains("UI/Suite/testHigh()"))
        #expect(Set(baseline.selectedTests).isSubset(of: Set(result.selectedTests)))
    }
}

@Test func aiSupplementSkipsFullSelectionWithoutProbingModel() async throws {
    try await withAISupplementFixture { root, graph, baseline in
        var full = baseline
        full.selectedTests = graph.tests.sorted()
        var probes = 0
        let result = try await AISelectionSupport.supplement(full, current: graph, repository: root,
            configuration: .init(), availability: { probes += 1; return "available" }) { _, _ in
            Issue.record("Unexpected model call"); return .init(confidencePercent: 0, reason: "unused")
        }
        #expect(probes == 0 && result.selectedTests == full.selectedTests)
        #expect(result.aiSelection?.status == "not-needed")
    }
}

@Test func aiSupplementIgnoresCommentOnlyProductionEdits() async throws {
    try await withAISupplementFixture(commentOnly: true) { root, graph, baseline in
        var probes = 0
        let result = try await AISelectionSupport.supplement(baseline, current: graph, repository: root,
            configuration: .init(), availability: { probes += 1; return "available" }) { _, _ in
            Issue.record("Unexpected model call"); return .init(confidencePercent: 0, reason: "unused")
        }
        #expect(probes == 0 && result.selectedTests == baseline.selectedTests)
    }
}

@Test func aiSupplementProviderErrorsRetainAndCancellationPropagates() async throws {
    try await withAISupplementFixture { root, graph, baseline in
        let result = try await AISelectionSupport.supplement(baseline, current: graph, repository: root,
            configuration: .init(), availability: { "available" }) { _, _ in throw ImpactError("provider failed") }
        #expect(result.aiSelection?.retainedUnknownTests.count == 3)
        #expect(result.aiSelection?.evaluation?.rows.allSatisfy { $0.prediction.error != nil } == true)
        await #expect(throws: CancellationError.self) {
            try await AISelectionSupport.supplement(baseline, current: graph, repository: root,
                configuration: .init(), availability: { "available" }) { _, _ in throw CancellationError() }
        }
    }
}
