// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation
import Testing
@testable import TestImpact

@Test(arguments: ["@_transparent", "@_alwaysEmitIntoClient"])
func sharedSourceImportsPreserveDefiningModuleAndFeatureMappings(attribute: String) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
    let derived = root.appendingPathComponent("DerivedData")
    try FileManager.default.createDirectory(at: derived, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("Shared.swift")
    try """
    import Foundation
    #if SECOND
    import First
    public func invoke() -> Int { First.value() + First.Box().extensionValue() + First.Box().count + First.Box()[0] + First.make()() }
    extension First.Box {
        @_alwaysEmitIntoClient public func extensionValue() -> Int { 1 }
    }
    #else
    \(attribute) public func value() -> Int { helper() }
    @usableFromInline internal func helper() -> Int { 1 }
    @_alwaysEmitIntoClient public func make() -> () -> Int { { 1 } }
    public class Child: NSObject {}
    public struct Box {
        @_alwaysEmitIntoClient public init(_ x: Int = 1) {}
        @_alwaysEmitIntoClient public var count: Int { 1 }
        @_alwaysEmitIntoClient public subscript(_ x: Int) -> Int { x }
    }
    #endif
    """.write(to: source, atomically: true, encoding: .utf8)
    let compiler = try CommandRunner.run("xcrun", ["--find", "swiftc"], at: root).text.trimmingCharacters(in: .whitespacesAndNewlines)
    _ = try CommandRunner.run(compiler, ["-emit-module", "-module-name", "First", source.path,
        "-emit-module-path", derived.appendingPathComponent("First.swiftmodule").path, "-Onone", "-g"], at: root)
    var logs: [String] = [], captures: [String: [URL]] = [:]
    var firstDefinitions = Set<String>()
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
        #expect(restored.importedSymbols?.contains("$s5First5valueSiyF") == (module == "Second" && attribute == "@_transparent"))
        #expect(restored.sharedSymbols == parsed.sharedSymbols)
        let resolved = try SILOwnership.resolve(restored, module: module, compiler: compiler, directory: root)
        #expect(resolved.importedSymbols?.contains("$s5First5valueSiyF") == (module == "Second"))
        #expect(resolved.sharedSymbols == nil)
        if module == "First" {
            firstDefinitions = Set(resolved.functions.keys.filter { $0.hasPrefix("$s5First") })
        }
        if module == "Second" {
            let extensionNode = try #require(resolved.functions.values.first { $0.name.contains("extensionValue()") })
            #expect(extensionNode.id.hasPrefix("$s5First")) // The type's module is not the extension's owner.
            #expect(resolved.importedSymbols?.contains(extensionNode.id) == false)
        }
        let cached = try GraphArchive.decodeValue(SILModule.self, from: GraphArchive.encodeValue(resolved))
        // A resolved fragment must not need the compiler or demangler again.
        let hit = try SILOwnership.resolve(cached, module: module, compiler: "/missing/swiftc", directory: root)
        #expect(hit.importedSymbols == resolved.importedSymbols)
    }
    var targets: [XcodeTarget] = [], modules: [String: String] = [:], unsupported: [String: [String]] = [:]
    var classified = Set<URL>(), diagnostics: [String] = []
    var generated: [String: [GeneratedSourceBoundary]] = [:], roles: [String: String] = [:]
    XcodeSourceOwnership.recover(log: logs.joined(separator: "\n"), sourceRoot: root, derived: derived, activeInputs: nil,
        targets: &targets, modules: &modules, listOwners: [:], unsupportedInputs: &unsupported,
        classifiedLists: &classified, diagnostics: &diagnostics, generated: &generated, roleDiagnostics: &roles)
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
                for symbol in firstDefinitions { #expect(graph.functions[symbol]?.module == "First") }
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

@Test func clientOwnershipRejectsUnknownContextsAndIgnoresSignatureModules() {
    let output = """
    Demangling for function
    kind=Global
      kind=Function
        kind=Module, text="Owner"
        kind=Type
          kind=Module, text="ResultTypeModule"
    Demangling for extension
    kind=Global
      kind=Function
        kind=Extension
          kind=Module, text="ExtensionOwner"
          kind=Structure
            kind=Module, text="TypeOwner"
    Demangling for dynamicConstructor
    kind=Global
      kind=DynamicAttribute
      kind=Constructor
        kind=Class
          kind=Module, text="DynamicOwner"
    Demangling for unknown
    kind=Global
      kind=UnknownContext
        kind=Module, text="NotProven"
    Demangling for signatureOnly
    kind=Global
      kind=Function
        kind=Type
          kind=Module, text="NotAnOwner"
    """
    #expect(SILOwnership.declarationOwners(output) == ["function": "Owner", "extension": "ExtensionOwner", "dynamicConstructor": "DynamicOwner"])
}

@Test func unresolvedClientOwnershipProducesExtractionDiagnostic() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let sil = root.appendingPathComponent("module.sil")
    try """
    // unknown(), loc "\(root.path)/Shared.swift":1:1
    sil shared [export_implementation] @not_a_swift_symbol : $@convention(thin) () -> () {
    } // end sil function 'not_a_swift_symbol'
    """.write(to: sil, atomically: true, encoding: .utf8)
    let compiler = try CommandRunner.run("xcrun", ["--find", "swiftc"], at: root).text.trimmingCharacters(in: .whitespacesAndNewlines)
    let capture = CapturedSIL(modules: ["Example": [sil]], fingerprints: [:], diagnostics: [])
    let graph = XcodeCompilerGraph.extract(log: "builtin-SwiftDriver -- \(compiler) -module-name Example", sourceRoot: root,
        directory: root, derived: root, progress: { _ in }, captured: capture)
    #expect(graph.functions.isEmpty)
    #expect(graph.diagnostics.contains { $0.contains("Cannot resolve defining module for client-emitted SIL symbol") })
}
