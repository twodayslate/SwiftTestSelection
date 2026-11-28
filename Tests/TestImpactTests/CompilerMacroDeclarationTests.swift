// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation
import Testing
@testable import TestImpact

@Test func serializedMacroNamesSurviveNewerSyntaxAndTrivia() {
    let comment = "/* " + String(repeating: "x", count: 700) + " */"
    let interface = "public var value: Swift::Int\npublic macro " + comment + " `repeat`()\npublic macro 🎈()"
    #expect(CompilerMacroDeclarations.names(in: interface) == ["repeat", "🎈"])
    #expect(CompilerMacroDeclarations.names(in: "@MainActor func update() {}").isEmpty)
}

@Test func macroNamesRemainWholeAtEveryFormerChunkBoundary() {
    for padding in 240...260 {
        let prefix = String(repeating: "a", count: padding)
        let name = prefix + "🎈suffix"
        let comment = "/* " + prefix + " /* nested */ */"
        for declaration in ["macro " + name + "()", "macro `" + name + "`()",
                            "macro " + comment + " `repeat`()"] {
            let expected = declaration.contains(comment) ? "repeat" : name
            #expect(CompilerMacroDeclarations.names(in: declaration) == [expected])
        }
    }
}

@Test func captureFindsBinaryMacrosAndRejectsChangedModuleBytes() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("binary-macro-declarations-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let plugin = try macroPlugin(expansion: "func peer() {}", root: root)
    var imports: [String: [String]] = [:], fingerprints: [String: String] = [:], printing: [String: [String]] = [:]
    func compile(_ module: String, source: String) throws {
        try Data(source.utf8).write(to: root.appendingPathComponent(module + ".swift"))
        let command = try CommandRunner.run("env", ["TMPDIR=" + root.path, "xcrun", "swiftc", "-v", "-save-temps",
            "-emit-module", "-explicit-module-build", "-module-name", module, "-I", root.path, "-load-plugin-executable", plugin,
            module + ".swift", "-emit-module-path", module + ".swiftmodule"], at: root)
        let log = String(decoding: command.stderr + command.stdout, as: UTF8.self)
        let line = try #require(log.components(separatedBy: .newlines).first {
            $0.contains(" -frontend ") && $0.contains(" -emit-module ") && $0.contains(" -explicit-swift-module-map-file ")
        })
        let arguments = try XcodeSourceFileList.parse(line)
        func operand(_ flag: String) throws -> String {
            let index = try #require(arguments.firstIndex(of: flag))
            return arguments[index + 1]
        }
        let frontend = try URL(fileURLWithPath: #require(arguments.first)).resolvingSymlinksInPath()
        fingerprints[frontend.path] = try ArtifactFiles.digest(frontend)
        let job = CapturedSIL.Job(status: "complete", compiler: frontend.path, arguments: arguments, directory: root.path,
            sources: [:], sourceFiles: [], primaryFiles: [], silFiles: [], silSHA256: [:])
        let commandForPrinting: [String] = try #require(job.moduleInterfaceCommand())
        printing[module] = commandForPrinting
        let map = try URL(fileURLWithPath: operand("-explicit-swift-module-map-file")).resolvingSymlinksInPath()
        fingerprints[map.path] = try ArtifactFiles.digest(map)
        let entries = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: map)) as? [[String: Any]])
        imports[module] = try entries.map { try #require($0["moduleName"] as? String) }
        for entry in entries {
            for key in ["modulePath", "clangModulePath", "clangModuleMapPath"] {
                guard let path = entry[key] as? String else { continue }
                let file = URL(fileURLWithPath: path).resolvingSymlinksInPath()
                fingerprints[file.path] = try ArtifactFiles.digest(file)
            }
        }
    }
    // The producer's dependencies contain only SDK modules. The client imports
    // the compiled producer. Its Swift source is deliberately absent at lookup.
    let longName = String(repeating: "a", count: 248) + "🎈suffix"
    let declaration = #"@attached(peer, names: named(peer)) public macro MainActor() = #externalMacro(module: "ReviewMacros", type: "CaptureLine")"#
    try compile("ActorKit", source: declaration + "\n" + declaration.replacingOccurrences(of: "MainActor()", with: longName + "()"))
    try compile("Client", source: "import ActorKit\npublic struct ClientValue {}")
    try FileManager.default.removeItem(at: root.appendingPathComponent("ActorKit.swift"))
    let build = HelperBindingBuildEvidence(sourceInputs: "fixture", inputFiles: fingerprints, importedModules: imports,
        buildLogDigest: "log", buildSettingsDigest: "settings", productsDigest: "products")
    let sil = CapturedSIL(modules: [:], fingerprints: [:], diagnostics: [], moduleInterfaceCommands: printing, compiledSourcePaths: [])
    let names = try CompilerMacroDeclarations.capture(modules: ["ActorKit", "Client"], sil: sil, build: build)
    #expect(try #require(names.namesByModule["ActorKit"]).contains("MainActor") == false)
    let clientNames = try #require(names.namesByModule["Client"])
    #expect(clientNames.isSuperset(of: ["MainActor", longName]))
    try Data("changed".utf8).write(to: root.appendingPathComponent("ActorKit.swiftmodule"))
    let changed = try CompilerMacroDeclarations.capture(modules: ["Client"], sil: sil, build: build)
    #expect(changed.namesByModule["Client"] == nil)
}

