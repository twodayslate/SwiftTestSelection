// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
import Foundation
import Testing
@testable import TestImpact

@Test func formattingBuildInputsBindFlagsWithoutBindingLogNoiseOrWorkspacePaths() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("formatting-build-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    func capture(_ name: String, setting: String = "DEBUG", flags: String = "-D DEBUG -Onone", noise: String = "", response: Bool = true) throws -> HelperFormattingBuildEvidence {
        let source = root.appendingPathComponent(name + "/source"), derived = root.appendingPathComponent(name + "/DerivedData")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: derived, withIntermediateDirectories: true)
        try Data("// an editable review comment\n".utf8).write(to: source.appendingPathComponent("Tests.swift"))
        try Data((source.appendingPathComponent("Tests.swift").path + "\n").utf8).write(to: derived.appendingPathComponent("sources.list"))
        let args = "-module-name Tests \(flags) -filelist \(derived.path)/sources.list -o \(derived.path)/Tests.o"
        try Data(args.utf8).write(to: source.appendingPathComponent("args.rsp"))
        let log = Data("\(noise)\ncd \(source.path)\nbuiltin-SwiftDriver -- /toolchain/swiftc \(response ? "@args.rsp" : args)\n** TEST BUILD SUCCEEDED **\n".utf8)
        let settings = try JSONSerialization.data(withJSONObject: [["target": "Tests", "buildSettings": ["SOURCE_ROOT": source.path, "BUILD_DIR": derived.path, "SWIFT_ACTIVE_COMPILATION_CONDITIONS": setting]]])
        return try .capture(log: log, settings: settings, source: source, derived: derived)
    }
    let first = try capture("first"), equivalent = try capture("second", noise: "New timestamp; unrelated progress")
    #expect(first.fingerprint == equivalent.fingerprint)
    #expect(first.buildLogDigest != equivalent.buildLogDigest)
    #expect(first.buildSettingsDigest != equivalent.buildSettingsDigest)
    #expect(try capture("first", setting: "OTHER").fingerprint != first.fingerprint)
    #expect(try capture("first", flags: "-D OTHER -Onone").fingerprint != first.fingerprint)
    #expect(try capture("first", flags: "-Onone -D DEBUG").fingerprint != first.fingerprint)
    #expect(try capture("first", response: false).fingerprint == first.fingerprint)
}

@Test func formattingBuildInputsRejectMissingOrRecursiveInvocationEvidence() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("formatting-missing-build-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let settings = Data(#"[{"buildSettings":{"CONFIGURATION":"Debug"}}]"#.utf8)
    for line in ["no compiler commands", "builtin-SwiftDriver -- swiftc -Onone", "builtin-SwiftDriver -- swiftc @missing.rsp"] {
        #expect(throws: ImpactError.self) {
            // File read failures are also rejected, but Foundation owns their type.
            do { _ = try HelperFormattingBuildEvidence.capture(log: Data(line.utf8), settings: settings, source: root, derived: root) }
            catch { throw ImpactError(String(describing: error)) }
        }
    }
    #expect(throws: ImpactError.self) {
        _ = try HelperFormattingBuildEvidence.capture(log: Data("builtin-SwiftDriver -- swiftc -module-name UI".utf8), settings: Data("[]".utf8), source: root, derived: root)
    }
    try Data("@recursive.rsp".utf8).write(to: root.appendingPathComponent("recursive.rsp"))
    #expect(throws: ImpactError.self) {
        _ = try HelperFormattingBuildEvidence.capture(log: Data("builtin-SwiftDriver -- swiftc @recursive.rsp".utf8), settings: settings, source: root, derived: root)
    }
}
