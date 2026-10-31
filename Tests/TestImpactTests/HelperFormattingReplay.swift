// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
import Foundation
import Testing
@testable import TestImpact

private struct FormattingReplay: Decodable {
    var graph: String
    var root: String
    var report: String
    var output: String
    var contracts: String?
    var refreshIndirectErrorEvidence: Bool?
    var refreshFormattingBuildEvidence: Bool?
}

/// Explicitly supplied reviewed declarations only. Never generates guarantees
/// or enables assertions from absent edges, test names or observed coverage.
@Test(.enabled(if: ProcessInfo.processInfo.environment["IMPACT_FORMATTING_REPLAY"] != nil))
func retainedHelperFormattingReview() throws {
    // Large real SwiftUI files exceed the debug Swift Testing worker's small
    // stack in the existing native syntax walkers. Use a dedicated bounded
    // stack; no compiler graph, source facts or selection rules are changed.
    final class Outcome: @unchecked Sendable { var value: Result<Void, Error> = .success(()) }
    let outcome = Outcome(), completion = DispatchSemaphore(value: 0)
    let worker = Thread {
        outcome.value = Result { try runFormattingReview() }
        completion.signal()
    }
    worker.stackSize = 64 * 1024 * 1024
    worker.start()
    completion.wait()
    try outcome.value.get()
}