@Test func modulePrintingRequiresAnUnambiguousOrdinaryLookup() {
    var job = CapturedSIL.Job(status: "complete", compiler: "/toolchain/bin/swiftc",
        arguments: ["-sdk", "/SDK", "-target", "arm64-apple-ios26-simulator"], directory: "/work",
        sources: [:], sourceFiles: [], primaryFiles: [], silFiles: [], silSHA256: [:])
    #expect(job.moduleInterfaceCommand()?.dropFirst().map { $0 } == job.arguments)
    job.arguments += ["-clang-target", "arm64-apple-ios27-simulator"]
    #expect(job.moduleInterfaceCommand()?.last == "arm64-apple-ios27-simulator")
    for flags in [["-module-alias", "UI=HiddenUI"], ["-testable-import-module=Hidden"], ["-package-name", "Shared"],
                  ["-disable-access-control"], ["-enable-private-imports"], ["-target", "other-target"], ["-target-variant"]] {
        var unsupported = job
        unsupported.arguments += flags
        #expect(unsupported.moduleInterfaceCommand() == nil)
    }
}

@Test func indexedActorSeparatesSDKIsolationFromABuilderWithTheSameName() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let compiler = URL(fileURLWithPath: try CommandRunner.run("xcrun", ["--find", "swiftc"], at: root).text.trimmingCharacters(in: .whitespacesAndNewlines))
    let file = root.appendingPathComponent("Feature.swift")
    let function = "@MainActor private func title() -> String { \"Sharing\" }"
    let sdk = "import Observation\n@available(macOS 14, *) @Observable final class Model { var title = \"Shared\" }\n"
    let builder = "@resultBuilder enum MainActor { static func buildBlock(_ value: String, line: Int = #line) -> String { String(line) } }\n"
    for (prefix, expected) in [(sdk, true), (builder, false)] {
        let source = prefix + "\n\n" + function
        let store = root.appendingPathComponent(UUID().uuidString), object = root.appendingPathComponent("Feature.o")
        try Data(source.utf8).write(to: file)
        _ = try CommandRunner.run(compiler.path, ["-module-name", "Feature", "-parse-as-library", "-index-store-path", store.path, "-c", file.path, "-o", object.path], at: root)
        let before = SwiftSourceSnapshot.parse(prefix + "\n" + function, path: "Feature.swift", module: "Feature")
        var after = SwiftSourceSnapshot.parse(source, path: "Feature.swift", module: "Feature")
        func read(_ module: String) -> IndexedActorLocations? {
            IndexedActorLocations.capture(file: file, path: "Feature.swift", module: module, snapshot: after,
                compiler: compiler, store: store.path, output: object.path)
        }
        #expect(read("Wrong") == nil)
        let proof = read("Feature")
        #expect((proof != nil) == expected)
        guard let proof else { continue }
        var old = before
        let historical = try #require(proof.historical(prefix + "\n" + function, path: "Feature.swift", module: "Feature", before: before, after: after))
        historical.apply(to: &old)
        proof.apply(to: &after)
        #expect(after.attachedAttributeInputs?["Observable"] == old.attachedAttributeInputs?["Observable"])
        #expect(after.attachedAttributeInputs?["MainActor"] == nil)
        let unit = try #require(after.units.first { $0.helperCallableName == "title" })
        #expect(unit.builderLocations?.isEmpty == true && unit.callerLocations?.isEmpty == true)
        let movedMacro = "\n" + source
        #expect(proof.historical(movedMacro, path: "Feature.swift", module: "Feature",
            before: .parse(movedMacro, path: "Feature.swift", module: "Feature"), after: after) == nil)
    }
}
