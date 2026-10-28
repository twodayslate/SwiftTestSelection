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
    for declaration in ui.inlineMappings!.declarations where declaration.kind == "method" {
        let name = declaration.scope + "." + declaration.method!
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
    // Explicitly naming Namespace.Parent remains a supported lexical binding.
    let text = """
    import XCTest
    import External
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
            #expect(headOnly.selectedTests == [tests[0]])
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
        graph.modules["Helpers"] = "Helpers"; graph.modules["Support"] = "Support"
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
    let conditional = inlineRegressionGraph(source.replacingOccurrences(of: "import XCTest", with: "#if NEVER\nimport XCTest\n#endif"), tests: current.tests)
    for graph in [legacy, conditional] {
        let saved = try GraphArchive.decode(GraphArchive.encode(graph))
        let report = XcodeFineSelector.select(current: saved, previous: saved, changes: [], baseRevision: "base")
        #expect(report.selectedTests == current.tests)
        #expect(report.diagnostics.contains { $0.code == "invalid_inline_mapping" })
        #expect(throws: MappingValidationError.self) {
            try saved.validateMappingSymbols(mappingFile: "ui.json", revision: "head", buildContext: [:])
        }
    }
}
