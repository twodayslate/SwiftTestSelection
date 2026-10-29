// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
import Foundation
import Testing
@testable import TestImpact

private let inlineUI = """
import XCTest
/// Checkout defaults.
/// swift-test-selection: {"symbols":["App.checkout()"]}
@MainActor
class Checkout: XCTestCase {
    // swift-test-selection: {"symbols":["App.shared()"]}
    func testBuy() {}
    func testHistory() {}
    // swift-test-selection: {"symbols":["App.missing()"]}
    func testDisabled() {}
}
// swift-test-selection: {"sources":["App/Notes.swift"]}
class Notes: XCTestCase {
    func testNotes() {}
}
"""

private func inlineModel(_ ui: String = inlineUI, changed: String? = nil) -> XcodeTestGraph {
    let sources = ["UI.swift": ui, "App/Checkout.swift": "func checkout() -> Int { \(changed == "checkout" ? 2 : 1) }",
                   "App/Notes.swift": "func notes() -> Int { \(changed == "notes" ? 2 : 1) }",
                   "App/Shared.swift": "func shared() -> Int { \(changed == "shared" ? 2 : 1) }"]
    var result = XcodeTestGraph(targets: [
        .init(name: "UI", productType: "com.apple.product-type.bundle.ui-testing", sourceFiles: ["UI.swift"]),
        .init(name: "App", productType: "com.apple.product-type.application", sourceFiles: Set(sources.keys.filter { $0 != "UI.swift" }))
    ], tests: ["UI/Checkout/testBuy()", "UI/Checkout/testHistory()", "UI/Notes/testNotes()"])
    result.modules = ["UI": "UI", "App": "App"]
    var graph = DependencyGraph()
    graph.compilerImplicitImports = ["UI": [], "App": []]
    for (path, text) in sources {
        let module = path == "UI.swift" ? "UI" : "App"
        let syntax = SwiftSourceSnapshot.parse(text, path: path, module: module)
        result.sources[module + ":" + path] = syntax
        if module == "UI" {
            for declaration in syntax.inlineMappings!.declarations where declaration.kind == "method" {
                let name = declaration.scope + "." + declaration.method!
                let id = name + ":" + String(declaration.region.startLine)
                graph.functions[id] = .init(id: id, module: module, name: name, regions: [declaration.region])
            }
        } else {
            let name = path == "App/Checkout.swift" ? "checkout()" : path == "App/Notes.swift" ? "notes()" : "shared()"
            graph.functions[name] = .init(id: name, module: module, name: name, regions: [syntax.units[0].region])
        }
    }
    XcodeCompilerGraph.bind(tests: result.tests, modules: result.modules, sources: result.sources, graph: &graph)
    result.dependencies = graph
    return result
}

private func inlineSelect(_ after: XcodeTestGraph, _ before: XcodeTestGraph, path: String = "UI.swift") -> ImpactReport {
    XcodeFineSelector.select(current: after, previous: before, changes: [.init(path: path)], baseRevision: "base")
}

@Test func inlineMappingConfigFreeSelectionAndAdditiveDefaults() throws {
    for binary in [false, true] {
        let base = inlineModel()
        let raw = inlineModel(changed: "checkout")
        let head = try binary ? GraphArchive.decode(GraphArchive.encode(raw)) : raw
        let report = inlineSelect(head, base, path: "App/Checkout.swift")
        #expect(report.selectedTests == ["UI/Checkout/testBuy()", "UI/Checkout/testHistory()"])
        #expect(report.diagnostics.isEmpty)
        #expect(report.uiMappingCoverage?.mappingFilePresent == false)
        #expect(report.explanations.allSatisfy { $0.kind == "explicitMapping" && $0.path.joined().contains("UI.swift:3") })
        #expect(inlineSelect(inlineModel(changed: "shared"), base, path: "App/Shared.swift").selectedTests == ["UI/Checkout/testBuy()"])
    }
    var base = inlineModel(), head = inlineModel(changed: "shared")
    let file = UIFeatureMappings(features: [.init(name: "shared", symbols: ["App.shared()"], tests: ["UI/Notes"])])
    base.mappings = file; head.mappings = file
    #expect(inlineSelect(head, base, path: "App/Shared.swift").selectedTests == ["UI/Checkout/testBuy()", "UI/Notes/testNotes()"])
}

