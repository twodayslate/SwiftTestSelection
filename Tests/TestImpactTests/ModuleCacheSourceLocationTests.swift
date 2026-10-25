// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import Testing
@testable import TestImpact

@Test func moduleCacheReplaysPresumedLocationsAfterRelocation() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("module-cache-presumed-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let first = root.appendingPathComponent("first")
    let second = root.appendingPathComponent("second")
    let compiler = try CommandRunner.run("xcrun", ["--find", "swiftc"], at: root.deletingLastPathComponent()).text.trimmingCharacters(in: .whitespacesAndNewlines)
    let text = "#sourceLocation(file: \"\(first.appendingPathComponent("source/Original.swift").path)\", line: 100)\npublic func value() -> Int { 1 }\n"
    var messages: [String] = []
    let cache = try XcodeGraphCache(.init(directory: root.appendingPathComponent("cache"), context: "test"), progress: { messages.append($0) })
    var hits = 0
    for folder in [first, second] {
        let source = folder.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let derived = folder.appendingPathComponent("derived")
        try FileManager.default.createDirectory(at: derived, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: source.appendingPathComponent("Input.swift"))
        let list = derived.appendingPathComponent("Example.SwiftFileList")
        try Data(source.appendingPathComponent("Input.swift").path.utf8).write(to: list)
        try JSONSerialization.data(withJSONObject: [["moduleName": "Swift", "modulePath": "/unused/Swift.swiftmodule", "isFramework": false]]).write(to: derived.appendingPathComponent("Example-dependencies-1.json"))
        let log = "builtin-SwiftDriver -- \(compiler) -module-name Example -explicit-module-build -Onone -g @\(list.path)"
        let fragments = XcodeModuleCache(cache: cache, identity: [:], source: source, derived: derived, workspace: folder)
        fragments.prepare(log: log)
        #expect(fragments.identity(for: "Example") == nil)
        let cached = XcodeCompilerGraph.extract(log: log, sourceRoot: source, directory: source, derived: derived,
            progress: { if $0.contains(": hit: compatible") { hits += 1 } }, moduleCache: fragments)
        #expect(cached.diagnostics.isEmpty)
        let paths = Set(cached.functions.values.flatMap(\.regions).map(\.path))
        #expect(paths == (folder == first ? ["Original.swift"] : []))
        let fresh = XcodeCompilerGraph.extract(log: log, sourceRoot: source, directory: source, derived: derived, progress: { _ in })
        #expect(fresh.diagnostics.isEmpty)
        #expect(try XcodeGraphCache.canonicalInventory(JSONEncoder().encode(cached)) == XcodeGraphCache.canonicalInventory(JSONEncoder().encode(fresh)))
    }
    #expect(hits == 0)
    #expect(messages.contains { $0.contains("bypass: #sourceLocation") })
}
