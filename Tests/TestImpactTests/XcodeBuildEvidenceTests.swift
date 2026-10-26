// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Testing
@testable import TestImpact

private final class EvidenceFixture {
    let folder: URL
    var root: URL { folder.appendingPathComponent("source") }
    var derived: URL { folder.appendingPathComponent("DerivedData") }
    var description: URL { derived.appendingPathComponent("Build/Intermediates.noindex/XCBuildData/session.xcbuilddata") }
    var metadata: URL { description.deletingLastPathComponent().appendingPathComponent("PIFCache/target/TARGET@v12_hash=fixture-json") }
    var list: URL { derived.appendingPathComponent("Build/Intermediates.noindex/Core.build/Core.SwiftFileList") }
    var generated: URL { derived.appendingPathComponent("Build/Intermediates.noindex/Core.build/DerivedSources/resource_bundle_accessor.swift") }
    var log: String { "Build description path: \(description.path)\n" }
    var args: [String] { ["/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc", "-module-name", "Core", "@" + list.path, "-Onone", "-g"] }
    var record: [String: Any] = ["name": "Core", "guid": "package-core", "type": "standard", "productTypeIdentifier": "org.swift.product-type.library.static",
        "buildConfigurations": [["guid": "config-id", "name": "Debug", "buildSettings": ["PRODUCT_MODULE_NAME": "Core", "GENERATE_RESOURCE_ACCESSORS": "YES", "PACKAGE_RESOURCE_BUNDLE_NAME": "Core_Core"]]]]
    var commands: [String: [String: Any]] { [
        "P0:target-Core-package-core-:Debug:SwiftDriver Compilation Core normal arm64": ["tool": "swift-driver-compilation", "inputs": [list.path], "outputs": []],
        "P2:target-Core-package-core-:Debug:WriteAuxiliaryFile " + generated.path: ["tool": "auxiliary-file", "inputs": ["<target-Core-package-core--immediate>"], "outputs": [generated.path]]
    ] }
    init(parent: URL = FileManager.default.temporaryDirectory) throws {
        folder = parent.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try write("public func value() -> Int { 42 }", to: root.appendingPathComponent("Core.swift"))
        try write("package resource settings", to: root.appendingPathComponent("Package.swift"))
        try write("resource", to: root.appendingPathComponent("Resources/value.txt"))
        try write("extension Bundle { static let module = Bundle.main }", to: generated)
        try write(root.appendingPathComponent("Core.swift").path + "\n" + generated.path, to: list)
        try save()
    }
    deinit { try? FileManager.default.removeItem(at: folder) }
    func write(_ value: String, to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try value.write(to: file, atomically: true, encoding: .utf8)
    }
    func save(commands: [String: [String: Any]]? = nil) throws {
        try write(String(decoding: JSONSerialization.data(withJSONObject: record), as: UTF8.self), to: metadata)
        try write(String(decoding: JSONSerialization.data(withJSONObject: ["commands": commands ?? self.commands]), as: UTF8.self), to: description.appendingPathComponent("manifest.json"))
    }
    func evidence() throws -> XcodeBuildEvidence { try .init(log: log, root: root, derived: derived) }
    func boundary(arguments: [String]? = nil) throws -> GeneratedSourceBoundary {
        try evidence().boundary(file: generated, module: "Core", list: list, arguments: arguments ?? args,
            repositoryInputs: XcodeBuildEvidence.repositoryInputs(root: root, derived: derived))
    }
}

@Test func activeMetadataProvesProductionRoleWithoutGuessingFromName() throws {
    let f = try EvidenceFixture()
    let role = try f.evidence().role(module: "Core", list: f.list)
    #expect(role.targetName == "Core" && role.productType == "org.swift.product-type.library.static")
    var target = XcodeTarget(name: "Compiler module: Core", productType: "compiler-module", sourceFiles: ["Core.swift"])
    #expect(!target.hasProductionRole)
    target.recoveredRole = role
    #expect(target.hasProductionRole && !target.isTest)
    let inputs = try ArtifactFiles.sourceInputs(log: f.log + "builtin-SwiftDriver -- " + f.args.joined(separator: " "), directory: f.root)
    #expect(inputs.keys.contains { URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath() == f.metadata.standardizedFileURL.resolvingSymlinksInPath() }, "\(inputs.keys.sorted())")
    #expect(inputs[f.description.appendingPathComponent("manifest.json").path] != nil)
}

