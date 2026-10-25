// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Testing
@testable import TestImpact

@Test func realCompilerCaptureKeepsGenericReceiversBroadAndConcreteReceiversPrecise() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("dispatch-stages-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/BuildTimeDispatch")
    var snapshots: [String: SwiftSourceSnapshot] = [:]
    for name in ["Model.swift", "Tests.swift"] {
        let destination = root.appendingPathComponent(name)
        try FileManager.default.copyItem(at: fixture.appendingPathComponent(name), to: destination)
        snapshots["Fixture:" + name] = SwiftSourceSnapshot.parse(try String(contentsOf: destination, encoding: .utf8), path: name, module: "Fixture")
    }
    func xcrun(_ arguments: [String]) throws -> String {
        try CommandRunner.run("xcrun", arguments, at: root).text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    let sdk = try xcrun(["--sdk", "iphonesimulator", "--show-sdk-path"])
    let platform = try xcrun(["--sdk", "iphonesimulator", "--show-sdk-platform-path"])
    let arguments = ["swiftc", "-Onone", "-g", "-whole-module-optimization", "-module-name", "Fixture",
        "-sdk", sdk, "-target", "arm64-apple-ios18.0-simulator", "-F", platform + "/Developer/Library/Frameworks",
        "-I", platform + "/Developer/usr/lib", root.appendingPathComponent("Model.swift").path, root.appendingPathComponent("Tests.swift").path]
    let capture = root.appendingPathComponent("capture.sil"), replay = root.appendingPathComponent("replay.sil")
    _ = try xcrun(arguments + ["-c", "-Xfrontend", "-sil-output-path", "-Xfrontend", capture.path, "-o", root.appendingPathComponent("fixture.o").path])
    _ = try xcrun(arguments + ["-emit-sil", "-o", replay.path])
    let capturedText = try String(contentsOf: capture, encoding: .utf8)
    #expect(capturedText.contains("witness_method $Element,"), "Fixture must reproduce named generic shadowing")
    let ids = ["ConcreteTests/testState()", "GenericTests/testFirst()", "GenericTests/testSecond()", "GenericTests/testAssociated()",
        "DispatchTests/testProtocol()", "DispatchTests/testClass()", "DispatchTests/testObjC()", "DispatchTests/testEscaped()",
        "DispatchTests/testShared()", "InheritedTests/testInheritedSetup()"].map { "Tests/" + $0 }
    func graph(_ file: URL) throws -> XcodeTestGraph {
        let parsed = try SILParser.parse(file: file, module: "Fixture", sourceRoot: root)
        var dependencies = DependencyGraph(functions: parsed.functions)
        XcodeCompilerGraph.resolveDispatch(&dependencies, tables: parsed.dispatchTargets)
        XcodeCompilerGraph.bind(tests: ids, modules: ["Tests": "Fixture"], sources: snapshots, graph: &dependencies)
        let concrete = try #require(dependencies.functions.values.first { $0.name == "concrete(_:)" })
        let generic = try #require(dependencies.functions.values.first { $0.name == "generic<A>(_:_:)" || $0.name.hasPrefix("generic<") })
        let equalities = try #require(parsed.dispatchTargets["Equatable.\"==\""])
        let state = try #require(parsed.dispatchTargets["Equatable.\"==\"@witness:UIApplication.State"])
        #expect(generic.dynamicDeclarations.contains("Equatable.\"==\""))
        #expect(generic.dependencies.isSuperset(of: equalities))
        #expect(dependencies.dependencyPath(from: [concrete.id], to: equalities.subtracting(state)) == nil)
        #expect(generic.uncertainties.contains { $0.hasPrefix("Dynamic dispatch:") })
        let callback = try #require(dependencies.functions.values.first { $0.name == "callbackCall(_:)" })
        #expect(callback.uncertainties.contains("Indirect function invocation"))
        let shared = try #require(dependencies.functions.values.first { $0.name == "sharedState()" })
        let globals = Set(dependencies.functions.values.filter { $0.uncertainties.contains("Global state access") }.map(\.id))
        #expect(dependencies.dependencyPath(from: [shared.id], to: globals) != nil)
        var result = XcodeTestGraph(targets: [
            .init(name: "App", productType: "com.apple.product-type.framework", sourceFiles: ["Model.swift"]),
            .init(name: "Tests", productType: "com.apple.product-type.bundle.unit-test", sourceFiles: ["Tests.swift"])
        ], tests: ids)
        result.modules = ["App": "Fixture", "Tests": "Fixture"]; result.sources = snapshots; result.dependencies = dependencies
        return result
    }
    let captured = try graph(capture), reference = try graph(replay)
    #expect(captured.dependencies!.tests == reference.dependencies!.tests)
    for (key, snapshot) in snapshots {
        for i in snapshot.units.indices where ["function", "type"].contains(snapshot.units[i].kind) {
            func selected(_ base: XcodeTestGraph) -> ImpactReport {
                var head = base
                head.sources[key]!.units[i].fingerprint += "edit"
                return XcodeFineSelector.select(current: head, previous: base, changes: [FileChange(path: snapshot.units[i].region.path)], baseRevision: "base")
            }
            #expect(selected(captured).selectedTests == selected(reference).selectedTests, "Stage selection differs for \(snapshot.units[i].key)")
        }
    }
}
