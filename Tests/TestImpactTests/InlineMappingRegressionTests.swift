// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
import Foundation
import Testing
@testable import TestImpact

private func inlineRegressionGraph(_ source: String, value: Int = 1, tests: [String]) -> XcodeTestGraph {
    let ui = SwiftSourceSnapshot.parse(source, path: "UI.swift", module: "UI")
    let app = SwiftSourceSnapshot.parse("func shared() -> Int { \(value) }\nfunc checkout() -> Int { 1 }", path: "App.swift", module: "App")
    var graph = XcodeTestGraph(targets: [
        .init(name: "UI", productType: "com.apple.product-type.bundle.ui-testing", sourceFiles: ["UI.swift"]),
        .init(name: "App", productType: "com.apple.product-type.application", sourceFiles: ["App.swift"])
    ], tests: tests)
    graph.modules = ["UI": "UI", "App": "App"]
    graph.sources = ["UI:UI.swift": ui, "App:App.swift": app]
    var dependencies = DependencyGraph()
    dependencies.compilerImplicitImports = ["UI": [], "App": []]
    for declaration in ui.inlineMappings!.declarations where declaration.kind == "method" {
        let name = InlineMappingSyntax.canonicalScope(declaration.scope) + "." + declaration.method!
        dependencies.functions[name] = .init(id: name, module: "UI", name: name, regions: [declaration.region])
    }
    for (index, name) in ["shared()", "checkout()"].enumerated() {
        dependencies.functions[name] = .init(id: name, module: "App", name: name, regions: [app.units[index].region])
    }
    XcodeCompilerGraph.bind(tests: graph.tests, modules: graph.modules, sources: graph.sources, graph: &dependencies)
    graph.dependencies = dependencies
    graph.mappings = .init(features: [], runtimeDependencyPolicy: .declared)
    return graph
}

@Test(arguments: ["Parent", "Namespace.Parent", "Alias.Parent"])
func inlineMappingInheritedScopesCannotBorrowOuterAnnotations(parent: String) throws {
    // Swift finds OuterBase's inherited nested member before the module-level
    // name. A covered change in Other must not mask the missing Case mapping.
    let source = """
    import XCTest
    // swift-test-selection: {"symbols":["App.checkout()"]}
    class Parent: XCTestCase {}
    enum Namespace {
        // swift-test-selection: {"symbols":["App.checkout()"]}
        class Parent: XCTestCase {}
    }
    typealias Alias = Namespace
    class OuterBase {
        // swift-test-selection: {"symbols":["App.shared()"]}
        class Parent: XCTestCase {}
        enum Namespace {
            // swift-test-selection: {"symbols":["App.shared()"]}
            class Parent: XCTestCase {}
        }
        typealias Alias = Namespace
    }
    class Outer: OuterBase {
        class Case: \(parent) { func testOne() {} }
    }
    // swift-test-selection: {"symbols":["App.shared()"]}
    class Other: XCTestCase { func testOther() {} }
    """
    let tests = ["UI/Outer.Case/testOne()", "UI/Other/testOther()"]
    let old = inlineRegressionGraph(source, tests: tests)
    let head = try GraphArchive.decode(GraphArchive.encode(inlineRegressionGraph(source, value: 2, tests: tests)))
    let resolution = InlineUIMappings.resolve(head)
    #expect(!resolution.features.contains { $0.tests?.contains(tests[0]) == true && $0.symbols == ["App.checkout()"] })
    #expect(resolution.diagnostics.contains { $0.tests == [tests[0]] && $0.message.contains("ancestry is unresolved") })
    let report = XcodeFineSelector.select(current: head, previous: old, changes: [.init(path: "App.swift")], baseRevision: "base")
    #expect(report.selectedTests == tests.sorted())
    #expect(report.diagnostics.contains { $0.code == "invalid_inline_mapping" && $0.tests == [tests[0]] })
    #expect(throws: MappingValidationError.self) {
        try head.validateMappingSymbols(mappingFile: "ui.json", revision: "head", buildContext: [:])
    }
}

@Test(arguments: ["import Foundation", ""], ["Imports.swift", "*.swift"])
func inlineMappingSourceConditionsAcceptCapturedFilesWithoutFunctions(contents: String, pattern: String) throws {
    func model(inline: Bool) -> XcodeTestGraph {
        let directive = inline ? "// swift-test-selection: {\"when\":{\"sourceChanged\":\"\(pattern)\"}}\n" : ""
        var graph = inlineRegressionGraph("import XCTest\n" + directive + "class Other: XCTestCase { func testOther() {} }",
                                          tests: ["UI/Other/testOther()"])
        graph.sources["App:Imports.swift"] = SwiftSourceSnapshot.parse(contents, path: "Imports.swift", module: "App")
        graph.targets[1].sourceFiles.insert("Imports.swift")
        if !inline {
            graph.mappings = .init(version: 2, features: [.init(name: "imports", tests: graph.tests, when: .sourceChanged(pattern))],
                                   runtimeDependencyPolicy: .declared)
        }
        return graph
    }
    for inline in [false, true] {
        let graph = try GraphArchive.decode(GraphArchive.encode(model(inline: inline)))
        try graph.validateMappingSymbols(mappingFile: "ui.json", revision: "head", buildContext: [:])
        let report = XcodeFineSelector.select(current: graph, previous: graph, changes: [], baseRevision: "base")
        #expect(report.selectedTests.isEmpty)
        #expect(report.diagnostics.isEmpty)
        #expect(report.uiConditionDecisions?.allSatisfy { $0.result.status == .notMatched } == true)
        #expect(InlineMappingAudit.inspect(graph).rules.allSatisfy { $0.unresolvedEntries.isEmpty })
    }
    // A direct-change predicate must not make an uncompiled dependency boundary
    // valid, or hide a stale leaf in a partially valid condition.
    for payload in [#"{"sources":["Imports.swift"]}"#,
                    #"{"when":{"any":[{"sourceChanged":"Imports.swift"},{"sourceChanged":"Missing.swift"}]}}"#] {
        var graph = model(inline: true)
        graph.sources["UI:UI.swift"] = SwiftSourceSnapshot.parse("import XCTest\n// swift-test-selection: " + payload + "\nclass Other: XCTestCase { func testOther() {} }", path: "UI.swift", module: "UI")
        #expect(throws: MappingValidationError.self) {
            try graph.validateMappingSymbols(mappingFile: "ui.json", revision: "head", buildContext: [:])
        }
    }
}

