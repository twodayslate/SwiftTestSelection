// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation
import Testing
@testable import TestImpact

@Test func generatedActorAdaptersAndObjCAsyncClosuresPreserveGraphs() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let compiler = try CommandRunner.run("xcrun", ["--find", "swiftc"], at: root).text.trimmingCharacters(in: .whitespacesAndNewlines)
    let platform = try CommandRunner.run("xcrun", ["--show-sdk-platform-path"], at: root).text.trimmingCharacters(in: .whitespacesAndNewlines)
    // Passing an isolated function to a Swift 5 API emits a runtime isolation
    // adapter under Swift 6. Its mangling describes types, not a declaration.
    let legacy = root.appendingPathComponent("Legacy.swift")
    try """
    import Foundation
    public func consume(_ callback: @escaping (Date) -> String) {}
    """.write(to: legacy, atomically: true, encoding: .utf8)
    _ = try CommandRunner.run(compiler, ["-swift-version", "5", "-emit-module", "-module-name", "Legacy", legacy.path,
        "-emit-module-path", root.appendingPathComponent("Legacy.swiftmodule").path], at: root)
    let source = root.appendingPathComponent("Generated.swift")
    try """
    import Foundation
    import XCTest
    import Legacy
    @MainActor public func render(_ value: Date) -> String { value.description }
    @MainActor public func use() { consume(render) }
    public func link(_ text: inout AttributedString, to url: URL) { text.link = url }
    @MainActor public final class AsyncTests: XCTestCase {
        public override func setUp() async throws { use() }
        public func testAsync() async throws { use() }
    }
    """.write(to: source, atomically: true, encoding: .utf8)
    var logs: [String] = [], captures: [String: [URL]] = [:]
    var adapterIDs: [String: Set<String>] = [:]
    var closureIDs = Set<String>()
    for module in ["First", "Second"] {
        let args = ["-module-name", module, "-swift-version", "6", source.path, "-I", root.path,
                    "-F", platform + "/Developer/Library/Frameworks", "-Onone", "-g"]
        logs.append("builtin-SwiftDriver -- " + ([compiler] + args).map { "\"" + $0 + "\"" }.joined(separator: " "))
        let sil = root.appendingPathComponent(module + ".sil")
        _ = try CommandRunner.run(compiler, args + ["-emit-sil", "-whole-module-optimization", "-o", sil.path], at: root)
        captures[module] = [sil]
        let parsed = try SILParser.parse(file: sil, module: module, sourceRoot: root)
        let adapter = try #require(parsed.functions.values.first { $0.id.hasSuffix("TRScMTU") })
        #expect(!adapter.regions.isEmpty)
        #expect(parsed.sharedSymbols?.contains(adapter.id) == true)
        let closures = parsed.functions.values.filter { $0.name.hasPrefix("@objc closure") }
        #expect(closures.count == 2)
        #expect(closures.contains { $0.name.contains("setUp()") })
        #expect(closures.contains { $0.name.contains("testAsync()") })
        let resolved = try SILOwnership.resolve(parsed, module: module, compiler: compiler, directory: root)
        let imported = try SILOwnership.resolve(parsed, module: "Importer", compiler: compiler, directory: root)
        for closure in closures {
            #expect(resolved.importedSymbols?.contains(closure.id) == false)
            #expect(imported.importedSymbols?.contains(closure.id) == true)
            #expect(resolved.functions[closure.id]?.regions == closure.regions)
            closureIDs.insert(closure.id)
        }
        let local = adapter.id + "@emitted:" + module
        adapterIDs[module, default: []].insert(local)
        let node = try #require(resolved.functions[local])
        #expect(resolved.functions[adapter.id] == nil)
        #expect(node.regions.isEmpty)
        #expect(node.dependencies == adapter.dependencies)
        #expect(node.uncertainties == adapter.uncertainties)
        #expect(!node.uncertainties.isEmpty) // The callback remains indirect.
        #expect(resolved.functions.values.contains { $0.dependencies.contains(local) })
        #expect(resolved.functions.values.contains { $0.compilerReferences?.contains(local) == true })
        #expect(!resolved.functions.values.contains { $0.dependencies.contains(adapter.id) })
        let keyPaths = parsed.functions.values.filter { $0.name.hasPrefix("key path index") }
        #expect(keyPaths.count == 2) // Type-only equality and hash helpers.
        for helper in keyPaths {
            #expect(!helper.regions.isEmpty)
            #expect(parsed.sharedSymbols?.contains(helper.id) == true)
            let id = helper.id + "@emitted:" + module
            adapterIDs[module, default: []].insert(id)
            let localHelper = try #require(resolved.functions[id])
            #expect(resolved.functions[helper.id] == nil)
            #expect(localHelper.regions.isEmpty)
            #expect(localHelper.dependencies == helper.dependencies)
            #expect(localHelper.compilerReferences == helper.compilerReferences)
            #expect(localHelper.uncertainties == helper.uncertainties)
            #expect(resolved.functions.values.contains { $0.dependencies.contains(id) })
            #expect(resolved.functions.values.contains { $0.compilerReferences?.contains(id) == true })
            #expect(resolved.functions.values.contains { $0.dependencies.contains(id) && $0.uncertainties.contains("Key path access") })
        }
        let cached = try GraphArchive.decodeValue(SILModule.self, from: GraphArchive.encodeValue(resolved))
        let hit = try SILOwnership.resolve(cached, module: module, compiler: "/missing/swiftc", directory: root)
        #expect(hit.sharedSymbols == nil)
        #expect(hit.functions.keys.sorted() == resolved.functions.keys.sorted())
        #expect(hit.functions[local]?.dependencies == node.dependencies)
        #expect(hit.functions[local]?.uncertainties == node.uncertainties)
        #expect(hit.functions[local]?.regions.isEmpty == true)
        try checkGeneratedAdapterSelection(node)
    }
    // Identical adapter manglings emitted by different modules cannot overwrite
    // each other's dependencies or be attributed to Foundation/Swift.MainActor.
    let capture = CapturedSIL(modules: captures, fingerprints: [:], diagnostics: [])
    let log = logs.joined(separator: "\n")
    for captured in [false, true] {
        for workers in [1, 2] {
            // Extraction waits on OperationQueue workers. Release the cooperative
            // test thread while it runs, then check results in this test's context.
            let graph = await withCheckedContinuation { continuation in
                DispatchQueue.global().async {
                    continuation.resume(returning: XcodeCompilerGraph.extract(log: log, sourceRoot: root,
                        directory: root, derived: root, progress: { _ in },
                        ownership: ["First": ["Generated.swift"], "Second": ["Generated.swift"]],
                        workers: workers, captured: captured ? capture : nil))
                }
            }
            #expect(graph.diagnostics.isEmpty)
            for (module, ids) in adapterIDs {
                for id in ids {
                    #expect(graph.functions[id]?.module == module)
                    #expect(graph.functions[id]?.regions.isEmpty == true)
                    let helper = try #require(graph.functions[id])
                    #expect(!helper.dependencies.isEmpty || !helper.dynamicDeclarations.isEmpty)
                    #expect(!helper.uncertainties.isEmpty)
                }
            }
            for id in closureIDs {
                #expect(graph.functions[id]?.regions.isEmpty == false)
                #expect(graph.functions[id]?.dependencies.isEmpty == false)
            }
        }
    }
}

@Test func objcAttributesDoNotTurnSignatureModulesIntoDeclarationOwners() {
    let tree = """
    Demangling for closure
    kind=Global
      kind=ObjCAttribute
      kind=ExplicitClosure
        kind=Function
          kind=Class
            kind=Module, text="Tests"
    Demangling for unknown
    kind=Global
      kind=ObjCAttribute
      kind=UnknownContext
        kind=Module, text="NotProven"
    Demangling for signature
    kind=Global
      kind=ObjCAttribute
      kind=Function
        kind=Type
          kind=Module, text="NotAnOwner"
    """
    #expect(SILOwnership.declarationOwners(tree) == ["closure": "Tests"])
}
