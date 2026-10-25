// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Testing
@testable import TestImpact

@Test(.serialized, arguments: ["body-path-rename", "caller-id-rename", "body-id-declaration", "caller-path-declaration"])
func compiledFixtureFileChangesRemainSemantic(kind: String) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("fixture-locations-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let platform = try CommandRunner.run("xcrun", ["--sdk", "macosx", "--show-sdk-platform-path"], at: root).text.trimmingCharacters(in: .whitespacesAndNewlines)
    let frameworks = platform + "/Developer/Library/Frameworks"
    let test = "Tests/LocationTests/testFile()"
    let macro = kind.contains("-id-") ? "fileID" : "filePath"
    let caller = kind.hasPrefix("caller-")
    let declarationMove = kind.hasSuffix("-declaration")
    let expression = caller ? "fixtureFile()" : "#" + macro
    let declaration = """
    import XCTest
    extension LocationTests {
        @objc func testFile() { XCTAssertTrue(\(expression).hasSuffix("Original.swift")) }
    }
    """
    let empty = "import XCTest\nextension LocationTests {}"
    var graphs: [String: XcodeTestGraph] = [:]
    for revision in ["base", "comment", "head"] {
        let folder = root.appendingPathComponent(revision)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var sources = [
            "Support.swift": "import XCTest\nclass LocationTests: XCTestCase {}" + (caller ? "\n@_transparent func fixtureFile(file: StaticString = #\(macro), line: Int = #line, column: Int = #column) -> String { String(describing: file) }" : ""),
            "main.swift": """
            import XCTest
            let suite = XCTestSuite(forTestCaseClass: LocationTests.self)
            suite.run()
            print("executed=\\(suite.testRun!.executionCount) failures=\\(suite.testRun!.failureCount)")
            """
        ]
        let path = revision == "head" ? "Moved.swift" : "Original.swift"
        sources[path] = (revision == "comment" ? "/// docs\n" : "") + declaration
        if declarationMove { sources[revision == "head" ? "Original.swift" : "Moved.swift"] = empty }
        for (path, text) in sources { try text.write(to: folder.appendingPathComponent(path), atomically: true, encoding: .utf8) }
        let args = ["swiftc", "-module-name", "Tests", "-g", "-Onone", "-F", frameworks, "-I", platform + "/Developer/usr/lib"] + sources.keys.sorted().map { folder.appendingPathComponent($0).path }
        let sil = folder.appendingPathComponent("Tests.sil")
        _ = try CommandRunner.run("xcrun", args + ["-emit-sil", "-whole-module-optimization", "-o", sil.path], at: folder)
        let executable = folder.appendingPathComponent("Tests")
        _ = try CommandRunner.run("xcrun", args + ["-L", platform + "/Developer/usr/lib", "-Xlinker", "-rpath", "-Xlinker", frameworks,
            "-Xlinker", "-rpath", "-Xlinker", platform + "/Developer/Library/PrivateFrameworks", "-Xlinker", "-rpath", "-Xlinker", platform + "/Developer/usr/lib", "-o", executable.path], at: folder)
        let run = try CommandRunner.run(executable.path, [], at: folder)
        #expect(run.text.contains("executed=1 failures=\(revision == "head" ? 1 : 0)"), "\(run.text)")
        let parsed = try SILParser.parse(file: sil, module: "Tests", sourceRoot: folder)
        let entry = try #require(parsed.functions.values.first { $0.name == "LocationTests.testFile()" })
        var graph = XcodeTestGraph(targets: [.init(name: "Tests", productType: "com.apple.product-type.bundle.unit-test", sourceFiles: Set(sources.keys))], tests: [test])
        graph.modules = ["Tests": "Tests"]
        for (path, text) in sources { graph.sources[path] = SwiftSourceSnapshot.parse(text, path: path, module: "Tests") }
        graph.dependencies = DependencyGraph(functions: parsed.functions, tests: [test: [entry.id]])
        graph.mappings = UIFeatureMappings(features: [])
        graph.mappings!.sourceLocationPolicy = .diagnosticLineColumn
        graphs[revision] = try GraphArchive.decode(GraphArchive.encode(graph))
    }
    let base = try #require(graphs["base"]), head = try #require(graphs["head"]), documented = try #require(graphs["comment"])
    var move = FileChange(path: "Moved.swift")
    move.previousPath = "Original.swift"; move.isPureMove = true
    let changes = declarationMove ? [FileChange(path: "Original.swift"), FileChange(path: "Moved.swift")] : [move]
    for (before, after) in [(base, head), (head, base)] {
        let report = XcodeFineSelector.select(current: after, previous: before, changes: changes, baseRevision: "base")
        #expect(report.selectedTests == [test])
        #expect(report.diagnostics.isEmpty)
    }
    let comment = XcodeFineSelector.select(current: documented, previous: base, changes: [.init(path: "Original.swift")], baseRevision: "base")
    #expect(comment.selectedTests.isEmpty)
    #expect(comment.diagnostics.isEmpty)
    // The wider opt-out retains its documented behavior for compatibility.
    var diagnosticBase = base, diagnosticHead = head
    diagnosticBase.mappings!.sourceLocationPolicy = .diagnostic
    diagnosticHead.mappings!.sourceLocationPolicy = .diagnostic
    #expect(XcodeFineSelector.select(current: diagnosticHead, previous: diagnosticBase, changes: changes, baseRevision: "base").selectedTests.isEmpty)
}
