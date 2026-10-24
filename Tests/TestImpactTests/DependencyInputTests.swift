// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import Testing
@testable import TestImpact

@Test func dependencyInputsUseCompilerInputsInsteadOfGeneratedModuleBytes() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let header = root.appendingPathComponent("SDK.h")
    let interface = root.appendingPathComponent("SDK.swiftinterface")
    let plugin = root.appendingPathComponent("plugin")
    try Data("void sdk(void);".utf8).write(to: header)
    try Data("public func sdk()".utf8).write(to: interface)
    try Data("plugin binary".utf8).write(to: plugin)
    func inventory(_ directory: String, option: String = "-DVERSION=1") throws -> XcodeDependencyInputs.Inventory {
        let pcm = directory + "/SDK-" + directory.count.description + ".pcm"
        let swift = directory + "/SDK-" + directory.count.description + ".swiftmodule"
        let records: [[String: Any]] = [
            ["swift": "Tests"], ["modulePath": "Tests.swiftmodule", "sourceFiles": [],
                "details": ["swift": ["commandLine": [], "contextHash": directory]]],
            ["swiftPrebuiltExternal": "Core"], ["modulePath": directory + "/Core.swiftmodule",
                "details": ["swiftPrebuiltExternal": ["compiledModulePath": directory + "/Core.swiftmodule"]]],
            ["clang": "SDK"], ["modulePath": pcm, "sourceFiles": [header.path],
                "details": ["clang": ["commandLine": ["-emit-pcm", "-o", pcm, option], "contextHash": directory]]],
            ["swift": "SDK"], ["modulePath": swift, "sourceFiles": [],
                "details": ["swift": ["moduleInterfacePath": interface.path,
                    "commandLine": ["-o", swift, "-fmodule-file=SDK=" + pcm], "contextHash": directory,
                    "macroDependencies": [["libraryPath": plugin.path, "executablePath": ""]]]]]
        ]
        let data = try JSONSerialization.data(withJSONObject: ["mainModuleName": "Tests", "modules": records])
        return try XcodeDependencyInputs.fingerprint(data, projectModules: ["Tests", "Core"], normalize: { $0 }, hash: {
            try ArtifactFiles.digest(URL(fileURLWithPath: $0))
        })
    }
    let base = try inventory("/one")
    #expect(base.digest == (try inventory("/different/build/root")).digest)
    #expect(base.projectImports == ["Core"])
    #expect(base.modules == ["swift:Tests", "swift:Core", "swift:SDK", "clang:SDK"])
    #expect(base.digest != (try inventory("/one", option: "-DVERSION=2")).digest)
    try Data("void sdk(int value);".utf8).write(to: header)
    let changedHeader = try inventory("/one")
    #expect(base.digest != changedHeader.digest)
    try Data("public func sdk(_ value: Int)".utf8).write(to: interface)
    let changedInterface = try inventory("/one")
    #expect(changedHeader.digest != changedInterface.digest)
    try Data("new plugin binary".utf8).write(to: plugin)
    #expect(changedInterface.digest != (try inventory("/one")).digest)
    try Data("#define NOW __TIME__".utf8).write(to: header)
    #expect(throws: ImpactError.self) { try inventory("/one") }
    try FileManager.default.removeItem(at: header)
    #expect(throws: (any Error).self) { try inventory("/one") }
    #expect(throws: ImpactError.self) {
        try XcodeDependencyInputs.fingerprint(Data(#"{"mainModuleName":"Tests","modules":[]}"#.utf8),
            projectModules: [], normalize: { $0 }, hash: { $0 })
    }
}