@Test func inlineMappingConditionsRetainBothRevisionResolutionAfterSourceMoves() throws {
    let source = """
    import XCTest
    // swift-test-selection: {"when":{"all":[{"sourceChanged":"App.swift"},{"symbolChanged":"App.checkout()"}]}}
    class Other: XCTestCase { func testOther() {} }
    """
    let base = inlineRegressionGraph(source, tests: ["UI/Other/testOther()"])
    var head = inlineRegressionGraph(source, value: 2, tests: base.tests)
    head.targets[1].sourceFiles = ["Moved.swift"]
    head.sources.removeValue(forKey: "App:App.swift")
    head.sources["App:Moved.swift"] = SwiftSourceSnapshot.parse("func shared() -> Int { 2 }\nfunc checkout() -> Int { 1 }", path: "Moved.swift", module: "App")
    for id in ["shared()", "checkout()"] {
        head.dependencies!.functions[id]!.regions = head.dependencies!.functions[id]!.regions.map {
            var region = $0; region.path = "Moved.swift"; return region
        }
    }
    var change = FileChange(path: "Moved.swift")
    change.previousPath = "App.swift"
    let report = XcodeFineSelector.select(current: head, previous: base, changes: [change], baseRevision: "base")
    #expect(report.selectedTests.isEmpty)
    #expect(report.diagnostics.isEmpty)
    #expect(report.uiConditionDecisions?.allSatisfy { $0.result.status == .notMatched && $0.result.children[0].status == .matched } == true)
    // Strict validation still requires a repair before the stale head operand
    // becomes a baseline for future comparisons.
    #expect(throws: MappingValidationError.self) {
        try head.validateMappingSymbols(mappingFile: "ui.json", revision: "head", buildContext: [:])
    }
}

@Test func inlineMappingStrictSourceBoundaryValidationRequiresCompilerEvidence() {
    let source = """
    import XCTest
    // swift-test-selection: {"sources":["App.swift"]}
    class Other: XCTestCase { func testOther() {} }
    """
    var graph = inlineRegressionGraph(source, tests: ["UI/Other/testOther()"])
    // Keep UI binding evidence, but remove the production compiler roots.
    graph.dependencies!.functions = graph.dependencies!.functions.filter { $0.value.module == "UI" }
    #expect(throws: MappingValidationError.self) {
        try graph.validateMappingSymbols(mappingFile: "ui.json", revision: "head", buildContext: [:])
    }
    graph.dependencies = nil
    #expect(throws: MappingValidationError.self) {
        try graph.validateMappingSymbols(mappingFile: "ui.json", revision: "head", buildContext: [:])
    }
}

@Test(arguments: [false, true])
func inlineMappingUnrelatedSuffixCannotEstablishAncestry(qualified: Bool) throws {
    // Parent is imported from External, whose source is not captured. The
    // unrelated Namespace.Parent must not lend its annotation to Suite.
    // Without the unknown import, explicitly naming Namespace.Parent remains
    // a supported lexical binding. Unknown exports also make Other conservative.
    let text = """
    import XCTest
    \(qualified ? "" : "import External")
    enum Namespace {
        // swift-test-selection: {"symbols":["App.checkout()"]}
        class Parent: XCTestCase {}
    }
    class Suite: \(qualified ? "Namespace.Parent" : "Parent") { func testOne() {} }
    // swift-test-selection: {"symbols":["App.shared()"]}
    class Other: XCTestCase { func testOther() {} }
    """
    let tests = ["UI/Suite/testOne()", "UI/Other/testOther()"]
    let base = inlineRegressionGraph(text, tests: tests)
    for archived in [false, true] {
        let raw = inlineRegressionGraph(text, value: 2, tests: tests)
        let head = try archived ? GraphArchive.decode(GraphArchive.encode(raw)) : raw
        let resolution = InlineUIMappings.resolve(head)
        let suiteRules = resolution.features.filter { $0.tests?.contains(tests[0]) == true }
        let report = XcodeFineSelector.select(current: head, previous: base,
            changes: [.init(path: "App.swift")], baseRevision: "base")
        if qualified {
            #expect(suiteRules.flatMap { $0.symbols ?? [] } == ["App.checkout()"])
            #expect(resolution.diagnostics.isEmpty)
            #expect(report.selectedTests == [tests[1]])
            #expect(report.diagnostics.isEmpty)
            try head.validateMappingSymbols(mappingFile: "ui.json", revision: "head", buildContext: [:])
        } else {
            #expect(suiteRules.isEmpty)
            #expect(resolution.diagnostics.contains { $0.tests == [tests[0]] && $0.message.contains("ancestry is unresolved") })
            #expect(report.selectedTests == tests.sorted())
            #expect(report.diagnostics.contains { $0.code == "invalid_inline_mapping" && $0.tests == [tests[0]] })
            #expect(throws: MappingValidationError.self) {
                try head.validateMappingSymbols(mappingFile: "ui.json", revision: "head", buildContext: [:])
            }
            let headOnly = XcodeHeadOnlySelector.select(current: head, source: .init(base: head.sources, mappings: head.mappings),
                changes: [], baseRevision: "base")
            #expect(headOnly.selectedTests == tests.sorted())
            #expect(headOnly.diagnostics.contains { $0.code == "invalid_inline_mapping" })
            #expect(InlineMappingAudit.inspect(head).diagnostics.contains { $0.tests == [tests[0]] })
        }
    }
}

@Test(arguments: ["XCTestCase", "NSObject"], ["complete", "absent", "unavailable", "unrelated", "uncaptured", "escapedLocal"])
func inlineMappingFrameworkNamesCannotBypassImportedAliases(parent: String, evidence: String) throws {
    let source = """
    \(["unrelated", "escapedLocal"].contains(evidence) ? "import XCTest" : "")
    \(evidence == "escapedLocal" ? "typealias `\(parent)` = Support.Parent" : evidence == "unrelated" ? "" : "import Helpers")
    import Support
    // swift-test-selection: {"symbols":["App.checkout()"]}
    class Suite: \(evidence == "unrelated" ? "XCTestCase" : parent) { func testOne() {} }
    class Other: Support.Parent { func testOther() {} }
    """
    let support = """
    import XCTest
    // swift-test-selection: {"symbols":["App.shared()"]}
    open class Parent: XCTestCase {}
    """
    func model(_ value: Int) -> XcodeTestGraph {
        var graph = inlineRegressionGraph(source, value: value, tests: ["UI/Suite/testOne()", "UI/Other/testOther()"])
        graph.modules["Helpers"] = "Helpers"; graph.dependencies!.compilerImplicitImports?["Helpers"] = []; graph.modules["Support"] = "Support"; graph.dependencies!.compilerImplicitImports?["Support"] = []
        for module in ["Helpers", "Support"] {
            graph.targets.append(.init(name: module, productType: "com.apple.product-type.framework", sourceFiles: [module + ".swift"]))
        }
        graph.sources["Helpers:Helpers.swift"] = .parse("import Support\npublic typealias \(parent) = Support.Parent", path: "Helpers.swift", module: "Helpers")
        graph.sources["Support:Support.swift"] = .parse(support, path: "Support.swift", module: "Support")
        if evidence == "uncaptured" { graph.sources.removeValue(forKey: "Helpers:Helpers.swift") }
        graph.dependencies!.testDiagnostics = [:]
        XcodeCompilerGraph.bind(tests: graph.tests, modules: graph.modules, sources: graph.sources, graph: &graph.dependencies!)
        if evidence != "absent" {
            graph.runtimeInventory = .init(imports: ["UI": evidence == "unrelated" ? ["Support"] : ["Helpers", "Support"],
                                                    "Helpers": ["Support"], "Support": []], hosts: [:])
            if evidence == "unavailable" { graph.runtimeInventory!.unavailableModules = ["UI": "incomplete imports"] }
        }
        return graph
    }
    let base = model(1)
    let head = try GraphArchive.decode(GraphArchive.encode(model(2)))
    let report = XcodeFineSelector.select(current: head, previous: base, changes: [.init(path: "App.swift")], baseRevision: "base")
    if evidence == "unrelated" {
        #expect(report.selectedTests == ["UI/Other/testOther()"])
        #expect(report.diagnostics.isEmpty)
        try head.validateMappingSymbols(mappingFile: "ui.json", revision: "head", buildContext: [:])
    } else {
        #expect(report.selectedTests == head.tests.sorted())
        #expect(report.diagnostics.contains { $0.code == "invalid_inline_mapping" && $0.tests == ["UI/Suite/testOne()"] })
        #expect(throws: MappingValidationError.self) {
            try head.validateMappingSymbols(mappingFile: "ui.json", revision: "head", buildContext: [:])
        }
        #expect(InlineMappingAudit.inspect(head).diagnostics.contains { $0.tests == ["UI/Suite/testOne()"] })
        let headOnly = XcodeHeadOnlySelector.select(current: head, source: .init(base: head.sources, mappings: head.mappings), changes: [], baseRevision: "base")
        #expect(headOnly.selectedTests.contains("UI/Suite/testOne()"))
        if evidence == "complete" {
            // Disabled suites do not acquire mappings or poison an unrelated
            // enabled suite whose compiler imports prove the alias is invisible.
            var disabled = head; disabled.tests = ["UI/Other/testOther()"]
            try disabled.validateMappingSymbols(mappingFile: "ui.json", revision: "head", buildContext: [:])
            #expect(InlineUIMappings.resolve(disabled).diagnostics.isEmpty)
        }
    }
}

