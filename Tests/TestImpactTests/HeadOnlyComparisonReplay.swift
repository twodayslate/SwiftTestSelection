// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import Testing
@testable import TestImpact

/// Optional diagnostic comparison with an independently compiled historical
/// graph. It is not a prerequisite of head-only selection or a correctness oracle.
/// JSON keys: root, base, head, baseGraph, headGraph, output.
@Test func headOnlyTwoGraphDiagnosticReplay() throws {
    guard let path = ProcessInfo.processInfo.environment["IMPACT_HEAD_ONLY_COMPARISON"] else { return }
    let config = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    func value(_ key: String) throws -> String { try #require(config[key]) }
    let base = try GraphArchive.decode(Data(contentsOf: URL(fileURLWithPath: value("baseGraph"))))
    var head = try GraphArchive.decode(Data(contentsOf: URL(fileURLWithPath: value("headGraph"))))
    let comparison = try RevisionComparison(base: value("base"), head: value("head"), mergeBase: true, root: URL(fileURLWithPath: value("root")))
    let changes = try GitChanges.readComparison(base: comparison.base, head: comparison.head, at: URL(fileURLWithPath: value("root")))
    var report = XcodeSelector.select(current: head, previous: base, changes: changes, baseRevision: comparison.base)
    report.headRevision = comparison.head
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(report).write(to: URL(fileURLWithPath: value("output")))
    if let originalReport = config["headOnlyReport"] {
        // Refresh native source metadata with the final analyzer, retaining the
        // exact independently captured head compiler graph and inventory.
        let paths = Set(changes.map(\.path))
        let root = URL(fileURLWithPath: try value("root"))
        for key in head.sources.keys.sorted() {
            guard let colon = key.firstIndex(of: ":") else { continue }
            let path = String(key[key.index(after: colon)...])
            guard paths.contains(path) else { continue }
            let text = try CommandRunner.run("git", ["show", comparison.head! + ":" + path], at: root).text
            head.sources[key] = SwiftSourceSnapshot.parse(text, path: path, module: String(key[..<colon]))
        }
        let workspace = URL(fileURLWithPath: try value("headGraph")).deletingLastPathComponent()
        let sourceRoot = workspace.appendingPathComponent("source"), derived = workspace.appendingPathComponent("DerivedData")
        let log = try String(contentsOf: workspace.appendingPathComponent("build.log"), encoding: .utf8)
        let evidence = try XcodeBuildEvidence(log: log, root: sourceRoot, derived: derived)
        let compiler = try CommandRunner.run("xcrun", ["--find", "swiftc"], at: root).text.trimmingCharacters(in: .whitespacesAndNewlines)
        let proof = evidence.documentationEvidence(files: try XcodeBuildEvidence.repositoryInputFiles(root: sourceRoot, derived: derived), compiler: compiler)
        let syntax = try XcodeHeadOnlySources.read(current: head, changes: changes, base: comparison.base, root: root, mappingPath: ".swift-test-selection.json")
        let focused = XcodeHeadOnlySelector.select(current: head, source: syntax, changes: changes, baseRevision: comparison.base,
            documentation: Set(proof.allowed), buildEvidenceFailure: proof.uncertainty.isEmpty ? nil : proof.uncertainty.joined(separator: "; "))
        let original = try JSONDecoder().decode(ImpactReport.self, from: Data(contentsOf: URL(fileURLWithPath: originalReport)))
        #expect(focused.selectedTests == original.selectedTests)
        #expect(focused.diagnostics.map(\.code) == original.diagnostics.map(\.code))
        try encoder.encode(focused).write(to: URL(fileURLWithPath: try value("output") + ".head-only.json"))
        print("Final head-only source/selector replay: \(focused.selectedTests.count)/\(focused.totalTests) selected")
    }
    print("Independent two-graph diagnostic: \(report.selectedTests.count)/\(report.totalTests) selected, \(report.diagnostics.count) diagnostics")
}
