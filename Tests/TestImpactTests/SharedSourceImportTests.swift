// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import Testing
@testable import TestImpact

@Test func sharedSourceImportsPreserveDefiningModuleAndFeatureMappings() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
    let derived = root.appendingPathComponent("DerivedData")
    try FileManager.default.createDirectory(at: derived, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("Shared.swift")
    try """
    #if SECOND
    import First
    public func invoke() -> Int { First.value() }
    #else
    @_transparent public func value() -> Int { helper() }
    @usableFromInline internal func helper() -> Int { 1 }
    #endif
    """.write(to: source, atomically: true, encoding: .utf8)
    let compiler = try CommandRunner.run("xcrun", ["--find", "swiftc"], at: root).text.trimmingCharacters(in: .whitespacesAndNewlines)
    _ = try CommandRunner.run(compiler, ["-emit-module", "-module-name", "First", source.path,
        "-emit-module-path", derived.appendingPathComponent("First.swiftmodule").path, "-Onone", "-g"], at: root)
    var logs: [String] = [], captures: [String: [URL]] = [:]
    for module in ["First", "Second"] {
        let list = derived.appendingPathComponent(module + ".SwiftFileList")
        try source.path.write(to: list, atomically: true, encoding: .utf8)
        let args = ["-module-name", module, "@" + list.path, "-I", derived.path, "-Onone", "-g"] + (module == "Second" ? ["-DSECOND"] : [])
        logs.append("builtin-SwiftDriver -- " + ([compiler] + args).map { "\"" + $0 + "\"" }.joined(separator: " "))
        let sil = derived.appendingPathComponent(module + ".sil")
        _ = try CommandRunner.run(compiler, args + ["-emit-sil", "-whole-module-optimization", "-o", sil.path], at: root)
        captures[module] = [sil]
        let parsed = try SILParser.parse(file: sil, module: module, sourceRoot: root)
        let restored = try GraphArchive.decodeValue(SILModule.self, from: GraphArchive.encodeValue(parsed))
        #expect(restored.importedSymbols == parsed.importedSymbols)
        #expect(restored.importedSymbols?.contains("$s5First5valueSiyF") == (module == "Second"))
    }
    var targets: [XcodeTarget] = [], modules: [String: String] = [:], unsupported: [String: [String]] = [:]
    var classified = Set<URL>(), diagnostics: [String] = []
    XcodeSourceOwnership.recover(log: logs.joined(separator: "\n"), sourceRoot: root, derived: derived, activeInputs: nil,
        targets: &targets, modules: &modules, listOwners: [:], unsupportedInputs: &unsupported,
        classifiedLists: &classified, diagnostics: &diagnostics)
    #expect(diagnostics.isEmpty)
    let ownership = Dictionary(uniqueKeysWithValues: targets.map { (modules[$0.name]!, $0.sourceFiles) })
    #expect(ownership == ["First": ["Shared.swift"], "Second": ["Shared.swift"]])
    let capture = CapturedSIL(modules: captures, fingerprints: [:], diagnostics: [])
    for captured in [false, true] {
        for workers in [1, 2] {
            for order in [logs, Array(logs.reversed())] {
                let graph = XcodeCompilerGraph.extract(log: order.joined(separator: "\n"), sourceRoot: root,
                    directory: root, derived: derived, progress: { _ in }, ownership: ownership,
                    workers: workers, captured: captured ? capture : nil)
                #expect(graph.diagnostics.isEmpty)
                let node = try #require(graph.functions["$s5First5valueSiyF"])
                #expect(node.module == "First" && node.name == "value()")
                #expect(node.dependencies.contains("$s5First6helperSiyF"))
                var snapshot = XcodeTestGraph(targets: targets, tests: ["UI/Features/testValue()"])
                snapshot.modules = modules
                let mappings = UIFeatureMappings(features: [.init(name: "value", symbols: ["First.value()"], tests: snapshot.tests)])
                let index = MappingIndex(mappings, snapshot: snapshot, graph: graph, index: DependencyIndex(graph))
                #expect(index.roots["value"] == [node.id])
            }
        }
    }
}

@Test func parserRecognizesExternalLinkagesAndLegacyFragmentMetadata() throws {
    let root = URL(fileURLWithPath: "/project")
    for linkage in ["public_external", "hidden_external", "shared_external", "public", "hidden", "shared", "private", ""] {
        let parsed = SILParser.parse("""
        sil \(linkage) @value : $@convention(thin) () -> () {
        } // end sil function 'value'
        """, module: "Example", sourceRoot: root)
        #expect(parsed.importedSymbols?.contains("value") == linkage.hasSuffix("_external"))
    }
    let legacy = Data(#"{"functions":{},"dispatchTargets":{}}"#.utf8)
    #expect(try GraphArchive.decodeValue(SILModule.self, from: legacy).importedSymbols == nil)
}
