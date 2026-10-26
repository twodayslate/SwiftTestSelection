// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
import Foundation
import Testing
@testable import TestImpact

@Test func compiledIndependentRuntimeBranchesPreserveSelectionAndExecution() throws {
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/RuntimeBoundary")
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("compiled-boundary-" + UUID().uuidString)
    try FileManager.default.copyItem(at: fixture, to: root)
    defer { try? FileManager.default.removeItem(at: root) }
    let platform = try CommandRunner.run("xcrun", ["--sdk", "macosx", "--show-sdk-platform-path"], at: root).text.trimmingCharacters(in: .whitespacesAndNewlines)
    let frameworks = platform + "/Developer/Library/Frameworks"
    var model = XcodeTestGraph(targets: [], tests: ["CoreTests/CoreCase/testIndependent()", "AppTests/AppCase/testLabel()"])
    var graph = DependencyGraph(), tables: [String: Set<String>] = [:], external: [String: Set<String>] = [:]
    for module in ["Core", "LabelApp", "CoreTests", "AppTests"] {
        let source = module + ".swift", isTest = module.hasSuffix("Tests")
        model.targets.append(.init(name: module, productType: isTest ? "com.apple.product-type.bundle.unit-test" : "com.apple.product-type.framework", sourceFiles: [source]))
        model.modules[module] = module
        model.sources[module + ":" + source] = SwiftSourceSnapshot.parse(try String(contentsOf: root.appendingPathComponent(source), encoding: .utf8), path: source, module: module)
        let args = ["swiftc", "-module-name", module, "-I", root.path, "-L", root.path, "-F", frameworks, "-L", platform + "/Developer/usr/lib", "-I", platform + "/Developer/usr/lib", "-g", "-Onone", root.appendingPathComponent(source).path]
        let sil = root.appendingPathComponent(module + ".sil")
        if isTest {
            _ = try CommandRunner.run("xcrun", args + ["-l" + (module == "CoreTests" ? "Core" : "LabelApp"), "-Xlinker", "-rpath", "-Xlinker", root.path, "-Xlinker", "-rpath", "-Xlinker", frameworks, "-Xlinker", "-rpath", "-Xlinker", platform + "/Developer/Library/PrivateFrameworks", "-Xlinker", "-rpath", "-Xlinker", platform + "/Developer/usr/lib", "-o", module], at: root)
            let run = try CommandRunner.run(root.appendingPathComponent(module).path, [], at: root)
            #expect(run.text.contains("Executed 1 test"))
        } else {
            _ = try CommandRunner.run("xcrun", args + ["-emit-library", "-emit-module", "-o", "lib" + module + ".dylib"], at: root)
        }
        _ = try CommandRunner.run("xcrun", args + ["-emit-sil", "-whole-module-optimization", "-o", sil.path], at: root)
        let parsed = try SILParser.parse(file: sil, module: module, sourceRoot: root)
        for (id, node) in parsed.functions where graph.functions[id] == nil || node.regions.contains(where: { $0.path == source }) { graph.functions[id] = node }
        for (key, values) in parsed.dispatchTargets { tables[key, default: []].formUnion(values) }
        for (key, values) in parsed.externalWitnesses ?? [:] { external[key, default: []].formUnion(values) }
    }
    XcodeCompilerGraph.resolveDispatch(&graph, tables: tables, externalWitnesses: external, projectModules: Set(model.modules.values))
    for (test, name) in [(model.tests[0], "CoreCase.testIndependent()"), (model.tests[1], "AppCase.testLabel()")] {
        let node = try #require(graph.functions.values.first { $0.name == name })
        graph.tests[test] = [node.id]
    }
    let setup = try #require(graph.functions.values.first { $0.name == "ParentCase.setUp()" })
    graph.tests[model.tests[0]]!.insert(setup.id)
    model.dependencies = graph
    model.runtimeInventory = .init(imports: ["Core": [], "LabelApp": [], "CoreTests": ["Core"], "AppTests": ["LabelApp"]], hosts: ["CoreTests": ["CoreTests"], "AppTests": ["AppTests"]])
    var policy = UIFeatureMappings(features: [])
    policy.testRuntimeBoundaries = [.init(target: "CoreTests", modules: ["CoreTests", "Core"], rationale: "Independent hostless executable; no loading or communication with LabelApp.")]
    model.mappings = policy
    var head = model
    let changedLabel = try String(contentsOf: root.appendingPathComponent("LabelApp.swift"), encoding: .utf8).replacingOccurrences(of: "A to Z", with: "Alphabetical")
    head.sources["LabelApp:LabelApp.swift"] = SwiftSourceSnapshot.parse(changedLabel, path: "LabelApp.swift", module: "LabelApp")
    try changedLabel.write(to: root.appendingPathComponent("LabelApp.swift"), atomically: true, encoding: .utf8)
    let headArguments = ["swiftc", "-module-name", "LabelApp", "-g", "-Onone", root.appendingPathComponent("LabelApp.swift").path]
    _ = try CommandRunner.run("xcrun", headArguments + ["-emit-library", "-emit-module", "-o", "libLabelApp.dylib"], at: root)
    let headSIL = root.appendingPathComponent("Head.sil")
    _ = try CommandRunner.run("xcrun", headArguments + ["-emit-sil", "-whole-module-optimization", "-o", headSIL.path], at: root)
    let parsedHead = try SILParser.parse(file: headSIL, module: "LabelApp", sourceRoot: root)
    for (id, node) in parsedHead.functions where node.regions.contains(where: { $0.path == "LabelApp.swift" }) { head.dependencies!.functions[id] = node }
    // Full fixture execution on both revisions, using the newly built library.
    for executable in ["AppTests", "CoreTests"] {
        #expect(try CommandRunner.run(root.appendingPathComponent(executable).path, [], at: root).text.contains("Executed 1 test"))
    }
    let narrowed = XcodeFineSelector.select(current: head, previous: model, changes: [.init(path: "LabelApp.swift")], baseRevision: "base")
    #expect(narrowed.selectedTests == [model.tests[1]], "\(narrowed.diagnostics.map(\.message))")
    #expect(narrowed.runtimeBoundaryDecisions?.contains { $0.boundedUncertaintyTests == [model.tests[0]] } == true)
    // A real compiled assertion edit accompanying the production change must
    // preserve the independent Core boundary, including after graph persistence.
    let appTestFile = root.appendingPathComponent("AppTests.swift")
    let changedTest = try String(contentsOf: appTestFile, encoding: .utf8)
        .replacingOccurrences(of: "XCTAssertFalse(label().isEmpty)", with: "XCTAssertFalse(label().isEmpty, \"updated assertion\")")
    try changedTest.write(to: appTestFile, atomically: true, encoding: .utf8)
    var mixed = head
    mixed.sources["AppTests:AppTests.swift"] = SwiftSourceSnapshot.parse(changedTest, path: "AppTests.swift", module: "AppTests")
    let testArgs = ["swiftc", "-module-name", "AppTests", "-I", root.path, "-F", frameworks, "-I", platform + "/Developer/usr/lib", "-g", "-Onone", appTestFile.path]
    let mixedSIL = root.appendingPathComponent("MixedTests.sil")
    _ = try CommandRunner.run("xcrun", testArgs + ["-emit-sil", "-whole-module-optimization", "-o", mixedSIL.path], at: root)
    for (id, node) in try SILParser.parse(file: mixedSIL, module: "AppTests", sourceRoot: root).functions
        where node.regions.contains(where: { $0.path == "AppTests.swift" }) { mixed.dependencies!.functions[id] = node }
    for archived in [false, true] {
        let candidate = try archived ? GraphArchive.decode(GraphArchive.encode(mixed)) : mixed
        let report = XcodeFineSelector.select(current: candidate, previous: model,
            changes: [.init(path: "LabelApp.swift"), .init(path: "AppTests.swift")], baseRevision: "base")
        #expect(report.selectedTests == narrowed.selectedTests)
        #expect(report.runtimeBoundaryDecisions?.count == 2)
    }
    head.mappings = nil
    var noPolicy = model; noPolicy.mappings = nil
    let broad = XcodeFineSelector.select(current: head, previous: noPolicy, changes: [.init(path: "LabelApp.swift")], baseRevision: "base")
    #expect(Set(broad.selectedTests) == Set(model.tests))
    // Changes inside the declared runtime closure must still reach the independent
    // tests, including shared storage, escaped callbacks, overrides, conformance,
    // imported extensions and inherited setup. Keep the other branch edit too.
    for (module, before, after) in [
        ("Core", "sharedValue = 3", "sharedValue = 4"),
        ("Core", "{ sharedValue }", "{ sharedValue + 1 }"),
        ("Core", "{ escapedCallback() }", "{ escapedCallback() + 1 }"),
        ("Core", "lhs.raw == rhs.raw", "lhs.raw != rhs.raw"),
        ("Core", "importedExtension() -> Int { sharedValue }", "importedExtension() -> Int { sharedValue + 1 }"),
        ("CoreTests", "sharedValue = 3", "sharedValue = 4")
    ] {
        var changed = head; changed.mappings = policy
        let file = module + ".swift", original = try String(contentsOf: root.appendingPathComponent(module + ".swift"), encoding: .utf8)
        #expect(original.contains(before))
        changed.sources[module + ":" + file] = SwiftSourceSnapshot.parse(original.replacingOccurrences(of: before, with: after), path: file, module: module)
        let selected = XcodeFineSelector.select(current: changed, previous: model, changes: [.init(path: "LabelApp.swift"), .init(path: file)], baseRevision: "stacked-base")
        #expect(selected.selectedTests.contains(model.tests[0]))
        #expect(selected.runtimeBoundaryDecisions == nil)
    }
}
