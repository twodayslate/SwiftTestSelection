// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// Additional selection queries over the same head compiler graph. Scopes do
/// not replace the full-review report or change its execution request.
public struct SelectionScopes: Codable, Sendable {
    public var version: Int
    public var scopes: [SelectionScope]
    public init(version: Int = 1, scopes: [SelectionScope]) { self.version = version; self.scopes = scopes }
    public func validate() throws {
        guard version == 1, Set(scopes.map(\.name)).count == scopes.count else { throw ImpactError("Invalid selection scopes version or duplicate names") }
        for scope in scopes {
            guard !scope.name.isEmpty, scope.name.allSatisfy({ $0.isLetter || $0.isNumber || "-_".contains($0) }),
                  Set(scope.paths).count == scope.paths.count, Set(scope.excludedTestEntries).count == scope.excludedTestEntries.count,
                  scope.paths.allSatisfy({ !$0.isEmpty && !$0.hasPrefix("/") && !$0.contains("\0") && !$0.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) }) else {
                throw ImpactError("Invalid selection scope: \(scope.name)")
            }
        }
    }
}
public struct SelectionScope: Codable, Sendable {
    public var name: String
    public var paths: [String]
    /// Independently executed test entries already covered by caller policy.
    /// Entries with compiled consumers outside this set remain change roots.
    public var excludedTestEntries: [String]
    public init(name: String, paths: [String], excludedTestEntries: [String] = []) {
        self.name = name; self.paths = paths; self.excludedTestEntries = excludedTestEntries
    }
}
public struct ScopedImpactReport: Codable, Sendable {
    public var scope: SelectionScope
    public var report: ImpactReport
}

extension XcodeHeadOnlySelector {
    static func scopedReports(current: XcodeTestGraph, requests: SelectionScopes, changes: [FileChange],
                              baseRevision: String, headRevision: String, root: URL, mappingPath: String,
                              documentation: Set<String>, buildEvidenceFailure: String?, retainedGraphPath: String? = nil,
                              sourceCache: XcodeBaseSourceCache? = nil, digestCache: HelperBindingDigestCache? = nil,
                              measurement: (XcodeAnalysisEvent) -> Void = { _ in }) throws -> [ScopedImpactReport] {
        try requests.validate()
        let digestCache = digestCache?.matching(current) ?? HelperBindingDigestCache(current: current)
        let sourceCache = try sourceCache ?? XcodeBaseSourceCache(root: root, base: baseRevision)
        try sourceCache.validate(root: root, base: baseRevision)
        let changedPaths = Set(changes.flatMap { [$0.path] + ($0.previousPath.map { [$0] } ?? []) })
        return try requests.scopes.map { scope in
            guard Set(scope.paths).isSubset(of: changedPaths), Set(scope.excludedTestEntries).isSubset(of: Set(current.tests)) else {
                throw ImpactError("Selection scope contains paths outside the review diff or unknown tests: \(scope.name)")
            }
            let paths = Set(scope.paths)
            let filtered = changes.filter { paths.contains($0.path) || ($0.previousPath.map(paths.contains) ?? false) }
            // Derive evidence independently, sharing only immutable reads/parses.
            let sourceStart = Date()
            let source = try XcodeHeadOnlySources.read(current: current, changes: filtered, base: baseRevision, root: root, mappingPath: mappingPath, cache: sourceCache)
            measurement(.init(phase: "scopeSourceSyntax", revision: baseRevision, seconds: Date().timeIntervalSince(sourceStart), detail: scope.name))
            let selectionStart = Date()
            var report = select(current: current, source: source, changes: filtered, baseRevision: baseRevision,
                                documentation: documentation, buildEvidenceFailure: buildEvidenceFailure,
                                excludedTestEntries: Set(scope.excludedTestEntries), digestCache: digestCache)
            measurement(.init(phase: "scopeSelection", revision: headRevision, seconds: Date().timeIntervalSince(selectionStart), detail: scope.name))
            for i in report.diagnostics.indices {
                report.diagnostics[i].fallback?.selectionScope = scope.name
            }
            report.headRevision = headRevision
            report.buildArtifactID = current.buildArtifact?.id
            report.buildArtifactPath = retainedGraphPath
            return ScopedImpactReport(scope: scope, report: report)
        }
    }

    static func independentEntryKeys(current: XcodeTestGraph, excluding entries: Set<String>) -> Set<String> {
        guard !entries.isEmpty, let graph = current.dependencies else { return [] }
        // Missing roots and incomplete lifecycle bindings hide possible callers.
        // Keep the change roots so normal selection reports that uncertainty;
        // absence of a path in a partial test inventory cannot prove isolation.
        guard current.tests.allSatisfy({ test in
            guard let roots = graph.tests[test], !roots.isEmpty,
                  graph.testDiagnostics[test]?.isEmpty ?? true else { return false }
            return roots.allSatisfy { graph.functions[$0] != nil }
        }) else { return [] }
        // Restrict expensive ownership/reachability checks to locations of the
        // requested entries, rather than scanning every test body in the graph.
        let regions = Dictionary(grouping: entries.flatMap { graph.tests[$0] ?? [] }
            .flatMap { graph.functions[$0]?.regions ?? [] }, by: \.path)
        let candidates = current.sources.values.flatMap(\.units).filter { unit in
            unit.kind == "function" && (regions[unit.region.path] ?? []).contains {
                $0.startLine >= unit.region.startLine && $0.startLine <= unit.region.endLine
            }
        }
        guard !candidates.isEmpty else { return [] }
        let index = DependencyIndex(graph)
        return Set(candidates.filter {
            isIndependentEntry($0, current: current, graph: graph, index: index, entries: entries)
        }.map(\.key))
    }

    private static func isIndependentEntry(_ unit: SourceUnit, current: XcodeTestGraph, graph: DependencyGraph,
                                          index: DependencyIndex, entries: Set<String>) -> Bool {
        guard XcodeFineSelector.isTestEntry(unit, in: current) else { return false }
        let module = String(unit.key.prefix { $0 != ":" })
        let ids = Set((index.byFile[unit.region.path] ?? []).filter { id in
            let node = graph.functions[id]!
            return node.module == module && node.regions.contains { $0.path == unit.region.path && $0.startLine >= unit.region.startLine && $0.startLine <= unit.region.endLine }
        })
        let paths = index.paths(to: ids)
        let consumers = Set(current.tests.filter { paths.path(from: graph.tests[$0] ?? []) != nil })
        return !consumers.isEmpty && consumers.isSubset(of: entries)
    }
}
