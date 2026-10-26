// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Testing
@testable import TestImpact

@Test func headOnlyOpaqueResultFallbackIncludesCallerWithFoldedDependency() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("head-only-opaque-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let platform = try CommandRunner.run("xcrun", ["--sdk", "macosx", "--show-sdk-platform-path"], at: root).text.trimmingCharacters(in: .whitespacesAndNewlines)
    let sdk = try CommandRunner.run("xcrun", ["--sdk", "macosx", "--show-sdk-path"], at: root).text.trimmingCharacters(in: .whitespacesAndNewlines)
    let frameworks = platform + "/Developer/Library/Frameworks"
    let model = """
    protocol Payload {}
    struct Small: Payload { var value: Int8 = 0 }
    struct Large: Payload { var a: Int64 = 0; var b: Int64 = 0 }
    func payload() -> (some Payload)? { Small() }
    @_transparent func resultSize<T>(of function: () -> T) -> Int { MemoryLayout<T>.size }
    """
    let tests = """
    import XCTest
    class LayoutTests: XCTestCase {
        @objc func testLayout() {
            if resultSize(of: payload) != 2 { XCTFail("layout changed") }
        }
    }
    """
    let main = """
    import XCTest
    let suite = XCTestSuite(forTestCaseClass: LayoutTests.self)
    suite.run()
    print("executed=\\(suite.testRun!.executionCount) failures=\\(suite.testRun!.failureCount)")
    """
    let test = "Tests/LayoutTests/testLayout()"
    for revision in ["base", "head"] {
        let folder = root.appendingPathComponent(revision)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let source = revision == "base" ? model : model.replacingOccurrences(of: "{ Small() }", with: "{ Large() }")
        let files = ["Model.swift": source, "Tests.swift": tests, "main.swift": main]
        for (path, text) in files { try text.write(to: folder.appendingPathComponent(path), atomically: true, encoding: .utf8) }
        let args = ["swiftc", "-module-name", "Fixture", "-sdk", sdk, "-g", "-Onone", "-F", frameworks, "-I", platform + "/Developer/usr/lib"] + files.keys.sorted().map { folder.appendingPathComponent($0).path }
        let executable = folder.appendingPathComponent("Tests")
        _ = try CommandRunner.run("xcrun", args + ["-L", platform + "/Developer/usr/lib", "-Xlinker", "-rpath", "-Xlinker", frameworks,
            "-Xlinker", "-rpath", "-Xlinker", platform + "/Developer/Library/PrivateFrameworks", "-Xlinker", "-rpath", "-Xlinker", platform + "/Developer/usr/lib", "-o", executable.path], at: folder)
        let run = try CommandRunner.run(executable.path, [], at: folder)
        #expect(run.text.contains("executed=1 failures=\(revision == "head" ? 1 : 0)"), "\(run.text)")
        guard revision == "head" else { continue }
        // Exercise the supplementary SIL from an executable compilation, as
        // used by head-only capture. No historical compiler graph is supplied.
        let sil = folder.appendingPathComponent("Fixture.sil")
        _ = try CommandRunner.run("xcrun", ["swiftc", "-frontend"] + args.dropFirst() + ["-c", "-sil-output-path", sil.path, "-o", folder.appendingPathComponent("Fixture.o").path], at: folder)
        let parsed = try SILParser.parse(file: sil, module: "Fixture", sourceRoot: folder)
        let entry = try #require(parsed.functions.values.first { $0.name == "LayoutTests.testLayout()" })
        let payload = try #require(parsed.functions.values.first { $0.name == "payload()" })
        let graph = DependencyGraph(functions: parsed.functions, tests: [test: [entry.id]])
        #expect(graph.dependencyPath(from: [entry.id], to: [payload.id]) == nil)
        var head = XcodeTestGraph(targets: [
            .init(name: "App", productType: "com.apple.product-type.framework", sourceFiles: ["Model.swift"]),
            .init(name: "Tests", productType: "com.apple.product-type.bundle.unit-test", sourceFiles: ["Tests.swift", "main.swift"])
        ], tests: [test])
        head.modules = ["App": "Fixture", "Tests": "Fixture"]
        head.dependencies = graph
        head.runtimeInventory = .init(imports: [:], hosts: ["Tests": ["Fixture"]])
        head.sources = Dictionary(uniqueKeysWithValues: files.map { path, text in
            ("Fixture:" + path, SwiftSourceSnapshot.parse(text, path: path, module: "Fixture"))
        })
        var base = head.sources
        base["Fixture:Model.swift"] = SwiftSourceSnapshot.parse(model, path: "Model.swift", module: "Fixture")
        let report = XcodeHeadOnlySelector.select(current: head, source: .init(base: base, mappings: nil), changes: [.init(path: "Model.swift")], baseRevision: "base")
        #expect(report.selectedTests == [test])
        #expect(report.diagnostics.contains { $0.code == "head_only_unsupported_body" })
    }
}
