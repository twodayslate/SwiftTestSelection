// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Testing
@testable import TestImpact

/// Optional policy diagnostic over preserved compiler evidence. This does not
/// verify retained products or authorize execution of a historical build.
@Test func headOnlyScopeDiagnosticReplay() throws {
    guard let path = ProcessInfo.processInfo.environment["IMPACT_SCOPE_REPLAY"] else { return }
    let cases = try JSONDecoder().decode([[String: String]].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    for config in cases {
        func value(_ key: String) throws -> String { try #require(config[key]) }
        let root = URL(fileURLWithPath: try value("root"))
        let head = try GraphArchive.decode(Data(contentsOf: URL(fileURLWithPath: value("headGraph"))))
        let original = try JSONDecoder().decode(ImpactReport.self, from: Data(contentsOf: URL(fileURLWithPath: value("originalReport"))))
        let request = try JSONDecoder().decode(SelectionScopes.self, from: Data(contentsOf: URL(fileURLWithPath: value("scopes"))))
        let comparison = try RevisionComparison(base: value("base"), head: value("head"), mergeBase: true, root: root)
        let changes = try GitChanges.readComparison(base: comparison.base, head: comparison.head, at: root)
        let source = try XcodeHeadOnlySources.read(current: head, changes: changes, base: comparison.base, root: root, mappingPath: ".swift-test-selection.json")
        let buildFailure = original.diagnostics.first { $0.code == "head_only_build_evidence" }?.message
        var report = XcodeHeadOnlySelector.select(current: head, source: source, changes: changes, baseRevision: comparison.base,
            documentation: Set(original.ignoredChanges), buildEvidenceFailure: buildFailure)
        #expect(report.selectedTests == original.selectedTests)
        #expect(report.diagnostics.map(\.code) == original.diagnostics.map(\.code))
        report.headRevision = comparison.head
        report.buildArtifactID = original.buildArtifactID
        let start = Date()
        report.selectionScopes = try XcodeHeadOnlySelector.scopedReports(current: head, requests: request, changes: changes,
            baseRevision: comparison.base, headRevision: try #require(comparison.head), root: root,
            mappingPath: ".swift-test-selection.json", documentation: Set(original.ignoredChanges), buildEvidenceFailure: buildFailure)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: URL(fileURLWithPath: value("output")))
        print("Scope replay \(try value("output")): \(Date().timeIntervalSince(start)) seconds; \(report.selectionScopes!.map { $0.report.selectedTests.count }) candidates")
    }
}
