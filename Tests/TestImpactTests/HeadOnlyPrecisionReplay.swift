// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation
import Testing
@testable import TestImpact

private struct PrecisionReplay: Decodable {
    var graph: String
    var root: String
    var report: String
    var output: String
    var knownConsumers: [String]
    var obsoleteBlockers: [String]
    var expectedBlocker: String
    var declarationFallbacks: Int
}

/// Opt-in source/selection replay over freshly captured retained head products.
/// No compiler graph is manufactured or patched; source fingerprints must match.
@Test(.enabled(if: ProcessInfo.processInfo.environment["IMPACT_PRECISION_REPLAY"] != nil))
func retainedHeadOnlyPrecisionReplay() throws {
    let path = try #require(ProcessInfo.processInfo.environment["IMPACT_PRECISION_REPLAY"])
    let cases = try JSONDecoder().decode([PrecisionReplay].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    for fixture in cases {
        let graphPath = URL(fileURLWithPath: fixture.graph)
        let root = URL(fileURLWithPath: fixture.root)
        let output = URL(fileURLWithPath: fixture.output)
        let prior = try JSONDecoder().decode(ImpactReport.self, from: Data(contentsOf: URL(fileURLWithPath: fixture.report)))
        var graph = try GraphArchive.decode(Data(contentsOf: graphPath))
        let sourceRoot = graphPath.deletingLastPathComponent().appendingPathComponent("source")
        let start = Date()
        for key in graph.sources.keys.sorted() {
            let colon = try #require(key.firstIndex(of: ":"))
            let module = String(key[..<colon]), path = String(key[key.index(after: colon)...])
            let fresh = SwiftSourceSnapshot.parse(try String(contentsOf: sourceRoot.appendingPathComponent(path), encoding: .utf8), path: path, module: module)
            let old = try #require(graph.sources[key])
            try #require(old.units.map(\.key) == fresh.units.map(\.key))
            try #require(old.units.map(\.fingerprint) == fresh.units.map(\.fingerprint))
            graph.sources[key] = fresh
        }
        let scopes = try #require(prior.selectionScopes)
        let reports = try XcodeHeadOnlySelector.scopedReports(current: graph,
            requests: .init(scopes: scopes.map(\.scope)), changes: prior.changedFiles.map { .init(path: $0) },
            baseRevision: prior.baseRevision, headRevision: try #require(prior.headRevision), root: root,
            mappingPath: ".swift-test-selection.json", documentation: [], buildEvidenceFailure: nil,
            retainedGraphPath: graphPath.path)
        let report = try #require(reports.first?.report)
        #expect(reports.count == 1)
        #expect(Set(fixture.knownConsumers).isSubset(of: Set(report.selectedTests)))
        #expect(report.diagnostics.filter { $0.code == "head_only_declaration_change" }.count == fixture.declarationFallbacks)
        #expect(report.diagnostics.contains { $0.message.contains(fixture.expectedBlocker) })
        for blocker in fixture.obsoleteBlockers { #expect(!report.diagnostics.contains { $0.message.contains(blocker) }) }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try encoder.encode(report).write(to: output.appendingPathComponent("scope.json"))
        let summary: [String: Any] = ["seconds": Date().timeIntervalSince(start), "selected": report.selectedTests.count,
            "ui": report.selectedTests.filter { $0.hasPrefix("ChainOfCustodyUITests/") }.count,
            "knownConsumers": fixture.knownConsumers.count,
            "blockers": report.diagnostics.filter { $0.code != "head_only_runtime_uncertainty" }.map(\.message)]
        try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("summary.json"))
        print("PRECISION REPLAY", output.path, summary)
    }
}
