// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
import Foundation
import Testing
@testable import TestImpact

@Test func inlineMappingsUseCompiledUIKitAncestryAcrossFiles() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("inline-ancestry-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let sdk = try CommandRunner.run("xcrun", ["--sdk", "iphonesimulator", "--show-sdk-path"], at: root).text.trimmingCharacters(in: .whitespacesAndNewlines)
    let platform = try CommandRunner.run("xcrun", ["--sdk", "iphonesimulator", "--show-sdk-platform-path"], at: root).text.trimmingCharacters(in: .whitespacesAndNewlines)
    let compiler = try CommandRunner.run("xcrun", ["--find", "swiftc"], at: root).text.trimmingCharacters(in: .whitespacesAndNewlines)
    let source = ["Base.swift": "import XCTest\nimport UIKit\nclass Base: XCTestCase {}\n",
                  "Child.swift": "import XCTest\n// swift-test-selection: {\"symbols\":[\"App.feature()\"]}\nfinal class Child: Base { func testOne() {} }\n"]
    for (path, text) in source { try Data(text.utf8).write(to: root.appendingPathComponent(path)) }
    let modulePath = root.appendingPathComponent("UI.swiftmodule").path
    let args = ["-module-name", "UI", "-sdk", sdk, "-target", "arm64-apple-ios16.0-simulator", "-F", platform + "/Developer/Library/Frameworks", "-I", platform + "/Developer/usr/lib", "-emit-module-path", modulePath]
    _ = try CommandRunner.run(compiler, args + ["-emit-module", "-parse-as-library", "-enable-testing"] + source.keys.sorted().map { root.appendingPathComponent($0).path }, at: root)
    let identities = try CompilerClassIdentities.extract(job: .init(module: "UI", compiler: compiler, arguments: args),
        sourceRoot: root, directory: root, scratch: root, ownership: Set(source.keys))
    let fileList = root.appendingPathComponent("UI.SwiftFileList")
    try Data(source.keys.sorted().map { root.appendingPathComponent($0).path }.joined(separator: "\n").utf8).write(to: fileList)
    let invocation = ([compiler] + args + ["@" + fileList.path]).map { "'" + $0.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }.joined(separator: " ")
    let extracted = XcodeCompilerGraph.extract(log: "builtin-SwiftDriver -- " + invocation,
        sourceRoot: root, directory: root, derived: root, progress: { _ in }, ownership: ["UI": Set(source.keys)])
    #expect(extracted.diagnostics.isEmpty, "\(extracted.diagnostics)")
    #expect(extracted.compilerClassIdentities == identities)
    #expect(identities["UI.Base"]?.superclass == "c:objc(cs)XCTestCase")
    #expect(identities["UI.Child"]?.superclass == identities["UI.Base"]?.symbol)
    var graph = XcodeTestGraph(targets: [.init(name: "UI", productType: "com.apple.product-type.bundle.ui-testing", sourceFiles: Set(source.keys)),
        .init(name: "App", productType: "com.apple.product-type.application", sourceFiles: ["App.swift"])], tests: ["UI/Child/testOne()"])
    graph.modules = ["UI": "UI", "App": "App"]
    graph.sources = Dictionary(uniqueKeysWithValues: source.map { ("UI:" + $0.key, SwiftSourceSnapshot.parse($0.value, path: $0.key, module: "UI")) })
    graph.sources["App:App.swift"] = SwiftSourceSnapshot.parse("func feature() {}", path: "App.swift", module: "App")
    let sil = root.appendingPathComponent("UI.sil")
    _ = try CommandRunner.run(compiler, args.filter { $0 != "-emit-module-path" && $0 != modulePath } + ["-emit-sil", "-g", "-Onone", "-whole-module-optimization", "-o", sil.path] + source.keys.sorted().map { root.appendingPathComponent($0).path }, at: root)
    let parsed = try SILOwnership.resolve(SILParser.parse(file: sil, module: "UI", sourceRoot: root), module: "UI", compiler: compiler, directory: root)
    var dependency = DependencyGraph(functions: parsed.functions)
    dependency.compilerImplicitImports = ["UI": [], "App": []]
    dependency.compilerClassIdentities = identities
    dependency.functions["feature"] = .init(id: "feature", module: "App", name: "feature()", regions: [.init(path: "App.swift", startLine: 1, endLine: 1)])
    XcodeCompilerGraph.bind(tests: graph.tests, modules: graph.modules, sources: graph.sources, graph: &dependency)
    graph.dependencies = dependency
    graph = try GraphArchive.decode(GraphArchive.encode(graph))
    let inline = InlineUIMappings.resolve(graph)
    #expect(inline.diagnostics.isEmpty, "\(inline.diagnostics)")
    #expect(inline.features.count == 1)
    try graph.validateMappingSymbols(mappingFile: "<inline>", revision: "head", buildContext: [:])
    #expect(XcodeFineSelector.select(current: graph, previous: graph, changes: [], baseRevision: "base").selectedTests.isEmpty)
    var central = graph
    central.mappings = .init(features: [.init(name: "feature", symbols: ["App.feature()"], tests: graph.tests)])
    for key in central.sources.keys {
        let declarations = central.sources[key]!.inlineMappings!.declarations.map { var d = $0; d.directives = []; return d }
        central.sources[key]!.inlineMappings?.declarations = declarations
    }
    for snapshot in [graph, central] {
        var head = snapshot
        head.sources["App:App.swift"] = SwiftSourceSnapshot.parse("func feature() { print(1) }", path: "App.swift", module: "App")
        #expect(XcodeFineSelector.select(current: head, previous: snapshot, changes: [.init(path: "App.swift")], baseRevision: "base").selectedTests == graph.tests)
    }
    for mutation in ["missing", "wrong-parent", "wrong-location", "incomplete-source", "alias", "reexport"] {
        var invalid = graph
        switch mutation {
        case "missing": invalid.dependencies!.compilerClassIdentities = nil
        case "wrong-parent": invalid.dependencies!.compilerClassIdentities!["UI.Base"]!.superclass = "c:objc(cs)ForeignBase"
        case "wrong-location": invalid.dependencies!.compilerClassIdentities!["UI.Base"]!.path = "Other.swift"
        case "incomplete-source": invalid.targets[0].sourceFiles.insert("Missing.swift")
        case "alias": invalid.sources["UI:Names.swift"] = SwiftSourceSnapshot.parse("typealias Base = Foreign.Base", path: "Names.swift", module: "UI")
        default: invalid.sources["UI:Names.swift"] = SwiftSourceSnapshot.parse("@_exported import class Foreign.Base", path: "Names.swift", module: "UI")
        }
        #expect(throws: MappingValidationError.self) { try invalid.validateMappingSymbols(mappingFile: "<inline>", revision: "head", buildContext: [:]) }
    }
    var legacy = graph
    legacy.dependencies!.compilerClassIdentities = nil
    #expect(InlineUIMappings.resolve(legacy).diagnostics.contains { $0.message.contains("UIKit") && $0.message.contains("superclass identity") })
}

@Test func compilerAncestryScopesExtractionOnlyWithCompleteImportMaps() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let jobs = ["UI", "Support", "App"].map { XcodeModuleJob(module: $0, compiler: "swiftc", arguments: ["-output-file-map", root.appendingPathComponent($0 + "-output.json").path]) }
    #expect(XcodeCompilerGraph.ancestryModules(annotated: [], jobs: jobs, directory: root).isEmpty)
    #expect(XcodeCompilerGraph.ancestryModules(annotated: ["UI"], jobs: jobs, directory: root) == ["UI", "Support", "App"])
    let map = root.appendingPathComponent("UI-dependencies-1.json")
    try Data(#"[{"moduleName":"Support","modulePath":"/Support.swiftmodule"},{"moduleName":"UIKit","clangModulePath":"/UIKit.pcm"}]"#.utf8).write(to: map)
    #expect(XcodeCompilerGraph.ancestryModules(annotated: ["UI"], jobs: jobs, directory: root) == ["UI", "Support"])
    try Data(#"[{"moduleName":"Support","unexpected":true}]"#.utf8).write(to: map)
    #expect(XcodeCompilerGraph.ancestryModules(annotated: ["UI"], jobs: jobs, directory: root) == ["UI", "Support", "App"])
}