@Test(arguments: ["schema", "reference", "load", "legacy", "collision", "valid"])
func inlineMappingAuditReportsFileFailuresWithoutHidingInlineEntries(policy: String) throws {
    let source = """
    import XCTest
    // swift-test-selection: {"symbols":["App.checkout()","App.missing()"]}
    class Suite: XCTestCase { func testOne() {} }
    class Other: XCTestCase { func testOther() {} }
    """
    var graph = inlineRegressionGraph(source, tests: ["UI/Suite/testOne()", "UI/Other/testOther()"])
    graph.mappings = .init(features: [.init(name: "file", symbols: ["App.shared()"], tests: ["UI/Other"])])
    switch policy {
    case "schema": graph.mappings = .init(version: 1, features: [.init(name: "file", tests: ["UI/Other"], when: .sourceChanged("App.swift"))])
    case "reference": graph.mappings!.features[0].dependsOn = ["absent"]
    case "load": graph.mappingLoadError = "Invalid mapping JSON"
    case "legacy": graph.diagnostics = ["Invalid UI mappings: Invalid mapping JSON"]
    case "collision": graph.mappings!.features[0].name = try #require(InlineUIMappings.resolve(graph).features.first?.name)
    default: break
    }
    for snapshot in [graph, try GraphArchive.decode(GraphArchive.encode(graph))] {
        let audit = InlineMappingAudit.inspect(snapshot)
        let rule = try #require(audit.rules.first)
        #expect(rule.resolvedSymbols == ["App.checkout()"])
        #expect(rule.unresolvedEntries == ["symbols: App.missing()"])
        if policy == "valid" {
            #expect(audit.diagnostics.isEmpty)
            #expect(audit.unmappedUITests.isEmpty)
        } else {
            #expect(audit.diagnostics.contains { $0.code == "invalid_mapping_file" })
            #expect(audit.unmappedUITests == ["UI/Other/testOther()"])
        }
    }
}

@Test func inlineMappingFrameworkImportsRequireCurrentUnconditionalEvidence() throws {
    let source = """
    import XCTest
    // swift-test-selection: {"symbols":["App.shared()"]}
    class Suite: XCTestCase { func testOne() {} }
    """
    let current = inlineRegressionGraph(source, tests: ["UI/Suite/testOne()"])
    try current.validateMappingSymbols(mappingFile: "ui.json", revision: "head", buildContext: [:])
    var legacy = current
    legacy.sources["UI:UI.swift"]!.inlineMappings!.frameworkImports = nil
    var legacyScoped = current
    legacyScoped.sources["UI:UI.swift"]!.inlineMappings!.scopedTypeImports = nil
    var legacyReexport = current
    legacyReexport.sources["UI:UI.swift"]!.inlineMappings!.reexportedTypeImports = nil
    let conditional = inlineRegressionGraph(source.replacingOccurrences(of: "import XCTest", with: "#if NEVER\nimport XCTest\n#endif"), tests: current.tests)
    for graph in [legacy, legacyScoped, legacyReexport, conditional] {
        let saved = try GraphArchive.decode(GraphArchive.encode(graph))
        let report = XcodeFineSelector.select(current: saved, previous: saved, changes: [], baseRevision: "base")
        #expect(report.selectedTests == current.tests)
        #expect(report.diagnostics.contains { $0.code == "invalid_inline_mapping" })
        #expect(throws: MappingValidationError.self) {
            try saved.validateMappingSymbols(mappingFile: "ui.json", revision: "head", buildContext: [:])
        }
    }
}

@Test(arguments: ["XCTestCase", "NSObject"], ["plain", "conditional", "escaped", "qualified", "unrelated"])
func inlineMappingScopedImportsCannotSupplyFrameworkIdentity(parent: String, mode: String) throws {
    let imported = mode == "escaped" ? "`\(parent)`" : mode == "unrelated" ? "Unrelated" : parent
    let scoped = "import typealias Helpers.\(imported)"
    let source = """
    import XCTest
    \(mode == "conditional" ? "#if DEBUG\n\(scoped)\n#endif" : scoped)
    import Support
    // swift-test-selection: {"symbols":["App.checkout()"]}
    class Suite: \(mode == "qualified" ? "XCTest.XCTestCase" : parent) { func testOne() {} }
    class Other: Support.Parent { func testOther() {} }
    """
    func model(_ value: Int) -> XcodeTestGraph {
        var graph = inlineRegressionGraph(source, value: value, tests: ["UI/Suite/testOne()", "UI/Other/testOther()"])
        graph.modules["Support"] = "Support"; graph.dependencies!.compilerImplicitImports?["Support"] = []
        graph.targets.append(.init(name: "Support", productType: "com.apple.product-type.framework", sourceFiles: ["Support.swift"]))
        graph.sources["Support:Support.swift"] = .parse("""
        import XCTest
        // swift-test-selection: {"symbols":["App.shared()"]}
        open class Parent: XCTestCase {}
        """, path: "Support.swift", module: "Support")
        // Helpers is an external module; no captured alias declaration can reveal
        // that its scoped import overrides the framework's unqualified name.
        graph.runtimeInventory = .init(imports: ["UI": ["Helpers", "Support"], "Support": []], hosts: [:])
        XcodeCompilerGraph.bind(tests: graph.tests, modules: graph.modules, sources: graph.sources, graph: &graph.dependencies!)
        return graph
    }
    let base = model(1)
    for head in [model(2), try GraphArchive.decode(GraphArchive.encode(model(2)))] {
        let safe = ["qualified", "unrelated"].contains(mode)
        let resolution = InlineUIMappings.resolve(head)
        let report = XcodeFineSelector.select(current: head, previous: base, changes: [.init(path: "App.swift")], baseRevision: "base")
        if safe {
            #expect(resolution.diagnostics.isEmpty)
            #expect(report.selectedTests == ["UI/Other/testOther()"])
            try head.validateMappingSymbols(mappingFile: "ui.json", revision: "head", buildContext: [:])
        } else {
            #expect(report.selectedTests == head.tests.sorted())
            #expect(resolution.diagnostics.contains { $0.tests == ["UI/Suite/testOne()"] })
            #expect(throws: MappingValidationError.self) {
                try head.validateMappingSymbols(mappingFile: "ui.json", revision: "head", buildContext: [:])
            }
            #expect(InlineMappingAudit.inspect(head).diagnostics.contains { $0.tests == ["UI/Suite/testOne()"] })
            let headOnly = XcodeHeadOnlySelector.select(current: head, source: .init(base: head.sources, mappings: head.mappings), changes: [], baseRevision: "base")
            #expect(headOnly.selectedTests == ["UI/Suite/testOne()"])
        }
        var disabled = head
        disabled.tests = ["UI/Other/testOther()"]
        try disabled.validateMappingSymbols(mappingFile: "ui.json", revision: "head", buildContext: [:])
    }
}

