// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

public struct ImpactAnalysis {
    public var packagePath: URL
    public var progress: (String) -> Void

    public init(packagePath: URL, progress: @escaping (String) -> Void = { _ in }) {
        self.packagePath = packagePath.standardizedFileURL.resolvingSymlinksInPath()
        self.progress = progress
    }

    public func select(base: String, head: String? = nil, mergeBase: Bool = false, fullSuite: Bool = false) throws -> ImpactReport {
        let root = try GitChanges.repositoryRoot(at: packagePath)
        let comparison = try RevisionComparison(base: base, head: head, mergeBase: mergeBase, root: root)
        let changes = try GitChanges.readComparison(base: comparison.base, head: comparison.head, at: root)
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("swift-test-impact-base-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let relative = String(packagePath.path.dropFirst(root.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var headRoot = root
        var headPackage = packagePath
        if let head = comparison.head {
            headRoot = temporary.appendingPathComponent("head")
            try GitChanges.export(base: head, from: root, into: headRoot)
            headPackage = relative.isEmpty ? headRoot : headRoot.appendingPathComponent(relative)
        }
        let current = try PackageAnalyzer(packagePath: headPackage, sourceRoot: headRoot, progress: progress).analyze()
        var previous: DependencyGraph?
        var fallback: [String] = []
        if changes.isEmpty { previous = current }
        else {
            do {
                let baseRoot = temporary.appendingPathComponent("base")
                progress("Analyzing base revision \(comparison.base.prefix(12))…")
                try GitChanges.export(base: comparison.base, from: root, into: baseRoot)
                let basePackage = relative.isEmpty ? baseRoot : baseRoot.appendingPathComponent(relative)
                previous = try PackageAnalyzer(packagePath: basePackage, sourceRoot: baseRoot, progress: progress).analyze()
            } catch { fallback.append("Unable to analyze base revision: \(error)") }
        }
        var report = StaticSelector.select(current: current, previous: previous, changes: changes, baseRevision: comparison.base, additionalFallbacks: fallback)
        report.headRevision = comparison.head ?? "WORKTREE"
        report.comparisonMode = comparison.mode
        if fullSuite {
            report.selectedTests = current.tests.keys.sorted()
            report.explanations += report.selectedTests.map { TestExplanation(test: $0, reason: "Full suite explicitly requested", revision: "head", path: [], kind: "fullSuite") }
        }
        return report
    }

    /// Executes only when explicitly requested by a caller. An empty selection
    /// returns immediately: omitting --filter would accidentally run all tests.
    public func run(_ report: ImpactReport) throws -> Int32 {
        guard let filter = report.filter else {
            progress("No selected tests; no test command was executed.")
            return 0
        }
        progress("Running \(report.selectedTests.count) selected tests…")
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("swift-test-impact-run-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        var executionPackage = packagePath
        if let head = report.headRevision, head != "WORKTREE" {
            let root = try GitChanges.repositoryRoot(at: packagePath)
            try GitChanges.export(base: head, from: root, into: temporary)
            let relative = String(packagePath.path.dropFirst(root.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            executionPackage = relative.isEmpty ? temporary : temporary.appendingPathComponent(relative)
        }
        let result = try CommandRunner.run("swift", [
            "test", "--package-path", executionPackage.path,
            "--scratch-path", executionPackage.appendingPathComponent(".build/test-impact").path,
            "--filter", filter
        ], at: executionPackage, allowFailure: true)
        progress(String(decoding: result.stdout + result.stderr, as: UTF8.self))
        return result.status
    }
}