@Test(arguments: ["test", "unknown", "host", "module", "duplicate", "inactive", "missing", "changed"])
func recoveredRoleRejectsIncompleteOrContradictoryEvidence(scenario: String) throws {
    let f = try EvidenceFixture()
    switch scenario {
    case "test": f.record["productTypeIdentifier"] = "com.apple.product-type.bundle.unit-test"
    case "unknown": f.record["productTypeIdentifier"] = "unknown"
    case "host": f.record["buildConfigurations"] = [["buildSettings": ["TEST_HOST": "/App.app/App"]]]
    case "module": f.record["buildConfigurations"] = [["buildSettings": ["PRODUCT_MODULE_NAME": "Other"]]]
    case "inactive": f.record["guid"] = "other-build"
    default: break
    }
    try f.save()
    if scenario == "duplicate" { try FileManager.default.copyItem(at: f.metadata, to: f.metadata.deletingLastPathComponent().appendingPathComponent("stale-json")) }
    if scenario == "missing" { try FileManager.default.removeItem(at: f.metadata) }
    let evidence = try f.evidence()
    if scenario == "changed" {
        try f.write("{}", to: f.metadata)
        #expect(throws: (any Error).self) { try evidence.validate(log: f.log) }
    } else { #expect(throws: (any Error).self) { try evidence.role(module: "Core", list: f.list) } }
}

@Test func generatedBoundaryIsStableAcrossBuildDirectoriesAndSwiftOnlyEdits() throws {
    let a = try EvidenceFixture(), b = try EvidenceFixture()
    #expect(try a.boundary() == b.boundary())
    try b.write("// comment\npublic func value() -> Int { 43 }", to: b.root.appendingPathComponent("Core.swift"))
    #expect(try a.boundary() == b.boundary())
    try FileManager.default.moveItem(at: b.root.appendingPathComponent("Core.swift"), to: b.root.appendingPathComponent("Moved.swift"))
    #expect(try a.boundary() == b.boundary())
}

@Test(arguments: ["content", "resource", "membership", "package", "settings", "flags"])
func generatedBoundaryChangesWithItsInputs(change: String) throws {
    let f = try EvidenceFixture(), before = try f.boundary()
    switch change {
    case "content": try f.write("extension Bundle { static let module = Bundle() }", to: f.generated)
    case "resource": try f.write("new resource", to: f.root.appendingPathComponent("Resources/value.txt"))
    case "membership": try f.write("new resource", to: f.root.appendingPathComponent("Resources/new.txt"))
    case "package": try f.write("changed bundle declaration", to: f.root.appendingPathComponent("Package.swift"))
    case "settings":
        f.record["buildConfigurations"] = [["name": "Debug", "buildSettings": ["PRODUCT_MODULE_NAME": "Core", "PACKAGE_RESOURCE_BUNDLE_NAME": "Other"]]]
        try f.save()
    default: break
    }
    #expect(try before != f.boundary(arguments: change == "flags" ? f.args + ["-D", "OTHER"] : nil))
}

@Test func arbitraryGeneratedFilesAndConflictingProducersStayUnsupported() throws {
    let f = try EvidenceFixture()
    var commands = f.commands
    let key = try #require(commands.keys.first { $0.contains("WriteAuxiliaryFile") })
    commands[key]?["tool"] = "shell"
    try f.save(commands: commands)
    #expect(throws: (any Error).self) { try f.boundary() }
    commands = f.commands
    commands["another-producer"] = commands[key]
    try f.save(commands: commands)
    #expect(throws: (any Error).self) { try f.boundary() }
}

/// Optional development replay. Does not label retained inputs a fresh build.
@Test func retainedBuildEvidenceReplay() throws {
    guard let path = ProcessInfo.processInfo.environment["IMPACT_BUILD_EVIDENCE_REPLAY"] else { return }
    let directory = URL(fileURLWithPath: path), root = directory.appendingPathComponent("source"), derived = directory.appendingPathComponent("DerivedData")
    let log = try String(contentsOf: directory.appendingPathComponent("build.log"), encoding: .utf8)
    var graph = try GraphArchive.decode(Data(contentsOf: directory.appendingPathComponent("head-graph.json")))
    var unsupported: [String: [String]] = [:], generated: [String: [GeneratedSourceBoundary]] = [:], roles: [String: String] = [:]
    var diagnostics: [String] = [], classified = Set<URL>()
    graph.targets.removeAll { $0.productType == XcodeSourceOwnership.productType }
    graph.modules = graph.modules.filter { !($0.key.hasPrefix("Compiler module:")) }
    try XcodeSourceOwnership.recover(log: log, sourceRoot: root, derived: derived, activeInputs: nil,
        targets: &graph.targets, modules: &graph.modules, listOwners: [:], unsupportedInputs: &unsupported, classifiedLists: &classified,
        diagnostics: &diagnostics, evidence: XcodeBuildEvidence(log: log, root: root, derived: derived), generated: &generated, roleDiagnostics: &roles)
    print("EVIDENCE", "roles", roles, "unsupported", unsupported, "generated", generated.keys.sorted())
    #expect(diagnostics.isEmpty && roles.isEmpty && unsupported.isEmpty)
    #expect(generated["ChainOfCustodyCore"]?.count == 1)
    #expect(graph.targets.first { graph.modules[$0.name] == "ShareExtension" }?.hasProductionRole == true)
}

@Test func generatedFilePathValuesRemainSemanticAcrossDerivedDataRoots() throws {
    let a = try EvidenceFixture(), b = try EvidenceFixture()
    for f in [a, b] { try f.write("func path() -> String { #filePath }", to: f.generated) }
    #expect(try a.boundary() != b.boundary())
    for f in [a, b] { try f.write("func path() -> String { #fileID }", to: f.generated) }
    #expect(try a.boundary() == b.boundary())
}

@Test func generatedInputSealRejectsChangesDuringCapture() throws {
    let f = try EvidenceFixture(), evidence = try f.evidence(), boundary = try f.boundary()
    try evidence.validate(log: f.log, boundaries: [boundary])
    try f.write("changed", to: f.root.appendingPathComponent("Resources/value.txt"))
    #expect(throws: (any Error).self) { try evidence.validate(log: f.log, boundaries: [boundary]) }
}

@Test func generatedEvidenceNormalizesPOSIXTemporaryDirectoryAliases() throws {
    let f = try EvidenceFixture(parent: URL(fileURLWithPath: "/tmp"))
    var args = f.args
    let resolved = try #require(realpath(f.derived.path, nil))
    defer { free(resolved) }
    let physical = String(cString: resolved)
    args = args.map { $0.replacingOccurrences(of: f.derived.path, with: physical) }
    #expect(try f.boundary() == f.boundary(arguments: args))
}
