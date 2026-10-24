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

    public func select(base: String) throws -> ImpactReport {
        let root = try GitChanges.repositoryRoot(at: packagePath)
        let revision = try GitChanges.revision(base, at: root)
        let changes = try GitChanges.read(base: revision, at: root)
        let current = try PackageAnalyzer(packagePath: packagePath, sourceRoot: root, progress: progress).analyze()
        if changes.isEmpty {
            return StaticSelector.select(current: current, previous: current, changes: [], baseRevision: revision)
        }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("swift-test-impact-base-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        var previous: DependencyGraph?
        var fallback: [String] = []
        do {
            progress("Exporting base revision \(revision.prefix(12)) into a temporary directory…")
            try GitChanges.export(base: revision, from: root, into: temporary)
            let relative = String(packagePath.path.dropFirst(root.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let basePackage = relative.isEmpty ? temporary : temporary.appendingPathComponent(relative)
            previous = try PackageAnalyzer(packagePath: basePackage, sourceRoot: temporary, progress: progress).analyze()
        } catch {
            fallback.append("Unable to analyze the base revision; selecting all tests. \(error)")
        }
        return StaticSelector.select(current: current, previous: previous, changes: changes, baseRevision: revision, additionalFallbacks: fallback)
    }

    /// Executes only when explicitly requested by a caller. An empty selection
    /// returns immediately: omitting --filter would accidentally run all tests.
    public func run(_ report: ImpactReport) throws -> Int32 {
        guard let filter = report.filter else {
            progress("No selected tests; no test command was executed.")
            return 0
        }
        progress("Running \(report.selectedTests.count) selected tests…")
        let result = try CommandRunner.run("swift", [
            "test", "--package-path", packagePath.path,
            "--scratch-path", packagePath.appendingPathComponent(".build/test-impact").path,
            "--filter", filter
        ], at: packagePath, allowFailure: true)
        progress(String(decoding: result.stdout + result.stderr, as: UTF8.self))
        return result.status
    }
}