@Test(arguments: [false, true])
func inlineMappingOrphanDiagnosticsFollowEnabledAncestors(extensionMethod: Bool) throws {
    let source = """
    import XCTest
    import Support
    class Suite: Support.Parent { \(extensionMethod ? "" : "func testOne() {}") }
    class Other: XCTestCase { func testOther() {} }
    """
    var graph = inlineRegressionGraph(source, tests: ["UI/Suite/testOne()", "UI/Other/testOther()"])
    graph.modules["Support"] = "Support"; graph.dependencies!.compilerImplicitImports?["Support"] = []
    graph.targets.append(.init(name: "Support", productType: "com.apple.product-type.framework", sourceFiles: ["Support.swift", "Extension.swift"]))
    let orphan = "// swift-test-selection: {\"symbols\":[\"App.shared()\"]}"
    graph.sources["Support:Support.swift"] = .parse("import XCTest\nopen class Parent: XCTestCase {} " + (extensionMethod ? "" : orphan), path: "Support.swift", module: "Support")
    if extensionMethod {
        let syntax = SwiftSourceSnapshot.parse("extension Parent { func testOne() {} } " + orphan, path: "Extension.swift", module: "Support")
        graph.sources["Support:Extension.swift"] = syntax
        let method = try #require(syntax.inlineMappings!.declarations.first { $0.kind == "method" })
        graph.dependencies!.functions["Parent.testOne()"] = .init(id: "Parent.testOne()", module: "Support", name: "Parent.testOne()", regions: [method.region])
    }
    graph.mappings = .init(features: [.init(name: "suite", symbols: ["App.checkout()"], tests: ["UI/Suite"]),
                                    .init(name: "other", symbols: ["App.shared()"], tests: ["UI/Other"])], runtimeDependencyPolicy: .declared)
    XcodeCompilerGraph.bind(tests: graph.tests, modules: graph.modules, sources: graph.sources, graph: &graph.dependencies!)
    for snapshot in [graph, try GraphArchive.decode(GraphArchive.encode(graph))] {
        let expectedPath = extensionMethod ? "Extension.swift" : "Support.swift"
        #expect(snapshot.sources.values.flatMap { $0.inlineMappings?.declarations ?? [] }.allSatisfy { $0.directives.isEmpty })
        let diagnostics = InlineMappingAudit.inspect(snapshot).diagnostics
        #expect(diagnostics.count == 1)
        #expect(diagnostics.first?.message.contains(expectedPath) == true)
        #expect(diagnostics.first?.tests == ["UI/Suite/testOne()"])
        #expect(throws: MappingValidationError.self) {
            try snapshot.validateMappingSymbols(mappingFile: "ui.json", revision: "head", buildContext: [:])
        }
        let report = XcodeFineSelector.select(current: snapshot, previous: snapshot, changes: [], baseRevision: "base")
        #expect(report.selectedTests == ["UI/Suite/testOne()"])
        let headOnly = XcodeHeadOnlySelector.select(current: snapshot, source: .init(base: snapshot.sources, mappings: snapshot.mappings), changes: [], baseRevision: "base")
        #expect(headOnly.selectedTests == ["UI/Suite/testOne()"])
        // A disabled ancestor's orphan must not poison an unrelated enabled suite,
        // even when that suite cannot supply complete inline ancestry evidence.
        var disabled = snapshot
        disabled.tests = ["UI/Other/testOther()"]
        disabled.sources["UI:UI.swift"]!.inlineMappings!.frameworkImports = nil
        #expect(InlineMappingAudit.inspect(disabled).diagnostics.isEmpty)
        try disabled.validateMappingSymbols(mappingFile: "ui.json", revision: "head", buildContext: [:])
    }
}

