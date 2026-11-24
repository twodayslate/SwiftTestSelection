// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
import Foundation
import Testing
@testable import TestImpact

@Test func swiftTestingSelectionIsIndependentOfExtractionWorkerCount() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let before = """
    import Testing
    import XCTest
    @Test func unrelated() {}
    @Suite(.serialized) struct OtherSuite {}
    struct Independent { @Test func plainMember() {} }
    final class Case: XCTestCase {
        func testEdited() { XCTAssertTrue(true) }
    }
    """
    let after = before.replacingOccurrences(of: "XCTAssertTrue(true)", with: "XCTAssertTrue(false)")
    try Data(after.utf8).write(to: root.appendingPathComponent("Tests.swift"))
    func query(_ command: String, _ arguments: [String]) throws -> String {
        try CommandRunner.run(command, arguments, at: root).text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    let platform = try query("xcrun", ["--sdk", "macosx", "--show-sdk-platform-path"])
    let sdk = try query("xcrun", ["--sdk", "macosx", "--show-sdk-path"])
    let compiler = try query("xcrun", ["--find", "swiftc"])
    let architecture = try query("uname", ["-m"])
    let plugins = URL(fileURLWithPath: compiler).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("lib/swift/host/plugins/testing")
    let arguments = [compiler, "-module-name", "Tests", "-sdk", sdk, "-target", architecture + "-apple-macosx13.0",
                     "-plugin-path", plugins.path, "-F", platform + "/Developer/Library/Frameworks",
                     "-I", platform + "/Developer/usr/lib", root.appendingPathComponent("Tests.swift").path]
    let log = "builtin-SwiftDriver -- " + arguments.map { "\"" + $0 + "\"" }.joined(separator: " ")
    let tests = ["Tests/unrelated()", "Tests/Case/testEdited()", "Tests/Independent/plainMember()"]
    let sources = ["Tests:Tests.swift": SwiftSourceSnapshot.parse(after, path: "Tests.swift", module: "Tests")]
    let base = XcodeHeadOnlySources(base: ["Tests:Tests.swift": .parse(before, path: "Tests.swift", module: "Tests")])
    let records = try linkedFixtureRecords(arguments, root: root, target: "Tests")
    var reference: DependencyGraph?
    for workers in [1, 2] {
        let scratch = root.appendingPathComponent("extract-\(workers)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        var graph = XcodeCompilerGraph.extract(log: log, sourceRoot: root, directory: root, derived: scratch,
            progress: { _ in }, ownership: ["Tests": ["Tests.swift"]], workers: workers, linkedTestingRecords: records)
        #expect(graph.diagnostics.isEmpty)
        #expect(graph.functions.values.compactMap(\.swiftTestingEmptyFactory).sorted() == ["member", "top-level"])
        let suite = try #require(graph.functions.values.first { $0.swiftTestingFactoryType == "OtherSuite" })
        let member = try #require(graph.functions.values.first { $0.swiftTestingFactoryType == "Independent" })
        XcodeCompilerGraph.bind(tests: tests, modules: ["Tests": "Tests"], sources: sources, graph: &graph)
        #expect(graph.testDiagnostics.isEmpty)
        #expect(graph.dependencyPath(from: graph.tests[tests[2]] ?? [], to: [suite.id]) != nil)
        for type in ["Independent", nil] {
            var uncertain = DependencyGraph(functions: graph.functions)
            uncertain.functions[suite.id]?.swiftTestingFactoryType = type
            XcodeCompilerGraph.bind(tests: tests, modules: ["Tests": "Tests"], sources: sources, graph: &uncertain)
            #expect(uncertain.testDiagnostics[tests[2]]?.contains(SwiftTestingDiscoveryRoots.runtimeEvidence) == true)
        }
        var unknown = DependencyGraph(functions: graph.functions)
        unknown.functions[member.id]?.swiftTestingFactoryType = nil
        XcodeCompilerGraph.bind(tests: tests, modules: ["Tests": "Tests"], sources: sources, graph: &unknown)
        #expect(unknown.testDiagnostics[tests[2]]?.contains(SwiftTestingDiscoveryRoots.runtimeEvidence) == true)
        if let reference {
            #expect(graph.functions == reference.functions)
            #expect(graph.tests == reference.tests)
        } else { reference = graph }
        var current = XcodeTestGraph(targets: [.init(name: "Tests", productType: "com.apple.product-type.bundle.unit-test", sourceFiles: ["Tests.swift"])], tests: tests)
        current.modules = ["Tests": "Tests"]; current.sources = sources; current.dependencies = graph
        let report = XcodeHeadOnlySelector.select(current: current, source: base, changes: [.init(path: "Tests.swift")], baseRevision: "base")
        #expect(report.selectedTests == [tests[1]])
        #expect(report.diagnostics.isEmpty)
    }
}

