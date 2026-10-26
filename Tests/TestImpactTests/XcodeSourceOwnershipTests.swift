// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import Testing
@testable import TestImpact

private final class OwnershipFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
    var derived: URL { root.appendingPathComponent("DerivedData") }
    var targets: [XcodeTarget] = []
    var modules: [String: String] = [:]
    var diagnostics: [String] = []
    var classified = Set<URL>()
    var owners: [URL: Set<String>] = [:]
    var unsupportedInputs: [String: [String]] = [:]
    var log = ""
    init() throws { try FileManager.default.createDirectory(at: derived, withIntermediateDirectories: true) }
    deinit { try? FileManager.default.removeItem(at: root) }
    @discardableResult func source(_ path: String) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "func value() -> Int { 1 }".write(to: url, atomically: true, encoding: .utf8)
        return url
    }
    @discardableResult func invocation(_ module: String, paths: [String], list: String? = nil) throws -> URL {
        let url = derived.appendingPathComponent((list ?? module) + ".SwiftFileList")
        try paths.map { "\"\(root.appendingPathComponent($0).path)\"" }.joined(separator: "\n")
            .write(to: url, atomically: true, encoding: .utf8)
        log += "SwiftDriver\n builtin-SwiftDriver -- swiftc -module-name \(module) @\"\(url.path)\" -Onone\n"
        return url
    }
    func recover(active: Set<String>? = nil) {
        var generated: [String: [GeneratedSourceBoundary]] = [:], roles: [String: String] = [:]
        XcodeSourceOwnership.recover(log: log, sourceRoot: root, derived: derived, activeInputs: active,
            targets: &targets, modules: &modules, listOwners: owners, unsupportedInputs: &unsupportedInputs, classifiedLists: &classified, diagnostics: &diagnostics, generated: &generated, roleDiagnostics: &roles)
    }
}

@Test func compilerOwnershipRecoversTransitiveModulesAndSharedFiles() throws {
    let f = try OwnershipFixture()
    for path in ["Local Core/Value.swift", "Shared.swift", "Share/Controller.swift", "Messages/Controller.swift"] { try f.source(path) }
    try f.invocation("LocalCore", paths: ["Local Core/Value.swift", "Shared.swift"])
    try f.invocation("ShareExtension", paths: ["Share/Controller.swift", "Shared.swift"])
    try f.invocation("MessagesExtension", paths: ["Messages/Controller.swift"])
    f.recover()
    #expect(f.diagnostics.isEmpty)
    #expect(f.classified.count == 3)
    #expect(Set(f.modules.values) == ["LocalCore", "ShareExtension", "MessagesExtension"])
    #expect(f.targets.filter { $0.sourceFiles.contains("Shared.swift") }.count == 2)
    #expect(f.targets.allSatisfy { $0.productType == XcodeSourceOwnership.productType && !$0.isTest })
}

@Test func compilerOwnershipMergesKnownTargetsWithoutInventingTestIdentities() throws {
    let f = try OwnershipFixture()
    try f.source("Tests.swift")
    let list = try f.invocation("TestsModule", paths: ["Tests.swift"])
    f.targets = [.init(name: "Tests", productType: "com.apple.product-type.bundle.unit-test", sourceFiles: [])]
    f.modules = ["Tests": "TestsModule"]
    f.owners = [list: ["Tests"]]
    f.recover()
    #expect(f.diagnostics.isEmpty)
    #expect(f.targets.count == 1)
    #expect(f.targets[0].isTest && f.targets[0].sourceFiles == ["Tests.swift"])
}

@Test func compilerOwnershipRejectsConflictsInactiveAndMissingInputs() throws {
    for scenario in ["module", "list", "settings", "inactive", "missingList", "missingSource", "relative", "generated", "duplicateOwners"] {
        let f = try OwnershipFixture()
        try f.source("Core.swift")
        let list = try f.invocation("Core", paths: ["Core.swift"])
        switch scenario {
        case "module": f.log += f.log.replacingOccurrences(of: "-Onone", with: "-O")
        case "list": f.log += f.log.replacingOccurrences(of: "-module-name Core", with: "-module-name Other")
        case "settings":
            f.targets = [.init(name: "App", productType: "app", sourceFiles: ["Core.swift"])]
            f.modules = ["App": "App"]; f.owners = [list: ["App"]]
        case "missingList": try FileManager.default.removeItem(at: list)
        case "missingSource": try FileManager.default.removeItem(at: f.root.appendingPathComponent("Core.swift"))
        case "relative": f.log = f.log.replacingOccurrences(of: list.path, with: "relative.SwiftFileList")
        case "generated", "mixed":
            try f.source("DerivedData/Generated.swift")
            try f.invocation("Core", paths: scenario == "mixed" ? ["Core.swift", "DerivedData/Generated.swift"] : ["DerivedData/Generated.swift"])
        case "duplicateOwners":
            f.targets = ["A", "B"].map { .init(name: $0, productType: "app", sourceFiles: []) }
            f.modules = ["A": "Core", "B": "Core"]
        default: break
        }
        f.recover(active: scenario == "inactive" ? [] : nil)
        #expect(!f.diagnostics.isEmpty, "Missing diagnostic for \(scenario)")
        #expect(f.classified.isEmpty, "Accepted unsupported ownership for \(scenario)")
        #expect(!f.targets.contains { $0.productType == XcodeSourceOwnership.productType })
    }
}