@Test func inlineMappingPolicyOnlyChangesAndProse() throws {
    let base = inlineModel()
    for replacement in ["App.notes()", "App.checkout()"] {
        let head = inlineModel(inlineUI.replacingOccurrences(of: "App.shared()", with: replacement))
        #expect(head.sources["UI:UI.swift"]!.units.map(\.fingerprint) == base.sources["UI:UI.swift"]!.units.map(\.fingerprint))
        let report = inlineSelect(try GraphArchive.decode(GraphArchive.encode(head)), base)
        #expect(report.selectedTests == ["UI/Checkout/testBuy()"])
        #expect(report.explanations.contains { $0.kind == "inlineMappingChanged" })
        #expect(report.ignoredChanges.isEmpty)
    }
    let removed = inlineModel(inlineUI.replacingOccurrences(of: "    // swift-test-selection: {\"symbols\":[\"App.shared()\"]}\n", with: ""))
    #expect(inlineSelect(removed, base).selectedTests == ["UI/Checkout/testBuy()"])
    #expect(inlineSelect(base, removed).selectedTests == ["UI/Checkout/testBuy()"])
    let prose = inlineModel("// unrelated header\n" + inlineUI.replacingOccurrences(of: "Checkout defaults.", with: "Other prose."))
    #expect(inlineSelect(prose, base).selectedTests.isEmpty)
    #expect(inlineSelect(prose, base).ignoredChanges == ["UI.swift"])
    let formatted = inlineModel(inlineUI.replacingOccurrences(of: "{\"symbols\":[\"App.shared()\"]}", with: "{ \"symbols\" : [ \"App.shared()\" ] }"))
    #expect(inlineSelect(formatted, base).selectedTests.isEmpty)
}

@Test func inlineMappingStrictValidationAndMalformedDiagnostics() {
    for payload in ["{\"symbols\":[\"App.shared()\",\"App.stale()\"]}", "{\"sources\":[\"App/**\",\"Missing/**\"]}", "{broken}", "{\"symbol\":[\"App.shared()\"]}"] {
        let head = inlineModel(inlineUI.replacingOccurrences(of: "{\"symbols\":[\"App.shared()\"]}", with: payload))
        let report = XcodeFineSelector.select(current: head, previous: head, changes: [], baseRevision: "base")
        #expect(report.selectedTests == ["UI/Checkout/testBuy()"])
        #expect(report.diagnostics.contains { $0.message.contains("UI.swift:6") })
    }
    // A disabled method's stale mapping neither fails active validation nor creates a test.
    let report = inlineSelect(inlineModel(changed: "notes"), inlineModel(), path: "App/Notes.swift")
    #expect(report.diagnostics.isEmpty)
    #expect(report.selectedTests == ["UI/Notes/testNotes()"])
    let orphan = inlineModel(inlineUI + "\n// swift-test-selection: {}\n")
    #expect(inlineSelect(orphan, inlineModel()).diagnostics.contains { $0.message.contains("leading trivia") })
}

@Test func inlineMappingInheritanceExtensionsAndConditionalBranches() {
    let text = """
    import XCTest
    // swift-test-selection: {"symbols":["App.checkout()"]}
    class Parent: XCTestCase {
        // swift-test-selection: {"symbols":["App.shared()"]}
        func testBuy() {}
    }
    class Checkout: Parent { }
    // swift-test-selection: {"sources":["App/Notes.swift"]}
    extension Checkout {
        func testHistory() {}
    }
    // swift-test-selection: {"sources":["App/Notes.swift"]}
    class Notes: XCTestCase { func testNotes() {} }
    #if NEVER
    // swift-test-selection: {"symbols":["App.stale()"]}
    extension Checkout { func testBuy() {} }
    #endif
    """
    var graph = inlineModel(text)
    graph.dependencies!.functions = graph.dependencies!.functions.filter { $0.value.name != "Checkout.testBuy()" }
    XcodeCompilerGraph.bind(tests: graph.tests, modules: graph.modules, sources: graph.sources, graph: &graph.dependencies!)
    let resolution = InlineUIMappings.resolve(graph)
    #expect(resolution.diagnostics.isEmpty)
    let buy = resolution.features.filter { $0.tests?.contains("UI/Checkout/testBuy()") == true }
    #expect(Set(buy.flatMap { $0.symbols ?? [] }) == ["App.checkout()", "App.shared()"])
    let history = resolution.features.filter { $0.tests?.contains("UI/Checkout/testHistory()") == true }
    #expect(history.contains { $0.sources == ["App/Notes.swift"] })
    #expect(history.contains { $0.symbols == ["App.checkout()"] })
    // Missing locations cannot borrow the inactive declaration's annotation.
    for id in graph.dependencies!.functions.keys { graph.dependencies!.functions[id]!.regions = [] }
    #expect(!InlineUIMappings.resolve(graph).diagnostics.isEmpty)
}

