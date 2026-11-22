// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
import Foundation
import Testing
@testable import TestImpact

@Test func removedHelpersReportHistoricalReferencesWithoutGuessingRenames() throws {
    let before = """
    import XCTest
    class Suite: XCTestCase {
        func testConsumer() { oldHelper() }
        private func oldHelper() { XCTAssertTrue(true) }
    }
    final class Inherited: Suite {}
    class Overriding: Suite {
        override func testConsumer() { overrideHelper() }
        private func overrideHelper() {}
    }
    final class Grandchild: Overriding {}
    final class Unrelated: XCTestCase {
        func testConsumer() {}
    }
    """
    let after = before.replacingOccurrences(of: "oldHelper", with: "newHelper")
        .replacingOccurrences(of: "overrideHelper", with: "newOverrideHelper")
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let inherited = ["UI/Inherited/testConsumer()", "UI/Suite/testConsumer()"]
    let overriding = ["UI/Grandchild/testConsumer()", "UI/Overriding/testConsumer()"]
    let current = try boundaryGraph(["UI.swift": after], tests: inherited + overriding + ["UI/Unrelated/testConsumer()"], root: root)
    let old = SwiftSourceSnapshot.parse(before, path: "UI.swift", module: "UI")
    let report = XcodeHeadOnlySelector.select(current: current, source: .init(base: ["UI:UI.swift": old], mappings: current.mappings), changes: [.init(path: "UI.swift")], baseRevision: "base")
    let removed = try #require(report.headOnlyDeclarationChanges?.first { $0.change == "removed" && $0.key.contains("oldHelper") })
    #expect(removed.baseRegions.first?.startLine == 4)
    #expect(removed.headRegions.isEmpty)
    #expect(removed.historicalReferences.contains { $0.sourceKey == "UI:UI.swift" && $0.callerLines.contains(3) })
    #expect(removed.historicalReferences.flatMap { $0.possibleCallers ?? [] }.contains {
        $0.baseRegion.startLine == 3 && $0.survivingTestEntries == inherited
    })
    let overrideHelper = try #require(report.headOnlyDeclarationChanges?.first { $0.key.contains("overrideHelper") })
    let overrideCallers = overrideHelper.historicalReferences.flatMap { $0.possibleCallers ?? [] }
    #expect(!overrideCallers.isEmpty)
    #expect(overrideCallers.allSatisfy { $0.survivingTestEntries == overriding })
    #expect(!removed.missingEvidence.isEmpty)
    #expect(report.selectedTests == current.tests.sorted())
    #expect(report.diagnostics.contains { $0.code == "head_only_declaration_change" })
}

@Test func conditionalHistoricalCallerMatchesOnlyItsCompiledBranch() throws {
    let before = """
    import XCTest
    final class Cases: XCTestCase {
        #if DEBUG
        func testReading() { oldHelper() }
        #else
        func testReading() { oldHelper() }
        #endif
    }
    func oldHelper() {}
    """
    let after = before.replacingOccurrences(of: "oldHelper", with: "newHelper")
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let entry = "UI/Cases/testReading()"
    let head = try boundaryGraph(["Tests.swift": after], tests: [entry], root: root, compilerArguments: ["-D", "DEBUG"])
    let base = SwiftSourceSnapshot.parse(before, path: "Tests.swift", module: "UI")
    let report = XcodeHeadOnlySelector.select(current: head, source: .init(base: ["UI:Tests.swift": base]),
        changes: [.init(path: "Tests.swift")], baseRevision: "base")
    let removed = try #require(report.headOnlyDeclarationChanges?.first { $0.change == "removed" && $0.key.contains("oldHelper") })
    let callers = removed.historicalReferences.flatMap { $0.possibleCallers ?? [] }
    #expect(callers.contains { $0.baseRegion.startLine == 4 && $0.survivingTestEntries == [entry] })
    #expect(callers.contains { $0.baseRegion.startLine == 6 && $0.survivingTestEntries.isEmpty })
}

