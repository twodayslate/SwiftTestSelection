// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import Testing
@testable import TestImpact

private func boundaryFixture() -> XcodeTestGraph {
    var model = XcodeTestGraph(targets: [
        .init(name: "App", productType: "com.apple.product-type.application", sourceFiles: ["App.swift"]),
        .init(name: "Core", productType: "com.apple.product-type.framework", sourceFiles: ["Core.swift"]),
        .init(name: "Tests", productType: "com.apple.product-type.bundle.unit-test", sourceFiles: ["Tests.swift"]),
        .init(name: "Hosted", productType: "com.apple.product-type.bundle.unit-test", sourceFiles: ["Hosted.swift"])
    ], tests: ["Tests/Other/testOther()", "Hosted/Labels/testLabel()"])
    model.modules = ["App": "App", "Core": "Core", "Tests": "Tests", "Hosted": "Hosted"]
    let inputs = ["App": "func label() -> String { \"A to Z\" }", "Core": "func shared() {}",
                  "Tests": "class Other { func testOther() {} }", "Hosted": "class Labels { func testLabel() {} }"]
    for (module, source) in inputs {
        model.sources[module + ":" + module + ".swift"] = SwiftSourceSnapshot.parse(source, path: module + ".swift", module: module)
    }
    func node(_ id: String, _ module: String, _ name: String, _ dependencies: Set<String> = [], _ uncertainties: Set<String> = []) -> FunctionNode {
        FunctionNode(id: id, module: module, name: name, regions: [.init(path: module + ".swift", startLine: 1, endLine: 1)], dependencies: dependencies, uncertainties: uncertainties)
    }
    model.dependencies = DependencyGraph(functions: [
        "label": node("label", "App", "label()"),
        "shared": node("shared", "Core", "shared()", [], ["Global state access", "Indirect function invocation", "Raw pointer operation", "Unresolved project dispatch: Callback.run (incomplete override ancestry)"]),
        "other": node("other", "Tests", "Other.testOther()", ["shared"]),
        "hosted": node("hosted", "Hosted", "Labels.testLabel()", ["label", "shared"])
    ], tests: [model.tests[0]: ["other"], model.tests[1]: ["hosted"]])
    model.runtimeInventory = .init(imports: ["App": ["Core"], "Core": [], "Tests": ["Core"], "Hosted": ["App", "Core"]],
        hosts: ["Tests": ["Tests"], "Hosted": ["Hosted", "App"]])
    var mappings = UIFeatureMappings(features: [], ignoredDocumentation: ["AGENTS.md"])
    mappings.testRuntimeBoundaries = [.init(target: "Tests", modules: ["Tests", "Core"], rationale: "Hostless tests only execute Core and test code; no dynamic loading or cross-process effects.")]
    model.mappings = mappings
    return model
}

private func labelEdit(_ old: XcodeTestGraph) -> XcodeTestGraph {
    var current = old
    current.sources["App:App.swift"] = SwiftSourceSnapshot.parse("func label() -> String { \"Alphabetical\" }", path: "App.swift", module: "App")
    return current
}

@Test func validatedBoundaryScopesUnrelatedUncertaintyAndExplainsEveryExclusion() throws {
    let old = boundaryFixture(), current = labelEdit(old)
    let report = XcodeFineSelector.select(current: current, previous: old, changes: [.init(path: "App.swift")], baseRevision: "base")
    #expect(report.selectedTests == ["Hosted/Labels/testLabel()"])
    #expect(report.explanations.contains { $0.kind == "dependency" })
    #expect(report.runtimeBoundaryDecisions?.count == 2)
    #expect(report.runtimeBoundaryDecisions?.allSatisfy { $0.boundedUncertaintyTests == ["Tests/Other/testOther()"] && $0.changedModules == ["App"] } == true)
    let mixed = XcodeFineSelector.select(current: current, previous: old, changes: [.init(path: "App.swift"), .init(path: "AGENTS.md")], baseRevision: "base")
    #expect(mixed.selectedTests == report.selectedTests)
    #expect(mixed.ignoredChanges == ["AGENTS.md"])
    #expect(try GraphArchive.decode(GraphArchive.encode(current)).runtimeInventory?.hosts == current.runtimeInventory?.hosts)
}

