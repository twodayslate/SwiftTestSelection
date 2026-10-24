// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import Testing
@testable import TestImpact

@Test func moduleCacheInvalidatesRetargetedSwiftSymlinksAndMatchesFreshRegions() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("review-symlink-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("source"), derived = root.appendingPathComponent("derived")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: derived, withIntermediateDirectories: true)
    for name in ["A.swift", "B.swift"] { try Data("public func value() -> Int { 1 }\n".utf8).write(to: source.appendingPathComponent(name)) }
    let alias = source.appendingPathComponent("Input.swift")
    try FileManager.default.createSymbolicLink(atPath: alias.path, withDestinationPath: "A.swift")
    let list = derived.appendingPathComponent("Example.SwiftFileList")
    try Data(alias.path.utf8).write(to: list)
    let compiler = try CommandRunner.run("xcrun", ["--find", "swiftc"], at: root).text.trimmingCharacters(in: .whitespacesAndNewlines)
    let map: [[String: Any]] = [["moduleName": "Swift", "modulePath": "/unused/Swift.swiftmodule", "isFramework": false]]
    try JSONSerialization.data(withJSONObject: map).write(to: derived.appendingPathComponent("Example-dependencies-1.json"))
    let log = "builtin-SwiftDriver -- \(compiler) -module-name Example -explicit-module-build -Onone -g @\(list.path)"
    let cache = try XcodeGraphCache(.init(directory: root.appendingPathComponent("cache"), context: "review"), progress: { _ in })
    func identity() throws -> [String: String] {
        let fragments = XcodeModuleCache(cache: cache, identity: ["revision": UUID().uuidString], source: source, derived: derived, workspace: root)
        fragments.prepare(log: log)
        return try #require(fragments.identity(for: "Example"))
    }
    var hits = 0
    func extract(cached: Bool) -> DependencyGraph {
        let fragments = XcodeModuleCache(cache: cache, identity: [:], source: source, derived: derived, workspace: root)
        let graph = XcodeCompilerGraph.extract(log: log, sourceRoot: source, directory: source, derived: derived,
            progress: { if $0.contains(": hit: compatible") { hits += 1 } }, moduleCache: cached ? fragments : nil)
        #expect(graph.diagnostics.isEmpty)
        return graph
    }
    let first = try identity()
    let old = extract(cached: true)
    _ = extract(cached: true)
    #expect(hits == 1)
    try FileManager.default.removeItem(at: alias)
    try FileManager.default.createSymbolicLink(atPath: alias.path, withDestinationPath: "B.swift")
    let second = try identity()
    let new = extract(cached: true)
    #expect(hits == 1) // Retargeted source must not load the A.swift fragment.
    let fresh = extract(cached: false)
    #expect(try XcodeGraphCache.canonicalInventory(JSONEncoder().encode(new)) == XcodeGraphCache.canonicalInventory(JSONEncoder().encode(fresh)))
    _ = extract(cached: true)
    #expect(hits == 2)
    let a = Set(old.functions.values.flatMap(\.regions).map(\.path)), b = Set(new.functions.values.flatMap(\.regions).map(\.path))
    #expect(first != second)
    #expect(a == ["A.swift"])
    #expect(b == ["B.swift"])
}
