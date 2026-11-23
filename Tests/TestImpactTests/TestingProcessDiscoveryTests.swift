// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
import Foundation
import Testing
@testable import TestImpact

@Test func linkedRegistrationEvidenceFollowsTheTestProcess() throws {
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
        [compiler, "-sdk", sdk, "-module-name", name, "-whole-module-optimization", "-g", "-Onone", "-plugin-path", plugins.path,
         "-F", platform + "/Developer/Library/Frameworks", "-I", platform + "/Developer/usr/lib",
         root.appendingPathComponent(name + ".swift").path]
    }
    let names = ["Local", "Companion"]
    let modules = ["LocalTests": "Local", "CompanionTests": "Companion"]
    let ownership = Dictionary(uniqueKeysWithValues: names.map { ($0, Set([$0 + ".swift"])) })
    let log = names.map { "builtin-SwiftDriver -- " + arguments($0).map { "\"" + $0 + "\"" }.joined(separator: " ") }.joined(separator: "\n")
    let plain = "LocalTests/Common/plain()", marked = "LocalTests/Other/marked()"
    let ordinary = "CompanionTests/Case/testIndependent()", observer = "CompanionTests/Foreign/observe()"
    let companion = """
    import Foundation
    import Testing
    import XCTest
    @_silgen_name("support") func support() -> Int32
    struct Marker: SuiteTrait { init() { UserDefaults.standard.set(support(), forKey: "startup") } }
    @Suite(Marker()) struct Foreign { @Test func observe() {} }
    final class Case: XCTestCase { func testIndependent() {} }
    """
    try Data(companion.utf8).write(to: root.appendingPathComponent("Companion.swift"))
    try Data("int support(void) { return 1; }".utf8).write(to: root.appendingPathComponent("support.c"))
    _ = try query(["clang", "-dynamiclib", "support.c", "-install_name", "@rpath/libSupport.dylib", "-o", "libSupport.dylib"])
    _ = try linkedFixtureRecords(arguments("Companion"), linkArguments: ["-L", root.path, "-lSupport", "-Xlinker", "-rpath", "-Xlinker", root.path],
        root: root.appendingPathComponent("Companion"), target: "CompanionTests")
    let localTarget = ["BlueprintName": "LocalTests", "TestBundlePath": "__TESTROOT__/Local/Fixture.xctest"]
    let companionTarget = ["BlueprintName": "CompanionTests", "TestBundlePath": "__TESTROOT__/Companion/Fixture.xctest"]
    let run = root.appendingPathComponent("Both.xctestrun")
    func capture(_ value: Bool, includeObserver: Bool) throws -> XcodeTestGraph {
        let source = "import Testing\nstruct Common { @Test func plain() {} }\nstruct Other { @Test func marked() { #expect(Bool(\(value))) } }"
        try Data(source.utf8).write(to: root.appendingPathComponent("Local.swift"))
        _ = try linkedFixtureRecords(arguments("Local"), root: root.appendingPathComponent("Local"), target: "LocalTests")
        func records(_ configurations: [[[String: String]]]) throws -> [String: Set<String>] {
            let plan = ["TestConfigurations": configurations.map { ["TestTargets": $0] }]
            try PropertyListSerialization.data(fromPropertyList: plan, format: .binary, options: 0).write(to: run)
            return try #require(LinkedTestingRecords.capture(testRun: run, products: root))
        }
        let alone = try records([[localTarget]])
        let linked = try records([[localTarget, companionTarget]])
        #expect(linked == alone && linked["LocalTests"]?.count == 2)
        // A second configuration of the same target can introduce an unknown host.
        var hosted = localTarget
        hosted["TestHostPath"] = "__TESTROOT__/Unavailable.app"
        #expect(try records([[localTarget], [hosted]])["LocalTests"] == nil)
        let tests = [plain, marked, ordinary] + (includeObserver ? [observer] : [])
        var graph = XcodeCompilerGraph.extract(log: log, sourceRoot: root, directory: root, derived: root,
            progress: { _ in }, ownership: ownership, linkedTestingRecords: linked)
        let targets = modules.map { XcodeTarget(name: $0.key, productType: "com.apple.product-type.bundle.unit-test", sourceFiles: ownership[$0.value]!) }
        var snapshot = XcodeTestGraph(targets: targets, tests: tests)
        snapshot.modules = modules
        snapshot.sources = ["Local:Local.swift": .parse(source, path: "Local.swift", module: "Local"),
                            "Companion:Companion.swift": .parse(companion, path: "Companion.swift", module: "Companion")]
        XcodeCompilerGraph.bind(tests: tests, modules: modules, sources: snapshot.sources, graph: &graph)
        snapshot.dependencies = graph
        return try GraphArchive.decode(GraphArchive.encode(snapshot))
    }
    for includeObserver in [false, true] {
        let base = try capture(true, includeObserver: includeObserver)
        let head = try capture(false, includeObserver: includeObserver)
        let changes = [FileChange(path: "Local.swift")]
        let reports = [XcodeFineSelector.select(current: head, previous: base, changes: changes, baseRevision: "base"),
                       XcodeHeadOnlySelector.select(current: head, source: .init(base: base.sources), changes: changes, baseRevision: "base")]
        for report in reports {
            #expect(Set(report.selectedTests) == Set(includeObserver ? [marked, observer] : [marked]))
            let fallback = report.diagnostics.filter { $0.code == "swift_testing_discovery_effects" }
            #expect(Set(fallback.flatMap(\.tests)) == Set(includeObserver ? [observer] : []))
        }
    }
}
