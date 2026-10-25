// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Testing
@testable import TestImpact

@Test func compiledCallerLocationChangeCannotHideAFailingTest() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("caller-locations-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let platform = try CommandRunner.run("xcrun", ["--sdk", "macosx", "--show-sdk-platform-path"], at: root).text.trimmingCharacters(in: .whitespacesAndNewlines)
    let frameworks = platform + "/Developer/Library/Frameworks"
    let test = "Tests/LocationTests/testLine()"
    let source = """
    import XCTest
    class LocationTests: XCTestCase {
        @objc func testLine() { XCTAssertEqual(currentLine(), 3) }
    }
    let suite = XCTestSuite(forTestCaseClass: LocationTests.self)
    suite.run()
    print("executed=\\(suite.testRun!.executionCount) failures=\\(suite.testRun!.failureCount)")
    """
    var graphs: [XcodeTestGraph] = []
    for revision in ["base", "head"] {
        let folder = root.appendingPathComponent(revision)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let sources = ["Helper.swift": "func currentLine(line: Int = #line) -> Int { line }",
                       "main.swift": revision == "base" ? source : source.replacingOccurrences(of: "    @objc", with: "// comment\n    @objc")]
        for (path, text) in sources { try text.write(to: folder.appendingPathComponent(path), atomically: true, encoding: .utf8) }
        let args = ["swiftc", "-module-name", "Tests", "-g", "-Onone", "-F", frameworks, "-I", platform + "/Developer/usr/lib"] + sources.keys.sorted().map { folder.appendingPathComponent($0).path }
        let sil = folder.appendingPathComponent("Tests.sil")
        _ = try CommandRunner.run("xcrun", args + ["-emit-sil", "-whole-module-optimization", "-o", sil.path], at: folder)
        let executable = folder.appendingPathComponent("Tests")
        _ = try CommandRunner.run("xcrun", args + ["-L", platform + "/Developer/usr/lib", "-Xlinker", "-rpath", "-Xlinker", frameworks,
            "-Xlinker", "-rpath", "-Xlinker", platform + "/Developer/Library/PrivateFrameworks", "-Xlinker", "-rpath", "-Xlinker", platform + "/Developer/usr/lib", "-o", executable.path], at: folder)
        let run = try CommandRunner.run(executable.path, [], at: folder)
        #expect(run.text.contains("executed=1 failures=\(revision == "base" ? 0 : 1)"), "\(run.text)")
        let parsed = try SILParser.parse(file: sil, module: "Tests", sourceRoot: folder)
        let entry = try #require(parsed.functions.values.first { $0.name == "LocationTests.testLine()" })
        var graph = XcodeTestGraph(targets: [.init(name: "Tests", productType: "com.apple.product-type.bundle.unit-test", sourceFiles: Set(sources.keys))], tests: [test])
        graph.modules = ["Tests": "Tests"]
        for (path, text) in sources { graph.sources[path] = SwiftSourceSnapshot.parse(text, path: path, module: "Tests") }
        graph.dependencies = DependencyGraph(functions: parsed.functions, tests: [test: [entry.id]])
        graphs.append(graph)
    }
    func select(_ before: XcodeTestGraph, _ after: XcodeTestGraph) -> ImpactReport {
        XcodeFineSelector.select(current: after, previous: before, changes: [.init(path: "main.swift")], baseRevision: "base")
    }
    for reverse in [false, true] {
        let before = graphs[reverse ? 1 : 0], after = graphs[reverse ? 0 : 1]
        let report = select(before, try GraphArchive.decode(GraphArchive.encode(after)))
        #expect(report.selectedTests == [test])
        #expect(report.diagnostics.isEmpty)
        #expect(report.ignoredChanges.isEmpty)
    }
    var diagnostic = graphs
    for i in diagnostic.indices {
        diagnostic[i].mappings = UIFeatureMappings(features: [])
        diagnostic[i].mappings!.sourceLocationPolicy = .diagnostic
    }
    #expect(select(diagnostic[0], diagnostic[1]).selectedTests.isEmpty)
    #expect(select(graphs[0], diagnostic[1]).selectedTests == [test])
    // Saved graphs without caller positions cannot prove that a shifted call is safe.
    var legacy = graphs[0]
    for path in legacy.sources.keys {
        for i in legacy.sources[path]!.units.indices {
            legacy.sources[path]!.units[i].callerLocations = nil
            legacy.sources[path]!.units[i].locationDefaultKinds = nil
        }
    }
    #expect(select(legacy, graphs[1]).selectedTests == [test])
    let legacyReport = select(legacy, legacy)
    #expect(legacyReport.selectedTests == [test])
    #expect(legacyReport.diagnostics.contains { $0.code == "incomplete_caller_locations" })
    var unbound = graphs[1]
    unbound.dependencies!.functions = unbound.dependencies!.functions.filter { !$0.value.name.hasPrefix("currentLine(") }
    #expect(select(graphs[0], unbound).selectedTests.contains(test))
    var unlocated = graphs
    for i in unlocated.indices {
        for id in unlocated[i].dependencies!.tests[test]! { unlocated[i].dependencies!.functions[id]!.regions = [] }
    }
    #expect(select(unlocated[0], unlocated[1]).selectedTests.contains(test))
}
