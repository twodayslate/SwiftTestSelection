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
    var expectedBlocker: String?
    var expectedSelected: [String]?
    var expectedSelectedCount: Int?
    var expectedUICount: Int?
    var declarationFallbacks: Int
    var refreshIndirectErrorEvidence: Bool?
    var fallbackOnlyTests: [String]?
    var retainedCapture: String?
}

/// Opt-in source/selection replay over freshly captured retained head products.
/// No compiler edges are manufactured or patched; source fingerprints must match.
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
        let retained = fixture.retainedCapture.map { URL(fileURLWithPath: $0) } ?? graphPath.deletingLastPathComponent()
        let sourceRoot = retained.appendingPathComponent("source")
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
        if fixture.refreshIndirectErrorEvidence == true {
            // Reparse sealed bytes, never replay the compiler or change edges.
            let captureRoot = retained.appendingPathComponent("SILCapture")
            let seal = try JSONDecoder().decode(CapturedSIL.Seal.self, from: Data(contentsOf: captureRoot.appendingPathComponent("build.json")))
            var files: [String: [URL]] = [:], fingerprints: [String: String] = [:]
            let module = "ChainOfCustodyUITests"
            for (relative, digest) in seal.manifests {
                let manifest = captureRoot.appendingPathComponent(relative)
                try #require(try ArtifactFiles.digest(manifest) == digest)
                let job = try JSONDecoder().decode(CapturedSIL.Job.self, from: Data(contentsOf: manifest))
                let index = try #require(job.arguments.firstIndex(of: "-module-name"))
                guard job.arguments[index + 1] == module else { continue }
                try #require(job.status == "complete")
                for (source, digest) in job.sources {
                    try #require(try ArtifactFiles.digest(URL(fileURLWithPath: source, relativeTo: URL(fileURLWithPath: job.directory))) == digest)
                }
                for filename in job.silFiles {
                    let file = manifest.deletingLastPathComponent().appendingPathComponent(filename)
                    files[module, default: []].append(file)
                    let digest: String = try #require(job.silSHA256[filename])
                    fingerprints[file.path] = digest
                }
            }
            let capture = CapturedSIL(modules: files, fingerprints: fingerprints, diagnostics: [])
            let raw = try #require(try capture.parse(module: module, sourceRoot: sourceRoot))
            let compiler = try CommandRunner.run("xcrun", ["--find", "swiftc"], at: root).text.trimmingCharacters(in: .whitespacesAndNewlines)
            let parsed = try SILOwnership.resolve(raw, module: module, compiler: compiler, directory: root)
            var refreshed = 0
            for id in graph.dependencies!.functions.keys.sorted() where graph.dependencies!.functions[id]!.module == module {
                let old = graph.dependencies!.functions[id]!
                guard let new = parsed.functions[id] else { continue }
                try #require(old.compilerReferences == new.compilerReferences)
                try #require(old.receiverErrorEffects == new.receiverErrorEffects)
                graph.dependencies!.functions[id]!.receiverIndirectErrorEffects = new.receiverIndirectErrorEffects
                refreshed += 1
            }
            try #require(refreshed > 0)
            print("Refreshed indirect error evidence from sealed SIL:", refreshed)
        }
        let scopes = try #require(prior.selectionScopes)
        let reports = try XcodeHeadOnlySelector.scopedReports(current: graph,
            requests: .init(scopes: scopes.map(\.scope)), changes: prior.changedFiles.map { .init(path: $0) },
            baseRevision: prior.baseRevision, headRevision: try #require(prior.headRevision), root: root,
            mappingPath: ".swift-test-selection.json", documentation: [], buildEvidenceFailure: nil,
            retainedGraphPath: graphPath.path)
        let report = try #require(reports.first?.report)
        #expect(reports.count == 1)
        for test in fixture.fallbackOnlyTests ?? [] {
            #expect(report.selectedTests.contains(test))
            #expect(report.explanations.contains { $0.test == test && $0.kind != "dependency" })
            #expect(!report.explanations.contains { $0.test == test && $0.kind == "dependency" })
        }
        #expect(Set(fixture.knownConsumers).isSubset(of: Set(report.selectedTests)))
        #expect(report.diagnostics.filter { $0.code == "head_only_declaration_change" }.count == fixture.declarationFallbacks)
        if let blocker = fixture.expectedBlocker {
            #expect(report.diagnostics.contains { $0.message.contains(blocker) })
        } else {
            #expect(report.diagnostics.isEmpty, "\(report.diagnostics.map(\.message))")
        }
        if let selected = fixture.expectedSelected { #expect(report.selectedTests == selected.sorted()) }
        if let count = fixture.expectedSelectedCount { #expect(report.selectedTests.count == count) }
        if let count = fixture.expectedUICount { #expect(report.selectedTests.filter { $0.hasPrefix("ChainOfCustodyUITests/") }.count == count) }
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
