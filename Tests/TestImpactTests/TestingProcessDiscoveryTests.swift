// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
import Foundation
import Testing
@testable import TestImpact

private enum ProcessEdit: CaseIterable {
    case suiteWitness, suiteMetadata, cleanup
    case archivedPredicate, guardedSuite, ambiguousSuite
    case bodyWithOpaqueCompanion, archivedBody, eagerTrait, eagerTraitInCompanionHost, suiteTrait, nestedMainActorSuite, registrationLocation
    case scopedRemovedMethod, scopedRemovedClass
    case pluginHost, principalClassPlugin, discoveryHookPlugin, instanceConstructionPlugin, testMethodPlugin, shadowedAssertionPlugin, removedTestMethodPlugin
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
    let predicate = edit == .archivedPredicate
    let plain = predicate ? "LocalTests/Container/Common/plain()" : "LocalTests/Common/plain()"
    let classTest = "LocalTests/Independent/plainClass()", inherited = "LocalTests/Other/Child/member()"
    let nested = edit == .nestedMainActorSuite
    let marked = nested ? "LocalTests/Outer/Other/marked()" : "LocalTests/Other/marked()"
    let guarded = edit == .guardedSuite || edit == .ambiguousSuite
    let ordinary = "CompanionTests/CompanionTests/testCompanionState()"
    let observer = predicate || edit == .suiteWitness ? "CompanionTests/Other/observe()" : "CompanionTests/Foreign/observe()"
    func suiteWithPredicate(_ value: Bool) -> String {
        """
        import Testing
        func gate() -> Bool { \(value) }
        struct Container { struct Common { @Test func plain() {} } }
        final class Independent { @Test func plainClass() {} }
        @Suite(.enabled(if: gate())) public struct Other {
            public init() {}
            struct Child { @Test func member() {} }
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
    let principalClassPlugin = edit == .principalClassPlugin
    let scopedRemoval = edit == .scopedRemovedMethod || edit == .scopedRemovedClass
    let platformLoadsPlugin = scopedRemoval || [.principalClassPlugin, .discoveryHookPlugin, .instanceConstructionPlugin, .testMethodPlugin, .shadowedAssertionPlugin, .removedTestMethodPlugin].contains(edit)
    let loadsPlugin = plugin || platformLoadsPlugin
    let companionSuite: String
    switch edit {
    case .suiteWitness: companionSuite = "private struct Other"
    case .suiteMetadata: companionSuite = "private struct Foreign"
    case .cleanup: companionSuite = "@Suite(Dropper()) struct Foreign"
    default: companionSuite = predicate ? "extension Local.Other" : (opaque ? "@Suite(Marker()) struct Foreign" : "struct Foreign")
    }
    let loadBundle = """
    let root = Bundle(for: CompanionTests.self).bundleURL.deletingLastPathComponent().deletingLastPathComponent()
    try! Bundle(url: root.appendingPathComponent("Local/Fixture.xctest"))!.loadAndReturnError()
    """
    let principalClass = """
    @objc(PluginLoader) final class PluginLoader: NSObject {
        override init() {
            super.init()
            \(loadBundle)
        }
    }
    """
    let suiteOverride = """
    override class var defaultTestSuite: XCTestSuite {
        \(loadBundle)
        return super.defaultTestSuite
    }
    """
    let testBody: String
    switch edit {
    case .testMethodPlugin, .removedTestMethodPlugin, .scopedRemovedMethod, .scopedRemovedClass: testBody = loadBundle
    case .shadowedAssertionPlugin: testBody = "XCTAssertTrue(true)"
    default: testBody = ""
    }
    func companionSource(body: String, includeCase: Bool = true) -> String {
        let testCase = """
        final class CompanionTests: XCTestCase {
            \(edit == .discoveryHookPlugin ? suiteOverride : "")
            \(edit == .instanceConstructionPlugin ? "private let startup: Void = { " + loadBundle + " }()" : "")
            func testCompanionState() { \(body) }
        }
        """
        return """
        import Foundation
        import Testing
        import XCTest
        \(opaque ? #"@_silgen_name("support") func support() -> Int32"# : "")
        \(opaque ? #"struct Marker: SuiteTrait { init() { UserDefaults.standard.set(support(), forKey: "startup") } }"# : "")
        \(predicate ? "import Local" : "")
        \(edit == .cleanup ? "final class Token { deinit {} }" : "")
        \(edit == .cleanup ? "struct Dropper: SuiteTrait { init() { _ = Token() } }" : "")
        \(principalClassPlugin ? principalClass : "")
        \(edit == .shadowedAssertionPlugin ? "func XCTAssertTrue(_ value: Bool) { " + loadBundle + " }" : "")
        \(companionSuite) { @Test func observe() { \(loadsPlugin ? #"#expect(UserDefaults.standard.bool(forKey: "pluginFlag"))"# : "") } }
        \(includeCase ? testCase : "")
        """
    }
    try Data("int support(void) { return 1; }".utf8).write(to: root.appendingPathComponent("support.c"))
    _ = try query(["clang", "-dynamiclib", "support.c", "-install_name", "@rpath/libSupport.dylib", "-o", "libSupport.dylib"])
    var linkArguments = opaque ? ["-L", root.path, "-lSupport", "-Xlinker", "-rpath", "-Xlinker", root.path] : []
    if predicate { linkArguments = ["-Xlinker", "-undefined", "-Xlinker", "dynamic_lookup"] }
    func buildCompanion(_ text: String) throws {
        try Data(text.utf8).write(to: root.appendingPathComponent("Companion.swift"))
        _ = try linkedFixtureRecords(arguments("Companion"), linkArguments: linkArguments,
            root: root.appendingPathComponent("Companion"), target: "CompanionTests", principalClass: principalClassPlugin ? "PluginLoader" : nil)
    }
    let originalCompanion = companionSource(body: testBody)
    try buildCompanion(originalCompanion)
    let localTarget = ["BlueprintName": "LocalTests", "TestBundlePath": "__TESTROOT__/Local/Fixture.xctest"]
    let companionTarget = ["BlueprintName": "CompanionTests", "TestBundlePath": "__TESTROOT__/Companion/Fixture.xctest"]
    let run = root.appendingPathComponent("Both.xctestrun")
    var linkedPredicates: [Bool: XcodeTestGraph] = [:]
    var unknownOwners: [Bool: XcodeTestGraph] = [:]
    var migratedPredicates: [Bool: XcodeTestGraph] = [:]
    if scopedRemoval { _ = try CommandRunner.run("git", ["init", "-q"], at: root) }
    func capture(_ value: Bool, includeObserver: Bool) throws -> XcodeTestGraph {
        let removesLoad = (edit == .removedTestMethodPlugin || scopedRemoval) && !value
        let removesClass = edit == .scopedRemovedClass && !value
        let companion = removesLoad ? companionSource(body: "", includeCase: !removesClass) : originalCompanion
        if removesLoad { try buildCompanion(companion) }
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
        case .suiteWitness, .suiteMetadata, .cleanup:
            source = """
            import Testing
            func gate() -> Bool { \(edit == .suiteMetadata || value) }
            struct Marker: SuiteTrait { func prepare(for test: Testing.Test) async throws { _ = gate() } }
            final class Unrelated { deinit { _ = gate() } }
            private struct Common { @Test func plain() {} }
            /// \(edit == .suiteMetadata && !value ? "New docs" : "Old docs")
            \(edit == .suiteWitness ? "@Suite(Marker())" : "@Suite") struct Other { @Test func marked() {} }
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
        case .pluginHost, .principalClassPlugin, .discoveryHookPlugin, .instanceConstructionPlugin, .testMethodPlugin, .shadowedAssertionPlugin, .removedTestMethodPlugin, .scopedRemovedMethod, .scopedRemovedClass:
            source = """
            import Foundation
            import Testing
            func writePluginFlag(_ value: Bool) {
                UserDefaults.standard.setVolatileDomain(["pluginFlag": value], forName: UserDefaults.argumentDomain)
            }
            struct Marker: TestTrait { init(value: Bool) { writePluginFlag(value) } }
            struct Common { @Test func plain() {} }
            struct Other { @Test(Marker(value: \(edit == .removedTestMethodPlugin || value))) func marked() {} }
            """
        case .bodyWithOpaqueCompanion, .archivedBody:
            source = "import Testing\nstruct Common { @Test func plain() {} }\nstruct Other { @Test func marked() { #expect(Bool(\(value))) } }"
        }
        try Data(source.utf8).write(to: root.appendingPathComponent("Local.swift"))
        if scopedRemoval {
            _ = try CommandRunner.run("git", ["add", "--", "Local.swift", "Companion.swift"], at: root)
            _ = try CommandRunner.run("git", ["-c", "user.name=Fixture", "-c", "user.email=test@example.invalid",
                "commit", "-qm", value ? "base" : "head"], at: root)
        }
        _ = try linkedFixtureRecords(arguments("Local"), root: root.appendingPathComponent("Local"), target: "LocalTests")
        if platformLoadsPlugin {
            let run = try CommandRunner.run("xcrun", ["xctest", "Companion/Fixture.xctest"], at: root, allowFailure: true)
            #expect(run.status == (value ? 0 : 1))
            #expect(String(decoding: run.stdout + run.stderr, as: UTF8.self).contains(value ? "Test observe() passed" : "Test observe() failed"))
        }
        let localSource = SwiftSourceSnapshot.parse(source, path: "Local.swift", module: "Local")
        let companionSource = SwiftSourceSnapshot.parse(companion, path: "Companion.swift", module: "Companion")
        let plainCases = ["LocalTests": localSource.xctestDiscoveryCases ?? [], "CompanionTests": companionSource.xctestDiscoveryCases ?? []]
        func records(_ configurations: [[String: Any]]) throws -> [String: LinkedTestingRecords.Inventory] {
            let plan = ["TestConfigurations": configurations]
            try PropertyListSerialization.data(fromPropertyList: plan, format: .binary, options: 0).write(to: run)
            return try #require(LinkedTestingRecords.capture(testRun: run, products: root, plainCases: plainCases))
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
        let hasSuite = [.suiteTrait, .suiteWitness, .suiteMetadata, .cleanup].contains(edit) || nested || guarded
        let recordCount = predicate ? 5 : (hasSuite ? 3 : 2)
        #expect(linked["LocalTests"]?.records.count == recordCount)
        #expect((linked["CompanionTests"] == nil) == (opaque || appHosted || (platformLoadsPlugin && edit != .shadowedAssertionPlugin && !removesLoad)))
        #expect(try records([active, ["TestTargets": [hosted]]])["LocalTests"] == nil)
        #expect(try records([active, ["IsEnabled": 0, "TestTargets": [hosted]]])["LocalTests"] == nil)
        let tests = [plain, marked] + (removesClass ? [] : [ordinary]) + (includeObserver ? [observer] : []) + (predicate ? [classTest, inherited] : [])
        var graph = XcodeCompilerGraph.extract(log: log, sourceRoot: root, directory: root, derived: root,
            progress: { _ in }, ownership: ownership, linkedTestingRecords: linked)
        if edit == .shadowedAssertionPlugin {
            #expect(linked["CompanionTests"]?.assertions.isEmpty == false)
            #expect(graph.swiftTestingFactoriesByTarget?["CompanionTests"] == nil)
        }
        let targets = modules.map { XcodeTarget(name: $0.key, productType: "com.apple.product-type.bundle.unit-test", sourceFiles: ownership[$0.value]!) }
        var snapshot = XcodeTestGraph(targets: targets, tests: tests)
        snapshot.modules = modules
        snapshot.sources = ["Local:Local.swift": localSource, "Companion:Companion.swift": companionSource]
        if predicate {
            // An old app-host inventory bounded each bundle by its own records.
            // Compare its migration with a fresh bind of the same compiler input
            // with unknown process linkage.
            var legacyGraph = graph
            XcodeCompilerGraph.bind(tests: tests, modules: modules, sources: snapshot.sources, graph: &legacyGraph)
            let gate = try #require(graph.functions.values.first { $0.name == "gate()" }?.id)
            #expect(legacyGraph.dependencyPath(from: legacyGraph.tests[observer] ?? [], to: [gate]) == nil)
            snapshot.dependencies = legacyGraph
            linkedPredicates[value] = try GraphArchive.decode(GraphArchive.encode(snapshot))
            #expect(legacyGraph.dependencyPath(from: legacyGraph.tests[inherited] ?? [], to: [gate]) != nil)
            for test in [plain, classTest] {
                #expect(legacyGraph.dependencyPath(from: legacyGraph.tests[test] ?? [], to: [gate]) == nil)
            }

            // When the entry method lacks nominal evidence, selection keeps the
            // uncertainty without assigning another suite's predicate to it.
            var unknown = legacyGraph
            for id in unknown.swiftTestingEntryRoots?[plain] ?? [] { unknown.functions[id]?.nominalTypeContext = nil }
            snapshot.dependencies = unknown
            let restoredUnknown = try GraphArchive.decode(GraphArchive.encode(snapshot))
            unknownOwners[value] = restoredUnknown
            let rebound = try #require(restoredUnknown.dependencies)
            #expect(rebound.testDiagnostics[plain]?.contains(SwiftTestingDiscoveryRoots.runtimeEvidence) == true)
            #expect(rebound.dependencyPath(from: rebound.tests[plain] ?? [], to: [gate]) == nil)
            legacyGraph.swiftTestingProcessInventoryVersion = nil
            legacyGraph.swiftTestingEntryRoots = nil
            var legacy = snapshot
            legacy.dependencies = legacyGraph
            graph.swiftTestingFactoriesByTarget = nil
            graph.swiftTestingProcessInventoryVersion = nil
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
        let changes = [FileChange(path: edit == .removedTestMethodPlugin ? "Companion.swift" : "Local.swift")]
        func selections(_ head: XcodeTestGraph, _ base: XcodeTestGraph) -> [ImpactReport] {
            [XcodeFineSelector.select(current: head, previous: base, changes: changes, baseRevision: "base"),
             XcodeHeadOnlySelector.select(current: head, source: .init(base: base.sources), changes: changes, baseRevision: "base")]
        }
        let reports = selections(head, base)
        if scopedRemoval {
            let scoped = try XcodeHeadOnlySelector.scopedReports(current: head, requests: .init(scopes: [
                .init(name: "trait", paths: ["Local.swift"]), .init(name: "empty", paths: [])
            ]), changes: changes + [FileChange(path: "Companion.swift")], baseRevision: "HEAD^", headRevision: "HEAD",
                root: root, mappingPath: ".swift-test-selection.json", documentation: [], buildEvidenceFailure: nil)
            #expect(reports[0].selectedTests.contains(observer))
            #expect(scoped[0].report.selectedTests.contains(observer))
            #expect(scoped[0].report.diagnostics.contains { $0.code == "swift_testing_discovery_effects" && $0.tests.contains(observer) })
            #expect(!scoped[0].report.selectedTests.contains(ordinary))
            #expect(scoped[1].report.selectedTests.isEmpty)
            continue
        }
        if edit == .removedTestMethodPlugin {
            for report in reports {
                #expect(report.selectedTests.contains(observer))
                #expect(report.diagnostics.contains { $0.code == "swift_testing_discovery_effects" && $0.tests.contains(observer) })
            }
            // Keep the source-only check across both on-disk encodings, independently
            // of whether a scoped query removes the changed XCTest entry as a root.
            for data in [try GraphArchive.encode(head), try JSONEncoder().encode(head)] {
                let restored = try GraphArchive.decode(data)
                let report = XcodeHeadOnlySelector.select(current: restored, source: .init(base: base.sources),
                    changes: changes, baseRevision: "base", excludedTestEntries: [ordinary])
                #expect(report.selectedTests.contains(observer))
            }
            continue
        }
        if edit == .suiteWitness {
            // Older binders attached a same-named foreign witness and could
            // persist that derived node among the entry roots on re-encoding.
            let clean = try #require(head.dependencies)
            let callbacks = Set(try #require(clean.swiftTestingSuiteWitnesses).values.flatMap { $0 })
            #expect(!callbacks.isEmpty)
            for saved in [true, false] {
                var stale = head
                stale.dependencies?.tests[observer, default: []].formUnion(callbacks)
                if saved { stale.dependencies?.swiftTestingEntryRoots?[observer, default: []].formUnion(callbacks) }
                else { stale.dependencies?.swiftTestingEntryRoots = nil }
                for data in [try GraphArchive.encode(stale), try JSONEncoder().encode(stale)] {
                    let restored = try #require(GraphArchive.decode(data).dependencies)
                    #expect(restored.tests[observer] == clean.tests[observer])
                    #expect(restored.testDiagnostics[observer] == clean.testDiagnostics[observer])
                }
            }
        }
        if [.suiteWitness, .suiteMetadata, .cleanup].contains(edit) {
            for report in reports {
                #expect(!report.explanations.contains { $0.test == observer && $0.kind == "dependency" })
                switch edit {
                case .suiteMetadata:
                    #expect(!report.selectedTests.contains(observer))
                    #expect(report.explanations.contains { $0.test == marked && $0.kind == "dependency" })
                    #expect(report.diagnostics.contains { $0.code == "unresolved_suite_membership" && $0.tests == [plain] })
                    #expect(!report.explanations.contains { $0.test == plain && $0.kind == "dependency" })
                case .suiteWitness:
                    #expect(!report.selectedTests.contains(observer))
                    #expect(report.explanations.contains { $0.test == marked && $0.path.contains("Local.gate()") })
                    #expect(report.explanations.contains { $0.test == plain && $0.kind == "fallback" })
                    #expect(!report.explanations.contains { $0.test == plain && $0.kind == "dependency" })
                default:
                    #expect(report.explanations.contains { $0.test == observer && $0.kind == "fallback" })
                }
            }
            continue
        }
        if predicate {
            for linked in try selections(#require(linkedPredicates[false]), #require(linkedPredicates[true])) {
                #expect(Set(linked.selectedTests).isDisjoint(with: [plain, classTest]))
                #expect(linked.explanations.contains { $0.test == inherited && $0.kind == "dependency" && $0.path.contains("Local.gate()") })
            }
            for report in try selections(#require(unknownOwners[false]), #require(unknownOwners[true])) {
                #expect(report.selectedTests.contains(plain))
                #expect(!report.explanations.contains { $0.test == plain && $0.kind == "dependency" })
            }
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
                graph.swiftTestingProcessInventoryVersion = nil
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
        if loadsPlugin {
            // Earlier archives trusted the static image list and omitted the plug-in.
            var legacy = head
            if edit == .instanceConstructionPlugin { legacy.dependencies?.swiftTestingProcessInventoryVersion = 3 }
            else { legacy.dependencies?.swiftTestingProcessInventoryVersion = edit == .discoveryHookPlugin ? 2 : nil }
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
                expected = [plain, classTest, inherited, marked, observer]
            case .ambiguousSuite:
                expected = report.analysisMode == "head-only-git-syntax" ? [plain, marked, observer, ordinary] : [plain, marked]
            case .archivedBody: expected = [marked]
            case .bodyWithOpaqueCompanion: expected = includeObserver ? [marked, observer] : [marked]
            default: expected = [plain, marked]
            }
            #expect(Set(report.selectedTests) == Set(expected + (appHosted || platformLoadsPlugin ? [observer] : [])))
            let fallback = report.diagnostics.filter { $0.code == "swift_testing_discovery_effects" }
            if appHosted || platformLoadsPlugin {
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
        ("#import <Foundation/Foundation.h>\n@interface Fixture: NSObject @end\n@implementation Fixture\n+ (void)load {}\n@end", true),
        ("#import <Foundation/Foundation.h>\n@interface Fixture: NSObject @end\n@implementation Fixture @end", false),
        ("#import <Foundation/Foundation.h>\n@interface Fixture: NSObject @end\n@implementation Fixture\n+ (id)testInvocations { return nil; }\n@end", true),
        ("#import <Foundation/Foundation.h>\n@interface NSObject (Fixture) @end\n@implementation NSObject (Fixture)\n+ (id)defaultTestSuite { return nil; }\n@end", true)
    ] {
        try Data(source.utf8).write(to: file)
        _ = try CommandRunner.run("xcrun", ["clang", "-bundle", file.path, "-framework", "Foundation", "-o", image.path], at: root)
        #expect(LinkedTestingRecords.recordsInImage(image)?.records == (hasStartup ? nil : Set<String>()))
    }
}

@Test func flatBundleChecksDestinationPrincipalClassMetadata() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let bundle = root.appendingPathComponent("Fixture.xctest")
    try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("int fixture(void) { return 1; }".utf8).write(to: root.appendingPathComponent("Fixture.c"))
    _ = try CommandRunner.run("xcrun", ["clang", "-bundle", "Fixture.c", "-o", "Fixture.xctest/Fixture"], at: root)
    let run = root.appendingPathComponent("Fixture.xctestrun")
    let plan = ["TestConfigurations": [["TestTargets": [["BlueprintName": "UI", "TestBundlePath": "__TESTROOT__/Fixture.xctest"]]]]]
    try PropertyListSerialization.data(fromPropertyList: plan, format: .binary, options: 0).write(to: run)
    func writeInfo(_ file: String, principalKey: String? = nil) throws {
        var info = ["CFBundleExecutable": "Fixture", "CFBundlePackageType": "BNDL"]
        if let principalKey { info[principalKey] = "PluginLoader" }
        try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0)
            .write(to: bundle.appendingPathComponent(file))
    }
    try writeInfo("Info.plist")
    #expect(LinkedTestingRecords.capture(testRun: run, products: root)?["UI"]?.records == Set<String>())
    for key in ["NSPrincipalClass-iphoneos", "NSPrincipalClass~ipad"] {
        try writeInfo("Info.plist", principalKey: key)
        #expect(LinkedTestingRecords.capture(testRun: run, products: root) == [:])
    }
    try writeInfo("Info.plist")
    try writeInfo("Info-iphoneos.plist", principalKey: "NSPrincipalClass")
    #expect(LinkedTestingRecords.capture(testRun: run, products: root) == [:])
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

@Test func incompleteDiscoveryDiagnosticsSurviveRepeatedArchiveMigration() throws {
    let file = "Tests.swift", test = "UI/Cases/example()"
    let source = SwiftSourceSnapshot.parse("import Testing\nstruct Cases { @Test func example() {} }", path: file, module: "UI")
    let entry = FunctionNode(id: "method", module: "UI", name: "Cases.example()",
                             regions: [.init(path: file, startLine: 2, endLine: 2)])
    var snapshot = XcodeTestGraph(targets: [], tests: [test])
    snapshot.modules = ["UI": "UI"]
    snapshot.sources = ["UI:" + file: source]
    var graph = DependencyGraph(functions: [entry.id: entry])
    graph.testDiagnostics[test] = ["existing diagnostic"]
    XcodeCompilerGraph.bind(tests: [test], modules: snapshot.modules, sources: snapshot.sources, graph: &graph)
    let diagnostics = ["existing diagnostic", SwiftTestingDiscoveryRoots.missingEvidence]
    #expect(graph.testDiagnostics[test] == diagnostics)
    graph.swiftTestingEntryRoots = nil
    snapshot.dependencies = graph
    for compact in [true, false] {
        var archive = snapshot
        for _ in 0..<2 {
            archive = try GraphArchive.decode(compact ? GraphArchive.encode(archive) : JSONEncoder().encode(archive))
            #expect(archive.dependencies?.testDiagnostics[test] == diagnostics)
        }
    }
}

private enum ProductionSuiteEdit: CaseIterable {
    case rename, archivedDocumentation, eagerArgument, removedEagerArgument
}

@Test(arguments: ProductionSuiteEdit.allCases)
private func productionSuiteEditsRetainUICoverage(_ edit: ProductionSuiteEdit) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    func query(_ args: [String]) throws -> String {
        try CommandRunner.run("xcrun", args, at: root).text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    let compiler = try query(["--find", "swiftc"])
    let plugins = URL(fileURLWithPath: compiler).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("lib/swift/host/plugins/testing")
    let platform = try query(["--sdk", "macosx", "--show-sdk-platform-path"])
    func arguments(_ module: String) -> [String] {
        [compiler, "-module-name", module, "-whole-module-optimization", "-g", "-Onone", "-parse-as-library", "-plugin-path", plugins.path,
         "-I", root.path, "-F", platform + "/Developer/Library/Frameworks", "-I", platform + "/Developer/usr/lib",
         root.appendingPathComponent(module + ".swift").path]
    }
    let member = "UI/Inventory/member()", mapped = "UI/Case/testMapped()", dependent = "UI/Case/testDependent()", plain = "UI/Common/plain()"
    let tests = [member, mapped, dependent, plain]
    let ui = """
        import Shared
        import Testing
        import XCTest
        extension Shared.Inventory { @Test func member() {} }
        struct Common { @Test func plain() {} }
        final class Case: XCTestCase {
            func testMapped() {}
            func testDependent() {}
        }
        """
    try ui.write(to: root.appendingPathComponent("UI.swift"), atomically: true, encoding: .utf8)
    let log = ["Shared", "UI"].map { "builtin-SwiftDriver -- " + arguments($0).map { "\"" + $0 + "\"" }.joined(separator: " ") }.joined(separator: "\n")
    func capture(_ name: String) throws -> XcodeTestGraph {
        let header: String
        switch edit {
        case .rename: header = "@Suite(\"\(name)\")"
        case .archivedDocumentation: header = "/// \(name)\n@Suite"
        case .eagerArgument: header = "@Suite(Marker(\(name == "Old")))"
        case .removedEagerArgument: header = name == "Old" ? "@Suite(Marker(true))" : "@Suite"
        }
        let shared = """
            import Foundation
            import Testing
            struct Marker: SuiteTrait {
                init(_ enabled: Bool) { UserDefaults.standard.set(enabled, forKey: "inventory.enabled") }
            }
            \(header) public struct Inventory { public init() {} }
            """
        try shared.write(to: root.appendingPathComponent("Shared.swift"), atomically: true, encoding: .utf8)
        let object = root.appendingPathComponent("Shared.o").path
        _ = try query(arguments("Shared") + ["-emit-module", "-emit-object", "-o", object])
        let records = try linkedFixtureRecords(arguments("UI"), linkArguments: [object], root: root, target: "UI")
        var graph = XcodeCompilerGraph.extract(log: log, sourceRoot: root, directory: root, derived: root, progress: { _ in },
                                               ownership: ["Shared": ["Shared.swift"], "UI": ["UI.swift"]], linkedTestingRecords: records)
        var snapshot = XcodeTestGraph(targets: [
            .init(name: "Shared", productType: "com.apple.product-type.library.static", sourceFiles: ["Shared.swift"]),
            .init(name: "UI", productType: "com.apple.product-type.bundle.ui-testing", sourceFiles: ["UI.swift"])
        ], tests: tests)
        snapshot.modules = ["UI": "UI", "Shared": "Shared"]
        snapshot.sources = ["UI:UI.swift": .parse(ui, path: "UI.swift", module: "UI"),
                            "Shared:Shared.swift": .parse(shared, path: "Shared.swift", module: "Shared")]
        snapshot.mappings = UIFeatureMappings(features: [.init(name: "inventory", sources: ["Shared*.swift"], tests: [mapped]),
                                                        .init(name: "client", tests: [dependent], dependsOn: ["inventory"])])
        XcodeCompilerGraph.bind(tests: tests, modules: snapshot.modules, sources: snapshot.sources, graph: &graph)
        snapshot.dependencies = graph
        if edit == .archivedDocumentation {
            // Version 4 recorded the suite role but omitted its registration arguments and metadata.
            var file = snapshot.sources["Shared:Shared.swift"]!
            file.parserVersion = 4
            file.swiftTestingDeclarations = nil
            for i in file.units.indices {
                file.units[i].swiftTestingArguments = nil
                file.units[i].swiftTestingSuiteMetadata = nil
                file.units[i].swiftTestingRegistrationDeclaration = nil
                file.units[i].swiftTestingSuiteInputs = nil
            }
            snapshot.sources["Shared:Shared.swift"] = file
        }
        return try GraphArchive.decode(GraphArchive.encode(snapshot))
    }
    let base = try capture("Old")
    var head = try capture("New")
    let changes = [FileChange(path: "Shared.swift")]
    let dual = XcodeFineSelector.select(current: head, previous: base, changes: changes, baseRevision: "base")
    func headOnly() -> ImpactReport {
        XcodeHeadOnlySelector.select(current: head, source: .init(base: base.sources, mappings: head.mappings), changes: changes, baseRevision: "base")
    }
    #expect(Set(dual.explanations.filter { $0.test == mapped && $0.kind == "explicitMapping" }.map(\.revision)) == ["base", "head"])
    for report in [dual, headOnly()] {
        if edit == .rename { #expect(report.selectedTests == [member, mapped, dependent].sorted()) }
        if edit == .archivedDocumentation {
            #expect(report.diagnostics.contains { $0.code == "incomplete_testing_registration" })
        }
        #expect(report.explanations.contains { $0.test == mapped && $0.kind == "explicitMapping" && $0.path.contains("Shared.swift") })
        #expect(report.explanations.contains { $0.test == dependent && $0.kind == "explicitMapping" && $0.path.contains("inventory") })
    }
    if edit == .eagerArgument || edit == .removedEagerArgument {
        head.mappings = UIFeatureMappings(features: [.init(name: "client", sources: ["UI.swift"], tests: tests)])
        head.mappings?.runtimeDependencyPolicy = .declared
        let uncovered = headOnly()
        #expect(uncovered.selectedTests == tests.sorted())
        #expect(uncovered.diagnostics.contains { $0.code == "head_only_unmapped_production" && $0.tests == tests.sorted() })
        head.mappings = nil
        #expect(headOnly().diagnostics.contains { $0.code == "head_only_missing_mappings" && $0.tests == tests.sorted() })
    }
}
