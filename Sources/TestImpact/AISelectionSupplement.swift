// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation

public struct AISelectionConfiguration: Sendable {
    public var confidenceThreshold: Int
    public var maximumPairs: Int
    public var templates: UIReachabilityPromptTemplates

    public init(confidenceThreshold: Int = 75, maximumPairs: Int = 100,
                templates: UIReachabilityPromptTemplates = .init()) {
        self.confidenceThreshold = confidenceThreshold
        self.maximumPairs = maximumPairs
        self.templates = templates
    }

    public func validate() throws {
        try UIReachabilitySelection.validateThreshold(confidenceThreshold)
        guard maximumPairs > 0 else { throw ImpactError("AI maximum pairs must be positive") }
        try templates.validate()
    }
}

public struct AISelectionSupplement: Codable, Sendable {
    public var status: String
    public var confidenceThreshold: Int
    public var maximumPairs: Int
    public var baselineSelectedTests: [String]
    public var candidateTests: [String]
    public var addedTests: [String] = []
    public var retainedUnknownTests: [String] = []
    public var notes: [String] = []
    public var evaluatedPairs: [UIReachabilityCaseSpec] = []
    public var evaluation: UIReachabilityEvaluation?
}

extension XcodeAnalysis {
    /// Run an existing selection path, then supplement its exact analyzed graph.
    /// No extra build, graph command, dataset file, or separate AI selection is needed.
    public func selectWithAI(configuration: AISelectionConfiguration,
                             baseline: (XcodeAnalysis) throws -> ImpactReport) async throws -> ImpactReport {
        try configuration.validate()
        var current: XcodeTestGraph?
        var analysis = self
        analysis.selectionGraphObserver = { current = $0 }
        let report = try baseline(analysis)
        guard let current else { throw ImpactError("AI selection requires the normal selector's analyzed head graph") }
        let root = try GitChanges.repositoryRoot(at: options.path.deletingLastPathComponent())
        return try await AISelectionSupport.supplement(report, current: current, repository: root,
            mappingsPath: options.mappingsPath, configuration: configuration,
            availability: { FoundationModelUIReachability.availability }, progress: progress) { _, rendered in
            try await FoundationModelUIReachability.predict(rendered: rendered)
        }
    }
}

enum AISelectionSupport {
    static func supplement(_ baseline: ImpactReport, current: XcodeTestGraph, repository: URL,
                           mappingsPath: String = ".swift-test-selection.json", configuration: AISelectionConfiguration,
                           availability: () -> String, progress: (String) -> Void = { _ in },
                           predict: (UIReachabilityInput, UIReachabilityPromptTemplates.Rendered) async throws -> UIReachabilityPrediction) async throws -> ImpactReport {
        try configuration.validate()
        let uiTargets = Set(current.targets.filter(\.isUITest).map(\.name))
        let candidates = Set(current.tests.filter { uiTargets.contains(String($0.prefix { $0 != "/" })) })
            .subtracting(baseline.selectedTests).sorted()
        var result = baseline
        var detail = AISelectionSupplement(status: "not-needed", confidenceThreshold: configuration.confidenceThreshold,
            maximumPairs: configuration.maximumPairs, baselineSelectedTests: baseline.selectedTests,
            candidateTests: candidates)
        var additions = Set<String>(), unknowns = Set<String>()
        func retain(_ tests: [String], because reason: String) {
            additions.formUnion(tests); unknowns.formUnion(tests)
            detail.notes.append(reason)
            result.diagnostics.append(.init(code: "ai_selection_unknown", message: reason, tests: tests))
        }
        func finished() -> ImpactReport {
            detail.addedTests = additions.sorted()
            detail.retainedUnknownTests = unknowns.sorted()
            result.selectedTests = Set(baseline.selectedTests).union(additions).sorted()
            result.onlyTestingArguments = result.selectedTests.map { "-only-testing:" + $0 }
            for test in additions.sorted() {
                let score = detail.evaluation?.selection?.decisions.first { $0.testIdentifier == test }?.maximumConfidencePercent
                let reason = unknowns.contains(test)
                    ? "AI supplement retained this UI test because evidence or a prediction was unavailable"
                    : "AI supplement predicted \(score ?? configuration.confidenceThreshold)% execution probability (threshold \(configuration.confidenceThreshold)%)"
                result.explanations.append(.init(test: test, reason: reason, revision: baseline.headRevision ?? "head",
                                                path: [], kind: "aiSupplement"))
            }
            result.aiSelection = detail
            if baseline.selectionScopes != nil {
                result.limitations.append("AI supplements the full comparison only; additional selectionScopes remain deterministic queries.")
            }
            return result
        }
        guard !candidates.isEmpty, !baseline.changedFiles.isEmpty else {
            detail.notes.append("No unselected UI tests or no changed files; no model requests were made.")
            return finished()
        }
        guard let head = baseline.headRevision, head != "WORKTREE",
              current.buildArtifact == nil || current.buildArtifact?.revision == head,
              let graph = current.dependencies else {
            detail.status = "unavailable"
            retain(candidates, because: "AI needs a revision-matched head compiler graph; the normal selection was preserved and remaining UI tests retained.")
            return finished()
        }
        do {
            try Task.checkCancellation()
            let functions = try changedFunctions(baseline, current: current, repository: repository)
            guard !functions.isEmpty else {
                detail.notes.append("No changed production declarations with head compiler locations; normal selection handles removed and non-function changes.")
                return finished()
            }
            let status = availability()
            guard status == "available" else {
                detail.status = "unavailable"
                retain(candidates, because: "AI model \(status); remaining UI tests retained.")
                return finished()
            }
            var specs: [UIReachabilityCaseSpec] = []
            for test in candidates {
                guard let location = testLocation(test, current: current, graph: graph) else {
                    retain([test], because: "AI cannot resolve the complete source method for \(test).")
                    continue
                }
                for function in functions {
                    guard specs.count < configuration.maximumPairs else {
                        unknowns.insert(test); additions.insert(test)
                        continue
                    }
                    specs.append(.init(id: "selection-pair-\(specs.count)", revision: head,
                        function: .init(path: function.path, line: function.startLine), test: location,
                        testIdentifier: test, evidenceKind: .unlabeled,
                        evidence: "Automatically paired changed production declaration and enabled UI test; no execution label"))
                }
            }
            if !unknowns.isEmpty {
                detail.notes.append("Unresolved or budget-limited tests are retained. At most \(configuration.maximumPairs) pairs are evaluated.")
            }
            if !specs.isEmpty {
                progress("AI supplement: evaluating \(specs.count) function/UI-test pairs at \(configuration.confidenceThreshold)%…")
                let dataset = try UIReachabilityPreparation.prepare(specs, repository: repository, graph: current,
                    mappingsPath: mappingsPath == ".swift-test-selection.json" ? nil : mappingsPath, analyzedRevision: head)
                var evaluation = try await UIReachabilityEvaluation.run(dataset,
                    provider: "Apple Foundation Models (on-device)", availability: status,
                    confidenceThreshold: configuration.confidenceThreshold, templates: configuration.templates, predict: predict)
                evaluation.advisoryOnly = false // These scores supplement the normal selection below.
                detail.evaluation = evaluation
                detail.evaluatedPairs = specs
                let errors = evaluation.rows.compactMap { $0.prediction.error }
                if !errors.isEmpty {
                    detail.notes.append("\(errors.count) model requests failed; affected tests were retained. See evaluation rows for errors.")
                }
                for decision in evaluation.selection?.decisions ?? [] {
                    if decision.selected { additions.insert(decision.testIdentifier) }
                    if decision.retainedForUnknown { unknowns.insert(decision.testIdentifier) }
                }
            }
            detail.status = unknowns.isEmpty ? "completed" : "incomplete"
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            detail.status = "unavailable"
            retain(candidates, because: "AI supplement could not complete: \(error). Remaining UI tests retained.")
        }
        progress("AI supplement added \(additions.count) UI tests (\(unknowns.count) retained for unknown evidence).")
        return finished()
    }

