// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation

/// Portable exports of `xccov view --report --json` and
/// `xcresulttool get test-results tests`. Percentages are deliberately unused.
public struct UICoverageReport: Codable, Sendable {
    public struct Function: Codable, Sendable {
        public var name: String
        public var lineNumber: Int
        public var executionCount: Int
    }
    public struct File: Codable, Sendable {
        public var path: String
        public var functions: [Function]
    }
    public struct Target: Codable, Sendable {
        public var name: String
        public var executableLines: Int
        public var files: [File]
    }
    public var targets: [Target]
}

public struct UICoverageTestResults: Codable, Sendable {
    public struct Node: Codable, Sendable {
        public var nodeType: String
        public var name: String
        public var nodeIdentifier: String?
        public var result: String?
        public var children: [Node]?
    }
    public var testNodes: [Node]

    /// Only actual test-case results establish attribution; suite names alone do not.
    func executions() -> [(id: String, result: String)] {
        func walk(_ nodes: [Node], target: String?) -> [(String, String)] {
            nodes.flatMap { node in
                let target = node.nodeType == "UI test bundle" || node.nodeType == "Unit test bundle"
                    ? node.name.replacingOccurrences(of: ".xctest", with: "") : target
                if node.nodeType == "Test Case", let id = node.nodeIdentifier, let result = node.result {
                    let parts = id.split(separator: "/")
                    if parts.count == 3 { return [(id, result)] }
                    if parts.count == 2, let target { return [(target + "/" + id, result)] }
                    return [(id, result)] // Retain malformed identities for explicit rejection.
                }
                return walk(node.children ?? [], target: target)
            }
        }
        return walk(testNodes, target: nil)
    }
}

public struct UICoverageArtifact: Codable, Sendable {
    public struct Session: Codable, Sendable {
        public var id: String
        /// Must equal the plan identity; contains revision, source/build identity,
        /// toolchain, configuration, destination, and graph identity.
        public var identity: [String: String]
        public var sourceRoot: String
        public var enabledTests: [String]
        public var selectedSuites: [String]
        public var appTargets: [String]
        public var resultBundle: String
        public var status: String // complete, incomplete, failed, crashed
        public var testResults: UICoverageTestResults?
        public var coverage: UICoverageReport?
    }
    public var schemaVersion: Int
    public var sessions: [Session]
}

public struct UICoverageDiagnostic: Codable, Sendable {
    public var code: String
    public var severity: String
    public var session: String?
    public var path: String?
    public var message: String
}

public struct UICoverageProposal: Codable, Sendable {
    public struct Evidence: Codable, Sendable {
        public var session: String
        public var path: String
        public var coverageFunction: String
        public var line: Int
        public var compilerCandidates: [String]
        public var suites: [String]
        /// Multiple-suite sessions always remain coarse associations.
        public var attribution: String
        public var expansion: String
    }
    public var schemaVersion = 1
    public var mappings: UIFeatureMappings
    public var additions: [UIFeatureMappings.Feature]
    public var evidence: [Evidence]
    public var diagnostics: [UICoverageDiagnostic]
    public var unmappedSuites: [String]
    public var provenance: [UICoverageArtifact.Session]
    public var validationPassed: Bool
    public var limitations: [String]
}

public struct UICoveragePlan: Codable, Sendable {
    public struct Execution: Codable, Sendable {
        public var id: String
        public var suite: String
        public var expectedTests: [String]
        public var arguments: [String]
    }
    public var schemaVersion = 1
    public var identity: [String: String]
    public var enabledTests: [String]
    public var appTargets: [String]
    public var productsDirectory: String
    public var products: [String: String]
    public var xctestrun: String
    public var executions: [Execution]
    public var buildReuse: String
}

