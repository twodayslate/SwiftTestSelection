// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation
import Testing
@testable import TestImpact

private func reachabilityCase(_ id: String = "case", expected: Bool? = true,
                              kind: UIReachabilityEvidence = .execution) -> UIReachabilityCase {
    let fragment = UIReachabilityInput.Fragment(name: "save", region: .init(path: "App.swift", startLine: 1, endLine: 1),
                                              source: "func save() {}", calls: [])
    return .init(id: id, input: .init(revision: String(repeating: "a", count: 40), testIdentifier: "UI/Suite/testSave()",
        function: fragment, test: fragment, context: [], contextKind: "fixture", limitations: []),
        expected: expected, evidenceKind: kind, evidence: "ISOLATED_EXECUTION_LABEL_SENTINEL")
}

@Test func aiPromptExcludesLabelsAndRejectsOversizedInput() throws {
    let item = reachabilityCase()
    let prompt = try UIReachabilityPrompt.render(item.input)
    #expect(!prompt.contains("ISOLATED_EXECUTION_LABEL_SENTINEL"))
    #expect(!prompt.contains("expected"))
    var large = item.input
    large.test.source = String(repeating: "x", count: UIReachabilityPrompt.maximumInputBytes)
    #expect(throws: ImpactError.self) { try UIReachabilityPrompt.render(large) }
}

@Test func aiEvaluationSeparatesProxiesAndCountsUnknownsAndErrors() async throws {
    let cases = [reachabilityCase("tp"), reachabilityCase("fn"), reachabilityCase("unknown"), reachabilityCase("error"),
                 reachabilityCase("tn", expected: false), reachabilityCase("fp", expected: false),
                 reachabilityCase("proxy", kind: .historicalAssociation),
                 reachabilityCase("unlabeled", expected: nil, kind: .unlabeled)]
    var index = 0
    let predictions: [Int?] = [90, 10, nil, 90, 10, 90, 90, nil]
    let report = try await UIReachabilityEvaluation.run(.init(cases: cases), provider: "test fake", availability: "test") { _ in
        defer { index += 1 }
        if index == 3 { throw ImpactError("model failed") }
        return .init(confidencePercent: predictions[index], reason: "test fake")
    }
    let metrics = try #require(report.metricsByEvidence["execution"])
    #expect(metrics.total == 6)
    #expect(metrics.truePositive == 1 && metrics.falseNegative == 1)
    #expect(metrics.trueNegative == 1 && metrics.falsePositive == 1)
    #expect(metrics.unknownPositive == 2 && metrics.errors == 1)
    #expect(metrics.accuracyAmongAnswered == 0.5)
    #expect(metrics.scoredCount == 4)
    #expect(abs(try #require(metrics.brierScore) - 0.41) < 0.000001)
    #expect(report.schemaVersion == 2 && report.positiveThresholdPercent == 75)
    #expect(metrics.recall == 0.25)
    #expect(metrics.retainUnknownRecall == 0.75)
    #expect(report.metricsByEvidence["historicalAssociation"]?.total == 1)
    #expect(report.unlabeledCount == 1)
    #expect(report.rows.count == 8 && report.advisoryOnly)
    let encoded = try JSONEncoder().encode(report)
    #expect(try JSONDecoder().decode(UIReachabilityEvaluation.self, from: encoded).metricsByEvidence["execution"]?.recall == 0.25)
}

@Test func aiUnavailableDoesNotReportPerfectAccuracyOrSkipCases() async throws {
    let report = try await UIReachabilityEvaluation.run(.init(cases: [reachabilityCase()]), provider: "test fake", availability: "unavailable") { _ in
        throw ImpactError("disabled")
    }
    #expect(report.metricsByEvidence["execution"]?.accuracyAmongAnswered == nil)
    #expect(report.metricsByEvidence["execution"]?.answerRate == 0)
    #expect(report.rows.first?.prediction.confidencePercent == nil)
    #expect(report.rows.first?.prediction.error == "disabled")
}

@Test func aiRejectsDuplicateCasesAndUnlabeledTruth() throws {
    #expect(throws: ImpactError.self) { try UIReachabilityDataset(cases: [reachabilityCase(), reachabilityCase()]).validate() }
    #expect(throws: ImpactError.self) { try UIReachabilityDataset(cases: [reachabilityCase(expected: nil)]).validate() }
}

@Test func aiCancellationPropagates() async throws {
    await #expect(throws: CancellationError.self) {
        try await UIReachabilityEvaluation.run(.init(cases: [reachabilityCase()]), provider: "test fake", availability: "test") { _ in
            throw CancellationError()
        }
    }
}

