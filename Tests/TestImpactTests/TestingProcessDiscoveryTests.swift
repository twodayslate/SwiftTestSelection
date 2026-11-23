// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
import Foundation
import Testing
@testable import TestImpact

private enum ProcessEdit: CaseIterable {
    case archivedPredicate, guardedSuite, ambiguousSuite
    case bodyWithOpaqueCompanion, archivedBody, eagerTrait, eagerTraitInCompanionHost, pluginHost, suiteTrait, nestedMainActorSuite, registrationLocation
}

@Test(.serialized, arguments: ProcessEdit.allCases)
private func linkedRegistrationEvidenceFollowsTheTestProcess(_ edit: ProcessEdit) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    func query(_ arguments: [String]) throws -> String {
        try CommandRunner.run("xcrun", arguments, at: root).text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    let platform = try query(["--sdk", "macosx", "--show-sdk-platform-path"])
    let sdk = try query(["--sdk", "macosx", "--show-sdk-path"])
    let compiler = try query(["--find", "swiftc"])
    let plugins = URL(fileURLWithPath: compiler).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("lib/swift/host/plugins/testing")
    func arguments(_ name: String) -> [String] {
        [compiler, "-sdk", sdk, "-module-name", name, "-whole-module-optimization", "-g", "-Onone", "-plugin-path", plugins.path, "-I", root.path,
         "-F", platform + "/Developer/Library/Frameworks", "-I", platform + "/Developer/usr/lib",
         root.appendingPathComponent(name + ".swift").path]
    }
    let names = ["Local", "Companion"]
    let modules = ["LocalTests": "Local", "CompanionTests": "Companion"]
    let ownership = Dictionary(uniqueKeysWithValues: names.map { ($0, Set([$0 + ".swift"])) })
    let log = names.map { "builtin-SwiftDriver -- " + arguments($0).map { "\"" + $0 + "\"" }.joined(separator: " ") }.joined(separator: "\n")
    let plain = "LocalTests/Common/plain()"
    let nested = edit == .nestedMainActorSuite
    let marked = nested ? "LocalTests/Outer/Other/marked()" : "LocalTests/Other/marked()"
    let predicate = edit == .archivedPredicate
    let guarded = edit == .guardedSuite || edit == .ambiguousSuite
    let ordinary = "CompanionTests/Case/testIndependent()"
    let observer = predicate ? "CompanionTests/Other/observe()" : "CompanionTests/Foreign/observe()"
    func suiteWithPredicate(_ value: Bool) -> String {
        """
        import Testing
        func gate() -> Bool { \(value) }
        struct Common { @Test func plain() {} }
        @Suite(.enabled(if: gate())) public struct Other {
            public init() {}
            @Test func marked() {}
        }
        """
    }
    if predicate {
        try Data(suiteWithPredicate(true).utf8).write(to: root.appendingPathComponent("Local.swift"))
        _ = try query(arguments("Local") + ["-parse-as-library", "-emit-module", "-emit-module-path",
                                           root.appendingPathComponent("Local.swiftmodule").path])
    }
    let opaque = edit == .bodyWithOpaqueCompanion
    let plugin = edit == .pluginHost
    let appHosted = plugin || edit == .eagerTraitInCompanionHost
    let companion = """
    import Foundation
    import Testing
    import XCTest
    \(opaque ? #"@_silgen_name("support") func support() -> Int32"# : "")
    \(opaque ? #"struct Marker: SuiteTrait { init() { UserDefaults.standard.set(support(), forKey: "startup") } }"# : "")
    \(predicate ? "import Local" : "")
    \(opaque ? "@Suite(Marker()) " : "")\(predicate ? "extension Local.Other" : "struct Foreign") { @Test func observe() { \(plugin ? #"#expect(UserDefaults.standard.bool(forKey: "pluginFlag"))"# : "") } }
    final class Case: XCTestCase { func testIndependent() {} }
    """
    try Data(companion.utf8).write(to: root.appendingPathComponent("Companion.swift"))
    try Data("int support(void) { return 1; }".utf8).write(to: root.appendingPathComponent("support.c"))
    _ = try query(["clang", "-dynamiclib", "support.c", "-install_name", "@rpath/libSupport.dylib", "-o", "libSupport.dylib"])
    var linkArguments = opaque ? ["-L", root.path, "-lSupport", "-Xlinker", "-rpath", "-Xlinker", root.path] : []
    if predicate { linkArguments = ["-Xlinker", "-undefined", "-Xlinker", "dynamic_lookup"] }
    _ = try linkedFixtureRecords(arguments("Companion"), linkArguments: linkArguments,
        root: root.appendingPathComponent("Companion"), target: "CompanionTests")
    let localTarget = ["BlueprintName": "LocalTests", "TestBundlePath": "__TESTROOT__/Local/Fixture.xctest"]
    let companionTarget = ["BlueprintName": "CompanionTests", "TestBundlePath": "__TESTROOT__/Companion/Fixture.xctest"]
    let run = root.appendingPathComponent("Both.xctestrun")
    var migratedPredicates: [Bool: XcodeTestGraph] = [:]
    func capture(_ value: Bool, includeObserver: Bool) throws -> XcodeTestGraph {
        let source: String
        switch edit {
        case .eagerTrait, .eagerTraitInCompanionHost, .registrationLocation:
            let argument = edit == .registrationLocation ? "line: #line" : "value: \(value)"
            let padding = edit == .registrationLocation && !value ? "\n" : ""
            source = """
            import Testing
            struct Marker: TestTrait { var value = true; var line = 0 }
            struct Common { @Test func plain() {} }
            \(padding)struct Other { @Test(Marker(\(argument))) func marked() {} }
            """
        case .archivedPredicate:
            source = suiteWithPredicate(value)
        case .suiteTrait, .nestedMainActorSuite, .guardedSuite, .ambiguousSuite:
            source = """
            import Testing
            struct Marker: SuiteTrait { let value: Bool }
            struct Common { @Test func plain() {} }
            \(nested ? "@MainActor struct Outer {" : "")
            \(guarded ? "#if canImport(Testing)" : "")
            @Suite(Marker(value: \(value))) struct Other { @Test func marked() {} }
            \(edit == .ambiguousSuite ? "#else\n@Suite struct Other {}" : "")
            \(guarded ? "#endif" : "")
            \(nested ? "}" : "")
            """
        case .pluginHost:
            source = """
            import Foundation
            import Testing
            func writePluginFlag(_ value: Bool) { UserDefaults.standard.set(value, forKey: "pluginFlag") }
            struct Marker: TestTrait { init(value: Bool) { writePluginFlag(value) } }
            struct Common { @Test func plain() {} }
            struct Other { @Test(Marker(value: \(value))) func marked() {} }
            """
        case .bodyWithOpaqueCompanion, .archivedBody:
            source = "import Testing\nstruct Common { @Test func plain() {} }\nstruct Other { @Test func marked() { #expect(Bool(\(value))) } }"
        }
        try Data(source.utf8).write(to: root.appendingPathComponent("Local.swift"))
        _ = try linkedFixtureRecords(arguments("Local"), root: root.appendingPathComponent("Local"), target: "LocalTests")
        func records(_ configurations: [[String: Any]]) throws -> [String: Set<String>] {
            let plan = ["TestConfigurations": configurations]
            try PropertyListSerialization.data(fromPropertyList: plan, format: .binary, options: 0).write(to: run)
            return try #require(LinkedTestingRecords.capture(testRun: run, products: root))
        }
        var companionRun = companionTarget
        if appHosted {
            let contents = root.appendingPathComponent("LocalHost.app/Contents")
            let binaries = contents.appendingPathComponent("MacOS")
            try FileManager.default.createDirectory(at: binaries, withIntermediateDirectories: true)
            let info = ["CFBundleExecutable": "LocalHost", "CFBundlePackageType": "APPL"]
            try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0)
                .write(to: contents.appendingPathComponent("Info.plist"))
            let main = root.appendingPathComponent("HostMain.swift")
            let executable = binaries.appendingPathComponent("LocalHost")
            if plugin {
                let runner = """
                import Foundation
                import Testing
                @main struct HostMain {
                    static func main() async throws {
                        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                        for name in ["Local", "Companion"] {
                            try Bundle(url: root.appendingPathComponent(name + "/Fixture.xctest"))!.loadAndReturnError()
                        }
                        let status: CInt = await Testing.__swiftPMEntryPoint()
                        exit(status)
                    }
                }
                """
                try Data(runner.utf8).write(to: main)
                let frameworks = platform + "/Developer/Library/Frameworks", libraries = platform + "/Developer/usr/lib"
                _ = try query([compiler, "-sdk", sdk, "-F", frameworks, "-L", libraries, "-I", libraries,
                               "-Xlinker", "-rpath", "-Xlinker", frameworks, "-Xlinker", "-rpath", "-Xlinker", libraries,
                               "-parse-as-library", main.path, "-o", executable.path])
                let run = try CommandRunner.run(executable.path, ["--filter", "observe"], at: root, allowFailure: true)
                #expect(run.status == (value ? 0 : 1))
                #expect(String(decoding: run.stderr + run.stdout, as: UTF8.self).contains("observe()"))
            } else {
                try Data("@main struct HostMain { static func main() {} }".utf8).write(to: main)
                _ = try query(arguments("Local") + ["-parse-as-library", main.path, "-L", platform + "/Developer/usr/lib",
                                                    "-o", executable.path])
            }
            companionRun["TestHostPath"] = "__TESTROOT__/LocalHost.app"
        }
        let active: [String: Any] = ["TestTargets": [localTarget, companionRun], "IsEnabled": true]
        var hosted = localTarget
        hosted["TestHostPath"] = "__TESTROOT__/Unavailable.app"
        let disabled: [String: Any] = ["TestTargets": [hosted], "IsEnabled": false]
        let linked = try records([["IsEnabled": false], active, disabled])
        #expect(linked == (try records([disabled, ["TestTargets": [localTarget, companionRun]]])))
        #expect(linked["LocalTests"]?.count == (edit == .suiteTrait || nested || guarded || predicate ? 3 : 2))
        #expect((linked["CompanionTests"] == nil) == (opaque || appHosted))
        #expect(try records([active, ["TestTargets": [hosted]]])["LocalTests"] == nil)
        #expect(try records([active, ["IsEnabled": 0, "TestTargets": [hosted]]])["LocalTests"] == nil)
        let tests = [plain, marked, ordinary] + (includeObserver ? [observer] : [])
        var graph = XcodeCompilerGraph.extract(log: log, sourceRoot: root, directory: root, derived: root,
            progress: { _ in }, ownership: ownership, linkedTestingRecords: linked)
        let targets = modules.map { XcodeTarget(name: $0.key, productType: "com.apple.product-type.bundle.unit-test", sourceFiles: ownership[$0.value]!) }
        var snapshot = XcodeTestGraph(targets: targets, tests: tests)
        snapshot.modules = modules
        snapshot.sources = ["Local:Local.swift": .parse(source, path: "Local.swift", module: "Local"),
                            "Companion:Companion.swift": .parse(companion, path: "Companion.swift", module: "Companion")]
        if predicate {
            // An old app-host inventory bounded each bundle by its own records.
            // Compare its migration with a fresh bind of the same compiler input
            // with unknown process linkage.
            var legacyGraph = graph
            XcodeCompilerGraph.bind(tests: tests, modules: modules, sources: snapshot.sources, graph: &legacyGraph)
            let gate = try #require(graph.functions.values.first { $0.name == "gate()" }?.id)
            #expect(legacyGraph.dependencyPath(from: legacyGraph.tests[observer] ?? [], to: [gate]) == nil)
            legacyGraph.swiftTestingPlatformAgentInventory = nil
            legacyGraph.swiftTestingEntryRoots = nil
            var legacy = snapshot
            legacy.dependencies = legacyGraph
            graph.swiftTestingFactoriesByTarget = nil
            graph.swiftTestingPlatformAgentInventory = nil
            XcodeCompilerGraph.bind(tests: tests, modules: modules, sources: snapshot.sources, graph: &graph)
            #expect(graph.dependencyPath(from: graph.tests[observer] ?? [], to: [gate]) != nil)
            for data in [try JSONEncoder().encode(legacy), try GraphArchive.encode(legacy)] {
                let migrated = try GraphArchive.decode(data)
                migratedPredicates[value] = migrated
                let restored = try #require(migrated.dependencies)
                #expect(restored.tests == graph.tests)
                #expect(restored.testDiagnostics == graph.testDiagnostics)
                #expect(restored.dependencyPath(from: restored.tests[observer] ?? [], to: [gate]) ==
                        graph.dependencyPath(from: graph.tests[observer] ?? [], to: [gate]))
            }
        } else {
            XcodeCompilerGraph.bind(tests: tests, modules: modules, sources: snapshot.sources, graph: &graph)
        }
        snapshot.dependencies = graph
        let restored = try GraphArchive.decode(GraphArchive.encode(snapshot))
        #expect(restored.dependencies?.tests == graph.tests)
        #expect(restored.dependencies?.testDiagnostics == graph.testDiagnostics)
        return restored
    }
    for includeObserver in (opaque ? [false, true] : [true]) {
        let base = try capture(true, includeObserver: includeObserver)
        let head = try capture(false, includeObserver: includeObserver)
        let changes = [FileChange(path: "Local.swift")]
        func selections(_ head: XcodeTestGraph, _ base: XcodeTestGraph) -> [ImpactReport] {
            [XcodeFineSelector.select(current: head, previous: base, changes: changes, baseRevision: "base"),
             XcodeHeadOnlySelector.select(current: head, source: .init(base: base.sources), changes: changes, baseRevision: "base")]
        }
        let reports = selections(head, base)
        if predicate {
            let migrated = try selections(#require(migratedPredicates[false]), #require(migratedPredicates[true]))
            for (fresh, restored) in zip(reports, migrated) {
                #expect(restored.selectedTests == fresh.selectedTests)
                func reasons(_ report: ImpactReport) -> [[String]] {
                    report.explanations.map { [$0.test, $0.kind, $0.reason, $0.revision] + $0.path }
                        .sorted { $0.lexicographicallyPrecedes($1) }
                }
                #expect(reasons(restored) == reasons(fresh))
            }
        }
        if edit == .archivedBody {
            func migrated(_ snapshot: XcodeTestGraph, compact: Bool, previouslyMigrated: Bool) throws -> XcodeTestGraph {
                var snapshot = snapshot
                var graph = try #require(snapshot.dependencies)
                graph.swiftTestingPlatformAgentInventory = nil
                graph.swiftTestingEntryRoots = nil
                if previouslyMigrated {
                    // The old reader could persist these edges after dropping its linkage flags.
                    graph.swiftTestingFactoriesByTarget = nil
                    let ids = graph.functions.values.filter {
                        $0.compilerReferences?.contains(where: SwiftTestingFactoryProof.isFactory) == true
                    }.map(\.id)
                    graph.functions[SwiftTestingDiscoveryRoots.sharedDiscoveryID]?.dependencies.formUnion(ids)
                }
                snapshot.dependencies = graph
                return try GraphArchive.decode(compact ? GraphArchive.encode(snapshot) : JSONEncoder().encode(snapshot))
            }
            for compact in [false, true] {
                for previouslyMigrated in [false, true] {
                    let old = try migrated(base, compact: compact, previouslyMigrated: previouslyMigrated)
                    let current = try migrated(head, compact: compact, previouslyMigrated: previouslyMigrated)
                    let dual = XcodeFineSelector.select(current: current, previous: old, changes: changes, baseRevision: "base")
                    let single = XcodeHeadOnlySelector.select(current: current, source: .init(base: old.sources), changes: changes, baseRevision: "base")
                    for report in [dual, single] {
                        #expect(Set(report.selectedTests) == [plain, marked, observer])
                        #expect(Set(report.explanations.filter { $0.kind == "dependency" }.map(\.test)) == [marked])
                        #expect(report.diagnostics.contains { $0.code == "swift_testing_discovery_effects" && $0.tests.contains(observer) })
                    }
                }
            }
        }
        if plugin {
            // Earlier archives trusted this host's static image list and omitted the plug-in.
            var legacy = head
            legacy.dependencies?.swiftTestingPlatformAgentInventory = nil
            legacy.dependencies?.swiftTestingFactoriesByTarget?["CompanionTests"] = []
            legacy.dependencies?.testDiagnostics[observer] = []
            legacy.dependencies?.functions[SwiftTestingDiscoveryRoots.processRoot("CompanionTests")]?.dependencies = []
            for data in [try GraphArchive.encode(legacy), try JSONEncoder().encode(legacy)] {
                let restored = try GraphArchive.decode(data)
                let graph = try #require(restored.dependencies)
                #expect(graph.swiftTestingFactoriesByTarget == nil)
                let writer = try #require(graph.functions.values.first { $0.module == "Local" && $0.name == "writePluginFlag(_:)" })
                #expect(graph.dependencyPath(from: graph.tests[observer] ?? [], to: [writer.id]) != nil)
                let report = XcodeHeadOnlySelector.select(current: restored, source: .init(base: base.sources), changes: changes, baseRevision: "base")
                #expect(report.selectedTests.contains(observer))
                #expect(report.diagnostics.contains { $0.code == "swift_testing_discovery_effects" && $0.tests.contains(observer) })
            }
        }
        if edit == .suiteTrait {
            // A simultaneous conformance change still needs historical compiler evidence.
            var historical = base.sources
            historical["Local:Local.swift"] = .parse("""
            import Testing
            struct Marker: SuiteTrait { let value: Bool }
            struct Common { @Test func plain() {} }
            @Suite(Marker(value: true)) struct Other: Sendable { @Test func marked() {} }
            """, path: "Local.swift", module: "Local")
            let structural = XcodeHeadOnlySelector.select(current: head, source: .init(base: historical), changes: changes, baseRevision: "base")
            #expect(structural.diagnostics.contains { $0.code == "head_only_declaration_change" && $0.tests.contains(ordinary) })
        }
        for report in reports {
            let expected: [String]
            switch edit {
            case .archivedPredicate:
                #expect(report.explanations.contains { $0.test == observer && $0.kind == "dependency" && $0.path.contains("Local.gate()") })
                expected = [plain, marked, observer]
            case .ambiguousSuite:
                expected = report.analysisMode == "head-only-git-syntax" ? [plain, marked, observer, ordinary] : [plain, marked]
            case .archivedBody: expected = [marked]
            case .bodyWithOpaqueCompanion: expected = includeObserver ? [marked, observer] : [marked]
            default: expected = [plain, marked]
            }
            #expect(Set(report.selectedTests) == Set(expected + (appHosted ? [observer] : [])))
            let fallback = report.diagnostics.filter { $0.code == "swift_testing_discovery_effects" }
            if appHosted {
                #expect(report.explanations.contains {
                    $0.test == observer && $0.kind == "dependency" && $0.path.contains("Testing.discovery in CompanionTests")
                })
            }
            if opaque {
                #expect(Set(fallback.flatMap(\.tests)) == Set(includeObserver ? [observer] : []))
            } else if edit != .archivedBody && !predicate && edit != .ambiguousSuite {
                #expect(report.explanations.contains {
                    $0.test == plain && $0.kind == "dependency" && $0.path.contains("Testing.discovery in LocalTests")
                })
            }
        }
    }
}