@Test func compilerOwnershipIgnoresExternalPackagesAndAcceptsValidatedActiveLists() throws {
    let f = try OwnershipFixture()
    try f.source("Core.swift")
    let local = try f.invocation("Core", paths: ["Core.swift"])
    let external = try f.invocation("External", paths: [])
    try "/external/package/Value.swift".write(to: external, atomically: true, encoding: .utf8)
    f.recover(active: [local.path, external.path])
    #expect(f.diagnostics.isEmpty)
    #expect(f.classified.count == 2)
    #expect(f.targets.count == 1 && f.modules.values.contains("Core"))
}

/// Opt-in ownership replay against retained consumer inputs, without rebuilding
/// or executing the consumer. The Xcode integration fixture covers execution.
@Test func retainedCompilerOwnershipReplay() throws {
    guard let path = ProcessInfo.processInfo.environment["IMPACT_OWNERSHIP_REPLAY"] else { return }
    let config = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    func url(_ key: String) throws -> URL { URL(fileURLWithPath: try #require(config[key])) }
    var graph = try GraphArchive.decode(Data(contentsOf: url("graph")))
    graph.targets.removeAll { $0.name == "Unclassified build inputs" }
    let log = try String(contentsOf: url("log"), encoding: .utf8)
    var classified = Set<URL>(), diagnostics: [String] = []
    var unsupportedInputs: [String: [String]] = [:]
    var generated: [String: [GeneratedSourceBoundary]] = [:], roles: [String: String] = [:]
    XcodeSourceOwnership.recover(log: log, sourceRoot: try url("root"), derived: try url("derived"), activeInputs: nil,
        targets: &graph.targets, modules: &graph.modules, listOwners: [:], unsupportedInputs: &unsupportedInputs, classifiedLists: &classified, diagnostics: &diagnostics, generated: &generated, roleDiagnostics: &roles)
    #expect(diagnostics.isEmpty, "\(diagnostics)")
    let expected = try #require(config["snapshot"])
    for target in graph.targets where target.productType == XcodeSourceOwnership.productType {
        let module = try #require(graph.modules[target.name])
        for path in target.sourceFiles {
            let source = try String(contentsOf: url("root").appendingPathComponent(path), encoding: .utf8)
            let snapshot = SwiftSourceSnapshot.parse(source, path: path, module: module)
            #expect(snapshot.diagnostics.isEmpty, "\(module):\(path): \(snapshot.diagnostics)")
            graph.sources[module + ":" + path] = snapshot
        }
        print("Recovered \(module): \(target.sourceFiles.count) semantic source snapshots; unsupported inputs: \(unsupportedInputs[module] ?? [])")
    }
    #expect(graph.sources[expected] != nil, "Missing recovered snapshot \(expected)")
}

@Test func mixedGeneratedInputsPreserveRepositoryOwnershipAndReportUnsupportedInputs() throws {
    let f = try OwnershipFixture()
    try f.source("Core.swift")
    try f.source("DerivedData/Generated.swift")
    try f.invocation("Core", paths: ["Core.swift", "DerivedData/Generated.swift"])
    f.recover()
    #expect(f.diagnostics.isEmpty)
    #expect(f.targets.first?.sourceFiles == ["Core.swift"])
    #expect(f.unsupportedInputs == ["Core": ["<DerivedData>/Generated.swift"]])
    #expect(f.classified.count == 1)
}

@Test(arguments: [false, true])
func generatedOnlyOwnershipIsIndependentOfDerivedDataLocation(external: Bool) throws {
    let f = try OwnershipFixture()
    let source = external ? f.root.appendingPathComponent("Checkout") : f.root
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    let list = try f.invocation("Generated", paths: ["DerivedData/Build/Intermediates.noindex/Generated.swift"])
    var targets: [XcodeTarget] = [], modules: [String: String] = [:], unsupported: [String: [String]] = [:]
    var classified = Set<URL>(), diagnostics: [String] = []
    func recover() {
        var generated: [String: [GeneratedSourceBoundary]] = [:], roles: [String: String] = [:]
        XcodeSourceOwnership.recover(log: f.log, sourceRoot: source, derived: f.derived, activeInputs: nil,
            targets: &targets, modules: &modules, listOwners: [:], unsupportedInputs: &unsupported,
            classifiedLists: &classified, diagnostics: &diagnostics, generated: &generated, roleDiagnostics: &roles)
    }
    recover()
    #expect(diagnostics == ["Compiler source ownership unavailable for Generated: Generated source ownership is unsupported"])
    #expect(classified.isEmpty && targets.isEmpty)

    // A normal remote Swift package checkout inside DerivedData is still external.
    try f.derived.appendingPathComponent("SourcePackages/checkouts/Package/Sources/Value.swift").path
        .write(to: list, atomically: true, encoding: .utf8)
    diagnostics = []
    recover()
    #expect(diagnostics.isEmpty && classified == [list] && targets.isEmpty)

    // Resource-bearing external packages also compile generated accessors.
    try ["SourcePackages/checkouts/Package/Sources/Value.swift", "Build/Intermediates.noindex/DerivedSources/resource_bundle_accessor.swift"]
        .map { f.derived.appendingPathComponent($0).path }.joined(separator: "\n")
        .write(to: list, atomically: true, encoding: .utf8)
    classified = []
    recover()
    #expect(diagnostics.isEmpty && classified == [list] && targets.isEmpty)
}