@Test func aiPreparationUsesCommittedSourceAndRefusesMismatchedGraph() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ai-input-test-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    func git(_ args: [String]) throws -> String { try CommandRunner.run("git", args, at: root).text }
    _ = try git(["init", "-q"])
    _ = try git(["config", "user.email", "test@example.com"])
    _ = try git(["config", "user.name", "Test"])
    let original = """
    func save() { persist() }
    func persist() {}
    class Suite {
        func setUp() { prepare() }
        func prepare() {}
        func testSave() { save() }
        var body: String { save(); return "" }
    }
    """
    try original.write(to: root.appendingPathComponent("Fixture.swift"), atomically: true, encoding: .utf8)
    _ = try git(["add", "."]); _ = try git(["commit", "-qm", "fixture"])
    let revision = try GitChanges.revision("HEAD", at: root)
    try "DIRTY_SENTINEL".write(to: root.appendingPathComponent("Fixture.swift"), atomically: true, encoding: .utf8)
    var spec = UIReachabilityCaseSpec(id: "original", revision: revision,
        function: .init(path: "Fixture.swift", line: 1), test: .init(path: "Fixture.swift", line: 6),
        testIdentifier: "UI/Suite/testSave()", expected: true, evidenceKind: .sourceReview, evidence: "direct call fixture")
    let dataset = try UIReachabilityPreparation.prepare([spec], repository: root)
    let input = try #require(dataset.cases.first?.input)
    #expect(input.function.source.contains("persist()"))
    #expect(input.context.contains { $0.name == "setUp" })
    #expect(input.context.contains { $0.name == "body" })
    #expect(!input.context.contains { $0.name.contains("variableDecl[") })
    #expect(try UIReachabilityPrompt.render(input).utf8.count < UIReachabilityPrompt.maximumInputBytes)
    #expect(!input.test.source.contains("DIRTY_SENTINEL"))
    #expect(input.revision == revision)
    #expect(throws: ImpactError.self) {
        try UIReachabilityPreparation.prepare([spec], repository: root, graph: XcodeTestGraph(targets: [], tests: []))
    }
    spec.function.path = "../Fixture.swift"
    #expect(throws: ImpactError.self) { try UIReachabilityPreparation.prepare([spec], repository: root) }
}

@Test func aiCompilerContextRequiresBothRootsAndPreservesEdges() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ai-graph-test-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    func git(_ args: [String]) throws { _ = try CommandRunner.run("git", args, at: root) }
    try git(["init", "-q"])
    try git(["config", "user.email", "test@example.com"]); try git(["config", "user.name", "Test"])
    try "func save() {}\nfunc tap() { save() }\n".write(to: root.appendingPathComponent("App.swift"), atomically: true, encoding: .utf8)
    try "class Suite {\n func testSave() {}\n}\n".write(to: root.appendingPathComponent("UI.swift"), atomically: true, encoding: .utf8)
    try git(["add", "."]); try git(["commit", "-qm", "fixture"])
    let revision = try GitChanges.revision("HEAD", at: root)
    var spec = UIReachabilityCaseSpec(id: "graph", revision: revision, function: .init(path: "App.swift", line: 1),
        test: .init(path: "UI.swift", line: 2), testIdentifier: "UI/Suite/testSave()", evidenceKind: .unlabeled, evidence: "fixture")
    var graph = XcodeTestGraph(targets: [.init(name: "UI", productType: "com.apple.product-type.bundle.ui-testing", sourceFiles: ["UI.swift"])],
                               tests: [spec.testIdentifier])
    graph.buildArtifact = XcodeBuildArtifact(revision: revision, context: [:], toolchain: "fixture", buildLogDigest: "fixture",
                                            buildSettingsDigest: "fixture", productsDirectory: "/unused", xctestrun: "unused", products: [:])
    graph.dependencies = DependencyGraph(functions: [
        "save": .init(id: "save", module: "App", name: "save()", regions: [.init(path: "App.swift", startLine: 1, endLine: 1)]),
        "tap": .init(id: "tap", module: "App", name: "tap()", regions: [.init(path: "App.swift", startLine: 2, endLine: 2)], dependencies: ["save"]),
        "test": .init(id: "test", module: "UI", name: "testSave()", regions: [.init(path: "UI.swift", startLine: 2, endLine: 2)])
    ])
    let result = try UIReachabilityPreparation.prepare([spec], repository: root, graph: graph)
    #expect(result.cases[0].input.compilerEdges?.contains { $0.caller == "tap()" && $0.callee == "save()" } == true)
    #expect(result.cases[0].input.context.contains { $0.name == "tap" })
    graph.dependencies?.functions.removeValue(forKey: "save")
    #expect(throws: ImpactError.self) { try UIReachabilityPreparation.prepare([spec], repository: root, graph: graph) }
    spec.testIdentifier = "UI/WrongSuite/testSave()"
    #expect(throws: ImpactError.self) { try UIReachabilityPreparation.prepare([spec], repository: root) }
}

@Test func aiConfidenceValidationAndThresholdBoundaries() async throws {
    let scores = [0, 74, 75, 100, -1, 101]
    var index = 0
    let report = try await UIReachabilityEvaluation.run(
        .init(cases: scores.indices.map { reachabilityCase("score-\($0)") }),
        provider: "test fake", availability: "test") { _ in
        defer { index += 1 }
        return .init(confidencePercent: scores[index], reason: "fixture")
    }
    let metrics = try #require(report.metricsByEvidence["execution"])
    #expect(metrics.truePositive == 2 && metrics.falseNegative == 2)
    #expect(metrics.unknownPositive == 2 && metrics.errors == 2)
    #expect(metrics.scoredCount == 4)
    #expect(report.rows.suffix(2).allSatisfy { $0.prediction.confidencePercent == nil })
    let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as! [String: Any]
    let rows = json["rows"] as! [[String: Any]]
    let prediction = rows.last!["prediction"] as! [String: Any]
    #expect(prediction["confidencePercent"] is NSNull)
    #expect(prediction["verdict"] == nil)
}

