// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
import Foundation

/// Persist the original head-only build audit so saved selection cannot discard
/// script/generated-input uncertainty or invent documentation exemptions.
public struct HeadOnlyBuildEvidence: Codable, Sendable {
    public var version = 1
    public var buildLogDigest: String
    public var buildSettingsDigest: String
    public var documentation: [String]
    public var uncertainty: String?

    func matches(_ artifact: XcodeBuildArtifact) -> Bool {
        version == 1 && !buildLogDigest.isEmpty && !buildSettingsDigest.isEmpty &&
            buildLogDigest == artifact.buildLogDigest && buildSettingsDigest == artifact.buildSettingsDigest
    }
}

extension XcodeAnalysis {
    /// Apply separately reviewed policy to the immutable captured head. The
    /// policy may be committed later without changing the analyzed revision.
    /// This path reads Git and saved evidence only; it never builds or compiles.
    public func selectHeadOnly(base: String, head: String, mergeBase: Bool = false, fullSuite: Bool = false,
                              headGraph: XcodeTestGraph, bindingReviews: [HelperBindingContract]? = nil,
                              selectionScopes: SelectionScopes? = nil, retainedGraphPath: String? = nil) throws -> ImpactReport {
        let root = try GitChanges.repositoryRoot(at: options.path.deletingLastPathComponent())
        let comparison = try RevisionComparison(base: base, head: head, mergeBase: mergeBase, root: root)
        let artifact = try validateArtifactGraph(headGraph, root: root)
        guard artifact.revision == comparison.head else { throw ImpactError("Saved head graph revision does not match the resolved comparison head") }
        guard let proof = artifact.headOnlyBuildEvidence, proof.matches(artifact) else {
            throw ImpactError("Saved graph lacks matching head-only build evidence; capture again with --head-only and --retain-build")
        }
        var current = headGraph
        if let bindingReviews {
            guard current.mappings != nil else { throw ImpactError("Binding reviews require the captured mapping policy") }
            current.mappings!.helperBindingContracts = bindingReviews
        }
        try validateMappings(in: current, revision: artifact.revision)
        let changes = try GitChanges.readComparison(base: comparison.base, head: comparison.head, at: root)
        let cache = try XcodeBaseSourceCache(root: root, base: comparison.base)
        var events: [XcodeAnalysisEvent] = []
        let sourceStart = AnalysisMeasurement()
        try current.refreshLegacyComparisonSyntax(paths: Set(changes.map(\.path)), revision: artifact.revision, root: root)
        let source = try XcodeHeadOnlySources.read(current: current, changes: changes, base: comparison.base,
            root: root, mappingPath: options.mappingsPath, cache: cache)
        events.append(sourceStart.event("baseSourceSyntax", revision: comparison.base))
        let digestCache = HelperBindingDigestCache(current: current)
        let selectionStart = AnalysisMeasurement()
        var report = XcodeHeadOnlySelector.select(current: current, source: source, changes: changes,
            baseRevision: comparison.base, documentation: Set(proof.documentation), buildEvidenceFailure: proof.uncertainty, digestCache: digestCache,
            measurement: { var event = $0; event.parentPhase = "selection"; events.append(event) })
        events.append(selectionStart.event("selection", revision: artifact.revision))
        if let selectionScopes {
            let scopesStart = AnalysisMeasurement()
            report.selectionScopes = try XcodeHeadOnlySelector.scopedReports(current: current, requests: selectionScopes,
                changes: changes, baseRevision: comparison.base, headRevision: artifact.revision, root: root,
                mappingPath: options.mappingsPath, documentation: Set(proof.documentation), buildEvidenceFailure: proof.uncertainty,
                retainedGraphPath: retainedGraphPath, sourceCache: cache, digestCache: digestCache, measurement: { events.append($0) })
            events.append(scopesStart.event("selectionScopes", revision: artifact.revision))
        }
        events.append(.init(phase: "baseSourceCache", revision: comparison.base, seconds: 0, detail: cache.counts.detail))
        report.analysisEvents = events
        report.headRevision = artifact.revision
        report.comparisonMode = comparison.mode
        report.buildArtifactID = artifact.id
        report.buildArtifactPath = retainedGraphPath
        // Keep the complete applied declaration with the report, including its
        // evidence/guarantees. The captured graph and UI mappings stay immutable.
        report.appliedHelperBindingReviews = bindingReviews
        if report.selectionScopes != nil {
            for i in report.selectionScopes!.indices { report.selectionScopes![i].report.appliedHelperBindingReviews = bindingReviews }
        }
        if fullSuite {
            report.selectedTests = current.tests.sorted()
            report.onlyTestingArguments = report.selectedTests.map { "-only-testing:" + $0 }
            report.explanations += report.selectedTests.map { .init(test: $0, reason: "Full suite explicitly requested", revision: "head", path: [], kind: "fullSuite") }
        }
        selectionGraphObserver?(current)
        return report
    }
}