@Test(arguments: ["missingBase", "missingInventory", "missingImports", "underdeclared", "unknownModule", "host", "visibleEdge", "incomplete", "unbound", "policyChanged"])
func invalidBoundaryCannotSuppressFallback(failure: String) {
    var old = boundaryFixture()
    switch failure {
    case "missingInventory": old.runtimeInventory = nil
    case "missingImports": old.runtimeInventory!.imports.removeValue(forKey: "Core")
    case "underdeclared": old.mappings!.testRuntimeBoundaries![0].modules.remove("Core")
    case "unknownModule": old.mappings!.testRuntimeBoundaries![0].modules.insert("Absent")
    case "host": old.runtimeInventory!.hosts["Tests"]!.insert("App")
    case "visibleEdge":
        old.dependencies!.functions["shared"]!.dependencies.insert("label")
        old.dependencies!.functions["shared"]!.compilerReferences = ["label"]
    case "incomplete": old.dependencies!.diagnostics.append("Missing compiler module")
    case "unbound": old.dependencies!.tests[old.tests[0]] = []
    default: break
    }
    var current = labelEdit(old)
    if failure == "policyChanged" { current.mappings!.testRuntimeBoundaries![0].rationale += "changed" }
    let report = XcodeFineSelector.select(current: current, previous: failure == "missingBase" ? nil : old,
        changes: [.init(path: "App.swift")], baseRevision: "base")
    #expect(Set(report.selectedTests) == Set(old.tests))
    #expect(report.diagnostics.contains { $0.code == "invalid_runtime_boundary" || $0.code == "base_unavailable" })
}

@Test func boundaryKeepsTestOnlyAndEmptySelectionBehavior() {
    let old = boundaryFixture()
    let empty = XcodeFineSelector.select(current: old, previous: old, changes: [], baseRevision: "base")
    #expect(empty.selectedTests.isEmpty)
    var current = old
    let key = "Tests:Tests.swift"
    let i = current.sources[key]!.units.firstIndex { $0.kind == "function" }!
    current.sources[key]!.units[i].fingerprint += "edit"
    let report = XcodeFineSelector.select(current: current, previous: old, changes: [.init(path: "Tests.swift")], baseRevision: "base")
    #expect(report.selectedTests == [old.tests[0]])
}

@Test func missingSourceSnapshotIsNotAnIgnoredSwiftChange() {
    var current = boundaryFixture()
    current.sources.removeValue(forKey: "Core:Core.swift")
    let report = XcodeFineSelector.select(current: current, previous: current, changes: [.init(path: "Core.swift")], baseRevision: "base")
    #expect(Set(report.selectedTests) == Set(current.tests))
    #expect(report.diagnostics.contains { $0.code == "unclassified_change" })
}

