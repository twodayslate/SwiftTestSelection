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
    func load(context: String? = nil, helper: String? = nil) throws -> CapturedSIL {
        try JSONSerialization.data(withJSONObject: seal).write(to: sealPath)
        return try CapturedSIL.load(at: root, root: root, inputs: inputs, logDigest: "log", settingsDigest: "settings", products: ["app": "digest"], toolchain: "compiler", expectedContext: context, expectedHelper: helper)
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
    seal["helperIdentity"] = "helper"
    seal["inputIdentity"] = ["context": "context", "helper": "helper"]
    _ = try load(context: "context", helper: "helper")
    #expect(throws: (any Error).self) { try load(context: "stale", helper: "helper") }
    #expect(throws: (any Error).self) { try load(context: "context", helper: "changed") }
    seal["toolchain"] = "different"
    #expect(throws: (any Error).self) { try load() }
    seal["toolchain"] = "compiler"
    try Data("tampered".utf8).write(to: sil)
    #expect(throws: (any Error).self) { try load() }
    try FileManager.default.removeItem(at: sil)
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

@Test func emptyAndPlatformExcludedPrimariesPreserveMixedCapturedModules() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("empty-primary-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let sources = ["Aliases.swift": "import Foundation\ntypealias Object = NSObject\n", "Empty.swift": "", "Excluded.swift": "#if os(Linux)\npublic func linuxOnly() {}\n#endif\n", "Real.swift": "public func value() -> Int { 42 }\n"]
    let sdk = try CommandRunner.run("xcrun", ["--show-sdk-path"], at: root).text.trimmingCharacters(in: .whitespacesAndNewlines)
    var args = ["-frontend", "-c", "-parse-as-library", "-sdk", sdk, "-g", "-Onone", "-module-name", "CaptureEmpty"]
    var map: [String: [String: String]] = [:]
    for (name, text) in sources.sorted(by: { $0.key < $1.key }) {
        let file = root.appendingPathComponent(name)
        try text.write(to: file, atomically: true, encoding: .utf8)
        args += ["-primary-file", file.path]
        map[file.path] = ["sil": root.appendingPathComponent(name + ".sil").path]
    }
    let fileMap = root.appendingPathComponent("outputs.json")
    try JSONEncoder().encode(map).write(to: fileMap)
    args += ["-supplementary-output-file-map", fileMap.path]
    for name in sources.keys.sorted() { args += ["-o", root.appendingPathComponent(name + ".o").path] }
    _ = try CommandRunner.run("swiftc", args, at: root)
    let files = sources.keys.sorted().map { root.appendingPathComponent($0 + ".sil") }
    for name in ["Empty.swift", "Excluded.swift", "Aliases.swift"] {
        let file = root.appendingPathComponent(name + ".sil")
        #expect(try SILParser.parse(file: file, module: "CaptureEmpty", sourceRoot: root).functions.isEmpty)
        try CapturedSIL.validateEmptyFragment(file)
    }
    let capture = CapturedSIL(modules: ["CaptureEmpty": files], fingerprints: try Dictionary(uniqueKeysWithValues: files.map { ($0.path, try ArtifactFiles.digest($0)) }), diagnostics: [])
    let fragment = try capture.parse(module: "CaptureEmpty", sourceRoot: root)
    let parsed = try #require(fragment)
    #expect(parsed.functions.values.contains { $0.name == "value()" })
    for malformed in ["", "sil_stage canonical\nimport Swift\n", "sil_stage raw\nimport Swift\n", "sil_stage canonical\nunsupported declaration"] {
        let file = root.appendingPathComponent("malformed.sil")
        try malformed.write(to: file, atomically: true, encoding: .utf8)
        #expect(throws: CapturedSIL.UnsupportedLayout.self) { try CapturedSIL.validateEmptyFragment(file) }
    }
}

@Test func unsupportedCapturedLayoutReplaysButIntegrityFailuresDoNot() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("capture-replay-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("Value.swift"), sil = root.appendingPathComponent("captured.sil")
    try "public func value() -> Int { 42 }".write(to: source, atomically: true, encoding: .utf8)
    try "unsupported capture layout".write(to: sil, atomically: true, encoding: .utf8)
    let compiler = try CommandRunner.run("xcrun", ["--find", "swiftc"], at: root).text.trimmingCharacters(in: .whitespacesAndNewlines)
    let log = "builtin-SwiftDriver -- \(compiler) -module-name CaptureReplay -parse-as-library -g -Onone \(source.path)"
    let captured = CapturedSIL(modules: ["CaptureReplay": [sil]], fingerprints: [sil.path: try ArtifactFiles.digest(sil)], diagnostics: [])
    // Do not block a Swift Testing cooperative executor while waiting for the
    // extractor's bounded worker queue (other compiled suites run concurrently).
    func extract() async -> (DependencyGraph, [String]) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                var messages: [String] = []
                let graph = XcodeCompilerGraph.extract(log: log, sourceRoot: root, directory: root, derived: root,
                    progress: { messages.append($0) }, ownership: ["CaptureReplay": ["Value.swift"]], captured: captured)
                continuation.resume(returning: (graph, messages))
            }
        }
    }
    let (graph, messages) = await extract()
    #expect(graph.diagnostics.isEmpty)
    #expect(graph.functions.values.contains { $0.name == "value()" })
    #expect(messages.contains { $0.contains("replaying module") })
    try "tampered".write(to: sil, atomically: true, encoding: .utf8)
    let (invalid, invalidMessages) = await extract()
    #expect(!invalid.diagnostics.isEmpty && invalid.functions.isEmpty)
    #expect(!invalidMessages.contains { $0.contains("replaying module") })
}