@Test func importedSuperclassUsesTheCompiledTestImplementation() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let head = "import XCTest\nopen class Suite: XCTestCase {\n    open func testReading() {}\n}"
    let old = head.replacingOccurrences(of: "testReading() {}", with: "testReading() { oldHelper() }") + "\nprivate func oldHelper() {}"
    let baseEntry = "BaseKit/Suite/testReading()"
    var current = try boundaryGraph(["Base.swift": head], tests: [baseEntry], root: root, module: "BaseKit", target: "BaseKit")
    let platform = try CommandRunner.run("xcrun", ["--sdk", "macosx", "--show-sdk-platform-path"], at: root).text.trimmingCharacters(in: .whitespacesAndNewlines)
    _ = try CommandRunner.run("xcrun", ["swiftc", "-emit-module", "-module-name", "BaseKit",
        "-F", platform + "/Developer/Library/Frameworks", "-I", platform + "/Developer/usr/lib", "Base.swift"], at: root)
    let classes = """
    import BaseKit
    final class Inherited: Suite {}
    class Overriding: Suite { override func testReading() {} }
    final class Grandchild: Overriding {}
    """
    let child = try boundaryGraph(["Child.swift": classes], tests: [], root: root, compilerArguments: ["-I", root.path])
    current.targets += child.targets
    current.modules.merge(child.modules) { first, _ in first }
    current.sources.merge(child.sources) { first, _ in first }
    current.tests += ["Inherited", "Overriding", "Grandchild"].map { "UI/" + $0 + "/testReading()" }
    var graph = try #require(child.dependencies)
    let baseGraph = try #require(current.dependencies)
    graph.functions.merge(baseGraph.functions) { _, base in base }
    XcodeCompilerGraph.bind(tests: current.tests, modules: current.modules, sources: current.sources, graph: &graph)
    current.dependencies = graph
    var previous = current.sources
    previous["BaseKit:Base.swift"] = .parse(old, path: "Base.swift", module: "BaseKit")
    let retained = try GraphArchive.decode(GraphArchive.encode(current))
    let report = XcodeHeadOnlySelector.select(current: retained, source: .init(base: previous),
        changes: [.init(path: "Base.swift")], baseRevision: "base")
    let removed = try #require(report.headOnlyDeclarationChanges?.first { $0.change == "removed" })
    let callers = removed.historicalReferences.flatMap { $0.possibleCallers ?? [] }
    #expect(!callers.isEmpty)
    #expect(callers.allSatisfy { $0.survivingTestEntries == [baseEntry, "UI/Inherited/testReading()"] })
}

@Test func sharedTestSourceProjectsHistoricalCallersWithinEachCompiledModule() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let head = "import XCTest\nfinal class Suite: XCTestCase {\n    func testReading() {}\n}"
    let old = head.replacingOccurrences(of: "testReading() {}", with: "testReading() { oldHelper() }") + "\nprivate func oldHelper() {}"
    var current = XcodeTestGraph(targets: [], tests: [])
    var graph = DependencyGraph(), base: [String: SwiftSourceSnapshot] = [:]
    for module in ["MacTests", "MobileTests"] {
        let target = module + "Target"
        let entry = target + "/Suite/testReading()"
        let capture = try boundaryGraph(["Shared.swift": head], tests: [entry], root: root, module: module, target: target)
        current.targets += capture.targets
        current.tests.append(entry)
        current.modules[target] = module
        let key = module + ":Shared.swift"
        current.sources[key] = capture.sources[key]
        base[key] = .parse(old, path: "Shared.swift", module: module)
        let fragment = try #require(capture.dependencies)
        graph.functions.merge(fragment.functions) { existing, _ in existing }
        graph.tests[entry] = fragment.tests[entry]
    }
    current.dependencies = graph
    let report = XcodeHeadOnlySelector.select(current: current, source: .init(base: base),
        changes: [.init(path: "Shared.swift")], baseRevision: "base")
    let removed = try #require(report.headOnlyDeclarationChanges?.first { $0.change == "removed" })
    for (target, module) in current.modules {
        let references = removed.historicalReferences.filter { $0.sourceKey == module + ":Shared.swift" }
        let callers = references.flatMap { $0.possibleCallers ?? [] }
        #expect(!callers.isEmpty)
        #expect(callers.allSatisfy { $0.survivingTestEntries == [target + "/Suite/testReading()"] })
    }
}