@Test func inlineMappingHeadOnlyPolicyChangeIsConservative() {
    let base = inlineModel()
    let head = inlineModel(inlineUI.replacingOccurrences(of: "App.shared()", with: "App.notes()"))
    let report = XcodeHeadOnlySelector.select(current: head, source: .init(base: base.sources), changes: [.init(path: "UI.swift")], baseRevision: "base")
    #expect(report.selectedTests == head.tests)
    #expect(report.diagnostics.contains { $0.code == "head_only_inline_policy_changed" })
    #expect(report.ignoredChanges.isEmpty)
    let prose = inlineModel(inlineUI.replacingOccurrences(of: "Checkout defaults.", with: "Other prose."))
    let proseReport = XcodeHeadOnlySelector.select(current: prose, source: .init(base: base.sources), changes: [.init(path: "UI.swift")], baseRevision: "base")
    #expect(proseReport.selectedTests.isEmpty, "\(proseReport.diagnostics)")
}

@Test func inlineMappingNewArchivesCannotBeReadByOldSourceSchema() throws {
    struct Legacy: Decodable { var sources: [String: SwiftSourceSnapshot] }
    let data = try JSONEncoder().encode(inlineModel())
    #expect(throws: (any Error).self) { try JSONDecoder().decode(Legacy.self, from: data) }
    #expect(try GraphArchive.decode(data).schemaVersion == 4)
}

@Test func inlineMappingConditionsAndStrictCLIValidation() throws {
    let annotated = inlineUI.replacingOccurrences(of: "{\"symbols\":[\"App.shared()\"]}", with: "{\"when\":{\"all\":[{\"symbolChanged\":\"App.shared()\"},{\"sourceChanged\":\"App/Notes.swift\"}]}}")
    let base = inlineModel(annotated)
    var head = inlineModel(annotated, changed: "shared")
    let single = inlineSelect(head, base, path: "App/Shared.swift")
    #expect(single.uiConditionDecisions?.contains { $0.result.status == .notMatched } == true)
    head.sources["App:App/Notes.swift"] = inlineModel(annotated, changed: "notes").sources["App:App/Notes.swift"]
    let both = XcodeFineSelector.select(current: head, previous: base,
        changes: [.init(path: "App/Shared.swift"), .init(path: "App/Notes.swift")], baseRevision: "base")
    #expect(both.selectedTests.contains("UI/Checkout/testBuy()"))
    #expect(both.uiConditionDecisions?.contains { $0.result.status == .matched && $0.feature.contains("UI.swift:6") } == true)
    try base.validateMappingSymbols(mappingFile: ".swift-test-selection.json", revision: "head", buildContext: [:])
    let stale = inlineModel(annotated.replacingOccurrences(of: "App.shared()", with: "App.stale()"))
    #expect(throws: MappingValidationError.self) {
        try stale.validateMappingSymbols(mappingFile: ".swift-test-selection.json", revision: "head", buildContext: [:])
    }
}

