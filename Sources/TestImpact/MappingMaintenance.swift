// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
import Foundation

/// Read-only mapping maintenance over reusable captured graphs. Nothing here
/// infers behavioral completeness, executes tests, or changes runtime policies.
public struct MappingMaintenance: Codable, Sendable {
    public struct Rule: Codable, Sendable {
        public var name: String
        public var sources: [String]
        public var symbols: [String]
        public var fixtures: [String]
        public var dependsOn: [String]
        public var condition: UIFeatureMappings.Condition?
        public var tests: [String]
        public var compiledRoots: [String]
        public var matchedSymbols: [String]
        public var unresolvedEntries: [String]
        public var unmatchedSelectors: [String]
    }
    public struct Audit: Codable, Sendable {
        public var valid: Bool
        public var errors: [String]
        public var suggestions: [String]
        public var rules: [Rule]
        public var inventory: [String]
        public var unmappedUITests: [String]
        public var graphDiagnostics: [String]
    }
    public struct Preview: Codable, Sendable {
        public var before: ImpactReport
        public var after: ImpactReport
        public var addedTests: [String]
        public var removedTests: [String]
        public var addedSuites: [String]
        public var removedSuites: [String]
        public var newFallbacks: [String]
    }
    public var current: Audit
    public var proposed: Audit?
    public var preview: Preview?
    public var previewLimitation: String

    public static func inspect(_ snapshot: XcodeTestGraph) -> Audit {
        var errors: [String] = []
        do { try snapshot.validateMappingSymbols(mappingFile: "<captured>", revision: "head", buildContext: [:]) }
        catch { errors.append(String(describing: error)) }
        let inline = InlineUIMappings.resolve(snapshot)
        let combined = inline.applying(to: snapshot)
        let graph = snapshot.dependencies ?? DependencyGraph()
        var rules: [Rule] = [], suggestions: [String] = []
        let uiTests = Set(snapshot.tests.filter { test in
            snapshot.targets.contains { $0.isUITest && test.hasPrefix($0.name + "/") }
        })
        var mapped = Set<String>()
        if let mappings = combined.mappings {
            do {
                try mappings.validate()
                let index = MappingIndex(mappings, snapshot: combined, graph: graph, index: DependencyIndex(graph))
                for feature in mappings.features.sorted(by: { $0.name < $1.name }) {
                    let tests = index.tests[feature.name] ?? []
                    mapped.formUnion(tests)
                    let unresolved = (index.unresolvedEntries[feature.name] ?? []).sorted()
                    let unmatched = (index.unmatched[feature.name] ?? []).sorted()
                    errors += unresolved.map { feature.name + ": unresolved " + $0 }
                    errors += unmatched.map { feature.name + ": unmatched test selector " + $0 }
                    rules.append(.init(name: feature.name, sources: feature.sources ?? [], symbols: feature.symbols ?? [],
                        fixtures: feature.fixtures ?? [], dependsOn: feature.dependsOn ?? [], condition: feature.when,
                        tests: tests.sorted(), compiledRoots: (index.roots[feature.name] ?? []).sorted(),
                        matchedSymbols: (index.roots[feature.name] ?? []).compactMap { id in graph.functions[id].map { $0.module + "." + $0.name } }.sorted(),
                        unresolvedEntries: unresolved, unmatchedSelectors: unmatched))
                    if !uiTests.isEmpty && tests.intersection(uiTests).count * 4 >= uiTests.count * 3 {
                        suggestions.append(feature.name + " matches at least 75% of UI methods; review whether shared/startup coverage is intentional.")
                    }
                }
                for (offset, rule) in rules.enumerated() {
                    for other in rules.dropFirst(offset + 1) where !Set(rule.tests).isDisjoint(with: other.tests) {
                        suggestions.append(rule.name + " overlaps " + other.name + "; shared dependencies may be intentional.")
                    }
                }
            } catch { errors.append(String(describing: error)) }
        }
        let unmapped = uiTests.subtracting(mapped).sorted()
        if !unmapped.isEmpty { suggestions.append("Review \(unmapped.count) unmapped UI methods; full identifiers are in unmappedUITests.") }
        if snapshot.dependencies == nil { errors.append("Compiled graph unavailable; recapture this build configuration.") }
        let diagnostics = (snapshot.diagnostics + graph.diagnostics + graph.testDiagnostics.values.flatMap { $0 }
            + snapshot.sources.values.flatMap(\.diagnostics)).sorted()
        return Audit(valid: errors.isEmpty && diagnostics.isEmpty, errors: Array(Set(errors)).sorted(), suggestions: suggestions,
                     rules: rules, inventory: snapshot.tests.sorted(), unmappedUITests: unmapped, graphDiagnostics: diagnostics)
    }

    public static func review(current: XcodeTestGraph, proposed: UIFeatureMappings? = nil,
                              previous: XcodeTestGraph? = nil, changes: [FileChange]? = nil) -> Self {
        var result = Self(current: inspect(current), proposed: nil, preview: nil,
                          previewLimitation: "No representative comparison supplied. Audit results are not a behavioral completeness proof.")
        var candidate = current
        if let proposed {
            candidate.mappings = proposed
            candidate.mappingLoadError = nil
            candidate.diagnostics.removeAll { $0.hasPrefix("Invalid UI mappings: ") }
            result.proposed = inspect(candidate)
        }
        if let previous, let changes {
            // Evaluate each policy at both revisions; otherwise a policy-only
            // change would obscure the widening/narrowing of the supplied diff.
            var oldBase = previous, newBase = previous
            oldBase.mappings = current.mappings
            oldBase.mappingLoadError = current.mappingLoadError
            oldBase.diagnostics.removeAll { $0.hasPrefix("Invalid UI mappings: ") }
            oldBase.diagnostics += current.diagnostics.filter { $0.hasPrefix("Invalid UI mappings: ") }
            newBase = oldBase
            if let proposed {
                newBase.mappings = proposed
                newBase.mappingLoadError = nil
                newBase.diagnostics.removeAll { $0.hasPrefix("Invalid UI mappings: ") }
            }
            let before = XcodeFineSelector.select(current: current, previous: oldBase, changes: changes, baseRevision: "preview-base")
            let after = XcodeFineSelector.select(current: candidate, previous: newBase, changes: changes, baseRevision: "preview-base")
            let old = Set(before.selectedTests), new = Set(after.selectedTests)
            func suites(_ tests: Set<String>) -> Set<String> { Set(tests.map { $0.split(separator: "/").prefix(2).joined(separator: "/") }) }
            func fallbacks(_ report: ImpactReport) -> Set<String> {
                Set(report.diagnostics.map { $0.code + ": " + $0.message }).union(report.fullRunReasons)
            }
            result.preview = .init(before: before, after: after, addedTests: new.subtracting(old).sorted(), removedTests: old.subtracting(new).sorted(),
                addedSuites: suites(new).subtracting(suites(old)).sorted(), removedSuites: suites(old).subtracting(suites(new)).sorted(),
                newFallbacks: fallbacks(after).subtracting(fallbacks(before)).sorted())
            result.previewLimitation = "Evaluated only the supplied comparison using the same compiled graphs. Selection paths, condition decisions, and fallbacks are included; this is not proof of test behavior or mapping completeness."
        }
        return result
    }
}
