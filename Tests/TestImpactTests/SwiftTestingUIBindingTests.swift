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
    var reference: DependencyGraph?
    for workers in [1, 2] {
        let scratch = root.appendingPathComponent("extract-\(workers)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        var graph = XcodeCompilerGraph.extract(log: log, sourceRoot: root, directory: root, derived: scratch,
            progress: { _ in }, ownership: ["Tests": ["Tests.swift"]], workers: workers)
        #expect(graph.diagnostics.isEmpty)
        #expect(graph.functions.values.compactMap(\.swiftTestingEmptyFactory).sorted() == ["member", "top-level"])
        let suite = try #require(graph.functions.values.first { $0.swiftTestingFactoryType == "OtherSuite" })
        let member = try #require(graph.functions.values.first { $0.swiftTestingFactoryType == "Independent" })
        XcodeCompilerGraph.bind(tests: tests, modules: ["Tests": "Tests"], sources: sources, graph: &graph)
        #expect(graph.testDiagnostics.isEmpty)
        #expect(graph.tests[tests[2]]?.contains(suite.id) == true)
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
    var graph = DependencyGraph(functions: parsed.functions)
    XcodeCompilerGraph.resolveDispatch(&graph, tables: parsed.dispatchTargets)
    let source = SwiftSourceSnapshot.parse(text, path: "Tests.swift", module: "UI")
    XcodeCompilerGraph.bind(tests: tests, modules: ["UI": "UI"], sources: ["UI:Tests.swift": source], graph: &graph)
    for test in tests { #expect(graph.tests[test]?.isEmpty == false, "\(test)") }
    #expect(graph.testDiagnostics[tests[0]]?.isEmpty ?? true)
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
        if name != "suiteEnabled()" {
            #expect(index.paths(to: [symbol]).path(from: graph.tests[tests[0]] ?? []) == nil, "\(name)")
        }
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
        #expect((discoveryPaths.path(from: roots) != nil) == (test != tests[4]), "\(test)")
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
    let external = """
    import Testing
    public struct RecursiveTrait: SuiteTrait {
        public var isRecursive: Bool { true }
        public func prepare(for test: Test) async throws {}
    }
    @Suite(RecursiveTrait()) public struct ImportedSuite { public init() {} }
    """
    try Data(external.utf8).write(to: root.appendingPathComponent("External.swift"))
    _ = try CommandRunner.run("xcrun", compilerArguments + ["-module-name", "External", "-emit-module", root.appendingPathComponent("External.swift").path, "-emit-module-path", root.appendingPathComponent("External.swiftmodule").path], at: root)
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
        public func prepare(for test: Testing.Test) async throws { hook() }
    }
    func hook() {}
    """
    let vendor = "import Testing\n" + trait + """

    @Suite(Mode()) struct Common { @Test func decorated() {} }
    #if os(iOS)
    @Suite struct IOSOnly { @Test func platformTest() {} }
    #endif
    """
    let client = "import Testing\nimport Vendor\n" + trait.replacingOccurrences(of: "public struct", with: "private struct") + """

    @Suite struct Common { @Test func plain() {} }
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
        sources[module + ":" + path] = .parse(source, path: path, module: module)
    }
    let expected: [String: Set<String>] = [
        "Vendor/Common/decorated()": ["Vendor"], "Client/Common/plain()": [], "Client/Decorated/local()": ["Client"],
        "Client/own()": ["Client"], "Client/imported()": ["Vendor"], "Client/both()": ["Client", "Vendor"]
    ]
    XcodeCompilerGraph.resolveDispatch(&graph, tables: tables, compiler: compiler)
    XcodeCompilerGraph.bind(tests: Array(expected.keys), modules: ["Client": "Client", "Vendor": "Vendor"], sources: sources, graph: &graph)
    #expect(graph.testDiagnostics["Client/Common/plain()"]?.isEmpty ?? true)
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