@Test func historicalChainedAndEscapedUsesRetainOwnersWithoutGuessingRenamedEntries() throws {
    let before = """
    import XCTest
    final class Suite: XCTestCase {
        func testChained() { XCTAssertTrue(oldHelper().isEmpty) }
        func testEscaped() { let closure = oldHelper; XCTAssertTrue(closure().isEmpty) }
        private func oldHelper() -> String { "" }
    }
    """
    let after = """
    import XCTest
    final class Suite: XCTestCase {
        func testChained() { XCTAssertTrue(true) }
        func testReplacement() { XCTAssertTrue(true) }
    }
    """
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let tests = ["UI/Suite/testChained()", "UI/Suite/testReplacement()"]
    let current = try boundaryGraph(["UI.swift": after], tests: tests, root: root)
    let old = SwiftSourceSnapshot.parse(before, path: "UI.swift", module: "UI")
    let report = XcodeHeadOnlySelector.select(current: current, source: .init(base: ["UI:UI.swift": old]),
        changes: [.init(path: "UI.swift")], baseRevision: "base")
    let helper = try #require(report.headOnlyDeclarationChanges?.first { $0.key.contains("oldHelper") })
    let callers = helper.historicalReferences.flatMap { $0.possibleCallers ?? [] }
    #expect(callers.contains { $0.baseRegion.startLine == 3 && $0.survivingTestEntries == [tests[0]] })
    #expect(callers.contains { $0.baseRegion.startLine == 4 && $0.survivingTestEntries.isEmpty })
    #expect(helper.historicalReferences.contains { $0.incomplete })
    #expect(report.selectedTests == tests)
}

@Test func localFunctionBlockersNameTheMissingCaptureAndEffectProof() {
    let source = SwiftSourceSnapshot.parse("""
    import XCTest
    final class Suite: XCTestCase {
        func testConsumer() { helper() }
        private func helper() {
            func nested() { XCTAssertTrue(true) }
            let escaped = nested
            escaped()
        }
    }
    """, path: "UI.swift", module: "UI")
    let helper = source.units.first { $0.helperCallableName == "helper" }
    #expect(helper?.privateTestHelper == nil)
    #expect(helper?.privateTestHelperBlocker?.contains("Nested local function nested at line 5") == true)
    #expect(helper?.privateTestHelperBlocker?.contains("recursion and nonescaping caller evidence") == true)
    let factory = SwiftSourceSnapshot.parse("""
    import XCTest
    final class Suite: XCTestCase {
        func testConsumer() { helper() }
        private func helper() {
            let app = XCUIApplication.make()
            func nested() { XCTAssertTrue(app.exists) }
            nested()
        }
    }
    """, path: "UI.swift", module: "UI")
    #expect(factory.units.first { $0.helperCallableName == "helper" }?.privateTestHelperBlocker?
        .contains("Application construction/factory reference XCUIApplication at line 5") == true)
}

@Test func selectionIndexReusePreservesQueriesAndRejectsMutatedInputs() throws {
    var graph = DependencyGraph()
    for i in 0..<1_000 {
        graph.functions["f\(i)"] = FunctionNode(id: "f\(i)", module: "App", name: "f\(i)()",
            regions: [.init(path: "App.swift", startLine: i + 1, endLine: i + 1)], dependencies: i == 0 ? [] : ["f\(i - 1)"])
    }
    graph.tests = ["Tests/Suite/test()": ["f999"]]
    var current = XcodeTestGraph(targets: [], tests: Array(graph.tests.keys))
    current.dependencies = graph
    let cache = HelperBindingDigestCache(current: current)
    let fresh = DependencyIndex(graph)
    for targets: Set<String> in [[], ["f0"], ["f999"], ["f4", "f500"], ["absent"]] {
        let cached = try #require(cache.dependencyIndex(current))
        #expect(cached.paths(to: targets).path(from: ["f999"]) == fresh.paths(to: targets).path(from: ["f999"]))
    }
    #expect(cache.indexComputations == 1)
    current.dependencies?.tests["Tests/New/test()"] = ["new-root"]
    #expect(cache.dependencyIndex(current)?.ids["new-root"] != nil)
    #expect(cache.indexComputations == 2)
    current.dependencies?.functions["f999"]?.dependencies = []
    #expect(cache.dependencyIndex(current)?.paths(to: ["f0"]).path(from: ["f999"]) == nil)
    let measured = AnalysisMeasurement().event("child", revision: "head", parent: "selection")
    #expect(measured.parentPhase == "selection")
    #expect(measured.seconds >= 0)
    #expect(measured.analyzerCPUSeconds.map { $0 >= 0 } == true)
}
