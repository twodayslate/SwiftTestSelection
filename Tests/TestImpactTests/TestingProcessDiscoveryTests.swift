// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
import Foundation
import Testing
@testable import TestImpact

private enum ProcessEdit: CaseIterable { case bodyWithOpaqueCompanion, eagerTrait, eagerTraitInCompanionHost, registrationLocation }

@Test(arguments: ProcessEdit.allCases)
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
    let opaque = edit == .bodyWithOpaqueCompanion
    let companion = """
    import Foundation
    import Testing
    import XCTest
    \(opaque ? #"@_silgen_name("support") func support() -> Int32"# : "")
    \(opaque ? #"struct Marker: SuiteTrait { init() { UserDefaults.standard.set(support(), forKey: "startup") } }"# : "")
    \(opaque ? "@Suite(Marker()) " : "")struct Foreign { @Test func observe() {} }
    final class Case: XCTestCase { func testIndependent() {} }
    """
    try Data(companion.utf8).write(to: root.appendingPathComponent("Companion.swift"))
    try Data("int support(void) { return 1; }".utf8).write(to: root.appendingPathComponent("support.c"))
    _ = try query(["clang", "-dynamiclib", "support.c", "-install_name", "@rpath/libSupport.dylib", "-o", "libSupport.dylib"])
    _ = try linkedFixtureRecords(arguments("Companion"), linkArguments: opaque ? ["-L", root.path, "-lSupport", "-Xlinker", "-rpath", "-Xlinker", root.path] : [],
        root: root.appendingPathComponent("Companion"), target: "CompanionTests")
    let localTarget = ["BlueprintName": "LocalTests", "TestBundlePath": "__TESTROOT__/Local/Fixture.xctest"]
    let companionTarget = ["BlueprintName": "CompanionTests", "TestBundlePath": "__TESTROOT__/Companion/Fixture.xctest"]
    let run = root.appendingPathComponent("Both.xctestrun")
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
        case .bodyWithOpaqueCompanion:
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
        if edit == .eagerTraitInCompanionHost {
            let contents = root.appendingPathComponent("LocalHost.app/Contents")
            let binaries = contents.appendingPathComponent("MacOS")
            try FileManager.default.createDirectory(at: binaries, withIntermediateDirectories: true)
            let info = ["CFBundleExecutable": "LocalHost", "CFBundlePackageType": "APPL"]
            try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0)
                .write(to: contents.appendingPathComponent("Info.plist"))
            let main = root.appendingPathComponent("HostMain.swift")
            try Data("@main struct HostMain { static func main() {} }".utf8).write(to: main)
            _ = try query(arguments("Local") + ["-parse-as-library", main.path, "-L", platform + "/Developer/usr/lib",
                                                "-o", binaries.appendingPathComponent("LocalHost").path])
            companionRun["TestHostPath"] = "__TESTROOT__/LocalHost.app"
        }
        let active: [String: Any] = ["TestTargets": [localTarget, companionRun], "IsEnabled": true]
        var hosted = localTarget
        hosted["TestHostPath"] = "__TESTROOT__/Unavailable.app"
        let disabled: [String: Any] = ["TestTargets": [hosted], "IsEnabled": false]
        let linked = try records([["IsEnabled": false], active, disabled])
        #expect(linked == (try records([disabled, ["TestTargets": [localTarget, companionRun]]])))
        #expect(linked["LocalTests"]?.count == 2)
        #expect((linked["CompanionTests"] == nil) == opaque)
        if edit == .eagerTraitInCompanionHost {
            #expect(try #require(linked["CompanionTests"]).isSuperset(of: #require(linked["LocalTests"])))
        }
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
        XcodeCompilerGraph.bind(tests: tests, modules: modules, sources: snapshot.sources, graph: &graph)
        snapshot.dependencies = graph
        return try GraphArchive.decode(GraphArchive.encode(snapshot))
    }
    for includeObserver in (opaque ? [false, true] : [true]) {
        let base = try capture(true, includeObserver: includeObserver)
        let head = try capture(false, includeObserver: includeObserver)
        let changes = [FileChange(path: "Local.swift")]
        let reports = [XcodeFineSelector.select(current: head, previous: base, changes: changes, baseRevision: "base"),
                       XcodeHeadOnlySelector.select(current: head, source: .init(base: base.sources), changes: changes, baseRevision: "base")]
        for report in reports {
            let expected = opaque ? (includeObserver ? [marked, observer] : [marked]) : [plain, marked]
            #expect(Set(report.selectedTests) == Set(expected + (edit == .eagerTraitInCompanionHost ? [observer] : [])))
            let fallback = report.diagnostics.filter { $0.code == "swift_testing_discovery_effects" }
            if edit == .eagerTraitInCompanionHost {
                #expect(report.explanations.contains {
                    $0.test == observer && $0.kind == "dependency" && $0.path.contains("Testing.discovery in CompanionTests")
                })
            }
            if opaque {
                #expect(Set(fallback.flatMap(\.tests)) == Set(includeObserver ? [observer] : []))
            } else {
                #expect(report.explanations.contains {
                    $0.test == plain && $0.kind == "dependency" && $0.path.contains("Testing.discovery in LocalTests")
                })
            }
        }
    }
}