extension XcodeTestGraph {
    /// Comparisons need the same syntax representation on both sides. Older
    /// captures lack conditional membership (before v5) or physical caller
    /// coordinates (before v11), or missed equivalent @Test spellings (before
    /// v28), implicit interpolation calls (before v29), or result-builder sites
    /// (before v30). Before v32 key-path subscripts and calls with only trailing
    /// closures omitted the location supplying their defaults. Recover source facts
    /// only from the authenticated Git blob.
    mutating func refreshLegacyComparisonSyntax(paths: Set<String>, revision: String, root: URL) throws {
        var cache: XcodeBaseSourceCache?
        for (key, var archived) in sources {
            guard let version = archived.parserVersion, version <= SwiftSourceSnapshot.currentParserVersion,
                  version < SwiftSourceSnapshot.currentParserVersion || archived.units.contains(where: { $0.builderLocations == nil }),
                  let blobs = archived.sourceBlobIDs, !blobs.isEmpty,
                  let separator = key.firstIndex(of: ":") else { continue }
            let path = String(key[key.index(after: separator)...])
            guard paths.contains(path) else { continue }
            if cache == nil { cache = try XcodeBaseSourceCache(root: root, base: revision) }
            guard let parsed = try cache?.snapshot(path: path, module: String(key[..<separator])),
                  parsed.diagnostics.isEmpty, let parsedBlobs = parsed.sourceBlobIDs, !blobs.isDisjoint(with: parsedBlobs) else { continue }
            archived.ordinaryManifestNamedSource = parsed.ordinaryManifestNamedSource
            let regions = Dictionary(grouping: parsed.units.indices, by: { parsed.units[$0].region })
            var matched = Set<Int>()
            var restoredInvocations = true
            var builderMatches = Set<Int>()
            for index in archived.units.indices {
                let unit = archived.units[index]
                let refreshCalls = unit.needsCallerLocationRefresh(version: version, verifiedInterpolation: archived.hasVerifiedInterpolationLocations == true)
                let matches = regions[unit.region]?.filter { parsed.units[$0].key == unit.key }
                guard let matches, matches.count == 1, let match = matches.first else {
                    if refreshCalls { restoredInvocations = false }
                    continue
                }
                let native = parsed.units[match]
                builderMatches.insert(match)
                archived.units[index].builderLocations = native.builderLocations
                if version < 11 {
                    archived.units[index].callerLocations = native.callerLocations
                    archived.units[index].conditionalBranch = native.conditionalBranch
                    matched.insert(match)
                }
                if refreshCalls {
                    archived.units[index].callerLocations = native.callerLocations
                    archived.units[index].swiftTestingArguments = native.swiftTestingArguments
                    archived.units[index].invocationNames = native.invocationNames
                    archived.units[index].hasOnlyDirectSourceCalls = native.hasOnlyDirectSourceCalls
                }
                if unit.swiftTestingEntryInputs?.bare == true, unit.swiftTestingRegistrationDeclaration == nil {
                    archived.units[index].swiftTestingRegistrationDeclaration = native.swiftTestingRegistrationDeclaration
                    archived.units[index].swiftTestingBodyCandidate = native.swiftTestingBodyCandidate
                }
            }
            if builderMatches.count != parsed.units.count || builderMatches.count != archived.units.count {
                for index in archived.units.indices { archived.units[index].builderLocations = nil }
            }
            archived.hasVerifiedInvocationLocations = restoredInvocations
            if version < 5, matched.count == parsed.units.count, matched.count == archived.units.count {
                archived.hasVerifiedConditionalMembership = true
            }
            sources[key] = archived
        }
    }
}