@Test(arguments: ["direct", "captured", "uncaptured", "suffix", "implicit", "testableImplicit"])
func inlineMappingCompiledSuperclassAmbiguityRetainsConservativeSelection(evidence: String) throws {
    let reexported = evidence != "direct"
    let implicit = ["implicit", "testableImplicit"].contains(evidence)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("inline-scoped-alias-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let platform = try CommandRunner.run("xcrun", ["--sdk", "macosx", "--show-sdk-platform-path"], at: root).text.trimmingCharacters(in: .whitespacesAndNewlines)
    let arguments = ["swiftc", "-F", platform + "/Developer/Library/Frameworks", "-I", platform + "/Developer/usr/lib", "-I", root.path]
    let baseName = evidence == "suffix" ? "Actual" : "Parent"
    let support = """
    import XCTest
    // swift-test-selection: {"symbols":["App.shared()"]}
    open class \(baseName): XCTestCase {}
    """
    for (module, source) in [("Support", support), ("Helpers", "import Support\npublic typealias XCTestCase = Support.\(baseName)"),
                             ("Reexport", "@_exported import typealias Helpers.XCTestCase"),
                             ("External", "import Support\nopen class Parent: Support.\(baseName) {}")] {
        let file = root.appendingPathComponent(module + ".swift")
        try source.write(to: file, atomically: true, encoding: .utf8)
        _ = try CommandRunner.run("xcrun", arguments + ["-emit-module", "-enable-testing", "-module-name", module, file.path,
            "-emit-module-path", root.appendingPathComponent(module + ".swiftmodule").path], at: root)
    }
    let source = """
    import XCTest
    \(implicit ? "" : evidence == "suffix" ? "import External" : reexported ? "import Reexport" : "import typealias Helpers.XCTestCase")
    import Support
    \(evidence == "suffix" ? "enum Namespace { class Parent {} }" : #"// swift-test-selection: {"symbols":["App.checkout()"]}"#)
    class Suite: \(evidence == "suffix" ? "Parent" : "XCTestCase") { func testOne() {} }
    let actualSuperclass: Support.\(baseName).Type = Suite.self
    """
    let file = root.appendingPathComponent("UI.swift"), sil = root.appendingPathComponent("UI.sil")
    try source.write(to: file, atomically: true, encoding: .utf8)
    let implicitFlags = implicit ? ["-Xfrontend", evidence == "testableImplicit" ? "-testable-import-module" : "-import-module", "-Xfrontend", "Reexport"] : []
    _ = try CommandRunner.run("xcrun", arguments + implicitFlags + ["-emit-sil", "-whole-module-optimization", "-Onone", "-g", "-module-name", "UI", file.path, "-o", sil.path], at: root)
    let compiled = try SILParser.parse(file: sil, module: "UI", sourceRoot: root)
    var graph = inlineRegressionGraph(source, tests: ["UI/Suite/testOne()"])
    if implicit {
        let compiler = try CommandRunner.run("xcrun", ["--find", "swiftc"], at: root).text.trimmingCharacters(in: .whitespacesAndNewlines)
        let invocation = [compiler] + Array(arguments.dropFirst()) + implicitFlags + ["-module-name", "UI", file.path]
        let extracted = XcodeCompilerGraph.extract(log: "builtin-SwiftDriver -- " + invocation.joined(separator: " "), sourceRoot: root, directory: root, derived: root, progress: { _ in })
        #expect(extracted.diagnostics.isEmpty)
        #expect(extracted.compilerImplicitImports?["UI"] == ["Reexport"])
        graph.dependencies!.compilerImplicitImports = extracted.compilerImplicitImports
    }
    graph.modules["Support"] = "Support"; graph.dependencies!.compilerImplicitImports?["Support"] = []
    graph.sources["Support:Support.swift"] = .parse(support, path: "Support.swift", module: "Support")
    if evidence == "captured" {
        graph.sources["Reexport:Reexport.swift"] = .parse("@_exported import typealias Helpers.XCTestCase", path: "Reexport.swift", module: "Reexport")
    }
    graph.dependencies!.functions = graph.dependencies!.functions.filter { $0.value.module != "UI" }
    graph.dependencies!.functions.merge(compiled.functions, uniquingKeysWith: { _, new in new })
    XcodeCompilerGraph.bind(tests: graph.tests, modules: graph.modules, sources: graph.sources, graph: &graph.dependencies!)
    let entry = try #require(compiled.functions.values.first { $0.name == "Suite.testOne()" })
    #expect(graph.dependencies!.tests[graph.tests[0]]?.contains(entry.id) == true)
    let saved = try GraphArchive.decode(GraphArchive.encode(graph))
    let report = XcodeFineSelector.select(current: saved, previous: saved, changes: [], baseRevision: "base")
    #expect(report.selectedTests == graph.tests)
    #expect(report.diagnostics.contains { $0.code == "invalid_inline_mapping" })
    #expect(InlineUIMappings.resolve(saved).features.isEmpty)
}

@Test(arguments: ["captured", "transitive", "conditional", "sameModule", "missingInventory", "unrelated", "qualified", "uncaptured", "partial", "transitiveUncaptured", "unlistedBinary", "legacyExports", "legacyImports", "generated", "sameModuleUncaptured", "unknownQualified"])
func inlineMappingReexportedScopedNamesCannotEstablishAncestry(mode: String) throws {
    let source = """
    import XCTest
    \(mode == "unrelated" ? "#if NEVER\nimport Reexport\n#endif" : ["transitive", "transitiveUncaptured"].contains(mode) ? "import Facade" : ["sameModule", "sameModuleUncaptured"].contains(mode) ? "" : "import Reexport")
    import Support
    // swift-test-selection: {"symbols":["App.checkout()"]}
    class Suite: \(["qualified", "unknownQualified"].contains(mode) ? "XCTest.XCTestCase" : "XCTestCase") { func testOne() {} }
    class Other: Support.Parent { func testOther() {} }
    """
    func model(_ value: Int) -> XcodeTestGraph {
        var graph = inlineRegressionGraph(source, value: value, tests: ["UI/Suite/testOne()", "UI/Other/testOther()"])
        graph.modules["Support"] = "Support"; graph.dependencies!.compilerImplicitImports?["Support"] = []
        graph.sources["Support:Support.swift"] = .parse("""
        import XCTest
        // swift-test-selection: {"symbols":["App.shared()"]}
        open class Parent: XCTestCase {}
        """, path: "Support.swift", module: "Support")
        let module = mode == "sameModule" ? "UI" : "Reexport"
        let exported = "@_exported import typealias Helpers.XCTestCase"
        graph.sources[module + ":Exports.swift"] = .parse(mode == "conditional" ? "#if DEBUG\n\(exported)\n#endif" : exported, path: "Exports.swift", module: module)
        graph.sources["Facade:Facade.swift"] = .parse("@_exported import Reexport", path: "Facade.swift", module: "Facade")
        if ["uncaptured", "transitiveUncaptured", "unlistedBinary", "unknownQualified"].contains(mode) {
            graph.sources.removeValue(forKey: module + ":Exports.swift")
        }
        if ["partial", "legacyExports", "legacyImports"].contains(mode) {
            graph.sources[module + ":Exports.swift"] = .parse("import Foundation", path: "Exports.swift", module: module)
            if mode == "partial" {
                graph.targets.append(.init(name: module, productType: "com.apple.product-type.framework", sourceFiles: ["Exports.swift", "MissingExports.swift"]))
            }
        }
        if mode == "sameModuleUncaptured" {
            graph.sources.removeValue(forKey: module + ":Exports.swift")
            graph.sources["UI:Exports.swift"] = .parse("@_exported import Binary", path: "Exports.swift", module: "UI")
        }
        if mode == "generated" {
            graph.sources[module + ":Exports.swift"] = .parse("import Foundation", path: "Exports.swift", module: module)
            graph.unsupportedSourceInputs = [module: ["/tmp/GeneratedExports.swift"]]
        }
        if mode == "legacyExports" { graph.sources[module + ":Exports.swift"]!.inlineMappings!.reexportedModules = nil }
        if mode == "legacyImports" { graph.sources["UI:UI.swift"]!.inlineMappings!.moduleImports = nil }
        if mode != "missingInventory" {
            graph.runtimeInventory = .init(imports: ["UI": mode == "unrelated" ? ["Support"] : ["Facade", "Reexport", "Helpers", "Support"],
                "Facade": ["Reexport", "Helpers", "Support"], "Reexport": ["Helpers", "Support"], "Support": []], hosts: [:])
        }
        if mode == "unlistedBinary" {
            // Runtime inventories enumerate project imports, not binary modules.
            graph.runtimeInventory = .init(imports: ["UI": ["Support"], "Support": []], hosts: [:])
        }
        XcodeCompilerGraph.bind(tests: graph.tests, modules: graph.modules, sources: graph.sources, graph: &graph.dependencies!)
        return graph
    }
    for head in [model(2), try GraphArchive.decode(GraphArchive.encode(model(2)))] {
        let report = XcodeFineSelector.select(current: head, previous: model(1), changes: [.init(path: "App.swift")], baseRevision: "base")
        if ["unrelated", "qualified"].contains(mode) {
            #expect(report.selectedTests == ["UI/Other/testOther()"])
            #expect(InlineMappingAudit.inspect(head).diagnostics.isEmpty)
            try head.validateMappingSymbols(mappingFile: "ui.json", revision: "head", buildContext: [:])
        } else {
            #expect(report.selectedTests == head.tests.sorted())
            #expect(InlineMappingAudit.inspect(head).diagnostics.contains { $0.tests == ["UI/Suite/testOne()"] })
            #expect(throws: MappingValidationError.self) {
                try head.validateMappingSymbols(mappingFile: "ui.json", revision: "head", buildContext: [:])
            }
            let headOnly = XcodeHeadOnlySelector.select(current: head, source: .init(base: head.sources, mappings: head.mappings), changes: [], baseRevision: "base")
            #expect(headOnly.selectedTests.contains("UI/Suite/testOne()"))
        }
    }
}