private func runFormattingReview() throws {
    let configuration = try #require(ProcessInfo.processInfo.environment["IMPACT_FORMATTING_REPLAY"])
    let fixtures = try JSONDecoder().decode([FormattingReplay].self, from: Data(contentsOf: URL(fileURLWithPath: configuration)))
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    for fixture in fixtures {
        let start = Date()
        let graphPath = URL(fileURLWithPath: fixture.graph), root = URL(fileURLWithPath: fixture.root)
        var current = try GraphArchive.decode(Data(contentsOf: graphPath))
        let prior = try JSONDecoder().decode(ImpactReport.self, from: Data(contentsOf: URL(fileURLWithPath: fixture.report)))
        let output = URL(fileURLWithPath: fixture.output)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for key in current.sources.keys.sorted() {
            let module = String(key.prefix { $0 != ":" }), path = String(key.dropFirst(module.count + 1))
            let text = try String(contentsOf: graphPath.deletingLastPathComponent().appendingPathComponent("source").appendingPathComponent(path), encoding: .utf8)
            let fresh = SwiftSourceSnapshot.parse(text, path: path, module: module)
            let old = current.sources[key]!
            try #require(old.units.map(\.key) == fresh.units.map(\.key))
            try #require(old.units.map(\.fingerprint) == fresh.units.map(\.fingerprint))
            current.sources[key] = fresh
        }
        if fixture.refreshIndirectErrorEvidence == true {
            // Reparse sealed bytes, never replay the compiler or change edges.
            let sourceRoot = graphPath.deletingLastPathComponent().appendingPathComponent("source")
            let captureRoot = graphPath.deletingLastPathComponent().appendingPathComponent("SILCapture")
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
            for id in current.dependencies!.functions.keys.sorted() where current.dependencies!.functions[id]!.module == module {
                let old = current.dependencies!.functions[id]!
                guard let new = parsed.functions[id] else { continue }
                try #require(old.compilerReferences == new.compilerReferences)
                try #require(old.receiverErrorEffects == new.receiverErrorEffects)
                current.dependencies!.functions[id]!.receiverIndirectErrorEffects = new.receiverIndirectErrorEffects
                refreshed += 1
            }
            try #require(refreshed > 0)
            print("Refreshed indirect error evidence from sealed SIL:", refreshed)
        }
        if fixture.refreshFormattingBuildEvidence == true {
            let retained = graphPath.deletingLastPathComponent()
            let log = try Data(contentsOf: retained.appendingPathComponent("build.log"))
            let settings = try Data(contentsOf: retained.appendingPathComponent("build-settings.json"))
            let artifact = try #require(current.buildArtifact)
            try #require(XcodeGraphCache.digest(log) == artifact.buildLogDigest)
            try #require(XcodeGraphCache.digest(settings) == artifact.buildSettingsDigest)
            current.buildArtifact!.helperFormattingBuild = try .capture(log: log, settings: settings,
                source: retained.appendingPathComponent("source"), derived: retained.appendingPathComponent("DerivedData"))
        }
        if let declarations = fixture.contracts {
            current.mappings!.helperFormattingContracts = try JSONDecoder().decode([HelperFormattingContract].self, from: Data(contentsOf: URL(fileURLWithPath: declarations)))
        }
        // Keep the original capture immutable. This archive carries refreshed
        // syntax/indirect-call metadata from the same sealed source and SIL,
        // plus the explicit review input; artifact and dependency edges persist.
        let reviewedGraph = output.appendingPathComponent("reviewed-head-graph.stigraph")
        try GraphArchive.encode(current).write(to: reviewedGraph)
        let scopes = try #require(prior.selectionScopes)
        let reports = try XcodeHeadOnlySelector.scopedReports(current: current, requests: .init(scopes: scopes.map(\.scope)),
            changes: prior.changedFiles.map { .init(path: $0) }, baseRevision: prior.baseRevision,
            headRevision: try #require(prior.headRevision), root: root, mappingPath: ".swift-test-selection.json",
            documentation: [], buildEvidenceFailure: nil, retainedGraphPath: reviewedGraph.path)
        for scoped in reports {
            let report = scoped.report
            try encoder.encode(report).write(to: output.appendingPathComponent(scoped.scope.name + ".json"))
            let known = Set(report.explanations.filter { $0.kind == "dependency" }.map(\.test))
            #expect(known.isSubset(of: Set(report.selectedTests)))
            #expect(report.helperContractPreview?.added.isEmpty ?? true)
            print("FORMATTING REVIEW", scoped.scope.name, "selected", report.selectedTests.count,
                  "UI", report.selectedTests.filter { $0.hasPrefix("ChainOfCustodyUITests/") }.count,
                  "known", known.count, "seconds", Date().timeIntervalSince(start))
            // Candidate identities for human review, without guarantees/rationale.
            // Limit producers to compiler-reachable callers of the changed helper.
            var candidates: [FormattingBoundary] = []
            let graph = try #require(current.dependencies), index = DependencyIndex(graph)
            for boundary in report.formattingBoundaries ?? [] {
                let symbols = report.helperContractReviewContext?.helperSymbols[boundary.helper] ?? []
                let paths = index.paths(to: Set(symbols))
                let consumers = graph.tests.filter { paths.path(from: $0.value) != nil }.keys
                var pending = Set(consumers.flatMap { graph.tests[$0] ?? [] }), visited = Set<String>()
                while let id = pending.popFirst() {
                    guard visited.insert(id).inserted, let node = graph.functions[id] else { continue }
                    pending.formUnion(node.dependencies)
                    for call in node.receiverGenericCalls ?? [] {
                        let parts = call.split(separator: "\t", maxSplits: 1).map(String.init)
                        guard parts.count == 2, let reason = SDKReceiverContracts.missingWitnessProof(parts[1], for: parts[0]) else { continue }
                        let units = current.sources.values.flatMap(\.units).filter { unit in
                            unit.key.hasPrefix(node.module + ":") && unit.kind == "function" && node.regions.contains {
                                $0.path == unit.region.path && $0.startLine >= unit.region.startLine && $0.endLine <= unit.region.endLine
                            }
                        }
                        guard units.count == 1 else { continue }
                        let candidate = FormattingBoundary(helper: boundary.helper, producer: units[0].key,
                            producerSymbol: node.id, assertionSymbol: parts[0], substitutions: parts[1], region: units[0].region, explanation: reason)
                        if !candidates.contains(candidate) { candidates.append(candidate) }
                    }
                }
            }
            try encoder.encode(candidates.sorted { ($0.helper, $0.producerSymbol, $0.substitutions) < ($1.helper, $1.producerSymbol, $1.substitutions) })
                .write(to: output.appendingPathComponent("review-candidates.json"))
        }
    }
}
