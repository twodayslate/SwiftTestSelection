// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import Testing
@testable import TestImpact

// Bound synchronous compiler/extraction work on Swift Testing's cooperative pool.
@Test(.serialized, arguments: ["ordinary", "swiftui", "retroactive"])
func protocolWitnessesPreserveCompilerGraphs(kind: String) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let compiler = try CommandRunner.run("xcrun", ["--find", "swiftc"], at: root).text.trimmingCharacters(in: .whitespacesAndNewlines)
    let source = root.appendingPathComponent("Conformance.swift")
    let text: String
    switch kind {
    case "swiftui":
        text = """
        import SwiftUI
        public struct SampleView: View {
            public var body: some View { Text("Hello") }
        }
        """
    case "retroactive":
        for (module, contents) in [
            ("TypeOwner", "public struct Model { public init() {} }"),
            ("ProtocolOwner", "public protocol Value { func value() -> Int }")
        ] {
            let file = root.appendingPathComponent(module + ".swift")
            try contents.write(to: file, atomically: true, encoding: .utf8)
            _ = try CommandRunner.run(compiler, ["-emit-module", "-module-name", module, file.path,
                "-emit-module-path", root.appendingPathComponent(module + ".swiftmodule").path], at: root)
        }
        text = """
        import TypeOwner
        import ProtocolOwner
        extension Model: @retroactive Value {
            public func value() -> Int { 42 }
        }
        """
    default:
        text = """
        public protocol Value { func value() -> Int }
        public struct Model: Value {
            public func value() -> Int { 42 }
        }
        """
    }
    try text.write(to: source, atomically: true, encoding: .utf8)
    let sil = root.appendingPathComponent("Conformance.sil")
    let args = ["-module-name", "Conformance", source.path, "-I", root.path, "-Onone", "-g"]
    _ = try CommandRunner.run(compiler, args + ["-emit-sil", "-whole-module-optimization", "-o", sil.path], at: root)
    let parsed = try SILParser.parse(file: sil, module: "Conformance", sourceRoot: root)
    let witnesses = parsed.functions.values.filter { $0.name.contains("protocol witness for") && !$0.regions.isEmpty }
    #expect(!witnesses.isEmpty)
    let resolved = try SILOwnership.resolve(parsed, module: "Conformance", compiler: compiler, directory: root)
    let imported = try SILOwnership.resolve(parsed, module: "Importer", compiler: compiler, directory: root)
    for witness in witnesses {
        #expect(parsed.sharedSymbols?.contains(witness.id) == true)
        #expect(resolved.importedSymbols?.contains(witness.id) == false)
        #expect(imported.importedSymbols?.contains(witness.id) == true)
    }
    let log = "builtin-SwiftDriver -- " + ([compiler] + args).map { "\"" + $0 + "\"" }.joined(separator: " ")
    let capture = CapturedSIL(modules: ["Conformance": [sil]], fingerprints: [:], diagnostics: [])
    for captured in [false, true] {
        let graph = XcodeCompilerGraph.extract(log: log, sourceRoot: root, directory: root, derived: root,
            progress: { _ in }, ownership: ["Conformance": ["Conformance.swift"]], captured: captured ? capture : nil)
        #expect(graph.diagnostics.isEmpty)
        for witness in witnesses {
            let node = try #require(graph.functions[witness.id])
            #expect(node.module == "Conformance")
            #expect(!node.dependencies.isEmpty)
            #expect(node.dependencies.contains { graph.functions[$0]?.regions.isEmpty == false })
        }
    }
}

@Test func protocolWitnessOwnershipRequiresUnambiguousConformanceModule() {
    func tree(_ modules: String) -> String {
        """
        Demangling for witness
        kind=Global
          kind=ProtocolWitness
            kind=ProtocolConformance
              kind=Type
                kind=Structure
                  kind=Module, text="TypeOwner"
              kind=Type
                kind=Protocol
                  kind=Module, text="ProtocolOwner"
        \(modules)
            kind=Function
              kind=Module, text="RequirementOwner"
        """
    }
    #expect(SILOwnership.declarationOwners(tree("      kind=Module, text=\"ConformanceOwner\"")) == ["witness": "ConformanceOwner"])
    #expect(SILOwnership.declarationOwners(tree("")) == [:])
    #expect(SILOwnership.declarationOwners(tree("      kind=Module, text=\"A\"\n      kind=Module, text=\"B\"")) == [:])
    #expect(SILOwnership.declarationOwners(tree("      kind=Module, text=\"\"")) == [:])
}