@Test(arguments: ["class", "method", "extension", "overridden"], ["External.Base", "Base"])
func inlineMappingDisabledPoliciesDoNotRequireUnrelatedAncestry(placement: String, parent: String) throws {
    let annotation = "// swift-test-selection: {\"symbols\":[\"App.stale()\"]}"
    let source: String
    switch placement {
    case "class": source = """
        import XCTest
        import External
        \(annotation)
        class Disabled: XCTestCase { func testDisabled() {} }
        class Enabled: \(parent) { func testOne() {} }
        """
    case "extension": source = """
        import External
        class Enabled: \(parent) { func testOne() {} }
        \(annotation)
        extension Enabled { func testDisabled() {} }
        """
    case "overridden": source = """
        import External
        class Parent: \(parent) {
            \(annotation)
            func testOne() {}
        }
        class Enabled: Parent { override func testOne() {} }
        """
    default: source = """
        import External
        class Enabled: \(parent) {
            func testOne() {}
            \(annotation)
            func testDisabled() {}
        }
        """
    }
    var graph = inlineRegressionGraph(source, tests: ["UI/Enabled/testOne()"])
    graph.mappings = .init(features: [.init(name: "enabled", symbols: ["App.checkout()"], tests: graph.tests)], runtimeDependencyPolicy: .declared)
    for snapshot in [graph, try GraphArchive.decode(GraphArchive.encode(graph))] {
        #expect(InlineMappingAudit.inspect(snapshot).diagnostics.isEmpty)
        try snapshot.validateMappingSymbols(mappingFile: "ui.json", revision: "head", buildContext: [:])
        #expect(XcodeFineSelector.select(current: snapshot, previous: snapshot, changes: [], baseRevision: "base").selectedTests.isEmpty)
        #expect(XcodeHeadOnlySelector.select(current: snapshot, source: .init(base: snapshot.sources, mappings: snapshot.mappings), changes: [], baseRevision: "base").selectedTests.isEmpty)
    }
    // Enabling the annotated executable still requires validation.
    var enabled = graph
    enabled.tests = [placement == "class" ? "UI/Disabled/testDisabled()" : placement == "overridden" ? "UI/Parent/testOne()" : "UI/Enabled/testDisabled()"]
    XcodeCompilerGraph.bind(tests: enabled.tests, modules: enabled.modules, sources: enabled.sources, graph: &enabled.dependencies!)
    #expect(throws: MappingValidationError.self) {
        try enabled.validateMappingSymbols(mappingFile: "ui.json", revision: "head", buildContext: [:])
    }
}

@Test(arguments: [false, true])
func inlineMappingSuffixCandidatesCannotSuppressImportedPolicyUncertainty(archived: Bool) throws {
    let source = """
    import XCTest
    import External
    import Support
    enum Namespace { class Parent {} }
    class Suite: Parent { func testOne() {} }
    class Other: Support.Actual { func testOther() {} }
    """
    func model(_ value: Int) -> XcodeTestGraph {
        var graph = inlineRegressionGraph(source, value: value, tests: ["UI/Suite/testOne()", "UI/Other/testOther()"])
        graph.modules["Support"] = "Support"; graph.dependencies!.compilerImplicitImports?["Support"] = []
        graph.sources["Support:Support.swift"] = .parse("""
        import XCTest
        // swift-test-selection: {"symbols":["App.shared()"]}
        open class Actual: XCTestCase {}
        """, path: "Support.swift", module: "Support")
        graph.mappings = .init(features: [.init(name: "suite-file", symbols: ["App.checkout()"], tests: ["UI/Suite"])], runtimeDependencyPolicy: .declared)
        graph.runtimeInventory = .init(imports: ["UI": ["External", "Support"], "Support": []], hosts: [:])
        XcodeCompilerGraph.bind(tests: graph.tests, modules: graph.modules, sources: graph.sources, graph: &graph.dependencies!)
        return graph
    }
    let graph = try archived ? GraphArchive.decode(GraphArchive.encode(model(2))) : model(2)
    let resolution = InlineUIMappings.resolve(graph)
    #expect(resolution.diagnostics.contains { $0.tests == ["UI/Suite/testOne()"] })
    #expect(throws: MappingValidationError.self) {
        try graph.validateMappingSymbols(mappingFile: "ui.json", revision: "head", buildContext: [:])
    }
    let report = XcodeFineSelector.select(current: graph, previous: model(1), changes: [.init(path: "App.swift")], baseRevision: "base")
    #expect(report.selectedTests == graph.tests.sorted())
    #expect(InlineMappingAudit.inspect(graph).diagnostics.contains { $0.tests == ["UI/Suite/testOne()"] })
    let headOnly = XcodeHeadOnlySelector.select(current: graph, source: .init(base: graph.sources, mappings: graph.mappings), changes: [], baseRevision: "base")
    #expect(headOnly.selectedTests.contains("UI/Suite/testOne()"))
}

@Test(arguments: ["`Suite`", "UI.`Suite`", "UI . Suite", "Alias"], [false, true])
func inlineMappingExtensionOwnersUseCompilerIdentity(spelling: String, extensionRule: Bool) throws {
    let source = """
    import XCTest
    class Suite: XCTestCase {}
    typealias Alias = Suite
    \(extensionRule ? #"// swift-test-selection: {"symbols":["App.shared()"]}"# : "")
    extension \(spelling) {
        \(extensionRule ? "" : #"// swift-test-selection: {"symbols":["App.shared()"]}"#)
        @objc func testOne() {}
    }
    // swift-test-selection: {"symbols":["App.shared()"]}
    class Other: XCTestCase { func testOther() {} }
    """
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("inline-extension-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let platform = try CommandRunner.run("xcrun", ["--sdk", "macosx", "--show-sdk-platform-path"], at: root).text.trimmingCharacters(in: .whitespacesAndNewlines)
    let file = root.appendingPathComponent("UI.swift"), sil = root.appendingPathComponent("UI.sil")
    try source.write(to: file, atomically: true, encoding: .utf8)
    _ = try CommandRunner.run("xcrun", ["swiftc", "-F", platform + "/Developer/Library/Frameworks", "-I", platform + "/Developer/usr/lib", "-emit-sil", "-whole-module-optimization", "-Onone", "-g", "-module-name", "UI", file.path, "-o", sil.path], at: root)
    let compiled = try SILParser.parse(file: sil, module: "UI", sourceRoot: root)
    func graph(_ value: Int) -> XcodeTestGraph {
        var graph = inlineRegressionGraph(source, value: value, tests: ["UI/Suite/testOne()", "UI/Other/testOther()"])
        graph.dependencies!.functions = graph.dependencies!.functions.filter { $0.value.module != "UI" }
        graph.dependencies!.functions.merge(compiled.functions, uniquingKeysWith: { _, new in new })
        graph.dependencies!.testDiagnostics = [:]
        XcodeCompilerGraph.bind(tests: graph.tests, modules: graph.modules, sources: graph.sources, graph: &graph.dependencies!)
        graph.mappings = .init(features: [.init(name: "suite", symbols: ["App.checkout()"], tests: ["UI/Suite"])], runtimeDependencyPolicy: .declared)
        return graph
    }
    let head = try GraphArchive.decode(GraphArchive.encode(graph(2)))
    #expect(head.dependencies!.testDiagnostics.isEmpty)
    #expect(InlineUIMappings.resolve(head).features.contains { $0.tests?.contains("UI/Suite/testOne()") == true })
    let report = XcodeFineSelector.select(current: head, previous: graph(1), changes: [.init(path: "App.swift")], baseRevision: "base")
    #expect(report.selectedTests == head.tests.sorted())
    try head.validateMappingSymbols(mappingFile: "ui.json", revision: "head", buildContext: [:])
    #expect(InlineMappingAudit.inspect(head).diagnostics.isEmpty)
    let headOnly = XcodeHeadOnlySelector.select(current: head, source: .init(base: graph(1).sources, mappings: head.mappings), changes: [.init(path: "App.swift")], baseRevision: "base")
    #expect(headOnly.selectedTests == head.tests.sorted())
    var disabled = head
    disabled.tests = ["UI/Other/testOther()"]
    try disabled.validateMappingSymbols(mappingFile: "ui.json", revision: "head", buildContext: [:])
    #expect(InlineMappingAudit.inspect(disabled).diagnostics.isEmpty)
    if spelling == "Alias" {
        var redirected = head
        redirected.sources["UI:UI.swift"]!.receiverPhysicalLocations = false
        #expect(throws: MappingValidationError.self) {
            try redirected.validateMappingSymbols(mappingFile: "ui.json", revision: "head", buildContext: [:])
        }
    }
}

