// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import Testing
@testable import TestImpact

/// Opt-in real-project source replay. This does not build or execute the edited
/// app: separately generated base/head CLI reports provide that evidence.
@Test func runtimeBoundarySourceReplay() throws {
    guard let path = ProcessInfo.processInfo.environment["IMPACT_BOUNDARY_REPLAY"] else { return }
    let config = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    func url(_ key: String) throws -> URL { URL(fileURLWithPath: try #require(config[key])) }
    var base = try GraphArchive.decode(Data(contentsOf: url("graph")))
    let settings = try JSONDecoder().decode([XcodeBuildSettings].self, from: Data(contentsOf: url("settings")))
    base.runtimeInventory = XcodeRuntimeInventory.capture(log: try String(contentsOf: url("log"), encoding: .utf8), settings: settings)
    #expect(base.runtimeInventory?.requiredModules(for: "ChainOfCustodyTests") == ["ChainOfCustodyTests", "ChainOfCustodyCore"])
    base.mappings?.testRuntimeBoundaries = nil
    let file = "ChainOfCustody/Features/Notes/NoteListSort.swift"
    let source = try String(contentsOf: url("root").appendingPathComponent(file), encoding: .utf8)
    #expect(source.contains("\"A to Z\""))
    let changed = source.replacingOccurrences(of: "\"A to Z\"", with: "\"Alphabetical\"")
    var head = base
    if let graph = config["headGraph"] {
        head = try GraphArchive.decode(Data(contentsOf: URL(fileURLWithPath: graph)))
        head.mappings?.testRuntimeBoundaries = nil
    } else {
        head.sources["ChainOfCustody:" + file] = SwiftSourceSnapshot.parse(changed, path: file, module: "ChainOfCustody")
    }
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
    let output = try url("output")
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    func write(_ report: ImpactReport, _ name: String) throws {
        try encoder.encode(report).write(to: output.appendingPathComponent(name + ".json"))
        print("\(name): \(report.selectedTests.count) selected; boundary decisions \(report.runtimeBoundaryDecisions?.count ?? 0)")
    }
    let baseline = XcodeFineSelector.select(current: head, previous: base, changes: [.init(path: file)], baseRevision: "source-replay")
    try write(baseline, "without-boundary")
    let contract = TestRuntimeBoundary(target: "ChainOfCustodyTests", modules: ["ChainOfCustodyTests", "ChainOfCustodyCore"],
        rationale: "Hostless core tests do not load or communicate with application code; requires full-run validation.")
    base.mappings!.testRuntimeBoundaries = [contract]
    head.mappings!.testRuntimeBoundaries = [contract]
    let narrowed = XcodeFineSelector.select(current: head, previous: base, changes: [.init(path: file)], baseRevision: "source-replay")
    try write(narrowed, "with-boundary")
    if config["legacy"] == "true" {
        #expect(narrowed.diagnostics.contains { $0.code == "invalid_runtime_boundary" })
        #expect(Set(baseline.selectedTests).isSubset(of: Set(narrowed.selectedTests)))
    } else {
        #expect(narrowed.selectedTests.count < baseline.selectedTests.count)
        #expect(!narrowed.diagnostics.contains { $0.code == "invalid_runtime_boundary" })
        #expect(narrowed.runtimeBoundaryDecisions?.count == 2)
    }
    let mixed = XcodeFineSelector.select(current: head, previous: base, changes: [.init(path: file), .init(path: "AGENTS.md")], baseRevision: "source-replay")
    #expect(mixed.selectedTests == narrowed.selectedTests)
    try write(mixed, "mixed-documentation")
    let empty = XcodeFineSelector.select(current: base, previous: base, changes: [], baseRevision: "source-replay")
    #expect(empty.selectedTests.isEmpty)
    try write(empty, "empty")
    var testOnly = base
    let testFile = "ChainOfCustodyUITests/PairingNotesUITests.swift"
    let key = "ChainOfCustodyUITests:" + testFile
    let method = "testSortsNotesAndHidesUtilitiesWhileSearching"
    let index = try #require(testOnly.sources[key]?.units.firstIndex { $0.kind == "function" && $0.key.contains(method) })
    testOnly.sources[key]!.units[index].fingerprint += "controlled-test-body-edit"
    let oneMethod = XcodeFineSelector.select(current: testOnly, previous: base, changes: [.init(path: testFile)], baseRevision: "source-replay")
    #expect(oneMethod.selectedTests == ["ChainOfCustodyUITests/PairingNotesSearchAndSortUITests/" + method + "()"])
    try write(oneMethod, "test-method")
}
