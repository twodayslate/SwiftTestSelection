// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
import Foundation
import Testing
@testable import TestImpact

@Test(arguments: [1, 2])
func uncachedCaptureDeclinesUnvalidatedLateReplay(workers: Int) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("late-replay-" + UUID().uuidString)
    let sourceRoot = root.appendingPathComponent("source")
    try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = sourceRoot.appendingPathComponent("Value.swift")
    try Data("public func value() -> Int { 42 }".utf8).write(to: source)
    let validSIL = root.appendingPathComponent("valid.sil")
    _ = try CommandRunner.run("xcrun", ["swiftc", "-module-name", "Replay", "-parse-as-library",
        "-emit-sil", "-Onone", "-g", source.path, "-o", validSIL.path], at: root)
    let unsupported = root.appendingPathComponent("unsupported.sil")
    try Data("unsupported capture layout".utf8).write(to: unsupported)
    // This dependency lies outside the source export and is not a direct
    // compiler operand. The replay double reads it after extraction starts,
    // when parsing has discovered the unsupported layout. A late scan cannot
    // detect that the bytes changed earlier in extraction.
    let header = root.appendingPathComponent("Dependency.h")
    try Data("before".utf8).write(to: header)
    let compiler = root.appendingPathComponent("compiler.py")
    try Data(#"""
    #!/usr/bin/env python3
    import pathlib, sys
    root = pathlib.Path(__file__).parent
    (root / 'replayed').write_text((root / 'Dependency.h').read_text())
    pathlib.Path(sys.argv[sys.argv.index('-o') + 1]).write_bytes((root / 'valid.sil').read_bytes())
    """#.utf8).write(to: compiler)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: compiler.path)
    let log = "builtin-SwiftDriver -- \(compiler.path) -module-name Replay -parse-as-library -g -Onone \(source.path)"
    func extract(_ file: URL) async throws -> (DependencyGraph, [String]) {
        let captured = CapturedSIL(modules: ["Replay": [file]],
            fingerprints: [file.path: try ArtifactFiles.digest(file)], diagnostics: [])
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                var phases: [String] = []
                let graph = XcodeCompilerGraph.extract(log: log, sourceRoot: sourceRoot, directory: root,
                    derived: root, progress: { message in
                        if message.hasPrefix("Extracting ") {
                            // Check this write below instead of throwing through
                            // the nonthrowing progress callback.
                            try? Data("changed during extraction".utf8).write(to: header)
                        }
                    }, ownership: ["Replay": ["Value.swift"]], workers: workers, captured: captured,
                    measurement: { phase, _ in phases.append(phase) }, allowCompilerReplay: false)
                continuation.resume(returning: (graph, phases))
            }
        }
    }
    let (fast, fastPhases) = try await extract(validSIL)
    #expect(fast.diagnostics.isEmpty && !fast.functions.isEmpty)
    #expect(fastPhases.contains("captureConsumption") && !fastPhases.contains("compilerReplay"))
    try Data("before".utf8).write(to: header)
    let (rejected, phases) = try await extract(unsupported)
    #expect(try String(contentsOf: header, encoding: .utf8) == "changed during extraction")
    #expect(rejected.functions.isEmpty)
    #expect(rejected.diagnostics.contains { $0.contains("dependency inputs were not validated before extraction") })
    #expect(!phases.contains("compilerReplay"))
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("replayed").path))
}
