// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation
import Testing
@testable import TestImpact

private struct BaseSourceBenchmarkCase: Decodable {
    var name: String
    var root: String
    var graph: String
    var report: String
    var output: String
    var repetitions: Int
}

/// Release-only opt-in comparison over identical captured compiler evidence.
/// Timed totals include primary + every scope's source loading and selection;
/// graph decoding and diff construction are outside those totals.
@Test(.enabled(if: ProcessInfo.processInfo.environment["IMPACT_BASE_SOURCE_BENCHMARK"] != nil))
func baseSourceCacheRealAppBenchmark() throws {
    let path = try #require(ProcessInfo.processInfo.environment["IMPACT_BASE_SOURCE_BENCHMARK"])
    let cases = try JSONDecoder().decode([BaseSourceBenchmarkCase].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    for fixture in cases {
        let graph = try GraphArchive.decode(Data(contentsOf: URL(fileURLWithPath: fixture.graph)))
        let original = try JSONDecoder().decode(ImpactReport.self, from: Data(contentsOf: URL(fileURLWithPath: fixture.report)))
        let root = URL(fileURLWithPath: fixture.root)
        let changes = try GitChanges.readComparison(base: original.baseRevision, head: original.headRevision, at: root)
        let scopes = original.selectionScopes ?? []
        let failure = original.diagnostics.first { $0.code == "head_only_build_evidence" }?.message
        var rows: [[String: Any]] = []
        var referenceReports: [ImpactReport] = []
        for repetition in 0..<fixture.repetitions {
            // Alternate ordering to expose rather than assume away warm effects.
            for cached in repetition % 2 == 0 ? [false, true] : [true, false] {
                let start = Date()
                let cache = try cached ? XcodeBaseSourceCache(root: root, base: original.baseRevision) : nil
                var counts: [String: Int] = [:]
                var queries: [[String: Any]] = []
                for index in 0...scopes.count {
                    let scope = index == 0 ? nil : scopes[index - 1].scope
                    let paths = Set(scope?.paths ?? [])
                    let filtered = scope == nil ? changes : changes.filter { paths.contains($0.path) || ($0.previousPath.map(paths.contains) ?? false) }
                    let sourceStart = Date()
                    let source: XcodeHeadOnlySources
                    if let cache {
                        source = try XcodeHeadOnlySources.read(current: graph, changes: filtered, base: original.baseRevision, root: root, mappingPath: ".swift-test-selection.json", cache: cache)
                    } else {
                        source = try uncachedHeadOnlySources(current: graph, changes: filtered, base: original.baseRevision, root: root, mappingPath: ".swift-test-selection.json", measurement: { counts[$0, default: 0] += 1 })
                    }
                    let sourceSeconds = Date().timeIntervalSince(sourceStart)
                    let selectionStart = Date()
                    let report = XcodeHeadOnlySelector.select(current: graph, source: source, changes: filtered, baseRevision: original.baseRevision,
                        documentation: Set(original.ignoredChanges), buildEvidenceFailure: failure, excludedTestEntries: Set(scope?.excludedTestEntries ?? []))
                    let selectionSeconds = Date().timeIntervalSince(selectionStart)
                    let expected = index == 0 ? original : scopes[index - 1].report
                    try #require(report.selectedTests == expected.selectedTests)
                    // Saved reports can choose a different representative path for an
                    // ambiguous declaration after dictionary reconstruction. Compare
                    // the full diagnostics against the uncached loader on this exact
                    // in-memory graph, never normalize away message differences.
                    if repetition == 0 && !cached { referenceReports.append(report) }
                    try #require(try diagnosticJSON(report) == diagnosticJSON(referenceReports[index]))
                    queries.append(["name": scope?.name ?? "primary", "sourceSeconds": sourceSeconds, "selectionSeconds": selectionSeconds,
                                    "selected": report.selectedTests.count, "diagnostics": report.diagnostics.count])
                }
                if let cache {
                    counts = ["blobReads": cache.counts.blobReads, "blobHits": cache.counts.blobHits,
                              "treeReads": cache.counts.treeReads, "treeHits": cache.counts.treeHits,
                              "parses": cache.counts.parses, "parseHits": cache.counts.parseHits]
                }
                let row: [String: Any] = ["repetition": repetition + 1, "cached": cached, "seconds": Date().timeIntervalSince(start), "counts": counts, "queries": queries]
                rows.append(row)
                print("Base syntax benchmark \(fixture.name) repeat \(repetition + 1) cached=\(cached): \(row["seconds"]!) s; \(counts)")
            }
        }
        let result: [String: Any] = ["case": fixture.name, "base": original.baseRevision, "head": original.headRevision ?? "",
                                   "exactIdentifiersAndDiagnosticsMatch": true, "measurements": rows]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: fixture.output))
    }
}
