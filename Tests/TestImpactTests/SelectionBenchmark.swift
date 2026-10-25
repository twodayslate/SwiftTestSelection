// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import Testing
@testable import TestImpact

/// Set IMPACT_SELECTION_BENCHMARK to a saved consumer graph; run in release.
/// Optional IMPACT_SELECTION_OUTPUT receives per-scenario measurements. Each
/// implementation runs three times against identical inputs, with full parity.
@Test func selectionBenchmark() throws {
    let env = ProcessInfo.processInfo.environment
    guard let path = env["IMPACT_SELECTION_BENCHMARK"] else { return }
    let before = try GraphArchive.decode(Data(contentsOf: URL(fileURLWithPath: path)))
    var records: [[String: Any]] = []
    let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
    for suffix in ["SharingPeopleUITests.swift", "SharingPeopleUITestView.swift", "NoteCommentsTests.swift"] {
        let key = try #require(before.sources.keys.sorted().first { $0.hasSuffix(suffix) })
        let source = before.sources[key]!
        let i = try #require(source.units.firstIndex { $0.kind == "function" })
        var after = before
        after.sources[key]!.units[i].fingerprint += "benchmark-edit"
        let changes = [FileChange(path: source.units[i].region.path)]
        for run in 1...3 {
            let indexedOnly = env["IMPACT_SELECTION_ENGINE"] == "indexed"
            let oldStart = Date()
            let old = indexedOnly ? nil : ReferenceXcodeFineSelector.select(current: after, previous: before, changes: changes, baseRevision: "benchmark")
            let oldSeconds = Date().timeIntervalSince(oldStart)
            let newStart = Date()
            let new = XcodeFineSelector.select(current: after, previous: before, changes: changes, baseRevision: "benchmark")
            let newSeconds = Date().timeIntervalSince(newStart)
            if let old { #expect(try encoder.encode(old) == encoder.encode(new)) }
            let record: [String: Any] = ["scenario": suffix, "run": run, "referenceSeconds": oldSeconds,
                "indexedSeconds": newSeconds, "selected": new.selectedTests.count]
            records.append(record)
            print("SELECTION \(record)")
            if let output = env["IMPACT_SELECTION_OUTPUT"] {
                try JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: output))
            }
        }
    }
}

@Test func compactArchiveBenchmark() throws {
    let env = ProcessInfo.processInfo.environment
    guard let path = env["IMPACT_ARCHIVE_BENCHMARK"] else { return }
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    let decodeStart = Date()
    let graph = try GraphArchive.decode(data)
    let jsonDecode = Date().timeIntervalSince(decodeStart)
    let encodeStart = Date()
    let binary = try GraphArchive.encode(graph)
    let binaryEncode = Date().timeIntervalSince(encodeStart)
    let loadStart = Date()
    let loaded = try GraphArchive.decode(binary)
    let binaryDecode = Date().timeIntervalSince(loadStart)
    #expect(loaded.dependencies?.functions.count == graph.dependencies?.functions.count)
    #expect(loaded.tests == graph.tests)
    #expect(loaded.dependencies?.tests == graph.dependencies?.tests)
    let result: [String: Any] = ["inputJSONBytes": data.count, "binaryBytes": binary.count,
        "jsonDecodeSeconds": jsonDecode, "binaryEncodeSeconds": binaryEncode, "binaryDecodeSeconds": binaryDecode,
        "memory": AnalysisMeasurement().report("archive benchmark process")]
    print("ARCHIVE \(result)")
    if let output = env["IMPACT_ARCHIVE_OUTPUT"] {
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: output))
    }
}