/// Coverage is an optional authoring input. Selection never loads these artifacts.
public enum UICoverageMappings {
    public static func identity(for graph: XcodeTestGraph) throws -> [String: String] {
        guard graph.schemaVersion == 2, graph.dependencies != nil, let build = graph.buildArtifact,
              !build.revision.isEmpty, !build.toolchain.isEmpty, !build.products.isEmpty,
              let destination = build.context["destination"], !destination.isEmpty else {
            throw ImpactError("Coverage authoring requires a captured compiler graph with build provenance and enabled test inventory.")
        }
        return ["graphID": build.id, "revision": build.revision,
                "sourceIdentity": build.revision + ":" + build.buildLogDigest,
                "buildIdentity": try XcodeGraphCache.key(build.products),
                "toolchain": build.toolchain, "configuration": build.context["configuration"] ?? "",
                "destination": destination, "context": try XcodeGraphCache.key(build.context),
                "simulatorRuntimes": build.simulatorRuntimes ?? ""]
    }

    public static func plan(graph: XcodeTestGraph, suites: [String], appTargets: [String]) throws -> UICoveragePlan {
        let identity = try identity(for: graph)
        let uiSuites = Set(uiTests(graph).compactMap(suite))
        guard !suites.isEmpty, Set(suites).isSubset(of: uiSuites) else {
            throw ImpactError("Select one or more exact enabled UI suites (Target/Class).")
        }
        try validateAppTargets(appTargets, graph: graph)
        let build = graph.buildArtifact!
        let testRun = URL(fileURLWithPath: build.productsDirectory).appendingPathComponent(build.xctestrun).path
        return UICoveragePlan(identity: identity, enabledTests: graph.tests.sorted(), appTargets: appTargets.sorted(),
            productsDirectory: build.productsDirectory, products: build.products, xctestrun: testRun,
            executions: Set(suites).sorted().enumerated().map { index, suite in
                .init(id: "suite-\(index + 1)", suite: suite,
                      expectedTests: graph.tests.filter { $0.hasPrefix(suite + "/") }.sorted(),
                      arguments: ["test-without-building", "-xctestrun", testRun,
                                  "-destination", identity["destination"]!, "-enableCodeCoverage", "YES",
                                  "-parallel-testing-enabled", "NO", "-only-testing:" + suite])
            }, buildReuse: "Reuse this single coverage-enabled build for one execution per suite; no method-by-method runs. Products must already contain app instrumentation.")
    }