@Test func platformAgentBundleWithStartupCodeHasOpenDiscovery() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("Fixture.m"), image = root.appendingPathComponent("Fixture")
    for (source, hasStartup) in [
        ("int fixture(void) { return 1; }", false),
        ("int initialized; __attribute__((constructor)) static void initialize(void) { initialized = 1; }", true),
        ("#import <Foundation/Foundation.h>\n@interface Fixture: NSObject @end\n@implementation Fixture\n+ (void)load {}\n@end", true)
    ] {
        try Data(source.utf8).write(to: file)
        _ = try CommandRunner.run("xcrun", ["clang", "-bundle", file.path, "-framework", "Foundation", "-o", image.path], at: root)
        #expect(LinkedTestingRecords.recordsInImage(image) == (hasStartup ? nil : Set<String>()))
    }
}

@Test func nestedSuiteRegistrationRequiresKnownEnclosingAttributes() throws {
    for (attribute, supported) in [("@MainActor", true), ("@Swift.MainActor", true), ("@MainActor @Custom", false),
                                   ("@Other.MainActor", false)] {
        let file = SwiftSourceSnapshot.parse("""
        import Testing
        \(attribute) struct Outer { @Suite struct Inner {} }
        """, path: "Nested.swift", module: "Local")
        let inner = try #require(file.units.first { $0.swiftTestingSuiteName == "Outer.Inner" })
        #expect((inner.swiftTestingRegistrationDeclaration != nil) == supported)
    }
}