@Test func compiledSwiftTestingUIEntriesPreserveNestedAndStaticIdentifiers() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let text = """
    import Testing
    import XCUIAutomation
    import XCTest
    func argumentValues() -> [Bool] { [true, false] }
    func testEnabled() -> Bool { true }
    func suiteEnabled() -> Bool { true }
    func runtimeHook() {}
    func suiteRuntimeHook() {}
    struct RecursiveSuiteTrait: SuiteTrait {
        var isRecursive: Bool { true }
        func prepare(for test: Testing.Test) async throws { suiteRuntimeHook() }
    }
    func nestedRuntimeHook() {}
    struct NestedSuiteTrait: SuiteTrait {
        func prepare(for test: Testing.Test) async throws { nestedRuntimeHook() }
    }
    struct Other { @Test func unrelatedMember() {} }
    func shadowHook() {}
    protocol Trait { func prepare() }
    func actualScopeHook() {}
    func unusedScopeHook() {}
    struct Provider: TestScoping {
        func provideScope(for test: Testing.Test, testCase: Testing.Test.Case?, performing run: @Sendable () async throws -> Void) async throws {
            actualScopeHook()
            try await run()
        }
    }
    struct RuntimeTrait: TestTrait, Trait, TestScoping {
        func scopeProvider(for test: Testing.Test, testCase: Testing.Test.Case?) -> Provider? { Provider() }
        func provideScope(for test: Testing.Test, testCase: Testing.Test.Case?, performing run: @Sendable () async throws -> Void) async throws {
            unusedScopeHook()
            try await run()
        }
        func prepare() { shadowHook() }
        func prepare(for test: Testing.Test) async throws { runtimeHook() }
    }
    @Test @MainActor func topLevel() { let app = XCUIApplication(); #expect(app.exists) }
    @Suite(RecursiveSuiteTrait(), .enabled(if: suiteEnabled()))
    struct Outer {
        @Test func sibling() {}
        @Suite(NestedSuiteTrait()) struct Inner {
            @Test @MainActor func instance() { let app = XCUIApplication(); #expect(app.exists) }
            @Test @MainActor static func typeTest() { let app = XCUIApplication(); #expect(app.exists) }
            @Test(RuntimeTrait(), .enabled(if: testEnabled()), arguments: argumentValues()) func arguments(value: Bool) { #expect(value || !value) }
        }
    }
    final class XCTestSuite: XCTestCase {
        func testOrdinary() { XCTAssertTrue(true) }
    }
    func incidentalHook() {}
    struct Incidental: TestTrait {
        func prepare(for test: Testing.Test) async throws { incidentalHook() }
    }
    struct Wrapper: TestTrait { let payload: [any TestTrait] }
    @Test(Wrapper(payload: [Incidental()]), RuntimeTrait()) func runtimeOnly() {}
    @Test(arguments: [true]) func argumentsOnly(value: Bool) {}
    """
    let tests = ["UI/topLevel()", "UI/Outer/Inner/instance()", "UI/Outer/Inner/typeTest()", "UI/Outer/Inner/arguments(value:)", "UI/XCTestSuite/testOrdinary()", "UI/runtimeOnly()", "UI/argumentsOnly(value:)", "UI/Other/unrelatedMember()", "UI/Outer/sibling()"]
    try Data(text.utf8).write(to: root.appendingPathComponent("Tests.swift"))
    let platform = try CommandRunner.run("xcrun", ["--sdk", "macosx", "--show-sdk-platform-path"], at: root).text.trimmingCharacters(in: .whitespacesAndNewlines)
    let sil = root.appendingPathComponent("UI.sil")
    let compiler = try CommandRunner.run("xcrun", ["--find", "swiftc"], at: root).text.trimmingCharacters(in: .whitespacesAndNewlines)
    let plugins = URL(fileURLWithPath: compiler).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("lib/swift/host/plugins/testing")
    _ = try CommandRunner.run("xcrun", ["swiftc", "-module-name", "UI", "-g", "-Onone", "-emit-sil", "-whole-module-optimization",
        "-plugin-path", plugins.path,
        "-F", platform + "/Developer/Library/Frameworks", "-I", platform + "/Developer/usr/lib", root.appendingPathComponent("Tests.swift").path, "-o", sil.path], at: root)
    let parsed = try SILParser.parse(file: sil, module: "UI", sourceRoot: root)
    let owned = try SILOwnership.resolve(parsed, module: "UI", compiler: compiler, directory: root)
    var graph = DependencyGraph(functions: owned.functions)
    XcodeCompilerGraph.resolveDispatch(&graph, tables: owned.dispatchTargets)
    let source = SwiftSourceSnapshot.parse(text, path: "Tests.swift", module: "UI")
    XcodeCompilerGraph.bind(tests: tests, modules: ["UI": "UI"], sources: ["UI:Tests.swift": source], graph: &graph)
    for test in tests { #expect(graph.tests[test]?.isEmpty == false, "\(test)") }
    #expect(graph.testDiagnostics[tests[0]] == [SwiftTestingDiscoveryRoots.unresolvedEffects])
    #expect(graph.testDiagnostics[tests[1]]?.contains(SwiftTestingDiscoveryRoots.runtimeEvidence) == true)
    #expect(graph.testDiagnostics[tests[3]]?.contains(SwiftTestingDiscoveryRoots.runtimeEvidence) == true)
    #expect(graph.testDiagnostics[tests[4]]?.isEmpty ?? true)
    for test in tests[5...6] {
        #expect(graph.testDiagnostics[test]?.contains(SwiftTestingDiscoveryRoots.runtimeEvidence) == true)
    }
    // A namesake macro's source spelling cannot hide compiler-emitted traits.
    let plainSpelling = SwiftSourceSnapshot.parse(text.replacingOccurrences(of: "@Test(Wrapper(payload: [Incidental()]), RuntimeTrait())", with: "@Test"), path: "Tests.swift", module: "UI")
    var hiddenTrait = DependencyGraph(functions: parsed.functions)
    XcodeCompilerGraph.bind(tests: tests, modules: ["UI": "UI"], sources: ["UI:Tests.swift": plainSpelling], graph: &hiddenTrait)
    #expect(hiddenTrait.testDiagnostics[tests[5]]?.contains(SwiftTestingDiscoveryRoots.runtimeEvidence) == true)
    let index = DependencyIndex(graph)
    let incidental = try #require(graph.functions.values.first { $0.name == "incidentalHook()" }?.id)
    #expect(index.paths(to: [incidental]).path(from: graph.tests[tests[5]] ?? []) == nil)
    let shadow = try #require(graph.functions.values.first { $0.name == "shadowHook()" }?.id)
    #expect(index.paths(to: [shadow]).path(from: graph.tests[tests[5]] ?? []) == nil)
    let provider = try #require(graph.functions.values.first { $0.name == "actualScopeHook()" })
    let unused = try #require(graph.functions.values.first { $0.name == "unusedScopeHook()" })
    #expect(index.paths(to: [provider.id]).path(from: graph.tests[tests[5]] ?? []) != nil)
    #expect(index.paths(to: [unused.id]).path(from: graph.tests[tests[5]] ?? []) == nil)
    let runtimeHook = try #require(graph.functions.values.first { $0.name == "runtimeHook()" }?.id)
    // The runtime invokes prepare through Trait. Bind its emitted witness even
    // while custom scoping and parameter iteration retain uncertainty.
    #expect(index.paths(to: [runtimeHook]).path(from: graph.tests[tests[3]] ?? []) != nil)
    #expect(index.paths(to: [runtimeHook]).path(from: graph.tests[tests[5]] ?? []) != nil)
    #expect(index.paths(to: [runtimeHook]).path(from: graph.tests[tests[0]] ?? []) == nil)
    for name in ["argumentValues()", "testEnabled()", "suiteEnabled()"] {
        let symbol = try #require(graph.functions.values.first { $0.name == name }?.id)
        #expect(index.paths(to: [symbol]).path(from: graph.tests[tests[3]] ?? []) != nil, "\(name)")
        #expect(index.paths(to: [symbol]).path(from: graph.tests[tests[0]] ?? []) == nil, "\(name)")
    }
    let suiteHook = try #require(graph.functions.values.first { $0.name == "suiteRuntimeHook()" }?.id)
    let suiteDiscovery = try #require(graph.functions.values.first { $0.name == "suiteEnabled()" }?.id)
    let nestedHook = try #require(graph.functions.values.first { $0.name == "nestedRuntimeHook()" }?.id)
    let outerPaths = index.paths(to: [suiteHook])
    let nestedPaths = index.paths(to: [nestedHook])
    let discoveryPaths = index.paths(to: [suiteDiscovery])
    for test in tests {
        let roots = graph.tests[test] ?? []
        #expect((nestedPaths.path(from: roots) != nil) == test.hasPrefix("UI/Outer/Inner/"), "\(test)")
        #expect((outerPaths.path(from: roots) != nil) == test.hasPrefix("UI/Outer/"), "\(test)")
        #expect((discoveryPaths.path(from: roots) != nil) == test.hasPrefix("UI/Outer/"), "\(test)")
    }

    // A deleted helper was called by a top-level test and two nested methods.
    let before = "private func oldHelper() {}\n" + text.replacingOccurrences(of: "{ let app =", with: "{ oldHelper(); let app =")
    let base = SwiftSourceSnapshot.parse(before, path: "Tests.swift", module: "UI")
    var current = XcodeTestGraph(targets: [.init(name: "UI", productType: "com.apple.product-type.bundle.ui-testing", sourceFiles: ["Tests.swift"])], tests: tests)
    current.modules = ["UI": "UI"]
    current.sources = ["UI:Tests.swift": source]
    current.dependencies = graph
    let report = XcodeHeadOnlySelector.select(current: current, source: .init(base: ["UI:Tests.swift": base]),
        changes: [.init(path: "Tests.swift")], baseRevision: "base")
    let removed = try #require(report.headOnlyDeclarationChanges?.first { $0.change == "removed" && $0.key.contains("oldHelper") })
    let callers = removed.historicalReferences.flatMap { $0.possibleCallers ?? [] }
    for test in tests.prefix(3) {
        let method = try #require(test.split(separator: "/").last?.dropLast(2))
        #expect(callers.contains { $0.declaration.contains(method) && $0.survivingTestEntries == [test] }, "\(test)")
    }

    let testFactories = Set(graph.functions.values.filter {
        $0.compilerReferences?.contains { $0.hasPrefix("$s7Testing4TestV10__function") } == true
    }.map(\.id))
    let suiteFactories = Set(graph.functions.values.filter {
        $0.compilerReferences?.contains { $0.hasPrefix("$s7Testing4TestV6__type") } == true
    }.map(\.id))
    #expect(!suiteFactories.isEmpty)
    for missing in [testFactories, suiteFactories] {
        var incomplete = DependencyGraph(functions: parsed.functions.filter { !missing.contains($0.key) })
        XcodeCompilerGraph.bind(tests: tests, modules: ["UI": "UI"], sources: ["UI:Tests.swift": source], graph: &incomplete)
        #expect(incomplete.testDiagnostics[tests[3]]?.contains(SwiftTestingDiscoveryRoots.missingEvidence) == true)
    }
    let factoryID = try #require(testFactories.intersection(graph.tests[tests[3]] ?? []).first)
    let factory = try #require(parsed.functions[factoryID])
    var duplicate = factory; duplicate.id += "-ambiguous"
    var ambiguous = DependencyGraph(functions: parsed.functions)
    ambiguous.functions[duplicate.id] = duplicate
    XcodeCompilerGraph.bind(tests: tests, modules: ["UI": "UI"], sources: ["UI:Tests.swift": source], graph: &ambiguous)
    #expect(ambiguous.testDiagnostics[tests[3]]?.contains(SwiftTestingDiscoveryRoots.missingEvidence) == true)
    let argumentThunk = try #require(factory.compilerReferences?.first { id in
        parsed.functions[id]?.compilerReferences?.contains { parsed.functions[$0]?.name == "argumentValues()" } == true
    })
    var missingArgument = DependencyGraph(functions: parsed.functions.filter { $0.key != argumentThunk })
    XcodeCompilerGraph.bind(tests: tests, modules: ["UI": "UI"], sources: ["UI:Tests.swift": source], graph: &missingArgument)
    #expect(missingArgument.testDiagnostics[tests[3]]?.contains(SwiftTestingDiscoveryRoots.missingEvidence) == true)
    var legacySource = source; legacySource.parserVersion = nil
    var legacy = DependencyGraph(functions: parsed.functions)
    XcodeCompilerGraph.bind(tests: tests, modules: ["UI": "UI"], sources: ["UI:Tests.swift": legacySource], graph: &legacy)
    #expect(legacy.testDiagnostics[tests[3]]?.contains(SwiftTestingDiscoveryRoots.missingEvidence) == true)
    let enumeration = try JSONSerialization.data(withJSONObject: ["errors": [], "values": [["enabledTests": tests.map { ["identifier": $0] }]]])
    #expect(try XcodeTestEnumeration.parse(enumeration) == tests.sorted())
    let options = XcodeConfiguration(container: .project, path: root.appendingPathComponent("App.xcodeproj"), scheme: "App", destination: "platform=macOS")
    let arguments = try options.executionArguments(tests: tests, derivedData: root, resultBundle: root.appendingPathComponent("Results.xcresult"))
    for test in tests { #expect(arguments.contains("-only-testing:" + test)) }
    // Compilation and binding are exercised here, not UI execution on Xcode 27.3.
    // Unauthenticated Testing macros remain outside head-only body isolation.
    #expect(source.units.filter { $0.swiftTestingRole == "test" }.allSatisfy { $0.headOnlyBodySupported == false })
}