@Test func inlineMappingAuthoringPreservesCommentsAndAddsRules() throws {
    let proposal = try InlineMappingAuthoring.propose(source: inlineUI, path: "UI.swift", module: "UI", suite: "Checkout", method: "testBuy()",
        payload: "{\n  \"sources\": [\"App/Notes.swift\"]\n}")
    #expect(proposal.proposedSource.replacingOccurrences(of: "    " + proposal.directive + "\n", with: "") == inlineUI)
    let audit = InlineMappingAudit.inspect(inlineModel(proposal.proposedSource))
    #expect(audit.diagnostics.isEmpty)
    #expect(audit.rules.contains { $0.feature.tests?.contains("UI/Checkout/testBuy()") == true && $0.feature.sources == ["App/Notes.swift"] })
    #expect(audit.rules.contains { $0.feature.tests?.contains("UI/Checkout/testBuy()") == true && $0.feature.symbols == ["App.shared()"] })
    #expect(audit.unmappedUITests.isEmpty)
    #expect(throws: ImpactError.self) {
        try InlineMappingAuthoring.propose(source: "class A { func testA() {} }", path: "A.swift", module: "UI", suite: "A", method: "testA()", payload: "{\"sources\":[\"App/**\"]}")
    }
}

@Test func inlineMappingConditionalClassAndNestedDeclarations() {
    let source = """
    import XCTest
    enum Namespace {
        // swift-test-selection: {"symbols":["App.shared()"]}
        class Inner: XCTestCase {
            func testNested() {}
        }
    }
    #if ACTIVE
    // swift-test-selection: {"symbols":["App.checkout()"]}
    class Checkout: XCTestCase { func testBuy() {} }
    #else
    // swift-test-selection: {"symbols":["App.stale()"]}
    class Checkout: XCTestCase { func testBuy() {} }
    #endif
    """
    var model = inlineModel(source)
    model.tests = ["UI/Checkout/testBuy()", "UI/Namespace.Inner/testNested()"]
    model.dependencies!.functions = model.dependencies!.functions.filter { $0.value.module != "UI" || $0.value.regions[0].startLine < 12 }
    XcodeCompilerGraph.bind(tests: model.tests, modules: model.modules, sources: model.sources, graph: &model.dependencies!)
    let resolution = InlineUIMappings.resolve(model)
    #expect(resolution.diagnostics.isEmpty)
    #expect(resolution.features.count == 2)
    #expect(resolution.features.allSatisfy { !($0.symbols ?? []).contains("App.stale()") })
}

@Test func inlineMappingLegacyMetadataCannotNarrowSilently() {
    var legacy = inlineModel()
    legacy.sources["UI:UI.swift"]!.inlineMappings = nil
    let report = inlineSelect(legacy, legacy, path: "App/Shared.swift")
    #expect(report.selectedTests == legacy.tests)
    #expect(report.diagnostics.contains { $0.message.contains("lack inline mapping metadata") })
}

@Test func inlineMappingCoverageOutputRetainsSharedDependenciesAndProvenance() throws {
    let data = Data(#"{"schemaVersion":1,"validationPassed":true,"diagnostics":[],"additions":[{"name":"checkout","sources":["App/Checkout.swift"],"tests":["UI/Checkout"]},{"name":"shared","sources":["App/Shared.swift"],"tests":["UI/Checkout","UI/Notes"]}],"provenance":[{"session":"suite-run"}]}"#.utf8)
    let proposal = try InlineMappingAuthoring.proposeCoverage(source: inlineUI, path: "UI.swift", module: "UI", target: "UI", suite: "Checkout", proposalData: data)
    #expect(proposal.coverageProposal == String(decoding: data, as: UTF8.self))
    #expect(proposal.coverageFeatures == ["checkout", "shared"])
    let audit = InlineMappingAudit.inspect(inlineModel(proposal.proposedSource))
    #expect(audit.rules.contains { $0.feature.sources == ["App/Checkout.swift", "App/Shared.swift"] && $0.feature.tests?.contains("UI/Checkout/testBuy()") == true })
    #expect(throws: ImpactError.self) {
        try InlineMappingAuthoring.proposeCoverage(source: inlineUI, path: "UI.swift", module: "UI", target: "Other", suite: "Checkout", proposalData: data)
    }
    let invalid = Data(String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\"validationPassed\":true", with: "\"validationPassed\":false").utf8)
    #expect(throws: ImpactError.self) {
        try InlineMappingAuthoring.proposeCoverage(source: inlineUI, path: "UI.swift", module: "UI", target: "UI", suite: "Checkout", proposalData: invalid)
    }
}

