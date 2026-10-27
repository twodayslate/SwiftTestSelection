// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation
import Testing
@testable import TestImpact

@Test(arguments: ["assertion", "body", "callee"])
func privateHelperAttachmentsRetainSharedStateChecks(location: String) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("attachment-state-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let before = """
    import XCTest
    @MainActor final class Suite: XCTestCase {
        func testCaller() { candidate(in: XCUIApplication()) }
        private func candidate(in app: XCUIApplication) {
            let menu = XCTAttachment(screenshot: app.screenshot())
            menu.name = "Menu"
            add(menu)
            let box = app.loadBox()
            XCTAssertTrue(true)
        }
    }
    """
    let after: String
    switch location {
    case "body": after = before.replacingOccurrences(of: "let box = app.loadBox()", with: "let box = app.loadBox(); let locked = box.lock.try()")
    case "callee": after = before.replacingOccurrences(of: "XCTAssertTrue(true)", with: "XCTAssertTrue(true); XCTAssertTrue(app.acquireSharedLock())")
    default: after = before.replacingOccurrences(of: "XCTAssertTrue(true)", with: "XCTAssertTrue(true); XCTAssertTrue(box.lock.try())")
    }
    let support = """
    import XCTest
    final class SharedBox { let lock = NSLock() }
    extension XCUIApplication {
        func loadBox() -> SharedBox { Thread.current.threadDictionary["attachment-state-box"] as! SharedBox }
        func acquireSharedLock() -> Bool { loadBox().lock.try() }
    }
    @MainActor final class Other: XCTestCase {
        func testObserve() { XCTAssertTrue(XCUIApplication().loadBox().lock.try()) }
    }
    """
    let files = ["UI.swift": after, "Support.swift": support]
    for (path, text) in files { try Data(text.utf8).write(to: root.appendingPathComponent(path)) }
    let platform = try CommandRunner.run("xcrun", ["--sdk", "macosx", "--show-sdk-platform-path"], at: root).text.trimmingCharacters(in: .whitespacesAndNewlines)
    let sil = root.appendingPathComponent("UI.sil")
    _ = try CommandRunner.run("xcrun", ["swiftc", "-emit-sil", "-whole-module-optimization", "-Onone", "-g", "-module-name", "UI", "-F", platform + "/Developer/Library/Frameworks", "-I", platform + "/Developer/usr/lib", root.appendingPathComponent("UI.swift").path, root.appendingPathComponent("Support.swift").path, "-o", sil.path], at: root)
    let parsed = try SILParser.parse(file: sil, module: "UI", sourceRoot: root)
    var graph = DependencyGraph(functions: parsed.functions)
    XcodeCompilerGraph.resolveDispatch(&graph, tables: parsed.dispatchTargets)
    let tests = ["UI/Suite/testCaller()", "UI/Other/testObserve()"]
    var current = XcodeTestGraph(targets: [.init(name: "UI", productType: "com.apple.product-type.bundle.ui-testing", sourceFiles: Set(files.keys))], tests: tests)
    current.modules = ["UI": "UI"]
    current.sources = Dictionary(uniqueKeysWithValues: files.map { ("UI:" + $0.key, SwiftSourceSnapshot.parse($0.value, path: $0.key, module: "UI")) })
    XcodeCompilerGraph.bind(tests: tests, modules: current.modules, sources: current.sources, graph: &graph)
    try #require(tests.allSatisfy { graph.tests[$0]?.isEmpty == false && graph.testDiagnostics[$0]?.isEmpty ?? true })
    current.dependencies = graph
    current = try JSONDecoder().decode(XcodeTestGraph.self, from: JSONEncoder().encode(current))
    current.mappings = UIFeatureMappings(features: [])
    current.mappings?.sourceLocationPolicy = .diagnosticLineColumn
    var base = current.sources
    let baseText = location == "body" ? after.replacingOccurrences(of: "XCTAssertTrue(true)", with: "") : before
    base["UI:UI.swift"] = .parse(baseText, path: "UI.swift", module: "UI")
    let unit = try #require(current.sources["UI:UI.swift"]!.units.first { $0.privateTestHelper != nil })
    let isolated = PrivateTestHelperIsolation.proves(unit, previous: base["UI:UI.swift"]!.units.first { $0.key == unit.key }, current: current, base: base, graph: graph, index: DependencyIndex(graph))
    let effectNodes = graph.functions.values.filter {
        $0.name.contains(location == "callee" ? "acquireSharedLock" : "candidate") && $0.uncertainties.contains("Shared state access")
    }
    #expect(!effectNodes.isEmpty)
    let report = XcodeHeadOnlySelector.select(current: current, source: .init(base: base, mappings: current.mappings), changes: [.init(path: "UI.swift")], baseRevision: "base")
    #expect(!isolated)
    #expect(report.selectedTests == tests.sorted())
    #expect(report.diagnostics.contains { $0.code == "head_only_helper_shared_state" })
    for version in [nil, 1, 2, 3, 4, 5, PrivateTestHelperSyntax.currentProofVersion + 1] as [Int?] {
        var stale = current
        for i in stale.sources["UI:UI.swift"]!.units.indices {
            stale.sources["UI:UI.swift"]!.units[i].privateTestHelper?.proofVersion = version
        }
        let report = XcodeHeadOnlySelector.select(current: stale, source: .init(base: base, mappings: current.mappings),
            changes: [.init(path: "UI.swift")], baseRevision: "base")
        #expect(report.selectedTests == tests.sorted())
        #expect(report.diagnostics.contains { $0.code == "head_only_helper_proof_version" })
    }
}

@Test(arguments: [5, 10, 15, 25])
func privateHelperDiamondTraversalIsBounded(depth: Int) throws {
    var methods = ["func testEntry() { a0(); b0() }"]
    for level in 0..<depth {
        let calls = level == depth - 1 ? "leaf()" : "a\(level+1)(); b\(level+1)()"
        methods += ["private func a\(level)() { \(calls) }", "private func b\(level)() { \(calls) }"]
    }
    methods += ["private func leaf() { XCTAssertTrue(true) }"]
    let before = "import XCTest\nfinal class Suite: XCTestCase {\n" + methods.joined(separator:"\n") + "\n}"
    let after = before.replacingOccurrences(of: "XCTAssertTrue(true)", with: "XCTAssertTrue(true); XCTAssertTrue(false)")
    let source = SwiftSourceSnapshot.parse(after, path: "UI.swift", module: "UI")
    let old = SwiftSourceSnapshot.parse(before, path: "UI.swift", module: "UI")
    var nodes: [String: FunctionNode] = [:]
    for unit in source.units where unit.kind == "function" {
        let name = unit.privateTestHelper?.name ?? "testEntry"
        let dependencies: Set<String>
        if name == "testEntry" { dependencies = ["a0", "b0"] }
        else if name == "leaf" { dependencies = [] }
        else { let level = Int(name.dropFirst())!; dependencies = level == depth - 1 ? ["leaf"] : ["a\(level+1)","b\(level+1)"] }
        nodes[name] = FunctionNode(id: name, module: "UI", name: "Suite." + name + "()", regions: [unit.region], dependencies: dependencies)
    }
    var graph = DependencyGraph(functions: nodes)
    let tests = ["UI/Suite/testEntry()"]
    graph.tests = [tests[0]: ["testEntry"]]
    var current = XcodeTestGraph(targets: [.init(name: "UI", productType: "com.apple.product-type.bundle.ui-testing", sourceFiles: ["UI.swift"])], tests: tests)
    current.modules = ["UI":"UI"]; current.sources = ["UI:UI.swift": source]; current.dependencies = graph
    let unit = try #require(source.units.first { $0.privateTestHelper?.name == "leaf" })
    let start = Date()
    var traversal = PrivateTestHelperIsolation.Traversal()
    let isolated = PrivateTestHelperIsolation.proves(unit, previous: old.units.first { $0.key == unit.key }, current: current, base: ["UI:UI.swift": old], graph: graph, index: DependencyIndex(graph), traversal: &traversal)
    print("Helper DAG: \(nodes.count) functions, \(traversal.evaluationCount) proofs, \(Date().timeIntervalSince(start)) seconds")
    #expect(isolated)
    // Deterministic work bound instead of a flaky wall-clock threshold.
    #expect(traversal.evaluationCount == 2 * depth + 1)
}

@Test(arguments: ["chain", "cycle", "shared", "attachment", "unsupported"])
func privateCalleeEffectTraversalUsesWorkQueue(scenario: String) throws {
    // Source parsing itself walks outbound effects for every helper. This
    // exceeded the debug worker stack before the caller graph was even built.
    let depth = scenario == "chain" ? 200 : 40
    var methods = ["func testEntry() { step0(XCUIApplication()) }"]
    for i in 0..<depth {
        let body: String
        if i < depth - 1 {
            let call = "step\(i + 1)(app)"
            body = scenario == "shared" ? call + "; " + call : call
        } else {
            switch scenario {
            case "cycle": body = "step0(app)"
            case "attachment": body = "let image = XCTAttachment(screenshot: app.screenshot()); image.name = \"Menu\"; add(image)"
            case "unsupported": body = "UserDefaults.standard.set(true, forKey: \"shared-mode\")"
            default: body = "XCTAssertTrue(true)"
            }
        }
        methods.append("private func step\(i)(_ app: XCUIApplication) { \(body) }")
    }
    let source = "import XCTest\n@MainActor final class Suite: XCTestCase {\n" + methods.joined(separator: "\n") + "\n}"
    let snapshot = SwiftSourceSnapshot.parse(source, path: "UI.swift", module: "UI")
    let root = try #require(snapshot.units.first { $0.privateTestHelper?.name == "step0" }?.privateTestHelper)
    if ["cycle", "unsupported"].contains(scenario) {
        #expect(root.calleeEffectsSupported == false)
        #expect(root.effectCalleeLines == nil)
    } else {
        let helpers = snapshot.units.compactMap(\.privateTestHelper)
        #expect(helpers.count == depth)
        #expect(helpers.allSatisfy { $0.calleeEffectsSupported == true })
        #expect(helpers.allSatisfy { $0.localAttachmentState == (scenario == "attachment") })
        // Every transitive declaration is retained, including shared callees.
        #expect(root.effectCalleeLines?.count == depth)
        #expect(root.effectCalleeLines?["step\(depth - 1)"] != nil)
    }
}