@Test func plainSwiftTestingEntriesDoNotBroadenUnrelatedXCTestEdits() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let before = """
    import Testing
    import XCTest
    import External
    @Test func plain() {}
    @Suite struct Empty {
        @Test("Display only") func member() {}
    }
    extension ImportedSuite { @Test func member() {} }
    final class Case: XCTestCase {
        func testEdited() { XCTAssertTrue(true) }
    }
    """
    let after = before.replacingOccurrences(of: "XCTAssertTrue(true)", with: "XCTAssertTrue(false)")
    let tests = ["UI/plain()", "UI/Empty/member()", "UI/Case/testEdited()", "UI/ImportedSuite/member()"]
    let platform = try CommandRunner.run("xcrun", ["--sdk", "macosx", "--show-sdk-platform-path"], at: root).text.trimmingCharacters(in: .whitespacesAndNewlines)
    let compiler = try CommandRunner.run("xcrun", ["--find", "swiftc"], at: root).text.trimmingCharacters(in: .whitespacesAndNewlines)
    let plugins = URL(fileURLWithPath: compiler).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("lib/swift/host/plugins/testing")
    let compilerArguments = ["swiftc", "-g", "-Onone", "-plugin-path", plugins.path, "-F", platform + "/Developer/Library/Frameworks", "-I", platform + "/Developer/usr/lib"]
    let external = "public struct ImportedSuite { public init() {} }"
    try Data(external.utf8).write(to: root.appendingPathComponent("External.swift"))
    _ = try CommandRunner.run("xcrun", compilerArguments + ["-module-name", "External", "-emit-library", "-static", "-o", root.appendingPathComponent("libExternal.a").path, "-emit-module", root.appendingPathComponent("External.swift").path, "-emit-module-path", root.appendingPathComponent("External.swiftmodule").path], at: root)
    let cache = try XcodeGraphCache(.init(directory: root.appendingPathComponent("cache"), context: "fixture"), progress: { _ in })
    func capture(_ text: String) throws -> (XcodeTestGraph, String) {
        try Data(text.utf8).write(to: root.appendingPathComponent("Tests.swift"))
        let sil = root.appendingPathComponent("UI.sil")
        _ = try CommandRunner.run("xcrun", compilerArguments + ["-module-name", "UI", "-emit-sil", "-whole-module-optimization", "-I", root.path, root.appendingPathComponent("Tests.swift").path, "-o", sil.path], at: root)
        let parsed = try SILParser.parse(file: sil, module: "UI", sourceRoot: root)
        // Production module-cache reads cross the compact archive boundary
        // before discovery binding, so exercise that order here as well.
        let identity = ["fixture": text]
        try cache.storeModule(parsed, identity: identity)
        let restored = try #require(try cache.loadModule(identity))
        #expect(restored.functions == parsed.functions)
        let source = SwiftSourceSnapshot.parse(text, path: "Tests.swift", module: "UI")
        var graph = DependencyGraph(functions: restored.functions)
        let records = try linkedFixtureRecords(compilerArguments + ["-module-name", "UI", "-I", root.path,
            root.appendingPathComponent("Tests.swift").path], linkArguments: [root.appendingPathComponent("libExternal.a").path], root: root, target: "UI")
        XcodeCompilerGraph.resolveDispatch(&graph, tables: restored.dispatchTargets, linkedTestingRecords: records)
        XcodeCompilerGraph.bind(tests: tests, modules: ["UI": "UI"], sources: ["UI:Tests.swift": source], graph: &graph)
        var current = XcodeTestGraph(targets: [.init(name: "UI", productType: "com.apple.product-type.bundle.unit-test", sourceFiles: ["Tests.swift"])], tests: tests)
        current.sources = ["UI:Tests.swift": source]
        current.modules = ["UI": "UI"]
        current.dependencies = graph
        return (current, try String(contentsOf: sil, encoding: .utf8))
    }
    let (previous, _) = try capture(before)
    let (current, sil) = try capture(after)
    for test in tests.prefix(3) { #expect(current.dependencies?.testDiagnostics[test]?.isEmpty ?? true) }
    #expect(current.dependencies?.testDiagnostics[tests[3]]?.contains(SwiftTestingDiscoveryRoots.runtimeEvidence) == true)
    let changes = [FileChange(path: "Tests.swift")]
    let headOnly = XcodeHeadOnlySelector.select(current: current, source: .init(base: previous.sources), changes: changes, baseRevision: "base")
    let twoGraphs = XcodeFineSelector.select(current: current, previous: previous, changes: changes, baseRevision: "base")
    #expect(headOnly.selectedTests == [tests[2], tests[3]])
    #expect(twoGraphs.selectedTests == [tests[2], tests[3]])

    // The runtime constructs Marker even when filtering to plain(). Its
    // argument and initializer can both affect what plain() observes.
    let discovery = before.replacingOccurrences(of: "@Test func plain() {}", with: """
        import Foundation
        func flag() -> Bool { true }
        func store(_ value: Bool) { UserDefaults.standard.set(value, forKey: "discovery") }
        struct Marker: TestTrait { init(_ value: Bool) { store(value) } }
        @Test func plain() { #expect(UserDefaults.standard.bool(forKey: "discovery")) }
        """).replacingOccurrences(of: "@Test(\"Display only\")", with: "@Test(Marker(flag()))")
    let (discoveryBase, _) = try capture(discovery)
    let (discoveryHead, _) = try capture(discovery.replacingOccurrences(of: "func flag() -> Bool { true }", with: "func flag() -> Bool { false }"))
    let bound = try #require(discoveryHead.dependencies)
    let roots = try #require(bound.tests[tests[0]])
    for name in ["flag()", "store(_:)"] {
        let symbol = try #require(bound.functions.values.first { $0.name == name }?.id)
        #expect(bound.dependencyPath(from: roots, to: [symbol]) != nil)
    }
    let member = try #require(bound.functions.values.first { $0.name == "Empty.member()" }?.id)
    #expect(bound.dependencyPath(from: roots, to: [member]) == nil)
    for report in [
        XcodeHeadOnlySelector.select(current: discoveryHead, source: .init(base: discoveryBase.sources), changes: changes, baseRevision: "base"),
        XcodeFineSelector.select(current: discoveryHead, previous: discoveryBase, changes: changes, baseRevision: "base")
    ] {
        #expect(report.explanations.contains { $0.test == tests[0] && $0.kind == "dependency" })
    }
    let (changedAttribute, _) = try capture(discovery.replacingOccurrences(of: "@Test(Marker(flag()))", with: "@Test(Marker(!flag()))"))
    let attributeReport = XcodeFineSelector.select(current: changedAttribute, previous: discoveryBase, changes: changes, baseRevision: "base")
    #expect(attributeReport.explanations.contains { $0.test == tests[0] && $0.kind == "dependency" })
    let attributeHeadOnly = XcodeHeadOnlySelector.select(current: changedAttribute, source: .init(base: discoveryBase.sources), changes: changes, baseRevision: "base")
    #expect(attributeHeadOnly.selectedTests.contains(tests[0]))
    var legacyDiscovery = discoveryHead
    legacyDiscovery.dependencies?.functions.removeValue(forKey: SwiftTestingDiscoveryRoots.sharedDiscoveryID)
    for id in bound.functions.keys { legacyDiscovery.dependencies?.functions[id]?.swiftTestingDiscoveryReferences = nil }
    for test in tests { legacyDiscovery.dependencies?.tests[test]?.remove(SwiftTestingDiscoveryRoots.sharedDiscoveryID) }
    let flag = try #require(bound.functions.values.first { $0.name == "flag()" }?.id)
    for data in [try JSONEncoder().encode(legacyDiscovery), try GraphArchive.encode(legacyDiscovery)] {
        let restored = try #require(try GraphArchive.decode(data).dependencies)
        #expect(restored.dependencyPath(from: restored.tests[tests[0]] ?? [], to: [flag]) != nil)
    }

    // Older archives and nonempty trait allocations cannot authorize exclusions.
    var legacy = current.dependencies!
    for id in legacy.functions.keys { legacy.functions[id]?.swiftTestingEmptyFactory = nil }
    legacy.tests = [:]; legacy.testDiagnostics = [:]
    XcodeCompilerGraph.bind(tests: tests, modules: current.modules, sources: current.sources, graph: &legacy)
    #expect(legacy.testDiagnostics[tests[0]]?.contains(SwiftTestingDiscoveryRoots.runtimeEvidence) == true)
    let nonempty = SILParser.parse(sil.replacingOccurrences(of: "integer_literal $Builtin.Word, 0,", with: "integer_literal $Builtin.Word, 1,"), module: "UI", sourceRoot: root)
    #expect(nonempty.functions.values.allSatisfy { $0.swiftTestingEmptyFactory == nil })
    // The location-based SDK ABI uses the same trait and output positions.
    let locationABI = SILParser.parse(sil.replacingOccurrences(of: "6traits12sourceBounds", with: "6traits14sourceLocation"), module: "UI", sourceRoot: root)
    #expect(locationABI.functions.values.compactMap(\.swiftTestingEmptyFactory).sorted() == ["member", "member", "suite", "top-level"])
    let escapedSIL = sil.components(separatedBy: "\n").map { line in
        line.hasPrefix("bb0(%0 : $*Test") ? line + "\n  %9999 = address_to_pointer %0 : $*Test to $Builtin.RawPointer" : line
    }.joined(separator: "\n")
    let escaped = SILParser.parse(escapedSIL, module: "UI", sourceRoot: root)
    #expect(escaped.functions.values.allSatisfy { $0.swiftTestingEmptyFactory == nil })
    for data in [try JSONEncoder().encode(current), try GraphArchive.encode(current)] {
        let decoded = try GraphArchive.decode(data)
        #expect(decoded.dependencies?.functions == current.dependencies?.functions)
        #expect(decoded.dependencies?.testDiagnostics == current.dependencies?.testDiagnostics)
    }
    // Withhold one body's effect evidence, as in an older capture. The
    // discovery fallback must survive both archive formats and scoped queries.
    var missingBodyProof = current
    let factory = try #require(current.dependencies?.functions.values.first { $0.swiftTestingEmptyFactory == "top-level" })
    missingBodyProof.dependencies?.functions[factory.id]?.hasModeledDiscoveryInstructions = nil
    var missingLinkProof = current
    missingLinkProof.dependencies?.swiftTestingFactoriesByTarget = nil
    let incomplete = try [missingBodyProof, missingLinkProof].flatMap { [try JSONEncoder().encode($0), try GraphArchive.encode($0)] }
    for data in incomplete {
        let restored = try GraphArchive.decode(data)
        let source = XcodeHeadOnlySources(base: previous.sources)
        let dual = XcodeFineSelector.select(current: restored, previous: previous, changes: changes, baseRevision: "base")
        let single = XcodeHeadOnlySelector.select(current: restored, source: source, changes: changes, baseRevision: "base")
        let scoped = XcodeHeadOnlySelector.select(current: restored, source: source, changes: changes,
            baseRevision: "base", excludedTestEntries: [tests[2]])
        #expect(dual.selectedTests == tests.sorted())
        #expect(single.selectedTests == tests.sorted())
        #expect(scoped.selectedTests == tests.filter { $0 != tests[2] }.sorted())
    }

}