@Test(arguments: [false, true])
func inlineMappingImplicitCompilerImportsCannotSupplyFrameworkIdentity(projectInventory: Bool) throws {
    let source = """
    import XCTest
    import Support
    // swift-test-selection: {"symbols":["App.checkout()"]}
    class Suite: XCTestCase { func testOne() {} }
    class Other: Support.Parent { func testOther() {} }
    """
    func graph(_ value: Int) -> XcodeTestGraph {
        var graph = inlineRegressionGraph(source, value: value, tests: ["UI/Suite/testOne()", "UI/Other/testOther()"])
        graph.sources["Support:Support.swift"] = .parse("""
        import XCTest
        // swift-test-selection: {"symbols":["App.shared()"]}
        open class Parent: XCTestCase {}
        """, path: "Support.swift", module: "Support")
        graph.modules["Support"] = "Support"; graph.dependencies!.compilerImplicitImports?["Support"] = []
        graph.targets.append(.init(name: "Support", productType: "com.apple.product-type.framework", sourceFiles: ["Support.swift"]))
        graph.dependencies!.compilerImplicitImports?["UI"] = ["Reexport"]
        graph.runtimeInventory = .init(imports: projectInventory ? ["UI": ["Reexport", "Helpers", "Support"], "Reexport": ["Helpers", "Support"], "Helpers": ["Support"], "Support": []] : ["UI": ["Support"], "Support": []], hosts: [:])
        XcodeCompilerGraph.bind(tests: graph.tests, modules: graph.modules, sources: graph.sources, graph: &graph.dependencies!)
        return graph
    }
    let head = try GraphArchive.decode(GraphArchive.encode(graph(2)))
    let report = XcodeFineSelector.select(current: head, previous: graph(1), changes: [.init(path: "App.swift")], baseRevision: "base")
    #expect(report.selectedTests == head.tests.sorted())
    #expect(throws: MappingValidationError.self) {
        try head.validateMappingSymbols(mappingFile: "ui.json", revision: "head", buildContext: [:])
    }
}

@Test(arguments: ["current", "legacy", "missingModule"], [false, true])
func inlineMappingCompilerImportEvidenceRequiresCurrentArchives(evidence: String, compact: Bool) throws {
    let source = """
    import XCTest
    // swift-test-selection: {"symbols":["App.checkout()"]}
    class Suite: XCTestCase { func testOne() {} }
    """
    var graph = inlineRegressionGraph(source, tests: ["UI/Suite/testOne()"])
    let legacy = evidence == "legacy"
    if legacy { graph.dependencies!.compilerImplicitImports = nil }
    if evidence == "missingModule" { graph.dependencies!.compilerImplicitImports?.removeValue(forKey: "UI") }
    let saved = try GraphArchive.decode(compact ? GraphArchive.encode(graph) : JSONEncoder().encode(graph))
    #expect((saved.dependencies!.compilerImplicitImports == nil) == legacy)
    if evidence != "current" {
        #expect(throws: MappingValidationError.self) {
            try saved.validateMappingSymbols(mappingFile: "ui.json", revision: "head", buildContext: [:])
        }
        #expect(InlineMappingAudit.inspect(saved).diagnostics.contains { $0.code == "invalid_inline_mapping" })
        let report = XcodeHeadOnlySelector.select(current: saved, source: .init(base: saved.sources, mappings: saved.mappings), changes: [], baseRevision: "base")
        #expect(report.selectedTests == saved.tests)
    } else {
        try saved.validateMappingSymbols(mappingFile: "ui.json", revision: "head", buildContext: [:])
        #expect(XcodeFineSelector.select(current: saved, previous: saved, changes: [], baseRevision: "base").selectedTests.isEmpty)
    }
}

@Test func inlineMappingCompilerImportOptionsPreserveFrontendOperands() throws {
    #expect(try XcodeCompilerGraph.implicitImports(["-Xfrontend", "-import-module", "-Xfrontend", "Binary", "-testable-import-module", "Support"]) == ["Binary", "Support"])
    #expect(try XcodeCompilerGraph.implicitImports(["-import-module=Binary", "-testable-import-module=Support"]) == ["Binary", "Support"])
    for args in [["-import-module"], ["-testable-import-module", "-O"], ["-import-module="]] {
        #expect(throws: ImpactError.self) { try XcodeCompilerGraph.implicitImports(args) }
    }
}

@Test func inlineMappingModuleNamedNamespaceKeepsItsLexicalScope() throws {
    let source = """
    import XCTest
    enum UI {
        // swift-test-selection: {"symbols":["App.shared()"]}
        class Suite: XCTestCase { func testOne() {} }
    }
    """
    let graph = inlineRegressionGraph(source, tests: ["UI/UI.Suite/testOne()"])
    let saved = try GraphArchive.decode(GraphArchive.encode(graph))
    let resolution = InlineUIMappings.resolve(saved)
    #expect(resolution.diagnostics.isEmpty)
    #expect(resolution.features.first?.tests == saved.tests)
    try saved.validateMappingSymbols(mappingFile: "ui.json", revision: "head", buildContext: [:])
}

