// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
import Foundation
import Testing
@testable import TestImpact

private struct BindingReplay: Decodable {
    var graph: String
    var root: String
    var report: String
    var output: String
    var formatting: String?
    var bindings: String?
}

/// Re-evaluate explicitly supplied policies against fresh retained build inputs.
/// Never creates reviews or invents compiler edges; no build or compiler replay.
@Test(.enabled(if: ProcessInfo.processInfo.environment["IMPACT_BINDING_REPLAY"] != nil))
func retainedHelperBindingReview() throws {
    final class Outcome: @unchecked Sendable { var result: Result<Void, Error> = .success(()) }
    let outcome = Outcome(), done = DispatchSemaphore(value: 0)
    let thread = Thread {
        outcome.result = Result { try runBindingReplay() }
        done.signal()
    }
    thread.stackSize = 64 * 1024 * 1024
    thread.start(); done.wait()
    try outcome.result.get()
}

private func runBindingReplay() throws {
    let config = try #require(ProcessInfo.processInfo.environment["IMPACT_BINDING_REPLAY"])
    let fixtures = try JSONDecoder().decode([BindingReplay].self, from: Data(contentsOf: URL(fileURLWithPath: config)))
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    for fixture in fixtures {
        let path = URL(fileURLWithPath: fixture.graph), retained = path.deletingLastPathComponent()
        let root = URL(fileURLWithPath: fixture.root), output = URL(fileURLWithPath: fixture.output)
        var current = try GraphArchive.decode(Data(contentsOf: path))
        let prior = try JSONDecoder().decode(ImpactReport.self, from: Data(contentsOf: URL(fileURLWithPath: fixture.report)))
        for key in current.sources.keys.sorted() {
            let module = String(key.prefix { $0 != ":" }), file = String(key.dropFirst(module.count + 1))
            let fresh = SwiftSourceSnapshot.parse(try String(contentsOf: retained.appendingPathComponent("source").appendingPathComponent(file), encoding: .utf8), path: file, module: module)
            try #require(fresh.units.map(\.key) == current.sources[key]!.units.map(\.key))
            try #require(fresh.units.map(\.fingerprint) == current.sources[key]!.units.map(\.fingerprint))
            current.sources[key] = fresh
        }
        var artifact = try #require(current.buildArtifact)
        let logData = try Data(contentsOf: retained.appendingPathComponent("build.log"))
        try #require(XcodeGraphCache.digest(logData) == artifact.buildLogDigest)
        try #require(ArtifactFiles.digest(retained.appendingPathComponent("build-settings.json")) == artifact.buildSettingsDigest)
        try #require(ArtifactFiles.manifest(at: URL(fileURLWithPath: artifact.productsDirectory)) == artifact.products)
        let log = String(decoding: logData, as: UTF8.self), sourceRoot = retained.appendingPathComponent("source")
        let evidence = try HelperBindingBuildEvidence.capture(log: log, source: sourceRoot,
            sourceInputs: ArtifactFiles.sourceInputs(log: log, directory: sourceRoot), artifact: artifact)
        try #require(evidence.matches(artifact))
        artifact.helperBindingBuild = evidence; artifact.helperBindingInputs = evidence.fingerprint; artifact.helperBindingBuildFailure = nil
        current.buildArtifact = artifact
        if let file = fixture.formatting {
            current.mappings!.helperFormattingContracts = try JSONDecoder().decode([HelperFormattingContract].self, from: Data(contentsOf: URL(fileURLWithPath: file)))
        }
        if let file = fixture.bindings {
            current.mappings!.helperBindingContracts = try JSONDecoder().decode([HelperBindingContract].self, from: Data(contentsOf: URL(fileURLWithPath: file)))
        }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let graphPath = output.appendingPathComponent("reviewed-head-graph.stigraph")
        try GraphArchive.encode(current).write(to: graphPath)
        let reports = try XcodeHeadOnlySelector.scopedReports(current: current,
            requests: .init(scopes: try #require(prior.selectionScopes).map(\.scope)),
            changes: prior.changedFiles.map { .init(path: $0) }, baseRevision: prior.baseRevision,
            headRevision: try #require(prior.headRevision), root: root, mappingPath: ".swift-test-selection.json",
            documentation: [], buildEvidenceFailure: nil, retainedGraphPath: graphPath.path)
        for report in reports {
            try encoder.encode(report.report).write(to: output.appendingPathComponent(report.scope.name + ".json"))
            let known = Set(prior.selectionScopes!.first!.report.explanations.filter { $0.kind == "dependency" }.map(\.test))
            #expect(known.isSubset(of: Set(report.report.selectedTests)))
            #expect(known.isSubset(of: Set(report.report.explanations.filter { $0.kind == "dependency" }.map(\.test))))
            print("BINDING REVIEW", report.scope.name, "selected", report.report.selectedTests.count, "known", known.count,
                  "imported modules", evidence.importedModules.count, "input files", evidence.inputFiles.count)
        }
    }
}