    private static func changedFunctions(_ report: ImpactReport, current: XcodeTestGraph, repository: URL) throws -> [SourceRegion] {
        let production = Set(current.targets.filter { !$0.isTest }.flatMap(\.sourceFiles))
        let changed = Set(report.changedFiles).subtracting(report.ignoredChanges).intersection(production)
        var regions = Set<SourceRegion>()
        for path in changed where !current.sources.values.contains(where: { $0.units.contains { $0.region.path == path } }) {
            if current.dependencies?.functions.values.contains(where: { $0.regions.contains { $0.path == path } }) == true {
                throw ImpactError("AI source snapshot is missing for changed production file \(path)")
            }
        }
        for (key, snapshot) in current.sources.sorted(by: { $0.key < $1.key }) {
            guard let path = snapshot.units.first?.region.path, changed.contains(path) else { continue }
            let module = String(key.prefix { $0 != ":" })
            let old = try CommandRunner.run("git", ["show", report.baseRevision + ":" + path], at: repository, allowFailure: true)
            let previous = old.status == 0 ? SwiftSourceSnapshot.parse(old.text, path: path, module: module).units : []
            for unit in snapshot.units where ["function", "state", "declaration"].contains(unit.kind) {
                // Compare semantic fingerprints, so comment/whitespace-only edits
                // do not introduce AI work or override a normal empty selection.
                guard !previous.contains(where: { $0.key == unit.key && $0.fingerprint == unit.fingerprint }),
                      current.dependencies?.functions.values.contains(where: { node in
                          node.module == module && node.regions.contains { $0.intersects(unit.region) }
                      }) == true else { continue }
                regions.insert(unit.region)
            }
        }
        return regions.sorted { ($0.path, $0.startLine, $0.endLine) < ($1.path, $1.startLine, $1.endLine) }
    }

    private static func testLocation(_ test: String, current: XcodeTestGraph, graph: DependencyGraph) -> UIReachabilityInput.Source? {
        let components = test.split(separator: "/").map(String.init)
        guard components.count == 3, components[2].hasSuffix("()") else { return nil }
        let method = String(components[2].dropLast(2))
        var regions = Set<SourceRegion>()
        for id in graph.tests[test] ?? [] {
            guard let node = graph.functions[id] else { continue }
            for region in node.regions {
                for unit in current.sources[node.module + ":" + region.path]?.units ?? [] where
                    unit.kind == "function" && unit.helperCallableName == method && unit.scope == components[1] &&
                    unit.region.intersects(region) {
                    regions.insert(unit.region)
                }
            }
        }
        guard regions.count == 1, let region = regions.first else { return nil }
        return .init(path: region.path, line: region.startLine)
    }
}