@Test(arguments: [false, true], ["class", "enum", "struct"])
func inlineMappingNestedAliasDeclarationsUseCompilerIdentity(methodRule: Bool, container: String) throws {
    let source = """
    import XCTest
    \(container) Outer {}
    typealias Alias = Outer
    extension Alias {
        enum Namespace {
            \(methodRule ? "" : #"// swift-test-selection: {"symbols":["App.shared()"]}"#)
            class Suite: XCTestCase {
                \(methodRule ? #"// swift-test-selection: {"symbols":["App.shared()"]}"# : "")
                func testOne() {}
            }
        }
    }
    // swift-test-selection: {"symbols":["App.shared()"]}
    class Other: XCTestCase { func testOther() {} }
    """
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("inline-nested-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("UI.swift"), sil = root.appendingPathComponent("UI.sil")
    try source.write(to: file, atomically: true, encoding: .utf8)
    let platform = try CommandRunner.run("xcrun", ["--sdk", "macosx", "--show-sdk-platform-path"], at: root).text.trimmingCharacters(in: .whitespacesAndNewlines)
    _ = try CommandRunner.run("xcrun", ["swiftc", "-F", platform + "/Developer/Library/Frameworks", "-I", platform + "/Developer/usr/lib", "-emit-sil", "-whole-module-optimization", "-g", "-module-name", "UI", file.path, "-o", sil.path], at: root)
    let compiled = try SILParser.parse(file: sil, module: "UI", sourceRoot: root)
    func model(_ value: Int) -> XcodeTestGraph {
        var graph = inlineRegressionGraph(source, value: value, tests: ["UI/Outer.Namespace.Suite/testOne()", "UI/Other/testOther()"])
        graph.dependencies!.functions = graph.dependencies!.functions.filter { $0.value.module != "UI" }
        graph.dependencies!.functions.merge(compiled.functions, uniquingKeysWith: { _, new in new })
        graph.dependencies!.testDiagnostics = [:]
        XcodeCompilerGraph.bind(tests: graph.tests, modules: graph.modules, sources: graph.sources, graph: &graph.dependencies!)
        graph.mappings = .init(features: [.init(name: "suite", symbols: ["App.checkout()"], tests: ["UI/Outer.Namespace.Suite"])], runtimeDependencyPolicy: .declared)
        return graph
    }
    for head in [model(2), try GraphArchive.decode(GraphArchive.encode(model(2))), try GraphArchive.decode(JSONEncoder().encode(model(2)))] {
        #expect(head.dependencies!.testDiagnostics.isEmpty)
        #expect(head.dependencies!.tests["UI/Outer.Namespace.Suite/testOne()"]?.isEmpty == false)
        let report = XcodeFineSelector.select(current: head, previous: model(1), changes: [.init(path: "App.swift")], baseRevision: "base")
        #expect(report.selectedTests == head.tests.sorted())
        #expect(InlineMappingAudit.inspect(head).rules.contains { $0.feature.tests?.contains("UI/Outer.Namespace.Suite/testOne()") == true })
        try head.validateMappingSymbols(mappingFile: "ui.json", revision: "head", buildContext: [:])
        #expect(InlineMappingAudit.inspect(head).diagnostics.isEmpty)
        let headOnly = XcodeHeadOnlySelector.select(current: head, source: .init(base: model(1).sources, mappings: head.mappings), changes: [.init(path: "App.swift")], baseRevision: "base")
        #expect(headOnly.selectedTests == head.tests.sorted())
        #expect(XcodeFineSelector.select(current: head, previous: head, changes: [], baseRevision: "base").selectedTests.isEmpty)

        for evidence in ["redirected", "missingOwner", "missingLocations"] {
            var incomplete = head
            if evidence == "redirected" { incomplete.sources["UI:UI.swift"]!.receiverPhysicalLocations = false }
            if evidence == "missingOwner" { incomplete.sources["UI:UI.swift"]!.units.removeAll { $0.kind == "type" && $0.scope == "Outer" } }
            if evidence == "missingLocations" {
                for id in incomplete.dependencies!.functions.keys where incomplete.dependencies!.functions[id]!.module == "UI" {
                    incomplete.dependencies!.functions[id]!.regions = []
                }
            }
            #expect(throws: MappingValidationError.self) {
                try incomplete.validateMappingSymbols(mappingFile: "ui.json", revision: "head", buildContext: [:])
            }
            #expect(InlineMappingAudit.inspect(incomplete).diagnostics.contains { $0.tests.contains("UI/Outer.Namespace.Suite/testOne()") })
            let selected = XcodeFineSelector.select(current: incomplete, previous: model(1), changes: [.init(path: "App.swift")], baseRevision: "base")
            #expect(selected.selectedTests == head.tests.sorted())
        }
        var disabled = head
        disabled.tests = ["UI/Other/testOther()"]
        try disabled.validateMappingSymbols(mappingFile: "ui.json", revision: "head", buildContext: [:])
        #expect(InlineMappingAudit.inspect(disabled).diagnostics.isEmpty)
    }
}

@Test(arguments: ["Alias", "UI . `Alias`"], ["alias", "inherited", "subclass"])
func inlineMappingNestedAliasPreservesUncertainAncestry(spelling: String, scenario: String) throws {
    let inherited = scenario != "alias"
    let suite = scenario == "subclass" ? "Derived" : "Outer.Suite"
    let test = "UI/" + suite + "/testOne()"
    let source = """
    import XCTest
    class Outer {}
    typealias Alias = Outer
    // swift-test-selection: {"symbols":["App.checkout()"]}
    class Base: XCTestCase { func testOne() {} }
    // swift-test-selection: {"symbols":["App.shared()"]}
    class Actual: XCTestCase {}
    extension \(spelling) {
        typealias Base = Actual
        // swift-test-selection: {"symbols":["App.shared()"]}
        class Suite: \(inherited ? "UI.Base" : "Base") {
            \(inherited ? "" : "func testOne() {}")
        }
    }
    \(scenario == "subclass" ? "class Derived: Outer.Suite {}" : "")
    // swift-test-selection: {"symbols":["App.shared()"]}
    class Other: XCTestCase { func testOther() {} }
    """
    // The inherited variant has no emitted method inside the extension; its
    // class default still needs a diagnostic when no owner can be established.
    // The other variant proves Outer but must retain the nested Base alias,
    // rather than treating the unrelated module-level Base as its superclass.
    var graph = inlineRegressionGraph(source, tests: [test, "UI/Other/testOther()"])
    if inherited {
        graph.dependencies!.tests[test] = ["Base.testOne()"]
        graph.dependencies!.testDiagnostics = [:]
    } else {
        for id in graph.dependencies!.functions.keys where graph.dependencies!.functions[id]!.name.hasSuffix(".Suite.testOne()") {
            graph.dependencies!.functions[id]!.name = "Outer.Suite.testOne()"
        }
        XcodeCompilerGraph.bind(tests: graph.tests, modules: graph.modules, sources: graph.sources, graph: &graph.dependencies!)
        #expect(graph.dependencies!.tests[test]?.isEmpty == false)
    }
    for saved in [graph, try GraphArchive.decode(GraphArchive.encode(graph))] {
        let resolution = InlineUIMappings.resolve(saved)
        #expect(resolution.diagnostics.contains { $0.tests == [test] })
        #expect(!resolution.features.contains { $0.tests?.contains(test) == true })
        #expect(throws: MappingValidationError.self) {
            try saved.validateMappingSymbols(mappingFile: "ui.json", revision: "head", buildContext: [:])
        }
        var disabled = saved
        disabled.tests = ["UI/Other/testOther()"]
        try disabled.validateMappingSymbols(mappingFile: "ui.json", revision: "head", buildContext: [:])
        #expect(InlineUIMappings.resolve(disabled).diagnostics.isEmpty)
    }
}