@Test func sameNamedTraitsAndSuitesBindAcrossCompiledModules() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let platform = try CommandRunner.run("xcrun", ["--sdk", "macosx", "--show-sdk-platform-path"], at: root).text.trimmingCharacters(in: .whitespacesAndNewlines)
    let compiler = try CommandRunner.run("xcrun", ["--find", "swiftc"], at: root).text.trimmingCharacters(in: .whitespacesAndNewlines)
    let plugins = URL(fileURLWithPath: compiler).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("lib/swift/host/plugins/testing")
    let flags = ["-g", "-Onone", "-I", root.path, "-plugin-path", plugins.path,
                 "-F", platform + "/Developer/Library/Frameworks", "-I", platform + "/Developer/usr/lib"]
    let trait = """
    public struct Mode: TestTrait, SuiteTrait {
        public init() {}
        public var isRecursive: Bool { true }
        public func prepare(for test: Testing.Test) async throws { hook() }
    }
    func hook() {}
    """
    let vendor = "import Testing\n" + trait + """

    #if os(macOS)
    @Suite(Mode()) struct Common { @Test func decorated() {} }
    #endif
    func register() {}
    struct Eager: TestTrait { init() { register() } }
    @Test(Eager()) func registered() {}
    @Suite(Mode()) public struct Extended { public init() {} }
    @Suite(Mode()) actor Live { @Test func real() {} }
    actor Host {
        #if os(macOS)
        @Testing.Suite(Mode()) struct Nested { @Test func inner() {} }
        #endif
    }
    #if os(macOS)
    @Suite(Mode())
    #endif
    struct Conditional { @Test func active() {} }
    #if os(iOS)
    @Suite(Mode())
    #endif
    struct OptionalSuite { @Test func ordinary() {} }
    struct Independent { @Test func plainMember() {} }
    @Test func top() {}
    #if os(iOS)
    @Suite struct IOSOnly { @Test func platformTest() {} }
    #endif
    """
    let client = "import Testing\nimport Vendor\n" + trait.replacingOccurrences(of: "public struct", with: "private struct") + """

    @Suite struct Common { @Test func plain() {} }
    @Suite(Mode()) struct Extended { @Test func localMember() {} }
    extension Vendor.Extended {
        @Test func member() {}
        @Test(arguments: [true]) static func parameterized(value: Bool) {}
    }
    @Suite(Mode()) struct Decorated { @Test func local() {} }
    @Test(Mode()) func own() {}
    @Test(Vendor.Mode()) func imported() {}
    @Test(Mode(), Vendor.Mode()) func both() {}
    """
    var graph = DependencyGraph(), tables: [String: Set<String>] = [:], sources: [String: SwiftSourceSnapshot] = [:]
    for (module, source) in [("Vendor", vendor), ("Client", client)] {
        let path = module + ".swift"
        let file = root.appendingPathComponent(path)
        try Data(source.utf8).write(to: file)
        if module == "Vendor" { _ = try CommandRunner.run(compiler, flags + ["-module-name", module, "-emit-module", file.path], at: root) }
        let sil = root.appendingPathComponent(module + ".sil")
        _ = try CommandRunner.run(compiler, flags + ["-module-name", module, "-emit-sil", "-whole-module-optimization", file.path, "-o", sil.path], at: root)
        let parsed = try SILParser.parse(file: sil, module: module, sourceRoot: root)
        let fragment = try SILOwnership.resolve(parsed, module: module, compiler: compiler, directory: root)
        for (id, node) in fragment.functions where graph.functions[id] == nil || !node.regions.isEmpty { graph.functions[id] = node }
        tables.merge(fragment.dispatchTargets) { $0.union($1) }
        let snapshot = SwiftSourceSnapshot.parse(source, path: path, module: module)
        sources[module + ":" + path] = try JSONDecoder().decode(SwiftSourceSnapshot.self, from: JSONEncoder().encode(snapshot))
    }
    let expected: [String: Set<String>] = [
        "Vendor/top()": [], "Vendor/Independent/plainMember()": [],
        "Vendor/Conditional/active()": ["Vendor"], "Vendor/Host/Nested/inner()": ["Vendor"], "Vendor/OptionalSuite/ordinary()": [],
        "Vendor/Live/real()": ["Vendor"], "Vendor/Common/decorated()": ["Vendor"], "Client/Common/plain()": [], "Client/Decorated/local()": ["Client"],
        "Client/Extended/localMember()": ["Client"], "Client/Extended/member()": ["Vendor"], "Client/Extended/parameterized(value:)": ["Vendor"],
        "Client/own()": ["Client"], "Client/imported()": ["Vendor"], "Client/both()": ["Client", "Vendor"]
    ]
    XcodeCompilerGraph.resolveDispatch(&graph, tables: tables, compiler: compiler)
    XcodeCompilerGraph.bind(tests: Array(expected.keys), modules: ["Client": "Client", "Vendor": "Vendor"], sources: sources, graph: &graph)
    for test in ["Client/Common/plain()", "Vendor/top()", "Vendor/Independent/plainMember()", "Vendor/OptionalSuite/ordinary()"] {
        #expect(graph.testDiagnostics[test] == [SwiftTestingDiscoveryRoots.unresolvedEffects])
    }
    let register = try #require(graph.functions.values.first { $0.module == "Vendor" && $0.name == "register()" })
    #expect(graph.dependencyPath(from: graph.tests["Client/Common/plain()"] ?? [], to: [register.id]) != nil)
    let activeSuite = try #require(graph.functions.values.first { $0.module == "Vendor" && $0.swiftTestingFactoryType == "Common" &&
        $0.compilerReferences?.contains(where: { $0.hasPrefix("$s7Testing4TestV6__type") }) == true })
    var incomplete = DependencyGraph(functions: graph.functions.filter { $0.key != activeSuite.id })
    XcodeCompilerGraph.resolveDispatch(&incomplete, tables: tables, compiler: compiler)
    XcodeCompilerGraph.bind(tests: Array(expected.keys), modules: ["Client": "Client", "Vendor": "Vendor"], sources: sources, graph: &incomplete)
    #expect(incomplete.testDiagnostics["Vendor/top()"]?.contains(SwiftTestingDiscoveryRoots.missingEvidence) == true)
    for module in ["Client", "Vendor"] {
        let hook = try #require(graph.functions.values.first { $0.module == module && $0.name == "hook()" })
        let paths = DependencyIndex(graph).paths(to: [hook.id])
        for (test, modules) in expected {
            let roots = try #require(graph.tests[test])
            #expect(!roots.isEmpty, "\(test)")
            #expect((paths.path(from: roots) != nil) == modules.contains(module), "\(test) to \(module).hook")
        }
    }
}

@Test func opaqueLibraryDiscoveryKeepsFailingSibling() throws {
    try verifyDiscoveryEdit(scenario: "externalWitness")
}

@Test func linkedArchiveSuiteKeepsFailingSibling() throws {
    try verifyDiscoveryEdit(scenario: "linkedSuite")
}

@Test(arguments: ["conditionalSuite", "conditionalSuiteHelper"])
func deferredSuiteConditionSelectsItsMember(scenario: String) throws {
    try verifyDiscoveryEdit(scenario: scenario)
}

@Test(arguments: ["display", "firstName", "firstSerializedName", "serializedName", "customSerializedName", "condition", "displayAndCondition", "eagerReason", "customCondition"])
func suiteRegistrationArgumentsFollowTheirEvaluationScope(scenario: String) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let compiler = try CommandRunner.run("xcrun", ["--find", "swiftc"], at: root).text.trimmingCharacters(in: .whitespacesAndNewlines)
    let plugins = URL(fileURLWithPath: compiler).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("lib/swift/host/plugins/testing")
    let plain = "UI/Common/plain()", members = ["UI/Other/marked()", "UI/Other/Child/nested()"]
    func capture(_ flag: Bool) throws -> XcodeTestGraph {
        let display = flag ? "\"Old\"" : "\"New\""
        let condition = ".enabled(if: \(flag))"
        let arguments: String?
        switch scenario {
        case "display": arguments = display
        case "firstName": arguments = flag ? nil : display
        case "firstSerializedName": arguments = flag ? ".serialized" : display + ", .serialized"
        case "serializedName": arguments = display + ", .serialized"
        case "customSerializedName": arguments = display + ", ParallelizationTrait.serialized"
        case "condition": arguments = condition
        case "displayAndCondition": arguments = display + ", " + condition
        case "eagerReason": arguments = ".enabled(if: true, reason(\(flag)))"
        default: arguments = ".enabled(if: \(flag ? 1 : 0))"
        }
        let source = """
            import Foundation
            import Testing
            func reason(_ flag: Bool) -> Comment {
                UserDefaults.standard.set(flag, forKey: "suite-registration")
                return "reason"
            }
            struct Marker: SuiteTrait {}
            extension Trait where Self == Marker {
                static func enabled(if value: Int) -> Self { _ = reason(value == 1); return Marker() }
            }
            struct Common {
                @Test func plain() {}
            }
            \(scenario == "customSerializedName" ? "struct ParallelizationTrait: SuiteTrait { static var serialized: Self { _ = reason(true); return Self() } }" : "")
            @Suite\(arguments.map { "(" + $0 + ")" } ?? "") struct Other {
                @Test func marked() {}
                struct Child { @Test func nested() {} }
            }
            """
        var graph = try boundaryGraph(["Tests.swift": source], tests: [plain] + members, root: root,
                                      compilerArguments: ["-plugin-path", plugins.path], allowTestDiagnostics: true, compiler: compiler)
        graph.mappings = nil
        return try GraphArchive.decode(GraphArchive.encode(graph))
    }
    var base = try capture(true), head = try capture(false)
    let changes = [FileChange(path: "Tests.swift")]
    func dual() -> ImpactReport { XcodeFineSelector.select(current: head, previous: base, changes: changes, baseRevision: "base") }
    func headOnly() -> ImpactReport {
        XcodeHeadOnlySelector.select(current: head, source: .init(base: base.sources), changes: changes, baseRevision: "base")
    }
    if ["eagerReason", "customCondition", "customSerializedName"].contains(scenario) {
        for report in [dual(), headOnly()] {
            #expect(report.explanations.contains { $0.test == plain && $0.kind == "dependency" && $0.path.contains("Testing.discovery in UI") })
        }
    } else {
        for report in [dual(), headOnly()] { #expect(report.selectedTests == members.sorted()) }
        if scenario == "firstSerializedName" {
            swap(&base, &head)
            for report in [dual(), headOnly()] { #expect(report.selectedTests == members.sorted()) }
        }
        if scenario == "display" {
            let mapping = UIFeatureMappings(version: 2, features: [
                .init(name: "suite registration", tests: [plain], when: .sourceChanged("Tests.swift"))
            ])
            base.mappings = mapping
            head.mappings = mapping
            let report = dual()
            #expect(report.selectedTests == ([plain] + members).sorted())
            let decisions = try #require(report.uiConditionDecisions)
            #expect(Set(decisions.map(\.revision)) == ["base", "head"])
            #expect(decisions.allSatisfy { $0.result.status == .matched })
            #expect(report.explanations.contains { $0.test == plain && $0.kind == "explicitCondition" })
        }
        if scenario == "condition" || scenario == "serializedName" {
            // Older captures lack suite argument evidence. Each selector must keep
            // shared coverage when the revision it relies on lacks the proof.
            let id = try #require(head.dependencies?.functions.values.first {
                $0.swiftTestingFactoryType == "Other" && (scenario == "condition"
                    ? $0.swiftTestingDeferredConditions?.predicates == [0: "enabled"]
                    : $0.swiftTestingDeferredConditions?.serializedSlots == [0])
            }?.id)
            func discardProof(in snapshot: inout XcodeTestGraph) {
                if scenario == "serializedName" {
                    snapshot.dependencies?.functions[id]?.swiftTestingDeferredConditions?.serializedSlots = nil
                } else { snapshot.dependencies?.functions[id]?.swiftTestingDeferredConditions = nil }
            }
            discardProof(in: &base)
            #expect(dual().selectedTests.contains(plain))
            discardProof(in: &head)
            #expect(headOnly().selectedTests.contains(plain))
        }
    }
}

