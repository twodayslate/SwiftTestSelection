// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

public struct TestExplanation: Codable, Sendable {
    public var test: String
    public var reason: String
    public var revision: String
    public var path: [String]
    public var kind: String = "dependency"
}

public struct ImpactReport: Codable, Sendable {
    public var schemaVersion = 1
    public var baseRevision: String
    public var totalTests: Int
    public var selectedTests: [String]
    public var explanations: [TestExplanation]
    public var fullRunReasons: [String]
    public var changedFiles: [String]
    public var unreferencedChanges: [String]
    public var limitations: [String]
    public var headRevision: String?
    public var comparisonMode: String?
    public var onlyTestingArguments: [String]?
    public var diagnostics: [SelectionDiagnostic] = []
    public var ignoredChanges: [String] = []
    public var uiMappingCoverage: UIMappingCoverage?

    public var filter: String? {
        guard !selectedTests.isEmpty else { return nil }
        // Swift Testing appends a source-location component to runtime IDs;
        // swift test list omits it. XCTest IDs have no such suffix.
        return "^(?:" + selectedTests.map {
            NSRegularExpression.escapedPattern(for: $0) + ($0.hasSuffix(")") ? "(?:/.*)?" : "")
        }.joined(separator: "|") + ")$"
    }
}

public enum StaticSelector {
    public static func select(
        current: DependencyGraph, previous: DependencyGraph?, changes: [FileChange],
        baseRevision: String, additionalFallbacks: [String] = []
    ) -> ImpactReport {
        var explanations: [TestExplanation] = []
        var fallback = additionalFallbacks
        var selected = Set<String>()
        var unreferenced = Set<String>()
        let allTests = Set(current.tests.keys)

        if !changes.isEmpty {
            fallback += current.diagnostics
            fallback += previous?.diagnostics ?? ["The base revision's dependency graph is unavailable."]
        }
        for change in changes where !change.path.hasSuffix(".swift") || change.path == "Package.swift" || change.requiresFallback {
            fallback.append("Change cannot be narrowed to Swift functions: \(change.path)")
        }

        for (label, optionalGraph, regions) in [
            ("base", previous, changes.flatMap(\.oldRegions)),
            ("current", Optional(current), changes.flatMap(\.newRegions))
        ] {
            guard let graph = optionalGraph else { continue }
            var affected = Set<String>()
            for region in regions {
                let matches = graph.functions.values.filter { $0.regions.contains { $0.intersects(region) } }
                affected.formUnion(matches.map(\.id))
                let ranges = matches.flatMap(\.regions).filter { $0.path == region.path }
                    .sorted { $0.startLine < $1.startLine }
                var uncovered = region.startLine
                for range in ranges where range.startLine <= region.endLine {
                    if range.startLine > uncovered { break }
                    uncovered = max(uncovered, range.endLine + 1)
                }
                if uncovered <= region.endLine {
                    fallback.append("\(label) change outside mapped function regions: \(region.path):\(uncovered)")
                }
            }
            var reached = Set<String>()
            for test in allTests.sorted() {
                let roots = graph.tests[test] ?? []
                if let path = graph.dependencyPath(from: roots, to: affected) {
                    selected.insert(test)
                    reached.insert(path.last!)
                    explanations.append(TestExplanation(
                        test: test, reason: "Depends on a changed function", revision: label,
                        path: path.map { graph.functions[$0].map { $0.module + "." + $0.name } ?? $0 }
                    ))
                }
            }
            // Check each affected function separately so gaps aren't an artifact
            // of the shortest-path explanation choosing a different destination.
            for id in affected.subtracting(reached) {
                if !graph.tests.values.contains(where: { graph.dependencyPath(from: $0, to: [id]) != nil }) {
                    let node = graph.functions[id]!
                    unreferenced.insert("\(label): \(node.module).\(node.name)")
                }
            }

            if !changes.isEmpty {
                let uncertain = Set(graph.functions.values.filter {
                    !$0.regions.isEmpty && !$0.uncertainties.isEmpty
                }.map(\.id))
                for test in allTests.sorted() {
                    if let path = graph.dependencyPath(from: graph.tests[test] ?? [], to: uncertain) {
                        selected.insert(test)
                        let node = graph.functions[path.last!]!
                        explanations.append(TestExplanation(
                            test: test, reason: "Conservative selection: " + node.uncertainties.sorted().joined(separator: "; "), revision: label,
                            path: path.map { graph.functions[$0].map { $0.module + "." + $0.name } ?? $0 }
                        ))
                    }
                }
            }
        }

        for test in allTests.sorted() {
            if previous?.tests[test] == nil && !changes.isEmpty {
                selected.insert(test)
                explanations.append(TestExplanation(test: test, reason: "New or previously undiscovered test", revision: "current", path: []))
            }
            if current.tests[test]?.isEmpty == true && !changes.isEmpty {
                selected.insert(test)
                explanations.append(TestExplanation(test: test, reason: "Test entry point could not be resolved", revision: "current", path: []))
            }
        }
        fallback = Array(Set(fallback)).sorted()
        if !fallback.isEmpty { selected = allTests }
        return ImpactReport(
            baseRevision: baseRevision, totalTests: allTests.count,
            selectedTests: selected.sorted(), explanations: explanations,
            fullRunReasons: fallback, changedFiles: changes.map(\.path).sorted(),
            unreferencedChanges: unreferenced.sorted(),
            limitations: [
                "Static reachability predicts possible execution; it is not a proof that skipped tests cannot fail.",
                "External frameworks, runtime registration, macros, and shared state can introduce dependencies absent from SIL references.",
                "The graph reflects a host-platform debug build; other platforms and build configurations need separate analysis."
            ]
        )
    }
}

public struct SelectionDiagnostic: Codable, Sendable {
    public var code: String
    public var message: String
    public var tests: [String]
}

public struct UIMappingCoverage: Codable, Sendable {
    public var mappingFilePresent: Bool
    public var mappedTests: [String]
    public var unmappedTests: [String]
    public var unresolvedBoundaries: [String] = []
    public var unmatchedSelectors: [String] = []
}