/// Read-only replay of the sealed real-app evidence from #44. No enumeration,
/// test bodies, source edits or artifact execution claims are involved.
@Test func sealedConsumerCaptureReplay() throws {
    guard let path = ProcessInfo.processInfo.environment["IMPACT_SEALED_CAPTURE_REPLAY"] else { return }
    let folder = URL(fileURLWithPath: path), session = folder.appendingPathComponent("head-capture")
    let seal = try JSONDecoder().decode(CapturedSIL.Seal.self, from: Data(contentsOf: session.appendingPathComponent("build.json")))
    let root = URL(fileURLWithPath: seal.root), derived = folder.appendingPathComponent("head-derived")
    let products = derived.appendingPathComponent("Build/Products")
    let runs = try FileManager.default.contentsOfDirectory(at: products, includingPropertiesForKeys: nil)
    let run = try #require(runs.first { $0.pathExtension == "xctestrun" })
    let inputs = XcodeBuildInputs(derivedData: derived, buildLog: session.appendingPathComponent("build.log"), buildSettings: session.appendingPathComponent("settings.json"), xctestrun: run, revision: seal.revision)
    let capture = try CapturedSIL.load(at: session, root: root, inputs: inputs, logDigest: ArtifactFiles.digest(inputs.buildLog),
        settingsDigest: ArtifactFiles.digest(inputs.buildSettings), products: ArtifactFiles.manifest(at: products), toolchain: ArtifactFiles.toolchain(at: root))
    var reference = try GraphArchive.decode(Data(contentsOf: folder.appendingPathComponent("head-graph.json")))
    let ownership = reference.targets.reduce(into: [String: Set<String>]()) { result, target in
        if let module = reference.modules[target.name] { result[module, default: []].formUnion(target.sourceFiles) }
    }
    let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("sealed-replay-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: scratch) }
    let log = try String(contentsOf: inputs.buildLog, encoding: .utf8)
    var messages: [String] = []
    var graph = XcodeCompilerGraph.extract(log: log, sourceRoot: root, directory: root, derived: scratch,
        progress: { message in messages.append(message); print(message) }, ownership: ownership, captured: capture)
    #expect(graph.diagnostics.isEmpty, "\(graph.diagnostics)")
    for module in ["CloudKitSyncMonitor", "SnapshotTesting"] {
        #expect(messages.contains { $0.contains("Captured SIL " + module + ": validated primary coverage") })
        #expect(graph.functions.values.contains { $0.module == module })
    }
    XcodeCompilerGraph.bind(tests: reference.tests, modules: reference.modules, sources: reference.sources, graph: &graph)
    reference.dependencies = graph; reference.buildArtifact = nil
    try capture.validateFiles()
    let output = folder.appendingPathComponent("issue44-repaired-graph.json")
    try JSONEncoder().encode(reference).write(to: output)
    print("Validated \(capture.modules.count) captured modules, \(reference.tests.count) enumerated entries, \(graph.functions.count) functions; output \(output.path)")
}

/// Opt-in comparison on an actual retained Xcode fixture. The same sealed
/// products/sources feed independent capture and ordinary compiler extraction.
@Test func retainedCaptureMatchesReplayedProjectDependencies() throws {
    guard let path = ProcessInfo.processInfo.environment["IMPACT_RETAINED_CAPTURE_PARITY"] else { return }
    let folder = URL(fileURLWithPath: path), session = folder.appendingPathComponent("SILCapture")
    let seal = try JSONDecoder().decode(CapturedSIL.Seal.self, from: Data(contentsOf: session.appendingPathComponent("build.json")))
    let root = URL(fileURLWithPath: seal.root, isDirectory: true)
    let derived = folder.appendingPathComponent("DerivedData"), products = derived.appendingPathComponent("Build/Products")
    let runs = try FileManager.default.contentsOfDirectory(at: products, includingPropertiesForKeys: nil)
    let run = try #require(runs.first { $0.pathExtension == "xctestrun" })
    let inputs = XcodeBuildInputs(derivedData: derived, buildLog: session.appendingPathComponent("build.log"), buildSettings: session.appendingPathComponent("settings.json"), xctestrun: run, revision: seal.revision)
    let captured = try CapturedSIL.load(at: session, root: root, inputs: inputs, logDigest: ArtifactFiles.digest(inputs.buildLog),
        settingsDigest: ArtifactFiles.digest(inputs.buildSettings), products: ArtifactFiles.manifest(at: products), toolchain: ArtifactFiles.toolchain(at: root),
        exportedRevision: seal.revision, sourceExportDigest: ArtifactFiles.digest(folder.appendingPathComponent("source-export.json")),
        expectedContext: seal.inputIdentity?.context, expectedHelper: seal.helperIdentity)
    let reference = try GraphArchive.decode(Data(contentsOf: folder.appendingPathComponent("head-graph.json")))
    let ownership = reference.targets.reduce(into: [String: Set<String>]()) { result, target in
        if let module = reference.modules[target.name] { result[module, default: []].formUnion(target.sourceFiles) }
    }
    let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("capture-parity-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: scratch) }
    let log = try String(contentsOf: inputs.buildLog, encoding: .utf8)
    var graphs: [DependencyGraph] = []
    for useCapture in [true, false] {
        var graph = XcodeCompilerGraph.extract(log: useCapture ? log : try captured.replayLog(log), sourceRoot: root,
            directory: root, derived: scratch, progress: { print($0) }, ownership: ownership, captured: useCapture ? captured : nil)
        #expect(graph.diagnostics.isEmpty, "\(graph.diagnostics)")
        XcodeCompilerGraph.bind(tests: reference.tests, modules: reference.modules, sources: reference.sources, graph: &graph)
        graphs.append(graph)
    }
    #expect(graphs[0].tests == graphs[1].tests)
    func projectFunctions(_ graph: DependencyGraph) -> Set<String> {
        Set(graph.functions.values.filter { node in
            node.regions.contains { ownership[node.module]?.contains($0.path) == true }
        }.map(\.id))
    }
    let project = projectFunctions(graphs[0]).union(projectFunctions(graphs[1]))
    for test in reference.tests {
        for id in project {
            let capturedPath = graphs[0].dependencyPath(from: graphs[0].tests[test] ?? [], to: [id])
            let replayedPath = graphs[1].dependencyPath(from: graphs[1].tests[test] ?? [], to: [id])
            #expect((capturedPath != nil) == (replayedPath != nil), "\(test) -> \(id)")
        }
    }
    print("Capture/replay reachability agrees for \(reference.tests.count) tests and \(project.count) project functions")
}