@Test(arguments: ["@Suite", "@Suite(\"Inventory\")", "@Suite(Marker(#fileID))"])
func movedSuiteRegistrationUsesItsRevisionPaths(attribute: String) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let compiler = try CommandRunner.run("xcrun", ["--find", "swiftc"], at: root).text.trimmingCharacters(in: .whitespacesAndNewlines)
    let plugins = URL(fileURLWithPath: compiler).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("lib/swift/host/plugins/testing")
    let plain = "UI/Common/plain()", marked = "UI/Other/marked()"
    func capture(_ path: String) throws -> XcodeTestGraph {
        let files = [path: "import Testing\n\(attribute) struct Other {}", "Tests.swift": """
            import Foundation
            import Testing
            struct Common { @Test func plain() {} }
            extension Other { @Test func marked() {} }
            struct Marker: SuiteTrait {
                init(_ file: String) { UserDefaults.standard.set(file, forKey: "suitePath") }
            }
            """]
        return try boundaryGraph(files, tests: [plain, marked], root: root, compilerArguments: ["-plugin-path", plugins.path],
                                 allowTestDiagnostics: true, compiler: compiler)
    }
    let oldPath = "Before.swift", newPath = "After.swift"
    var base = try capture(oldPath), head = try capture(newPath)
    var change = FileChange(path: newPath)
    change.previousPath = oldPath
    change.isPureMove = true
    func select() -> ImpactReport {
        XcodeFineSelector.select(current: head, previous: base, changes: [change], baseRevision: "base")
    }
    let report = select()
    if attribute.contains("Marker") {
        #expect(report.explanations.contains { $0.test == plain && $0.kind == "dependency" && $0.path.contains("Testing.discovery in UI") })
        return
    }
    #expect(report.selectedTests == [marked])
    #expect(report.explanations.contains { $0.test == marked && $0.reason == "Swift Testing suite metadata changed" })
    let mappings = UIFeatureMappings(version: 2, features: [oldPath, newPath].map {
        .init(name: $0, tests: [plain], when: .sourceChanged($0))
    })
    base.mappings = mappings
    head.mappings = mappings
    let mapped = select()
    #expect(mapped.selectedTests == [plain, marked])
    let decisions = try #require(mapped.uiConditionDecisions)
    for path in [oldPath, newPath] {
        let matches = decisions.filter { $0.feature == path }
        #expect(Set(matches.map(\.revision)) == ["base", "head"])
        #expect(matches.allSatisfy { $0.result.status == .matched && $0.result.changes == [(path == oldPath ? "base:" : "head:") + path] })
    }
}

@Test(arguments: [false, true])
func discoveryCommentChangesMatchTheirRevisionPaths(moved: Bool) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let compiler = try CommandRunner.run("xcrun", ["--find", "swiftc"], at: root).text.trimmingCharacters(in: .whitespacesAndNewlines)
    let plugins = URL(fileURLWithPath: compiler).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("lib/swift/host/plugins/testing")
    let mapped = "UI/MappedCase/testMapped()"
    func capture(path: String, comment: String) throws -> XcodeTestGraph {
        let files = [path: """
            import Testing
            @Suite actor Other {
                /// \(comment)
                @Test func marked() { #expect(Test.current?.comments.first?.rawValue == "/// Old") }
            }
            """, "Mapped.swift": "import XCTest\nfinal class MappedCase: XCTestCase { func testMapped() {} }"]
        var graph = try boundaryGraph(files, tests: [mapped, "UI/Other/marked()"], root: root,
                                      compilerArguments: ["-plugin-path", plugins.path], allowTestDiagnostics: true, compiler: compiler)
        graph.mappings = UIFeatureMappings(version: 2, features: [
            .init(name: "registration", tests: [mapped], when: .sourceChanged("*Suite.swift"))
        ])
        return graph
    }
    let oldPath = "OldSuite.swift", newPath = moved ? "NewSuite.swift" : oldPath
    let base = try capture(path: oldPath, comment: "Old"), head = try capture(path: newPath, comment: "New")
    var change = FileChange(path: newPath)
    if moved { change.previousPath = oldPath }
    let report = XcodeFineSelector.select(current: head, previous: base, changes: [change], baseRevision: "base")
    #expect(report.selectedTests.contains(mapped))
    #expect(report.explanations.contains { $0.test == mapped && $0.kind == "explicitCondition" })
    let decisions = try #require(report.uiConditionDecisions)
    #expect(Set(decisions.map(\.revision)) == ["base", "head"])
    for decision in decisions {
        #expect(decision.result.status == .matched)
        #expect(decision.result.changes == ["base:" + oldPath, "head:" + newPath])
    }
}

@Test(arguments: ["fileMove", "line", "defaultLine", "actor", "display", "annotatedDisplay", "providers",
                  "sdkLocation", "binaryDefault", "escaped", "qualified", "mixedProvider", "mixedTrait",
                  "comments", "bareLocation", "helperLocation", "enabled", "disabled", "mixedCondition", "customCondition",
                  "physical", "providerHelper", "gateHelper", "transparent", "suiteBody", "documented", "reason", "qualifiedGate", "eagerReason",
                  "opaqueCallback", "wrappedCallback", "selectorCallback", "keyValueCallback", "predicateLookup", "collectionPredicate", "expressionLookup", "sortedLookup", "interpolation", "containsWitness", "descriptionWitness", "erasedDescription", "selectorResolution", "destruction", "unusedDestructor", "namedUnusedDestructor", "staticClassMetadata", "projectValue", "selectorQuery", "privateBesideNamedTest", "retainedV12", "privateBesideTest", "namedSuite", "docSuite", "serializedSuite", "unusedInline", "privateInline", "fileprivateInline", "localCall"])
func swiftTestingDiscoveryEditsReachTheirConsumers(scenario: String) throws {
    try verifyDiscoveryEdit(scenario: scenario)
}

