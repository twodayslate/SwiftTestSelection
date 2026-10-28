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