@Test func inlineMappingCachePreservesPolicyAndRejectsLegacySchema() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let cache = try XcodeGraphCache(.init(directory: root, context: "inline"), progress: { _ in })
    let base = inlineModel()
    let head = inlineModel(inlineUI.replacingOccurrences(of: "App.shared()", with: "App.notes()"))
    try cache.store(base, identity: ["revision": "base"])
    try cache.store(head, identity: ["revision": "head"])
    let old = try #require(try cache.load(["revision": "base"]))
    let new = try #require(try cache.load(["revision": "head"]))
    #expect(inlineSelect(new, old).selectedTests == ["UI/Checkout/testBuy()"])
    var legacy = base; legacy.schemaVersion = 2
    try cache.store(legacy, identity: ["revision": "legacy"])
    #expect(try cache.load(["revision": "legacy"]) == nil)
}

@Test func inlineMappingInheritedMethodReadsAnotherCompiledModule() {
    let ui = """
    import XCTest
    import Helpers
    /**
     * swift-test-selection: {"symbols":["App.checkout()"]}
     */
    class Checkout: Helpers.Parent {
        func testHistory() {}
    }
    // swift-test-selection: {"sources":["App/Notes.swift"]}
    class Notes: XCTestCase { func testNotes() {} }
    """
    let support = """
    import XCTest
    // swift-test-selection: {"symbols":["App.shared()"]}
    class Parent: XCTestCase {
        // swift-test-selection: {"sources":["App/Notes.swift"]}
        func testBuy() {}
    }
    """
    var graph = inlineModel(ui)
    let snapshot = SwiftSourceSnapshot.parse(support, path: "Support/Parent.swift", module: "Helpers")
    graph.sources["Helpers:Support/Parent.swift"] = snapshot
    graph.modules["Helpers"] = "Helpers"; graph.dependencies!.compilerImplicitImports?["Helpers"] = []
    graph.targets.append(.init(name: "Helpers", productType: "com.apple.product-type.framework", sourceFiles: ["Support/Parent.swift"]))
    let method = snapshot.inlineMappings!.declarations.first { $0.kind == "method" }!
    graph.dependencies!.functions["parentEntry"] = .init(id: "parentEntry", module: "Helpers", name: "Parent.testBuy()", regions: [method.region])
    XcodeCompilerGraph.bind(tests: graph.tests, modules: graph.modules, sources: graph.sources, graph: &graph.dependencies!)
    let rules = InlineUIMappings.resolve(graph)
    #expect(rules.diagnostics.isEmpty)
    let inherited = rules.features.filter { $0.tests?.contains("UI/Checkout/testBuy()") == true }
    #expect(Set(inherited.flatMap { $0.symbols ?? [] }) == ["App.checkout()", "App.shared()"])
    #expect(inherited.contains { $0.sources == ["App/Notes.swift"] && $0.name.contains("Support/Parent.swift:4") })
    #expect(rules.features.contains { $0.tests?.contains("UI/Checkout/testHistory()") == true && $0.symbols == ["App.shared()"] })
}

@Test func inlineMappingConditionsCannotRepairInvalidFileSchemaImplicitly() {
    var graph = inlineModel(inlineUI.replacingOccurrences(of: "{\"symbols\":[\"App.shared()\"]}", with: "{\"when\":{\"sourceChanged\":\"App/Notes.swift\"}}"))
    graph.mappings = UIFeatureMappings(version: 1, features: [.init(name: "invalid", tests: graph.tests, when: .sourceChanged("App/Notes.swift"))])
    #expect(throws: MappingValidationError.self) {
        try graph.validateMappingSymbols(mappingFile: "ui.json", revision: "head", buildContext: [:])
    }
    let report = inlineSelect(graph, graph)
    #expect(report.selectedTests == graph.tests)
    #expect(report.diagnostics.contains { $0.code == "invalid_ui_mappings" })
}