private func verifyDiscoveryEdit(scenario: String) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let discoveryKey = "registration-" + UUID().uuidString
    let compiler = try CommandRunner.run("xcrun", ["--find", "swiftc"], at: root).text.trimmingCharacters(in: .whitespacesAndNewlines)
    let plugins = URL(fileURLWithPath: compiler).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("lib/swift/host/plugins/testing")
    let plain = "UI/Common/plain()"
    let parameterized = ["providerHelper", "providers", "mixedProvider", "mixedTrait"].contains(scenario)
    let marked = parameterized ? "UI/Other/marked(value:)" :
        (scenario == "actor" ? "UI/Outer/Other/marked()" : "UI/Other/marked()")
    var flags = ["-plugin-path", plugins.path]
    var runtimeFlags: [String] = []
    var linkArguments: [String] = []
    let helperEdits = ["helperLocation", "providerHelper", "gateHelper", "transparent"]
    let unusedBodies = ["unusedInline", "privateInline", "fileprivateInline", "privateBesideTest", "privateBesideNamedTest"]
    let keyValueReads = ["keyValueCallback": "Settings().value(forKey: \"selected\") as? Bool == true",
                         "predicateLookup": "NSPredicate(format: \"selected == YES\").evaluate(with: Settings())",
                         "collectionPredicate": "NSArray(object: Settings()).filtered(using: NSPredicate(format: \"selected == YES\")).count == 1",
                         "expressionLookup": "NSExpression(forKeyPath: \"selected\").expressionValue(with: Settings(), context: nil) as? Bool == true"]
    let callbacks = ["sortedLookup", "interpolation", "containsWitness", "externalWitness", "linkedSuite", "opaqueCallback", "wrappedCallback", "selectorCallback", "selectorResolution", "erasedDescription"] + Array(keyValueReads.keys)
    let predicateEdits = ["enabled", "disabled", "mixedCondition", "documented", "reason", "qualifiedGate"]
    let suiteBodies = ["suiteBody", "retainedV12", "namedSuite", "docSuite", "serializedSuite", "conditionalSuite", "conditionalSuiteHelper"]
    let localEdits = suiteBodies + ["selectorQuery", "projectValue", "comments", "bareLocation", "physical", "providerHelper", "gateHelper"] + predicateEdits
    if ["binaryDefault", "externalWitness", "linkedSuite"].contains(scenario) || helperEdits.contains(scenario) {
        // The selector cannot discover this default by indexing project sources.
        let vendor = root.appendingPathComponent("BinaryLocation.swift")
        let vendorSource = scenario == "linkedSuite" ? """
            import Testing
            import Foundation
            @_silgen_name("sts_registration_flag") func clientFlag() -> Int32
            struct Marker: SuiteTrait {
                init() { UserDefaults.standard.set(clientFlag() == 1, forKey: "\(discoveryKey)") }
            }
            @Suite(Marker()) struct ImportedSuite {}
            """ : """
            public func callerLine(_ x: Int = #line) -> Int { x }
            public protocol Probe { func visit() }
            public func inspect<T: Probe>(_ value: T) { value.visit() }
            """
        try Data(vendorSource.utf8).write(to: vendor)
        let archive = root.appendingPathComponent("libBinaryLocation.a")
        let architecture = try CommandRunner.run("uname", ["-m"], at: root).text.trimmingCharacters(in: .whitespacesAndNewlines)
        let platform = try CommandRunner.run("xcrun", ["--sdk", "macosx", "--show-sdk-platform-path"], at: root).text.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try CommandRunner.run("xcrun", ["swiftc", "-plugin-path", plugins.path, "-F", platform + "/Developer/Library/Frameworks", "-target", architecture + "-apple-macosx13.0", "-emit-library", "-static",
            "-emit-module", "-module-name", "BinaryLocation", vendor.path, "-o", archive.path], at: root)
        flags += ["-I", root.path]
        linkArguments = scenario == "linkedSuite" ? ["-Xlinker", "-force_load", "-Xlinker", archive.path] : ["-Xlinker", archive.path]
        runtimeFlags = ["-Xswiftc", "-I", "-Xswiftc", root.path] + linkArguments
    }
    func verifyRuntime(_ files: [String: String], head: Bool) throws {
        let package = root.appendingPathComponent("Runtime")
        let tests = package.appendingPathComponent("Tests/RegistrationTests")
        try FileManager.default.createDirectory(at: tests, withIntermediateDirectories: true)
        let manifest = """
            // swift-tools-version: 6.0
            import PackageDescription
            let package = Package(name: "Runtime", platforms: [.macOS(.v13)], targets: [.testTarget(name: "RegistrationTests")])
            """
        try Data(manifest.utf8).write(to: package.appendingPathComponent("Package.swift"))
        for (name, text) in files { try Data(text.utf8).write(to: tests.appendingPathComponent(name)) }
        let method = (localEdits + ["providers", "mixedProvider"]).contains(scenario) ? "marked" : "plain"
        let run = try CommandRunner.run("xcrun", ["swift", "test", "--filter", method] + runtimeFlags, at: package, allowFailure: true)
        let output = String(decoding: run.stdout + run.stderr, as: UTF8.self)
        try #require((run.status == 0) == !head, "\(output)")
        let outcome = head ? "failed" : ((predicateEdits + ["gateHelper", "conditionalSuiteHelper"]).contains(scenario) ? "skipped" : "passed")
        try #require(output.components(separatedBy: .newlines).contains {
            $0.contains("Test " + method + "(") && $0.contains(outcome)
        }, "\(output)")
    }
    func capture(head: Bool) throws -> XcodeTestGraph {
        let suiteTrait = keyValueReads[scenario] != nil || ["destruction", "selectorResolution", "sortedLookup", "interpolation", "containsWitness", "descriptionWitness", "erasedDescription"].contains(scenario)
        var files = ["Support.swift": """
            import Foundation
            import Testing
            struct Marker: \(suiteTrait ? "SuiteTrait" : "TestTrait") {
                init(_ flag: Bool) { UserDefaults.standard.set(flag, forKey: "\(discoveryKey)") }
            }
            struct Common {
                @Test func plain() { #expect(UserDefaults.standard.bool(forKey: "\(discoveryKey)")) }
            }
            """]
        if !suiteTrait && scenario != "actor" && !suiteBodies.contains(scenario) { files["Support.swift"]! += "\nstruct Other {}" }
        switch scenario {
        case "physical":
            files["Tests.swift"] = "import Testing\nextension Other {\n" + (head ? "\n" : "") +
                "#sourceLocation(file: \"Virtual.swift\", line: 101)\n@Test func marked() { #expect(Test.current!.sourceLocation.line == 4) }\n#sourceLocation()\n}"
        case "linkedSuite":
            files["Helper.swift"] = "@_cdecl(\"sts_registration_flag\") public func bridge() -> Int32 { flag() }\nfunc flag() -> Int32 { " + (head ? "0" : "1") + " }"
            files["Tests.swift"] = "import Testing\n@Suite(.serialized) struct Other { @Test func marked() {} }"
            files["Support.swift"] = "import Testing\nimport Foundation\nstruct Common { @Test func plain() { #expect(UserDefaults.standard.bool(forKey: \"\(discoveryKey)\")) } }"
        case "externalWitness":
            // Only the binary knows that its generic parameter receives a callback.
            // The local graph contains the conformance but no call to its witness.
            files["Support.swift"] = """
                import Testing
                import Foundation
                struct Common { @Test func plain() { #expect(UserDefaults.standard.bool(forKey: "\(discoveryKey)")) } }
                """
            files["Helper.swift"] = "func flag() -> Bool { " + (head ? "false" : "true") + " }"
            files["Lookup.swift"] = """
                import BinaryLocation
                import Testing
                import Foundation
                struct Observer: Probe { func visit() { UserDefaults.standard.set(flag(), forKey: "\(discoveryKey)") } }
                struct Marker: SuiteTrait { init() { inspect(Observer()) } }
                """
            files["Tests.swift"] = "import Testing\n@Suite(Marker()) struct Other { @Test func marked() {} }"
        case "opaqueCallback":
            files["Helper.swift"] = "@_cdecl(\"sts_registration_flag\") public func bridge() -> Int32 { flag() }\nfunc flag() -> Int32 { " + (head ? "0" : "1") + " }"
            files["Tests.swift"] = """
                import Darwin
                import Testing
                extension Other {
                    @Test(Marker(unsafeBitCast(dlsym(UnsafeMutableRawPointer(bitPattern: -2), "sts_registration_flag")!, to: (@convention(c) () -> Int32).self)() == 1))
                    func marked() {}
                }
                """
        case "sortedLookup", "interpolation", "containsWitness", "keyValueCallback", "destruction", "predicateLookup", "collectionPredicate", "expressionLookup", "selectorResolution", "descriptionWitness", "erasedDescription":
            files["Helper.swift"] = "func flag() -> Bool { " + (head ? "false" : "true") + " }"
            if let read = keyValueReads[scenario] {
                files["Lookup.swift"] = """
                    import Foundation
                    final class Settings: NSObject { @objc dynamic var selected: Bool { flag() } }
                    func resolveFlag() -> Bool { \(read) }
                    """
            } else if scenario == "sortedLookup" {
                files["Lookup.swift"] = """
                    import Foundation
                    final class Settings: NSObject {
                        let index: Int
                        init(_ index: Int) { self.index = index }
                        @objc dynamic var rank: Int { flag() ? index : -index }
                    }
                    func resolveFlag() -> Bool {
                        let first = Settings(1), second = Settings(2)
                        let sorted = NSArray(array: [second, first]).sortedArray(using: [NSSortDescriptor(key: "rank", ascending: true)])
                        return sorted.first as? Settings === first
                    }
                    """
            } else if scenario == "containsWitness" {
                files["Lookup.swift"] = """
                    struct Settings: Equatable { static func == (_ lhs: Self, _ rhs: Self) -> Bool { flag() } }
                    func resolveFlag() -> Bool { [Settings()].contains(Settings()) }
                    """
            } else if scenario == "interpolation" {
                files["Lookup.swift"] = #"""
                    struct Settings: CustomStringConvertible { var description: String { flag() ? "yes" : "no" } }
                    func resolveFlag() -> Bool { "\(Settings())" == "yes" }
                    """#
            } else if ["descriptionWitness", "erasedDescription"].contains(scenario) {
                let value = scenario == "erasedDescription" ? "Settings() as Any" : "Settings()"
                files["Lookup.swift"] = """
                    struct Settings: CustomStringConvertible { var description: String { flag() ? "yes" : "no" } }
                    func resolveFlag() -> Bool { String(describing: \(value)) == "yes" }
                    """
            } else if scenario == "selectorResolution" {
                files["Lookup.swift"] = """
                    import Foundation
                    final class Settings: NSObject {
                        override class func resolveInstanceMethod(_ sel: Selector!) -> Bool {
                            if NSStringFromSelector(sel) == "stsMissingPermission" {
                                setenv("STS_RESOLVED", flag() ? "1" : "0", 1)
                            }
                            return super.resolveInstanceMethod(sel)
                        }
                    }
                    func resolveFlag() -> Bool {
                        _ = Settings().responds(to: NSSelectorFromString("stsMissingPermission"))
                        _ = NSObject().responds(to: NSSelectorFromString("description"))
                        return getenv("STS_RESOLVED")?.pointee == 49
                    }
                    """
            } else {
                files["Lookup.swift"] = """
                    import Darwin
                    final class Token { deinit { setenv("STS_DEINIT_FLAG", flag() ? "1" : "0", 1) } }
                    @inline(never) func consumeToken() { _ = Token() }
                    func resolveFlag() -> Bool { consumeToken(); return getenv("STS_DEINIT_FLAG")?.pointee == 49 }
                    """
            }
            files["Tests.swift"] = "import Testing\n@Suite(Marker(resolveFlag())) struct Other { @Test func marked() {} }"
        case "unusedDestructor", "namedUnusedDestructor", "staticClassMetadata":
            files["Helper.swift"] = "func flag() -> Bool { " + (head ? "false" : "true") + " }"
            files["Lookup.swift"] = "private final class Token { deinit { _ = flag() } }"
            files["Support.swift"] = "import Testing\nstruct Common { @Test func plain() {} }"
            let attribute = scenario == "namedUnusedDestructor" ? "@Test(\"Simple display name\")" : "@Test"
            let declaration = scenario == "staticClassMetadata" ? "final class Other { @Test static" : "struct Other { " + attribute
            files["Tests.swift"] = "import Testing\n" + declaration + " func marked() {} }"
        case "selectorQuery", "projectValue":
            let lookup = scenario == "selectorQuery" ? "NSObject().responds(to: NSSelectorFromString(\"description\"))" : "Counter().value(\"key\")"
            files["Support.swift"] = """
                import Foundation
                import Testing
                struct Marker: SuiteTrait { let enabled: Bool }
                final class Counter: NSObject { @objc dynamic func value(_ key: String) -> Bool { true } }
                func resolveFlag() -> Bool { \(lookup) }
                struct Common { @Test func plain() {} }
                """
            files["Tests.swift"] = "import Testing\n@Suite(Marker(enabled: resolveFlag())) struct Other { @Test func marked() { " +
                (head ? "#expect(Bool(false))" : "") + " } }"
        case "selectorCallback":
            files["Helper.swift"] = "func flag() -> Bool { " + (head ? "false" : "true") + " }"
            files["Support.swift"] = "import Foundation\nimport Testing\nstruct Common { @Test func plain() { #expect(UserDefaults.standard.bool(forKey: \"\(discoveryKey)\")) } }"
            files["Lookup.swift"] = """
                import Foundation
                import Testing
                final class Observer: NSObject {
                    @objc func record(_ notification: Notification) {
                        UserDefaults.standard.set(flag(), forKey: "\(discoveryKey)")
                    }
                }
                struct Marker: SuiteTrait {
                    init() {
                        let target = Observer()
                        let center = NotificationCenter()
                        let event = Notification.Name("ready")
                        center.addObserver(target, selector: #selector(Observer.record(_:)), name: event, object: nil)
                        center.post(name: event, object: nil)
                        withExtendedLifetime(target) {}
                    }
                }
                """
            files["Tests.swift"] = "import Testing\n@Suite(Marker()) struct Other { @Test func marked() {} }"
        case "wrappedCallback":
            files["Helper.swift"] = """
                import Darwin
                import Testing
                struct Callback {
                    @Test func update() { setenv("STS_REGISTRATION_FLAG", "\(head ? "0" : "1")", 1) }
                }
                """
            files["Lookup.swift"] = """
                import Darwin
                @_cdecl("sts_registration_flag") public func bridge() -> Int32 {
                    Callback().update()
                    return getenv("STS_REGISTRATION_FLAG").map { String(cString: $0) == "1" } == true ? 1 : 0
                }
                func readFlag() -> Bool {
                    let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "sts_registration_flag")!
                    return unsafeBitCast(symbol, to: (@convention(c) () -> Int32).self)() == 1
                }
                """
            files["Tests.swift"] = "import Testing\nextension Other { @Test(Marker(readFlag())) func marked() {} }"
        case "unusedInline", "privateInline", "fileprivateInline", "privateBesideTest", "privateBesideNamedTest", "localCall":
            let assertion = scenario == "localCall" ? "#expect(helper())" : ""
            files["Support.swift"] = "import Testing\nstruct Common { @Test func plain() { " + assertion + " } }"
            files["Tests.swift"] = "import Testing\nstruct Other { @Test func marked() { " + assertion + " } }"
            if scenario == "localCall" {
                files["Helper.swift"] = "func yes() -> Bool { true }\nfunc helper() -> Bool {\n" + (head ? "    " : "  ") + "return yes()\n}"
            } else {
                let modifiers = ["privateInline": "@inline(__always) private", "privateBesideTest": "@inline(__always) private", "privateBesideNamedTest": "@inline(__always) private", "fileprivateInline": "@inline(__always) fileprivate"]
                files["Helper.swift"] = (modifiers[scenario] ?? "@inlinable") + " func unused() -> Bool { " + (head ? "false" : "true") + " }"
                if ["privateBesideTest", "privateBesideNamedTest"].contains(scenario) {
                    let attribute = scenario == "privateBesideNamedTest" ? "@Test(\"Named test\")" : "@Test"
                    files["Helper.swift"] = "import Testing\n" + files["Helper.swift"]! + "\nstruct Other { " + attribute + " func marked() {} }"
                    files.removeValue(forKey: "Tests.swift")
                }
                if modifiers[scenario] != nil { files["Unrelated.swift"] = "import Darwin\nprivate func unused() {}" }
            }
        case "conditionalSuiteHelper":
            files["Helper.swift"] = "func suiteGate() -> Bool { " + (head ? "true" : "false") + " }"
            files["Tests.swift"] = "import Testing\n@Suite(.enabled(if: suiteGate())) struct Other { @Test func marked() { #expect(Bool(false)) } }"
        case "suiteBody", "retainedV12", "namedSuite", "docSuite", "serializedSuite", "conditionalSuite":
            let suite = ["namedSuite": "@Suite(\"Other tests\")", "docSuite": "/// Other tests\n@Suite", "serializedSuite": "@Suite(.serialized)", "conditionalSuite": "@Suite(.enabled(if: true))"][scenario] ?? "@Suite"
            files["Tests.swift"] = "import Testing\n" + suite + " struct Other {\n@Test func marked() {\n" +
                (head ? "#expect(Bool(false))\n" : "") + "}\n}"
        case "providerHelper", "gateHelper", "transparent":
            files["Helper.swift"] = "import BinaryLocation\n" + (head ? "\n" : "") +
                (scenario == "transparent" ? "@_transparent " : "") + "func flag() -> Bool { callerLine() == 2 }"
            let declaration: String
            switch scenario {
            case "providerHelper": declaration = "@Test(arguments: [flag()]) func marked(value: Bool) { #expect(value) }"
            case "gateHelper": declaration = "@Test(.disabled(if: flag())) func marked() { #expect(Bool(false)) }"
            default: declaration = "@Test(Marker(flag())) func marked() {}"
            }
            files["Tests.swift"] = "import Testing\nextension Other { " + declaration + " }"
        case "eagerReason":
            files["Support.swift"]! += "\nfunc reason(_ flag: Bool) -> Comment { _ = Marker(flag); return \"reason\" }"
            files["Tests.swift"] = "import Testing\nextension Other { @Test(.enabled(if: true, reason(\(!head)))) func marked() {} }"
        case "comments":
            files["Tests.swift"] = "import Testing\nextension Other {\n/// \(head ? "STOP" : "PASS")\n" +
                "@Test func marked() { #expect(Test.current!.comments.contains { $0.rawValue.contains(\"PASS\") }) }\n}"
        case "bareLocation":
            files["Tests.swift"] = "import Testing\nextension Other {\n" + (head ? "\n" : "") +
                "@Test func marked() { #expect(Test.current!.sourceLocation.line == 3) }\n}"
        case "helperLocation":
            files["Tests.swift"] = "import Testing\nextension Other { @Test(Marker(flag())) func marked() {} }"
            files["Helper.swift"] = "import BinaryLocation\nfunc flag() -> Bool { inner() }\n" + (head ? "\n" : "") +
                "func inner() -> Bool { callerLine() == 3 }"
        case "enabled", "disabled", "mixedCondition", "documented", "reason", "qualifiedGate":
            let condition = scenario == "disabled" ? "disabled" : "enabled"
            let flag = condition == "enabled" ? head : !head
            let trait = scenario == "mixedCondition" ? "Marker(true), " : ""
            let qualifier = scenario == "qualifiedGate" ? "Testing.ConditionTrait" : ""
            let reason = scenario == "reason" ? ", \"feature gate\"" : ""
            let comment = scenario == "documented" ? "/// Explains the gate\n" : ""
            files["Tests.swift"] = "import Testing\nextension Other {\n\(comment)@Test(\(trait)\(qualifier).\(condition)(if: \(flag)\(reason))) func marked() { #expect(Bool(false)) }\n}"
        case "customCondition":
            files["Support.swift"]! += "\nextension Trait where Self == Marker { static func enabled(if value: Int) -> Self { Marker(value == 1) } }"
            files["Tests.swift"] = "import Testing\nextension Other { @Test(.enabled(if: \(head ? 0 : 1))) func marked() {} }"
        case "fileMove":
            for (file, value) in [("First.swift", true), ("Second.swift", false)] {
                let method = value != head ? "@Test(Marker(flag())) func marked() {}" : ""
                files[file] = "import Testing\nprivate func flag() -> Bool { \(value) }\nextension Other {\n\(method)\n}"
            }
        case "actor":
            files["Tests.swift"] = "import Testing\nstruct Outer { actor Other { @Test(Marker(\(!head))) func marked() {} } }"
        case "providers", "mixedProvider", "mixedTrait":
            let trait = scenario == "providers" ? "" : "Marker(\(scenario != "mixedTrait" || !head)), "
            let value = head && scenario != "mixedTrait" ? 0 : 1
            files["Tests.swift"] = "import Testing\nextension Other { @Test(\(trait)arguments: [\(value)]) func marked(value: Int) { #expect(value > 0) } }"
        case "escaped", "qualified":
            let name = scenario == "escaped" ? "`Test`" : "Testing /* module */ .Test"
            files["Tests.swift"] = "import Testing\nextension Other { @\(name)(Marker(\(!head))) func marked() {} }"
        case "sdkLocation", "binaryDefault":
            let prefix = scenario == "binaryDefault" ? "import BinaryLocation" : "// SDK macro"
            let expression = scenario == "binaryDefault" ? "callerLine()" : "(#_sourceLocation).line"
            files["Tests.swift"] = "import Testing\n" + prefix + "\nextension Other {\n" + (head ? "\n" : "") +
                "@Test(Marker(\(expression) == 4)) func marked() {}\n}"
        case "display", "annotatedDisplay":
            let isolation = scenario == "display" ? "" : "@MainActor "
            files["Tests.swift"] = "import Testing\nextension Other { \(isolation)@Test(\"\(head ? "New" : "Old")\") static func marked() {} }"
        default:
            let location = scenario == "line" ? "#line" : "readLine()"
            files["Tests.swift"] = "import Testing\nfunc readLine(_ value: Int = #line) -> Int { value }\nextension Other {\n" +
                (head ? "\n" : "") + "@Test(Marker(\(location) == 4)) func marked() {}\n}"
        }
        if (localEdits + helperEdits + callbacks + ["destruction", "descriptionWitness", "sdkLocation", "binaryDefault", "escaped", "qualified", "customCondition", "eagerReason"]).contains(scenario) || parameterized {
            try verifyRuntime(files, head: head)
        }
        var inventory = [plain, marked]
        if scenario == "wrappedCallback" { inventory.append("UI/Callback/update()") }
        if ["externalWitness", "linkedSuite"].contains(scenario) {
            files["Independent.swift"] = "import XCTest\nfinal class Independent: XCTestCase { func testSeparate() {} }"
            inventory.append("UI/Independent/testSeparate()")
        }
        var graph = try boundaryGraph(files, tests: inventory, root: root, compilerArguments: flags, allowTestDiagnostics: true,
                                      compiler: compiler, allowedUnbound: scenario == "physical" ? [marked] : [], linkArguments: linkArguments)
        #expect((graph.dependencies?.swiftTestingFactoriesByTarget?["UI"] != nil) == (scenario != "linkedSuite"))
        graph.mappings = nil
        if scenario == "retainedV12" {
            for key in Array(graph.sources.keys) { graph.sources[key]?.parserVersion = 12 }
        }
        return try GraphArchive.decode(GraphArchive.encode(graph))
    }
    var base = try capture(head: false), head = try capture(head: true)
    let changes = (scenario == "fileMove" ? ["First.swift", "Second.swift"] : [(helperEdits + unusedBodies + callbacks + ["conditionalSuiteHelper", "descriptionWitness", "destruction", "unusedDestructor", "namedUnusedDestructor", "staticClassMetadata", "localCall"]).contains(scenario) ? "Helper.swift" : "Tests.swift"]).map { FileChange(path: $0) }
    func dual() -> ImpactReport { XcodeFineSelector.select(current: head, previous: base, changes: changes, baseRevision: "base") }
    if scenario == "conditionalSuiteHelper" {
        let graph = try #require(head.dependencies)
        let gate = try #require(graph.functions.values.first { $0.name == "suiteGate()" })
        for test in [plain, marked] {
            #expect((graph.dependencyPath(from: graph.tests[test] ?? [], to: [gate.id]) != nil) == (test == marked))
        }
    }
    let report = dual()
    let headOnly = XcodeHeadOnlySelector.select(current: head, source: .init(base: base.sources), changes: changes, baseRevision: "base")
    if (unusedBodies + ["unusedDestructor", "namedUnusedDestructor", "staticClassMetadata", "localCall"]).contains(scenario) {
        for result in [report, headOnly] { #expect(result.selectedTests.isEmpty) }
        if ["privateBesideTest", "privateBesideNamedTest"].contains(scenario) {
            for id in head.dependencies!.functions.keys { head.dependencies!.functions[id]?.swiftTestingEmptyFactory = nil }
            #expect(dual().selectedTests.contains(plain))
            let unproven = XcodeHeadOnlySelector.select(current: head, source: .init(base: base.sources), changes: changes, baseRevision: "base")
            #expect(unproven.selectedTests.contains(plain))
        }
    } else if scenario == "descriptionWitness" {
        for result in [report, headOnly] {
            #expect(result.explanations.contains {
                $0.test == plain && $0.kind == "dependency" && $0.path.contains { $0.contains("Settings.description") }
            })
        }
        // Retained graphs without the binding must still select the sibling.
        for id in head.dependencies!.functions.keys { head.dependencies!.functions[id]?.swiftTestingFormattingRequirements = nil }
        let legacy = try GraphArchive.decode(GraphArchive.encode(head))
        #expect(legacy.dependencies?.functions[SwiftTestingDiscoveryRoots.processRoot("UI")]?.hasOpaqueRuntimeDependency == true)
    } else if scenario == "destruction" {
        for result in [report, headOnly] {
            #expect(result.explanations.contains {
                $0.test == plain && $0.kind == "dependency" && $0.path.contains("UI.Token.deinit")
            })
        }
        // Legacy captures had no release-site binding. Discard their derived
        // root edges and keep selection conservative across archive migration.
        let root = SwiftTestingDiscoveryRoots.processRoot("UI")
        let destructors = Set(head.dependencies!.functions.values.filter { $0.name.contains("deinit") }.map(\.id))
        let caller = try #require(head.dependencies!.functions.values.first { $0.name == "consumeToken()" }?.id)
        head.dependencies!.functions[caller]?.dependencies.subtract(destructors)
        head.dependencies!.functions[caller]?.mayDestroyValue = nil
        head.dependencies!.functions[root]?.dependencies.formUnion(destructors)
        for archive in [try GraphArchive.encode(head), try JSONEncoder().encode(head)] {
            let restored = try #require(GraphArchive.decode(archive).dependencies)
            #expect(restored.functions[root]?.hasOpaqueRuntimeDependency == true)
            #expect(restored.functions[root]?.dependencies.isDisjoint(with: destructors) == true)
            #expect(restored.dependencyPath(from: restored.tests[plain] ?? [], to: destructors) == nil)
        }
    } else if callbacks.contains(scenario) {
        for result in [report, headOnly] { #expect(result.selectedTests.contains(plain)) }
        if ["externalWitness", "linkedSuite"].contains(scenario) {
            for result in [report, headOnly] {
                #expect(result.selectedTests == [plain, marked].sorted())
                let shared = result.diagnostics.filter { $0.code == "swift_testing_discovery_effects" }
                #expect(!shared.isEmpty && shared.allSatisfy { $0.tests == [plain, marked].sorted() })
            }
            #expect(headOnly.diagnostics.filter { $0.code == "swift_testing_discovery_effects" }.count == 1)
        }
        // Archives produced before discovery inherited factory uncertainty still
        // contain the original SIL evidence. Restore it during decoding.
        head.dependencies?.functions[SwiftTestingDiscoveryRoots.processRoot("UI")]?.uncertainties = []
        let restored = try GraphArchive.decode(GraphArchive.encode(head))
        #expect(restored.dependencies?.functions[SwiftTestingDiscoveryRoots.processRoot("UI")]?.hasOpaqueRuntimeDependency == true)
    } else if ["mixedCondition", "mixedProvider", "projectValue", "selectorQuery"].contains(scenario) {
        // The edited test is local, but another registration runs UserDefaults
        // or Objective-C code whose callbacks can also consume the edit.
        for result in [report, headOnly] {
            #expect(result.selectedTests == [plain, marked].sorted())
            #expect(result.diagnostics.contains { $0.message.contains(SwiftTestingDiscoveryRoots.unresolvedEffects) && $0.tests.contains(plain) })
        }
    } else if localEdits.contains(scenario) {
        for result in [report, headOnly] {
            if scenario == "physical" {
                #expect(result.selectedTests.contains(marked))
            } else { #expect(result.selectedTests == [marked]) }
        }
        if ["comments", "bareLocation", "physical", "providerHelper", "gateHelper"].contains(scenario) {
            var mappings = UIFeatureMappings(features: [])
            mappings.sourceLocationPolicy = .diagnosticLineColumn
            base.mappings = mappings
            head.mappings = mappings
            let one = XcodeHeadOnlySelector.select(current: head, source: .init(base: base.sources, mappings: mappings),
                                                   changes: changes, baseRevision: "base")
            for result in [dual(), one] { #expect(result.selectedTests == (scenario == "comments" ? [marked] : [])) }
        } else if predicateEdits.contains(scenario) {
            for id in head.dependencies!.functions.keys { head.dependencies!.functions[id]?.swiftTestingDeferredConditions = nil }
            #expect(dual().selectedTests.contains(plain))
            #expect(XcodeHeadOnlySelector.select(current: head, source: .init(base: base.sources), changes: changes,
                                                 baseRevision: "base").selectedTests.contains(plain))
        }
    } else if ["display", "annotatedDisplay", "providers"].contains(scenario) {
        for result in [report, headOnly] {
            #expect(result.selectedTests == [marked])
            if !parameterized { #expect(result.diagnostics.isEmpty) }
        }
        // Discarding the compiler proof restores conservative discovery coverage.
        for id in head.dependencies!.functions.keys {
            head.dependencies!.functions[id]?.swiftTestingEmptyFactory = nil
            head.dependencies!.functions[id]?.swiftTestingDeferredProviderCount = nil
        }
        #expect(dual().selectedTests.contains(plain))
        #expect(XcodeHeadOnlySelector.select(current: head, source: .init(base: base.sources), changes: changes,
                                             baseRevision: "base").selectedTests.contains(plain))
    } else {
        if scenario == "transparent" {
            #expect(report.diagnostics.contains { $0.code == "swift_testing_inline_origin" && $0.tests.contains(plain) })
        } else { #expect(report.explanations.contains { $0.test == plain && $0.kind == "dependency" }) }
        #expect(headOnly.selectedTests.contains(plain))
        if ["line", "defaultLine", "binaryDefault", "sdkLocation", "helperLocation"].contains(scenario) {
            var mappings = UIFeatureMappings(features: [])
            mappings.sourceLocationPolicy = .diagnosticLineColumn
            base.mappings = mappings
            head.mappings = mappings
            #expect(dual().selectedTests.isEmpty)
            let one = XcodeHeadOnlySelector.select(current: head, source: .init(base: base.sources, mappings: mappings),
                                                   changes: changes, baseRevision: "base")
            #expect(one.selectedTests.isEmpty)
        } else if scenario == "escaped" {
            // An unfamiliar source macro may still produce a real SDK factory.
            // Losing that source association must preserve discovery coverage.
            let key = "UI:Tests.swift"
            for i in head.sources[key]!.units.indices { head.sources[key]!.units[i].swiftTestingArguments = nil }
            for i in base.sources[key]!.units.indices { base.sources[key]!.units[i].swiftTestingArguments = nil }
            head.sources[key]?.swiftTestingDeclarations?.tests = []
            base.sources[key]?.swiftTestingDeclarations?.tests = []
            let one = XcodeHeadOnlySelector.select(current: head, source: .init(base: base.sources), changes: changes, baseRevision: "base")
            for result in [dual(), one] {
                #expect(result.diagnostics.contains { $0.code == "incomplete_testing_registration" && $0.tests.contains(plain) })
            }
        } else if scenario == "actor" {
            for key in [String](head.sources.keys) {
                head.sources[key]?.parserVersion = 7
                for i in head.sources[key]!.units.indices {
                    head.sources[key]!.units[i].swiftTestingArguments = nil
                }
            }
            #expect(dual().selectedTests.contains(plain))
        }
    }
}

@Test func discoveryProofRequiresEveryEagerBody() throws {
    let root = SwiftTestingDiscoveryRoots.sharedDiscoveryID
    let sdk = "$s7Testing4TestV6__type"
    var factory = FunctionNode(id: "factory", module: "Local", name: "factory", dependencies: [sdk, "wrapper", "body"])
    factory.compilerReferences = factory.dependencies
    factory.swiftTestingDiscoveryReferences = [sdk, "wrapper"]
    factory.hasModeledDiscoveryInstructions = true
    factory.mayDestroyValue = false
    func graph(leafInstruction: String) -> DependencyGraph {
        let sil = """
            sil @wrapper : $@convention(thin) () -> () {
            bb0:
              %0 = function_ref @leaf : $@convention(thin) () -> ()
              %1 = apply %0() : $@convention(thin) () -> ()
              return %1 : $()
            } // end sil function 'wrapper'
            sil @leaf : $@convention(thin) () -> () {
            bb0:
              %0 = \(leafInstruction)
              return %0 : $()
            } // end sil function 'leaf'
            """
        var result = DependencyGraph(functions: SILParser.parse(sil, module: "Local", sourceRoot: URL(fileURLWithPath: "/")).functions)
        result.functions[factory.id] = factory
        result.functions[root] = FunctionNode(id: root, module: "Testing", name: "discovery", dependencies: ["wrapper", sdk])
        result.swiftTestingLinkedRecordsVerified = true
        result.tests = ["Local/plain()": [root]]
        return result
    }
    func unresolved(_ input: DependencyGraph) -> Bool {
        var graph = input
        SwiftTestingDiscoveryRoots.restoreDiscoveryEffects(&graph)
        return graph.testDiagnostics["Local/plain()"]?.contains(SwiftTestingDiscoveryRoots.unresolvedEffects) == true
    }
    let closed = graph(leafInstruction: "tuple ()")
    #expect(!unresolved(closed)) // The deferred test body needs no discovery proof.
    var legacy = closed
    legacy.swiftTestingLinkedRecordsVerified = nil
    #expect(unresolved(legacy))
    var external = closed
    external.functions.removeValue(forKey: "leaf")
    #expect(unresolved(external))
    #expect(unresolved(graph(leafInstruction: "unmodeled_operation $()")))
}