    public static func propose(graph: XcodeTestGraph, artifact: UICoverageArtifact,
                               existing: UIFeatureMappings? = nil) throws -> UICoverageProposal {
        guard artifact.schemaVersion == 1 else { throw ImpactError("Unsupported coverage artifact version") }
        let expectedIdentity = try identity(for: graph)
        var mappings = existing ?? graph.mappings ?? UIFeatureMappings(features: [])
        try mappings.validate()
        var diagnostics: [UICoverageDiagnostic] = []
        func diagnose(_ code: String, _ message: String, _ session: String? = nil, _ path: String? = nil, severity: String = "warning") {
            diagnostics.append(.init(code: code, severity: severity, session: session, path: path, message: message))
        }
        var evidence: [UICoverageProposal.Evidence] = []
        var associations: [String: Set<String>] = [:]
        let ui = Set(uiTests(graph))
        let allSuites = Set(ui.compactMap(suite))
        let productionFiles = Set(graph.targets.filter(\.hasProductionRole).flatMap(\.sourceFiles))
        let snapshotPaths = Set(graph.sources.values.flatMap(\.units).map { $0.region.path })
            .union(graph.sources.keys.map { key in key.firstIndex(of: ":").map { String(key[key.index(after: $0)...]) } ?? key })
        let dependencyIndex = DependencyIndex(graph.dependencies!)
        var sessionIDs = Set<String>()
        for session in artifact.sessions.sorted(by: { $0.id < $1.id }) {
            guard sessionIDs.insert(session.id).inserted else { throw ImpactError("Duplicate coverage session ID: \(session.id)") }
            let differences = Set(expectedIdentity.keys).union(session.identity.keys).filter { expectedIdentity[$0] != session.identity[$0] }.sorted()
            guard differences.isEmpty, Set(session.enabledTests) == Set(graph.tests) else {
                diagnose("incompatible_artifact", "Cannot combine: identity fields \(differences) or enabled inventory differ from the graph.", session.id, severity: "error"); continue
            }
            guard session.sourceRoot.hasPrefix("/"), !session.resultBundle.isEmpty else {
                diagnose("missing_provenance", "An absolute build source root and result bundle reference are required.", session.id, severity: "error"); continue
            }
            guard session.status == "complete" else {
                diagnose("collection_" + (["failed", "crashed", "incomplete"].contains(session.status) ? session.status : "incomplete"),
                         "Collection is \(session.status); no proposal is derived from this session.", session.id, severity: "error"); continue
            }
            guard let results = session.testResults, !results.executions().isEmpty else {
                diagnose("missing_execution_evidence", "Aggregate coverage without exact executed-test results cannot establish suite attribution.", session.id, severity: "error"); continue
            }
            let executions = results.executions()
            let executed = Set(executions.map(\.id))
            guard executed.isSubset(of: ui), executions.allSatisfy({ $0.result == "Passed" }) else {
                diagnose("unsuccessful_or_unknown_tests", "Results contain failed, skipped, unknown, or non-UI tests; cannot attribute this session.", session.id, severity: "error"); continue
            }
            let suites = Set(executed.compactMap(suite))
            guard suites == Set(session.selectedSuites), !suites.isEmpty else {
                diagnose("suite_attribution_mismatch", "Selected suites disagree with actual executed-test evidence.", session.id, severity: "error"); continue
            }
            let expectedTests = ui.filter { suite($0).map(suites.contains) == true }
            guard executed == expectedTests else {
                diagnose("partial_suite_execution", "Not every enabled method in the attributed suites completed; rerun the complete suites.", session.id, severity: "error"); continue
            }
            if suites.count > 1 {
                diagnose("coarse_multi_suite_attribution", "Every observed file is associated with all contributing suites; this report cannot identify which suite covered each function.", session.id)
            }
            do { try validateAppTargets(session.appTargets, graph: graph) }
            catch { diagnose("invalid_app_targets", String(describing: error), session.id, severity: "error"); continue }
            guard let coverage = session.coverage else {
                diagnose("coverage_unavailable", "Coverage export is missing or failed; this is not a measured empty result.", session.id, severity: "error"); continue
            }
            func reportMatches(_ name: String, _ target: String) -> Bool {
                name == target || name == target + ".app" || name == target + ".framework"
            }
            let targets = coverage.targets.filter { report in session.appTargets.contains { reportMatches(report.name, $0) } }
            guard session.appTargets.allSatisfy({ target in targets.contains { reportMatches($0.name, target) } }),
                  targets.allSatisfy({ $0.executableLines > 0 && !$0.files.isEmpty }) else {
                diagnose("missing_app_instrumentation", "Expected app targets have no measurable coverage; UI-runner coverage alone is insufficient.", session.id, severity: "error"); continue
            }
            let observed = targets.flatMap(\.files).flatMap { file in
                file.functions.filter { $0.executionCount > 0 }.map { (file.path, $0) }
            }
            if observed.isEmpty { diagnose("measured_empty", "Instrumented app targets were measured successfully with no executed functions.", session.id, severity: "info") }
            for (rawPath, function) in observed {
                guard let path = repositoryPath(rawPath, sourceRoot: session.sourceRoot) else {
                    diagnose("external_source", "Coverage path is outside the recorded repository root: \(rawPath)", session.id); continue
                }
                guard productionFiles.contains(path), snapshotPaths.contains(path) else {
                    diagnose("generated_or_unowned_source", "Source has no repository production snapshot; no boundary was invented.", session.id, path); continue
                }
                guard function.lineNumber > 0 else {
                    diagnose("invalid_source_location", "Coverage function has no valid source line.", session.id, path); continue
                }
                let candidates = (dependencyIndex.byFile[path] ?? []).compactMap { graph.dependencies!.functions[$0] }.filter { node in
                    node.regions.contains { $0.path == path && $0.startLine <= function.lineNumber && function.lineNumber <= $0.endLine }
                }.map(\.id).sorted()
                if candidates.isEmpty {
                    diagnose("unresolved_compiler_identity", "No compiler function contains line \(function.lineNumber); propose only the compiler-owned file boundary.", session.id, path)
                } else if candidates.count > 1 {
                    diagnose("ambiguous_compiler_identity", "Multiple compiler functions contain line \(function.lineNumber); no exact symbol mapping is inferred.", session.id, path)
                }
                associations[path, default: []].formUnion(suites)
                evidence.append(.init(session: session.id, path: path, coverageFunction: function.name,
                    line: function.lineNumber, compilerCandidates: candidates, suites: suites.sorted(),
                    attribution: suites.count == 1 ? "isolatedSuite" : "coarseMultipleSuites",
                    expansion: "Observed function expanded to the entire repository source file; unobserved functions in that file are included."))
            }
        }
        var additions: [UIFeatureMappings.Feature] = []
        for path in associations.keys.sorted() {
            let suites = associations[path]!
            if suites.count > 1 { diagnose("shared_dependency", "Shared file retained for all observed suites: \(suites.sorted().joined(separator: ", ")).", nil, path, severity: "info") }
            // Append new boundaries. Never mutate user policies, feature conditions,
            // fixtures, or dependencies; never subtract an unobserved association.
            let alreadyMapped = Set(mappings.features.filter { $0.sources == [path] && ($0.symbols ?? []).isEmpty }
                .flatMap { $0.tests ?? [] })
            let missing = suites.subtracting(alreadyMapped)
            guard !missing.isEmpty else { continue }
            let stem = "coverage:" + path
            var name = stem, suffix = 2
            while mappings.features.contains(where: { $0.name == name }) { name = stem + ":\(suffix)"; suffix += 1 }
            let feature = UIFeatureMappings.Feature(name: name, sources: [path], tests: missing.sorted())
            mappings.features.append(feature); additions.append(feature)
        }
        try mappings.validate() // Same schema validation used by selection.
        var valid = true
        // Resolve every proposed boundary/selector using selection's own index.
        let index = MappingIndex(mappings, snapshot: graph, graph: graph.dependencies!, index: dependencyIndex)
        for feature in additions where index.roots[feature.name]?.isEmpty != false || !(index.unmatched[feature.name] ?? []).isEmpty {
            valid = false
            diagnose("proposal_validation_failed", "Proposed boundary or selector did not resolve: \(feature.name)", severity: "error")
        }
        let mapped = Set(associations.values.flatMap { $0 })
        let unmapped = allSuites.subtracting(mapped).sorted()
        for suite in unmapped { diagnose("unmapped_suite", "No usable positive app-code observations for \(suite).") }
        return UICoverageProposal(mappings: mappings, additions: additions,
            evidence: evidence.sorted { ($0.session, $0.path, $0.line, $0.coverageFunction) < ($1.session, $1.path, $1.line, $1.coverageFunction) },
            diagnostics: diagnostics, unmappedSuites: unmapped, provenance: artifact.sessions,
            validationPassed: valid, limitations: [
                "Positive observations do not prove complete runtime dependencies; runtimeDependencyPolicy is never changed.",
                "File boundaries are additive OR associations; co-execution never implies an AND condition.",
                "Source lines establish candidate compiler identities, not exact symbol identity. Generated and external code require manual review.",
                "This version validates using the mapping schema and selection index available in this build."
            ])
    }

    private static func validateAppTargets(_ targets: [String], graph: XcodeTestGraph) throws {
        let production = Set(graph.targets.filter(\.hasProductionRole).map(\.name))
        guard !targets.isEmpty, Set(targets).isSubset(of: production) else { throw ImpactError("App coverage targets must be explicit production target names from the graph.") }
    }
    private static func uiTests(_ graph: XcodeTestGraph) -> [String] {
        let targets = Set(graph.targets.filter(\.isUITest).map(\.name))
        return graph.tests.filter { targets.contains(String($0.prefix(while: { $0 != "/" }))) }
    }
    private static func suite(_ test: String) -> String? {
        let parts = test.split(separator: "/")
        return parts.count == 3 ? parts.prefix(2).joined(separator: "/") : nil
    }
    private static func repositoryPath(_ path: String, sourceRoot: String) -> String? {
        // Lexical normalization supports imports on another machine; no basename
        // matching or dependence on files/symlinks in the importing checkout.
        let root = URL(fileURLWithPath: sourceRoot).standardizedFileURL.path
        let full = URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: root, isDirectory: true)).standardizedFileURL.path
        guard full.hasPrefix(root + "/") else { return nil }
        return String(full.dropFirst(root.count + 1))
    }
}
