// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import Testing
@testable import TestImpact

@Test func sealedCaptureChecksProvenanceCoverageAndEveryFile() throws {
    let temp = FileManager.default.temporaryDirectory.appendingPathComponent("sealed-sil-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temp) }
    _ = try CommandRunner.run("git", ["init"], at: temp)
    _ = try CommandRunner.run("git", ["-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "--allow-empty", "-m", "fixture"], at: temp)
    let root = try GitChanges.repositoryRoot(at: temp)
    let revision = try GitChanges.revision("HEAD", at: root)
    let source = root.appendingPathComponent("A.swift")
    let missing = root.appendingPathComponent("B.swift")
    try Data("func a() {}".utf8).write(to: source)
    try Data("func b() {}".utf8).write(to: missing)
    let job = root.appendingPathComponent("job")
    try FileManager.default.createDirectory(at: job, withIntermediateDirectories: true)
    let sil = job.appendingPathComponent("output.sil")
    try Data("// a(), loc \"\(source.path)\":1:1\nsil hidden @a : $@convention(thin) () -> () {\n} // end sil function\n".utf8).write(to: sil)
    let record: [String: Any] = ["status": "complete", "arguments": ["-module-name", "M", "-g", "-Onone"],
        "directory": root.path, "sources": [source.path: try ArtifactFiles.digest(source), missing.path: try ArtifactFiles.digest(missing)],
        "sourceFiles": [source.path, missing.path], "primaryFiles": [source.path], "silFiles": ["output.sil"], "silSHA256": ["output.sil": try ArtifactFiles.digest(sil)]]
    let manifest = job.appendingPathComponent("manifest.json")
    try JSONSerialization.data(withJSONObject: record).write(to: manifest)
    var seal: [String: Any] = ["schemaVersion": 1, "root": root.path, "revision": revision, "toolchain": "compiler",
        "buildLogDigest": "log", "buildSettingsDigest": "settings", "products": ["app": "digest"],
        "manifests": ["job/manifest.json": try ArtifactFiles.digest(manifest)], "inventory": ["M": [source.path, missing.path]]]
    let sealPath = root.appendingPathComponent("build.json")
    let log = root.appendingPathComponent("build.log")
    try Data("builtin-SwiftDriver -- swiftc -module-name M \"\(source.path)\" \"\(missing.path)\"\n".utf8).write(to: log)
    let inputs = XcodeBuildInputs(derivedData: root, buildLog: log, buildSettings: root, xctestrun: root, revision: revision)
    func load() throws -> CapturedSIL {
        try JSONSerialization.data(withJSONObject: seal).write(to: sealPath)
        return try CapturedSIL.load(at: root, root: root, inputs: inputs, logDigest: "log", settingsDigest: "settings", products: ["app": "digest"], toolchain: "compiler")
    }
    let incomplete = try load()
    #expect(incomplete.modules.isEmpty)
    #expect(incomplete.diagnostics.contains { $0.contains("replaying") })
    var complete = record
    complete["primaryFiles"] = [] // Whole-module capture covers both inputs.
    try JSONSerialization.data(withJSONObject: complete).write(to: manifest)
    seal["manifests"] = ["job/manifest.json": try ArtifactFiles.digest(manifest)]
    let capture = try load()
    #expect(capture.diagnostics.isEmpty)
    #expect(try capture.parse(module: "M", sourceRoot: root)?.functions["a"] != nil)
    seal["toolchain"] = "different"
    #expect(throws: (any Error).self) { try load() }
    seal["toolchain"] = "compiler"
    try Data("tampered".utf8).write(to: sil)
    #expect(throws: (any Error).self) { try load() }
}

@Test func hashingAndSourceInventoriesDetectChangesAndPreserveParallelResults() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    for i in 0..<20 { try Data(repeating: UInt8(i), count: 16384).write(to: root.appendingPathComponent("\(i).swift")) }
    #expect(try ArtifactFiles.manifest(at: root, workers: 1) == ArtifactFiles.manifest(at: root, workers: 4))
    let list = root.appendingPathComponent("M.SwiftFileList")
    try Data("\"\(root.path)/0.swift\"\n".utf8).write(to: list)
    let before = try ArtifactFiles.sourceInputs(derived: root, directory: root)
    try Data("new source".utf8).write(to: root.appendingPathComponent("0.swift"))
    #expect(try before != ArtifactFiles.sourceInputs(derived: root, directory: root))
}
