// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
import Foundation
import Testing
@testable import TestImpact

/// Run with IMPACT_INLINE_BENCHMARK pointing at a JSON or compact captured graph.
/// Decode is excluded; output is reusable JSON and never claims test execution.
@Test(.enabled(if: ProcessInfo.processInfo.environment["IMPACT_INLINE_BENCHMARK"] != nil))
func inlineResolutionBenchmark() throws {
    let path = try #require(ProcessInfo.processInfo.environment["IMPACT_INLINE_BENCHMARK"])
    let graph = try GraphArchive.decode(Data(contentsOf: URL(fileURLWithPath: path)))
    var samples: [[String: Double]] = []
    let expected = InlineUIMappings.resolve(graph)
    for _ in 0..<7 {
        let start = Date()
        let result = InlineUIMappings.resolve(graph)
        let resolved = Date()
        try graph.validateMappingSymbols(mappingFile: "<benchmark>", revision: "head", buildContext: [:])
        let validated = Date()
        let audit = InlineMappingAudit.inspect(graph)
        #expect(result.features.map(\.name) == expected.features.map(\.name))
        #expect(result.diagnostics.map(\.message) == expected.diagnostics.map(\.message))
        #expect(audit.diagnostics.isEmpty)
        samples.append(["resolve": resolved.timeIntervalSince(start), "validate": validated.timeIntervalSince(resolved), "audit": Date().timeIntervalSince(validated)])
    }
    let data = try JSONSerialization.data(withJSONObject: ["graph": path, "tests": graph.tests.count, "rules": expected.features.count, "samples": samples], options: [.prettyPrinted, .sortedKeys])
    if let output = ProcessInfo.processInfo.environment["IMPACT_INLINE_BENCHMARK_OUTPUT"] { try data.write(to: URL(fileURLWithPath: output)) }
    print(String(decoding: data, as: UTF8.self))
}
