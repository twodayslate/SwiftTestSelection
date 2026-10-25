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
    let log = "builtin-SwiftDriver -- swiftc -module-name M @\"\(list.path)\""
    let before = try ArtifactFiles.sourceInputs(log: log, directory: root)
    try Data("new source".utf8).write(to: root.appendingPathComponent("0.swift"))
    #expect(try before != ArtifactFiles.sourceInputs(log: log, directory: root))
}

@Test func compilerSourceFingerprintIgnoresInactiveListsButRejectsMissingActiveInputs() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("Active.swift")
    let list = root.appendingPathComponent("Active.SwiftFileList")
    try Data("func active() {}".utf8).write(to: source)
    try Data("Active.swift\n".utf8).write(to: list)
    let log = "builtin-SwiftDriver -- swiftc -module-name Active @Active.SwiftFileList"
    let before = try ArtifactFiles.sourceInputs(log: log, directory: root)
    let stale = root.appendingPathComponent("Inactive.SwiftFileList")
    try Data("Deleted.swift\n".utf8).write(to: stale)
    #expect(try ArtifactFiles.sourceInputs(log: log, directory: root) == before)
    // Adding an active source must change the fingerprint, even when its bytes
    // match another source. A missing active source or response file must fail.
    let added = root.appendingPathComponent("Added.swift")
    try Data(contentsOf: source).write(to: added)
    try Data("Active.swift Added.swift\n".utf8).write(to: list)
    #expect(try ArtifactFiles.sourceInputs(log: log, directory: root) != before)
    try FileManager.default.removeItem(at: added)
    #expect(throws: (any Error).self) { try ArtifactFiles.sourceInputs(log: log, directory: root) }
    try FileManager.default.removeItem(at: list)
    #expect(throws: (any Error).self) { try ArtifactFiles.sourceInputs(log: log, directory: root) }
}

@Test func compilerSourceFingerprintHandlesWorkingDirectoriesAndResponseFiles() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let nested = root.appendingPathComponent("Nested")
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let direct = nested.appendingPathComponent("Direct.swift")
    let literal = nested.appendingPathComponent("Space Name.swift")
    try Data("func direct() {}".utf8).write(to: direct)
    try Data("func literal() {}".utf8).write(to: literal)
    try Data("Space Name.swift\n".utf8).write(to: nested.appendingPathComponent("sources.list"))
    try Data("@nested.rsp".utf8).write(to: nested.appendingPathComponent("outer.rsp"))
    try Data("Direct.swift -filelist sources.list".utf8).write(to: nested.appendingPathComponent("nested.rsp"))
    let log = "cd \"\(nested.path)\"\nbuiltin-SwiftDriver -- swiftc -module-name M @outer.rsp"
    let fingerprints = try ArtifactFiles.sourceInputs(log: log, directory: root)
    #expect(fingerprints.count == 5)
    #expect(fingerprints[direct.path] != nil && fingerprints[literal.path] != nil)
    let working = "builtin-SwiftDriver -- swiftc -working-directory Nested Direct.swift"
    #expect(try ArtifactFiles.sourceInputs(log: working, directory: root)[direct.path] == fingerprints[direct.path])
    try Data("@outer.rsp".utf8).write(to: nested.appendingPathComponent("nested.rsp"))
    #expect(throws: ImpactError.self) { try ArtifactFiles.sourceInputs(log: log, directory: root) }
    #expect(throws: ImpactError.self) { try ArtifactFiles.sourceInputs(log: "", directory: root) }
}

@Test func mappingFingerprintTracksExistenceContentsAndResolvedPath() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("GeneratedMappings.json")
    let missing = try ArtifactFiles.mappingInputs(path: file.lastPathComponent, root: root)
    try Data(#"{"version":1,"features":[]}"#.utf8).write(to: file)
    let first = try ArtifactFiles.mappingInputs(path: file.lastPathComponent, root: root)
    #expect(first != missing)
    try Data("invalid JSON".utf8).write(to: file)
    #expect(try ArtifactFiles.mappingInputs(path: file.lastPathComponent, root: root) != first)
    try FileManager.default.removeItem(at: file)
    #expect(try ArtifactFiles.mappingInputs(path: file.lastPathComponent, root: root) == missing)
    let target = root.appendingPathComponent("Target.json")
    try Data(#"{"version":1,"features":[]}"#.utf8).write(to: target)
    try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
    #expect(try ArtifactFiles.mappingInputs(path: file.lastPathComponent, root: root) != first)
    #expect(throws: ImpactError.self) { try ArtifactFiles.mappingInputs(path: "../outside.json", root: root) }
    #expect(throws: ImpactError.self) { try ArtifactFiles.mappingInputs(path: file.path, root: root) }
}
