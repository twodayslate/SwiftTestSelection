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
        let source = try XcodeHeadOnlySources.read(current: current, changes: changes, base: comparison.base,
            root: root, mappingPath: options.mappingsPath, cache: cache)
        var report = XcodeHeadOnlySelector.select(current: current, source: source, changes: changes,
            baseRevision: comparison.base, documentation: Set(proof.documentation), buildEvidenceFailure: proof.uncertainty)
        if let selectionScopes {
            report.selectionScopes = try XcodeHeadOnlySelector.scopedReports(current: current, requests: selectionScopes,
                changes: changes, baseRevision: comparison.base, headRevision: artifact.revision, root: root,
                mappingPath: options.mappingsPath, documentation: Set(proof.documentation), buildEvidenceFailure: proof.uncertainty,
                retainedGraphPath: retainedGraphPath, sourceCache: cache)
        }
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
        return report
    }
}