@Test func compilerImportInventoryRejectsUnknownAndBridgingMetadata() throws {
    let valid = Data(#"[{"moduleName":"Core","modulePath":"/Core.swiftmodule"},{"moduleName":"Foundation","modulePath":"/Foundation.swiftmodule"}]"#.utf8)
    #expect(try XcodeRuntimeInventory.projectImports(valid, inventory: ["Tests", "Core"]) == ["Core"])
    for text in ["[]", #"[{"moduleName":"Core","modulePath":"/Core.swiftmodule","newField":true}]"#,
                 #"[{"moduleName":"Core","modulePath":"/Core.swiftmodule","isBridgingHeaderDependency":true}]"#] {
        #expect(throws: ImpactError.self) { try XcodeRuntimeInventory.projectImports(Data(text.utf8), inventory: ["Core"]) }
    }
}

@Test func runtimeInventoryCapturesTransitiveImportsAndAppHosts() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("boundary-inventory-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    var lines: [String] = []
    for (module, dependencies) in ["Core": ["Foundation"], "App": ["Core", "Foundation"], "Tests": ["Core"], "Hosted": ["App", "Core"], "UI": ["Foundation"]] {
        let directory = root.appendingPathComponent(module)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let rows = dependencies.map { ["moduleName": $0, "modulePath": "/" + $0 + ".swiftmodule"] }
        try JSONSerialization.data(withJSONObject: rows).write(to: directory.appendingPathComponent(module + "-dependencies-1.json"))
        lines.append("builtin-SwiftDriver -- swiftc -module-name \(module) -explicit-module-build -output-file-map \(directory.path)/outputs.json" + (module == "UI" ? " -import-objc-header UI.h" : ""))
    }
    let settings: [XcodeBuildSettings] = [
        .init(buildSettings: ["PRODUCT_TYPE": "com.apple.product-type.application", "TARGET_NAME": "App", "PRODUCT_MODULE_NAME": "App", "TARGET_BUILD_DIR": root.path, "EXECUTABLE_PATH": "App.app/App"]),
        .init(buildSettings: ["PRODUCT_TYPE": "com.apple.product-type.bundle.unit-test", "TARGET_NAME": "Tests", "PRODUCT_MODULE_NAME": "Tests", "TEST_HOST": ""]),
        .init(buildSettings: ["PRODUCT_TYPE": "com.apple.product-type.bundle.unit-test", "TARGET_NAME": "Hosted", "PRODUCT_MODULE_NAME": "Hosted", "TEST_HOST": root.path + "/App.app/App"])
    ]
    let log = lines.joined(separator: "\n")
    let inventory = XcodeRuntimeInventory.capture(log: log, settings: settings)
    #expect(inventory.diagnostics.isEmpty)
    #expect(inventory.requiredModules(for: "Tests") == ["Tests", "Core"])
    #expect(inventory.requiredModules(for: "Hosted") == ["Hosted", "App", "Core"])
    #expect(inventory.imports["UI"] == nil)
    #expect(inventory.unavailableModules?["UI"]?.contains("Unsupported") == true)
    try FileManager.default.removeItem(at: root.appendingPathComponent("Core/Core-dependencies-1.json"))
    let missing = XcodeRuntimeInventory.capture(log: log, settings: settings)
    #expect(missing.requiredModules(for: "Tests") == nil)
    #expect(missing.unavailableModules?["Core"]?.contains("Missing") == true)
    var badHost = settings
    badHost[2].buildSettings["TEST_HOST"] = "/unresolved/App"
    let badHostInventory = XcodeRuntimeInventory.capture(log: log, settings: badHost)
    #expect(badHostInventory.diagnostics.isEmpty)
    #expect(badHostInventory.unavailableTargets?["Hosted"]?.contains("Cannot resolve test host") == true)
    #expect(badHostInventory.requiredModules(for: "Hosted") == nil)
    #expect(!XcodeRuntimeInventory.capture(log: "", settings: settings).diagnostics.isEmpty)
}

@Test(arguments: ["candidate", "direct", "legacy"])
func boundaryDistinguishesDispatchCandidatesFromCompilerReferences(kind: String) throws {
    var old = boundaryFixture()
    old.dependencies!.functions["shared"]!.dependencies.insert("label")
    if kind != "legacy" { old.dependencies!.functions["shared"]!.compilerReferences = kind == "direct" ? ["label"] : [] }
    let archived = try GraphArchive.decode(GraphArchive.encode(old))
    #expect(archived.dependencies!.functions["shared"]!.compilerReferences == old.dependencies!.functions["shared"]!.compilerReferences)
    let report = XcodeFineSelector.select(current: labelEdit(archived), previous: archived, changes: [.init(path: "App.swift")], baseRevision: "base")
    // All explicit/candidate dependency selections still win, even when the
    // contract can independently exclude an uncertainty fallback.
    #expect(Set(report.selectedTests) == Set(old.tests))
    if kind == "candidate" {
        #expect(report.runtimeBoundaryDecisions?.count == 2)
        #expect(!report.diagnostics.contains { $0.code == "invalid_runtime_boundary" })
    } else {
        #expect(report.diagnostics.contains { $0.code == "invalid_runtime_boundary" })
    }
}

@Test(arguments: ["bridgingHeader", "missingMap", "unresolvedHost", "duplicateTarget", "missingModule", "transitiveImport", "missingTargetName"])
func runtimeInventoryScopesUnsupportedUnitTargets(failure: String) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("boundary-isolation-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    var lines: [String] = []
    for (module, dependencies) in ["Core": failure == "transitiveImport" ? ["Hosted"] : ["Foundation"],
                                   "App": ["Core"], "Tests": ["Core"], "Hosted": ["Core"]] {
        let directory = root.appendingPathComponent(module)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if !(module == "Hosted" && failure == "missingMap") {
            let rows = dependencies.map { ["moduleName": $0, "modulePath": "/" + $0 + ".swiftmodule"] }
            try JSONSerialization.data(withJSONObject: rows).write(to: directory.appendingPathComponent(module + "-dependencies-1.json"))
        }
        let bridged = module == "Hosted" && ["bridgingHeader", "transitiveImport"].contains(failure)
        lines.append("builtin-SwiftDriver -- swiftc -module-name \(module) -explicit-module-build -output-file-map \(directory.path)/outputs.json" + (bridged ? " -import-objc-header Bridge.h" : ""))
    }
    var settings: [XcodeBuildSettings] = ["Tests", "Hosted"].map {
        .init(buildSettings: ["PRODUCT_TYPE": "com.apple.product-type.bundle.unit-test", "TARGET_NAME": $0, "PRODUCT_MODULE_NAME": $0, "TEST_HOST": ""])
    }
    switch failure {
    case "unresolvedHost": settings[1].buildSettings["TEST_HOST"] = "/unresolved/App"
    case "duplicateTarget": settings.append(settings[1])
    case "missingModule": settings[1].buildSettings.removeValue(forKey: "PRODUCT_MODULE_NAME")
    case "missingTargetName": settings[1].buildSettings.removeValue(forKey: "TARGET_NAME")
    default: break
    }
    // Duplicate or bad records cannot be accepted depending on settings order.
    for ordered in [settings, Array(settings.reversed())] {
        var old = boundaryFixture()
        old.runtimeInventory = XcodeRuntimeInventory.capture(log: lines.joined(separator: "\n"), settings: ordered)
        old.mappings!.testRuntimeBoundaries!.append(.init(target: "Hosted", modules: ["Hosted", "Core"], rationale: "Hostless core-only test module."))
        let archived = try GraphArchive.decode(GraphArchive.encode(old))
        #expect(archived.runtimeInventory?.unavailableTargets == old.runtimeInventory?.unavailableTargets)
        let report = XcodeFineSelector.select(current: labelEdit(archived), previous: archived,
            changes: [.init(path: "App.swift")], baseRevision: "base")
        #expect(archived.runtimeInventory?.requiredModules(for: "Hosted") == nil)
        let independent = !["transitiveImport", "missingTargetName"].contains(failure)
        #expect((archived.runtimeInventory?.requiredModules(for: "Tests") == ["Tests", "Core"]) == independent)
        #expect(Set(report.selectedTests) == (independent ? ["Hosted/Labels/testLabel()"] : Set(old.tests)))
        #expect(report.diagnostics.contains { $0.code == "invalid_runtime_boundary" && $0.tests == ["Hosted/Labels/testLabel()"] })
        if independent {
            #expect(archived.runtimeInventory?.diagnostics.isEmpty == true)
            #expect(archived.runtimeInventory?.unavailableTargets?["Hosted"] != nil)
            #expect(report.runtimeBoundaryDecisions?.allSatisfy { $0.target == "Tests" } == true)
            #expect(report.runtimeBoundaryDecisions?.count == 2)
        } else {
            #expect(report.runtimeBoundaryDecisions == nil)
        }
    }
}
