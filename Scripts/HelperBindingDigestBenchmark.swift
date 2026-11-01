// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Link against the release TestImpact objects, as described in
// Documentation/HelperBindingCacheValidation.md. No builds, tests or policies
// are executed/adopted by this benchmark. Input: saved graph, report, Git root.
// The three passes measure the digest workload used by primary/scope/preview
// contexts, not total selector time. Real internal previews now skip this work.
import Foundation
@testable import TestImpact
let input = CommandLine.arguments[1], reportFile = CommandLine.arguments[2], root = URL(fileURLWithPath: CommandLine.arguments[3])
let graph = try XcodeAnalysis.executionGraph(at: URL(fileURLWithPath: input))
let prior = try JSONDecoder().decode(ImpactReport.self, from: Data(contentsOf: URL(fileURLWithPath: reportFile)))
let changes = try GitChanges.readComparison(base: prior.baseRevision, head: prior.headRevision!, at: root)
let source = try XcodeHeadOnlySources.read(current: graph, changes: changes, base: prior.baseRevision, root: root, mappingPath: ".swift-test-selection.json")
let candidates = prior.helperBindingReviewContext!.sources
let cache = HelperBindingDigestCache(current: graph)
for phase in ["primary", "scope", "preview"] {
    let start = Date()
    let old = candidates.map { candidate in
        HelperBindingContracts.bindingDigest(key: candidate.sourceKey, snapshot: (candidate.revision == "head" ? graph.sources : source.base)[candidate.sourceKey]!, current: graph)
    }
    let seconds = Date().timeIntervalSince(start)
    let newStart = Date()
    let cached = candidates.map { candidate in
        cache.bindingDigest(key: candidate.sourceKey, snapshot: (candidate.revision == "head" ? graph.sources : source.base)[candidate.sourceKey]!)
    }
    precondition(old == cached)
    print(phase, "uncached", seconds, "cached", Date().timeIntervalSince(newStart), "sources", candidates.count, "snapshot computations", cache.snapshotComputations, "hits", cache.snapshotHits, "node computations", cache.nodeComputations)
}