@Test func aiProviderErrorCannotContributeConfidence() async throws {
    let report = try await UIReachabilityEvaluation.run(.init(cases: [reachabilityCase()]),
        provider: "test fake", availability: "test") { _ in
        .init(confidencePercent: 100, reason: "invalid provider response", error: "failed")
    }
    #expect(report.rows[0].prediction.confidencePercent == nil)
    #expect(report.metricsByEvidence["execution"]?.scoredCount == 0)
    #expect(report.metricsByEvidence["execution"]?.brierScore == nil)
}

@Test func aiSelectionThresholdGroupsPairsAndSeparatesRevisions() async throws {
    var cases = [reachabilityCase("low"), reachabilityCase("boundary"), reachabilityCase("unknown"),
                 reachabilityCase("other-revision"), reachabilityCase("error")]
    cases[2].input.testIdentifier = "UI/Suite/testUnknown()"
    cases[3].input.revision = String(repeating: "b", count: 40)
    cases[4].input.testIdentifier = "UI/Suite/testError()"
    let dataset = UIReachabilityDataset(cases: cases)
    let scores: [Int?] = [20, 75, nil, 74, 90]
    var cursor = 0
    let report = try await UIReachabilityEvaluation.run(dataset, provider: "fake", availability: "test") { _ in
        defer { cursor += 1 }
        return .init(confidencePercent: scores[cursor], reason: "fixture", error: cursor == 4 ? "failure" : nil)
    }
    let selection = try #require(report.selection)
    #expect(selection.confidenceThreshold == 75 && selection.decisions.count == 4)
    let grouped = try #require(selection.decisions.first { $0.caseIDs.contains("boundary") })
    #expect(grouped.selected && grouped.maximumConfidencePercent == 75 && grouped.caseIDs == ["boundary", "low"])
    #expect(selection.decisions.filter(\.retainedForUnknown).count == 2)
    #expect(selection.selectedTestsByRevision[cases[3].input.revision] == [])
    let stricter = try UIReachabilitySelection.select(dataset, report: report, confidenceThreshold: 76)
    #expect(stricter.decisions.filter(\.selected).count == 2)
    let all = try UIReachabilitySelection.select(dataset, report: report, confidenceThreshold: 0)
    #expect(all.decisions.allSatisfy { $0.selected })
    let hundred = try UIReachabilitySelection.select(dataset, report: report, confidenceThreshold: 100)
    #expect(hundred.decisions.filter(\.selected).allSatisfy { $0.retainedForUnknown })
    #expect(!UIReachabilityPrompt.instructions.contains("75"))
}

@Test func aiSelectionRejectsStaleIncompleteAndDuplicateReports() async throws {
    let dataset = UIReachabilityDataset(cases: [reachabilityCase("one"), reachabilityCase("two")])
    let report = try await UIReachabilityEvaluation.run(dataset, provider: "fake", availability: "test") { _ in
        .init(confidencePercent: 75, reason: "fixture")
    }
    var stale = report
    stale.datasetDigest = "wrong"
    #expect(throws: ImpactError.self) { try UIReachabilitySelection.select(dataset, report: stale) }
    stale = report; stale.rows[0].inputDigest = "wrong"
    #expect(throws: ImpactError.self) { try UIReachabilitySelection.select(dataset, report: stale) }
    stale = report; stale.rows.removeLast()
    #expect(throws: ImpactError.self) { try UIReachabilitySelection.select(dataset, report: stale) }
    stale = report; stale.rows[1] = stale.rows[0]
    #expect(throws: ImpactError.self) { try UIReachabilitySelection.select(dataset, report: stale) }
}

@Test func aiCustomThresholdControlsMetricsAndInvalidThresholdSkipsInference() async throws {
    let dataset = UIReachabilityDataset(cases: [reachabilityCase()])
    let report = try await UIReachabilityEvaluation.run(dataset, provider: "fake", availability: "test",
        confidenceThreshold: 80) { _ in .init(confidencePercent: 75, reason: "fixture") }
    #expect(report.positiveThresholdPercent == 80)
    #expect(report.metricsByEvidence["execution"]?.falseNegative == 1)
    #expect(report.selection?.decisions.first?.selected == false)
    var calls = 0
    for threshold in [-1, 101] {
        await #expect(throws: ImpactError.self) {
            try await UIReachabilityEvaluation.run(dataset, provider: "fake", availability: "test",
                confidenceThreshold: threshold) { _ in
                calls += 1; return .init(confidencePercent: 100, reason: "fixture")
            }
        }
    }
    #expect(calls == 0)
}
