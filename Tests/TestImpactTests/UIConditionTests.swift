// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation
import Testing
@testable import TestImpact

private let conditionTest = "UI/Suite/testFlow()"
private let aAndB = UIFeatureMappings.Condition.all([.symbolChanged("App.a()"), .symbolChanged("App.b()")])

private func conditionGraph(a: Int = 1, b: Int = 1, callee: Int = 1,
                            condition: UIFeatureMappings.Condition = aAndB,
                            path: String = "App/A.swift", renamed: Bool = false) -> XcodeTestGraph {
    let files = [path: "func \(renamed ? "renamed" : "a")() -> Int { common() + \(a) }",
                 "App/Nested/B.swift": "func b() -> Int { \(b) }",
                 "App/Common.swift": "func common() -> Int { \(callee) }",
                 "Tests/UI.swift": "import XCTest\nclass Suite: XCTestCase {\n func testFlow() {}\n}"]
    var graph = XcodeTestGraph(targets: [
        .init(name: "App", productType: "com.apple.product-type.application", sourceFiles: Set(files.keys.filter { $0 != "Tests/UI.swift" })),
        .init(name: "UI", productType: "com.apple.product-type.bundle.ui-testing", sourceFiles: ["Tests/UI.swift"])
    ], tests: [conditionTest])
    graph.modules = ["App": "App", "UI": "UI"]
    var dependencies = DependencyGraph()
    for (file, text) in files {
        let module = file == "Tests/UI.swift" ? "UI" : "App"
        let source = SwiftSourceSnapshot.parse(text, path: file, module: module)
        graph.sources[file] = source
        for unit in source.units where unit.kind == "function" {
            let name = module == "UI" ? "Suite.testFlow()" : file == path ? (renamed ? "renamed()" : "a()") : file == "App/Common.swift" ? "common()" : "b()"
            let id = module + "." + name
            dependencies.functions[id] = .init(id: id, module: module, name: name, regions: [unit.region],
                dependencies: name == "a()" ? ["App.common()"] : [])
        }
    }
    dependencies.tests[conditionTest] = ["UI.Suite.testFlow()"]
    graph.dependencies = dependencies
    graph.mappings = .init(version: 2, fixtures: ["flow": ["UI/Suite"]], features: [
        .init(name: "combined", fixtures: ["flow"], when: condition)
    ], runtimeDependencyPolicy: .declared)
    return graph
}

private func compareConditions(_ head: XcodeTestGraph, _ base: XcodeTestGraph = conditionGraph()) -> ImpactReport {
    XcodeSelector.select(current: head, previous: base, changes: [FileChange(path: "App/A.swift"), FileChange(path: "App/Nested/B.swift")], baseRevision: "base")
}

@Test func uiConditionsANDUsesEntireComparisonAndKeepsFalseBoundariesCovered() {
    for (a, b, matched) in [(1, 1, false), (2, 1, false), (1, 2, false), (2, 2, true)] {
        let report = compareConditions(conditionGraph(a: a, b: b))
        #expect(report.selectedTests == (matched ? [conditionTest] : []))
        #expect(report.diagnostics.isEmpty)
        #expect(report.uiConditionDecisions?.count == 2)
        #expect(report.uiConditionDecisions?.allSatisfy { $0.result.status == (matched ? .matched : .notMatched) } == true)
        if matched { #expect(report.explanations.allSatisfy { $0.kind == "explicitCondition" && $0.reason.contains("App.a()") && $0.reason.contains("App.b()") }) }
    }
}

@Test func uiConditionsORAndNestedPaths() {
    let conditions: [UIFeatureMappings.Condition] = [
        .any([.symbolChanged("App.a()"), .symbolChanged("App.b()")]),
        .all([.symbolChanged("App.a*"), .any([.symbolChanged("App.b()"), .sourceChanged("App/Nested/**")])]),
        .all([.sourceChanged("App/A.swift"), .sourceChanged("App/*/B.swift")])
    ]
    for condition in conditions {
        let base = conditionGraph(condition: condition)
        #expect(compareConditions(conditionGraph(a: 2, b: 2, condition: condition), base).selectedTests == [conditionTest])
        #expect(compareConditions(base, base).selectedTests.isEmpty)
    }
    let either = conditions[0]
    for (a, b) in [(2, 1), (1, 2)] {
        #expect(compareConditions(conditionGraph(a: a, b: b, condition: either), conditionGraph(condition: either)).selectedTests == [conditionTest])
    }
}

@Test func uiConditionDoesNotTurnTransitiveImpactIntoDirectChange() {
    let report = compareConditions(conditionGraph(callee: 2))
    #expect(report.selectedTests.isEmpty)
    #expect(report.diagnostics.isEmpty)
    #expect(report.uiConditionDecisions?.allSatisfy { $0.result.status == .notMatched } == true)
}

@Test func uiConditionSemanticNoopsAndPureMoves() {
    let condition = UIFeatureMappings.Condition.any([.sourceChanged("App/**"), .symbolChanged("App.a()")])
    let base = conditionGraph(condition: condition)
    var head = conditionGraph(condition: condition, path: "Moved/A.swift")
    head.sources["Moved/A.swift"] = SwiftSourceSnapshot.parse("// comment\nfunc a() -> Int { common( ) + 1 }", path: "Moved/A.swift", module: "App")
    head.dependencies!.functions["App.a()"]!.regions = [head.sources["Moved/A.swift"]!.units.first { $0.kind == "function" }!.region]
    let report = compareConditions(head, base)
    #expect(report.selectedTests.isEmpty)
    #expect(report.uiConditionDecisions?.allSatisfy { $0.result.status == .notMatched } == true)
}

@Test func uiConditionRenameMatchesOldAndNewSymbolsAndPaths() throws {
    for pattern in ["App.a()", "App.renamed()", "App.*"] {
        let condition = UIFeatureMappings.Condition.symbolChanged(pattern)
        let base = conditionGraph(condition: condition)
        let head = conditionGraph(condition: condition, renamed: true)
        let report = compareConditions(head, base)
        #expect(report.selectedTests == [conditionTest])
        #expect(report.uiConditionDecisions?.allSatisfy { $0.result.status == .matched } == true)
    }
    let condition = UIFeatureMappings.Condition.all([.sourceChanged("App/A.swift"), .sourceChanged("Moved/A.swift")])
    let report = compareConditions(conditionGraph(a: 2, condition: condition, path: "Moved/A.swift"), conditionGraph(condition: condition))
    #expect(report.uiConditionDecisions?.allSatisfy { $0.result.status == .matched } == true)
}

@Test func uiConditionUnresolvedBranchesNeverShortCircuit() {
    for condition in [UIFeatureMappings.Condition.all([.symbolChanged("App.b()"), .symbolChanged("App.missing()")]),
                      .any([.symbolChanged("App.a()"), .symbolChanged("App.missing*")]),
                      .any([.sourceChanged("Missing/**"), .symbolChanged("App.a()")])] {
        let report = compareConditions(conditionGraph(a: 2, condition: condition), conditionGraph(condition: condition))
        #expect(report.selectedTests == [conditionTest])
        #expect(report.uiConditionDecisions?.allSatisfy { $0.result.status == .unresolved } == true)
        #expect(report.diagnostics.contains { $0.code == "unresolved_mapping_condition" })
        #expect(report.uiConditionDecisions?.first?.result.children.count == 2)
    }
}

@Test func uiConditionIncompleteCompilerEvidenceAndHeadOnlyStayConservative() {
    let base = conditionGraph()
    var head = base
    head.dependencies = nil
    let missing = compareConditions(head, base)
    #expect(missing.selectedTests == [conditionTest])
    #expect(missing.uiConditionDecisions?.allSatisfy { $0.result.status == .unresolved } == true)
    head = base; head.dependencies!.diagnostics = ["Incomplete SIL"]
    #expect(compareConditions(head, base).uiConditionDecisions?.first?.result.status == .unresolved)
    let headOnly = XcodeHeadOnlySelector.select(current: base, source: .init(base: base.sources, mappings: base.mappings), changes: [], baseRevision: "base")
    #expect(headOnly.selectedTests == [conditionTest])
    #expect(headOnly.uiConditionDecisions?.allSatisfy { $0.result.status == .unresolved } == true)
    #expect(headOnly.diagnostics.contains { $0.code == "head_only_unsupported_condition" })
}

@Test func uiConditionFalseDoesNotVetoMandatoryOrIndependentSelections() {
    var base = conditionGraph(), head = conditionGraph(a: 2)
    for index in [0, 1] {
        if index == 0 { base.mappings!.features.append(.init(name: "independent", symbols: ["App.a()"], tests: ["UI/Suite"])) }
        else { head.mappings!.features.append(.init(name: "independent", symbols: ["App.a()"], tests: ["UI/Suite"])) }
    }
    let independent = compareConditions(head, base)
    #expect(independent.selectedTests == [conditionTest])
    #expect(independent.explanations.contains { $0.kind == "explicitMapping" })
    base = conditionGraph(); head = base
    let text = "import XCTest\nclass Suite: XCTestCase {\n func testFlow() { print(2) }\n}"
    head.sources["Tests/UI.swift"] = SwiftSourceSnapshot.parse(text, path: "Tests/UI.swift", module: "UI")
    #expect(compareConditions(head, base).selectedTests == [conditionTest])
}

@Test func uiConditionsRoundTripSavedGraphsAndReports() throws {
    let base = conditionGraph(), head = conditionGraph(a: 2, b: 2)
    let saved = try JSONDecoder().decode(XcodeTestGraph.self, from: JSONEncoder().encode(head))
    let report = compareConditions(saved, base)
    let cached = try GraphArchive.decode(GraphArchive.encode(head))
    #expect(compareConditions(cached, base).uiConditionDecisions?.first?.result.status == .matched)
    #expect(report.selectedTests == compareConditions(head, base).selectedTests)
    let restored = try JSONDecoder().decode(ImpactReport.self, from: JSONEncoder().encode(report))
    #expect(restored.uiConditionDecisions?.first?.result.status == .matched)
    #expect(restored.uiConditionDecisions?.first?.result.children.count == 2)
}

@Test func uiConditionSchemaRejectsMalformedAndAmbiguousRules() throws {
    for json in [#"{}"#, #"{"all":[]}"#, #"{"any":[]}"#, #"{"not":{"symbolChanged":"App.a()"}}"#,
                 #"{"all":[],"any":[]}"#, #"{"symbolChanged":""}"#, #"{"sourceChanged":"../App.swift"}"#,
                 #"{"sourceChanged":false}"#, #"{"any":[{"all":[] }]}"#] {
        #expect(throws: (any Error).self) { try JSONDecoder().decode(UIFeatureMappings.Condition.self, from: Data(json.utf8)) }
    }
    var mappings = conditionGraph().mappings!
    try mappings.validate()
    mappings.version = 1
    #expect(throws: ImpactError.self) { try mappings.validate() }
    mappings.version = 2
    mappings.features[0].symbols = ["App.a()"]
    #expect(throws: ImpactError.self) { try mappings.validate() }
    mappings.features[0].symbols = []; mappings.features[0].sources = ["App/**"]
    #expect(throws: ImpactError.self) { try mappings.validate() }
    mappings.features[0].sources = []; mappings.features.append(.init(name: "other", dependsOn: ["combined"]))
    #expect(throws: ImpactError.self) { try mappings.validate() }
}

@Test func uiConditionAdditionsDeletionsAndSignatureChanges() {
    let condition = UIFeatureMappings.Condition.symbolChanged("App.b*")
    let original = conditionGraph(condition: condition)
    var removed = original
    removed.sources["App/Nested/B.swift"] = SwiftSourceSnapshot.parse("", path: "App/Nested/B.swift", module: "App")
    removed.dependencies!.functions.removeValue(forKey: "App.b()")
    for (head, base) in [(removed, original), (original, removed)] {
        let report = compareConditions(head, base)
        #expect(report.selectedTests == [conditionTest])
        #expect(report.uiConditionDecisions?.allSatisfy { $0.result.status == .matched } == true)
    }
    var changed = original
    let source = SwiftSourceSnapshot.parse("func b(_ value: Int) -> Int { value }", path: "App/Nested/B.swift", module: "App")
    changed.sources["App/Nested/B.swift"] = source
    changed.dependencies!.functions.removeValue(forKey: "App.b()")
    changed.dependencies!.functions["App.b(_:)"] = .init(id: "App.b(_:)", module: "App", name: "b(_:)", regions: [source.units[0].region])
    #expect(compareConditions(changed, original).uiConditionDecisions?.allSatisfy { $0.result.status == .matched } == true)
}

@Test func uiConditionSourceLocationValuesAndCompiledBindingsRemainSemantic() {
    let condition = UIFeatureMappings.Condition.symbolChanged("App.a()")
    var base = conditionGraph(condition: condition), head = base
    head.dependencies!.functions["App.a()"]!.dependencies.insert("App.b()")
    #expect(compareConditions(head, base).uiConditionDecisions?.first?.result.status == .matched)
    func located(_ path: String) -> XcodeTestGraph {
        var graph = conditionGraph(condition: condition, path: path)
        graph.sources[path] = SwiftSourceSnapshot.parse("func a() -> String { #filePath }", path: path, module: "App")
        graph.dependencies!.functions["App.a()"]!.regions = [graph.sources[path]!.units[0].region]
        return graph
    }
    base = located("App/A.swift"); head = located("Moved/A.swift")
    #expect(compareConditions(head, base).uiConditionDecisions?.first?.result.status == .matched)
    base.mappings!.sourceLocationPolicy = .diagnostic; head.mappings!.sourceLocationPolicy = .diagnostic
    #expect(compareConditions(head, base).uiConditionDecisions?.first?.result.status == .notMatched)
}

@Test func uiConditionRejectsNullAndVersionOneOnDecodeValidation() {
    for json in [#"{"version":2,"features":[{"name":"x","when":null}]}"#,
                 #"{"version":1,"features":[{"name":"x","when":{"symbolChanged":"App.a()"}}]}"#] {
        #expect(throws: (any Error).self) {
            let value = try JSONDecoder().decode(UIFeatureMappings.self, from: Data(json.utf8))
            try value.validate()
        }
    }
}

@Test func uiConditionMissingSourceEvidenceIsUnresolvedEvenOnNoop() {
    let condition = UIFeatureMappings.Condition.sourceChanged("App/**")
    var graph = conditionGraph(condition: condition)
    graph.sources.removeValue(forKey: "App/Nested/B.swift")
    #expect(compareConditions(graph, graph).uiConditionDecisions?.first?.result.status == .unresolved)
}

@Test func uiConditionsUseActualCompiledDeclarationLocations() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ui-conditions-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    func compile(a: Int, b: Int, callee: Int) throws -> XcodeTestGraph {
        let folder = root.appendingPathComponent("\(a)-\(b)-\(callee)")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("App/Nested"), withIntermediateDirectories: true)
        var graph = conditionGraph(a: a, b: b, callee: callee)
        let files = ["App/A.swift": "func a() -> Int { common() + \(a) }",
                     "App/Nested/B.swift": "func b() -> Int { \(b) }",
                     "App/Common.swift": "func common() -> Int { \(callee) }"]
        for (path, source) in files {
            try source.write(to: folder.appendingPathComponent(path), atomically: true, encoding: .utf8)
        }
        let output = folder.appendingPathComponent("App.sil")
        _ = try CommandRunner.run("swiftc", ["-module-name", "App", "-g", "-Onone", "-emit-sil", "-whole-module-optimization"] + files.keys.sorted().map { folder.appendingPathComponent($0).path } + ["-o", output.path], at: folder)
        let parsed = try SILParser.parse(file: output, module: "App", sourceRoot: folder)
        graph.dependencies!.functions = parsed.functions
        graph.dependencies!.functions["UI.Suite.testFlow()"] = .init(id: "UI.Suite.testFlow()", module: "UI", name: "Suite.testFlow()",
            regions: [graph.sources["Tests/UI.swift"]!.units.first { $0.kind == "function" }!.region])
        return try GraphArchive.decode(GraphArchive.encode(graph))
    }
    let base = try compile(a: 1, b: 1, callee: 1)
    for (a, b, common, expected) in [(2, 1, 1, false), (2, 2, 1, true), (1, 1, 2, false)] {
        let report = compareConditions(try compile(a: a, b: b, callee: common), base)
        #expect(report.selectedTests == (expected ? [conditionTest] : []))
        #expect(report.diagnostics.isEmpty)
        #expect(report.uiConditionDecisions?.allSatisfy { $0.result.status == (expected ? .matched : .notMatched) } == true)
    }
}

@Test func uiConditionsStrictValidationChecksAllLeavesAndAllowsHeadRepairs() throws {
    func validate(_ graph: XcodeTestGraph) throws {
        try graph.validateMappingSymbols(mappingFile: "ui.json", revision: "head", buildContext: ["scheme": "App"])
    }
    for condition in [UIFeatureMappings.Condition.any([.symbolChanged("App.a()"), .symbolChanged("App.missing*")]),
                      .all([.sourceChanged("App/**"), .symbolChanged("App.missing*")])] {
        let head = conditionGraph(condition: condition)
        for graph in [head, try GraphArchive.decode(GraphArchive.encode(head))] {
            do {
                try validate(graph)
                Issue.record("Missing leaf must fail even when another operand resolves")
            } catch let error as MappingValidationError {
                #expect(error.diagnostics.map(\.pattern) == ["App.missing*"])
                #expect(error.diagnostics.first?.feature == "combined")
                #expect(error.diagnostics.first?.revision == "head")
            }
        }
        let fixed = conditionGraph(condition: .symbolChanged("App.a*"))
        try validate(fixed)
        #expect(compareConditions(fixed, head).uiConditionDecisions?.first?.result.status == .unresolved)
    }
    var missing = conditionGraph()
    missing.dependencies = nil
    do {
        try validate(missing)
        Issue.record("Missing compiler graph cannot bypass condition validation")
    } catch let error as MappingValidationError {
        #expect(error.diagnostics.count == 2)
        #expect(error.diagnostics.allSatisfy { $0.code == "mapping_symbol_graph_unavailable" })
    }
    let renamed = conditionGraph(condition: .symbolChanged("App.a()"), renamed: true)
    #expect(throws: MappingValidationError.self) { try validate(renamed) }
    try validate(conditionGraph(condition: .symbolChanged("App.renamed()"), renamed: true))
}

@Test func uiConditionSourceCoverageFollowsEditedDeclarationAcrossMove() {
    let condition = UIFeatureMappings.Condition.all([.sourceChanged("App/A.swift"), .symbolChanged("App.b()")])
    let base = conditionGraph(condition: condition)
    let head = conditionGraph(a: 2, condition: condition, path: "Moved/A.swift")
    let report = compareConditions(head, base)
    #expect(report.selectedTests.isEmpty)
    #expect(report.diagnostics.isEmpty)
    #expect(report.uiConditionDecisions?.allSatisfy { $0.result.status == .notMatched } == true)
    #expect(report.uiConditionDecisions?.first?.result.children[0].status == .matched)
}

@Test func uiConditionArchivesRequireANewGraphSchemaForOlderClients() throws {
    let graph = conditionGraph()
    #expect(graph.schemaVersion == 3)
    #expect(try GraphArchive.decode(GraphArchive.encode(graph)).schemaVersion == 3)
    #expect(try JSONDecoder().decode(XcodeTestGraph.self, from: JSONEncoder().encode(graph)).schemaVersion == 3)
    var legacy = XcodeTestGraph(targets: [], tests: [])
    legacy.mappings = .init(features: [.init(name: "legacy", symbols: ["App.a()"], tests: ["UI/Suite"])])
    #expect(legacy.schemaVersion == 2)
}

@Test func uiConditionCacheSupportsSchemaThreeAndPreservesComparison() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("condition-cache-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let cache = try XcodeGraphCache(.init(directory: root, context: "conditions"), progress: { _ in })
    let head = conditionGraph(a: 2, b: 2)
    try cache.store(head, identity: ["revision": "head"])
    let loaded = try #require(try cache.load(["revision": "head"]))
    #expect(loaded.schemaVersion == 3)
    #expect(compareConditions(loaded).selectedTests == [conditionTest])
    #expect(compareConditions(loaded).uiConditionDecisions?.first?.result.status == .matched)
    // A downgraded archive must not be accepted as compatible with old clients.
    var downgraded = head
    downgraded.schemaVersion = 2
    try cache.store(downgraded, identity: ["revision": "invalid"])
    #expect(try cache.load(["revision": "invalid"]) == nil)
}

@Test(arguments: [false, true])
func uiConditionMissingHeadGraphPreservesFullFallback(conditionOnlyAtBase: Bool) {
    var base = conditionGraph()
    let test = "Unit/Suite/testUnit()"
    base.tests.append(test)
    base.targets.append(.init(name: "Unit", productType: "com.apple.product-type.bundle.unit-test", sourceFiles: ["Tests/Unit.swift"]))
    base.modules["Unit"] = "Unit"
    let source = SwiftSourceSnapshot.parse("import XCTest\nclass Suite: XCTestCase {\nfunc testUnit() {}\n}", path: "Tests/Unit.swift", module: "Unit")
    base.sources["Unit:Tests/Unit.swift"] = source
    base.dependencies!.functions[test] = .init(id: test, module: "Unit", name: "Suite.testUnit()", regions: [source.units.first { $0.kind == "function" }!.region])
    base.dependencies!.tests[test] = [test]
    var head = base
    head.sources["App:App/State.swift"] = SwiftSourceSnapshot.parse("let state = 42", path: "App/State.swift", module: "App")
    head.targets[0].sourceFiles.insert("App/State.swift")
    head.dependencies = nil
    if conditionOnlyAtBase { head.mappings!.features = [] }
    let report = XcodeSelector.select(current: head, previous: base, changes: [.init(path: "App/State.swift")], baseRevision: "base")
    #expect(Set(report.selectedTests) == Set(head.tests))
    #expect(report.diagnostics.contains { $0.code == "head_unavailable" && Set($0.tests) == Set(head.tests) })
    #expect(report.fullRunReasons.contains("Head compiler graph is unavailable."))
    #expect(report.uiConditionDecisions?.allSatisfy { $0.result.status == .unresolved } == true)
}

@Test(arguments: [UIConditionResult.Status.notMatched, .matched, .unresolved])
func uiConditionRemovedSuiteDoesNotBroadenSurvivingTests(status: UIConditionResult.Status) {
    let condition: UIFeatureMappings.Condition
    switch status {
    case .notMatched: condition = aAndB
    case .matched: condition = .symbolChanged("UI.Suite.testFlow()")
    case .unresolved: condition = .symbolChanged("App.missing()")
    }
    var base = conditionGraph(condition: condition)
    let other = "UI/Other/testOther()"
    base.tests.append(other)
    base.dependencies!.tests[other] = [other]
    base.dependencies!.functions[other] = .init(id: other, module: "UI", name: "Other.testOther()")
    var head = base
    head.tests = [other]
    head.mappings!.features = []
    head.sources["Tests/UI.swift"] = SwiftSourceSnapshot.parse("import XCTest\nclass Suite: XCTestCase {\n}\n", path: "Tests/UI.swift", module: "UI")
    head.dependencies!.tests.removeValue(forKey: conditionTest)
    head.dependencies!.functions.removeValue(forKey: "UI.Suite.testFlow()")
    let report = XcodeSelector.select(current: head, previous: base, changes: [.init(path: "Tests/UI.swift")], baseRevision: "base")
    #expect(report.selectedTests.isEmpty)
    #expect(report.uiConditionDecisions?.first?.result.status == status)
    #expect(!report.diagnostics.contains { $0.code == "unresolved_mapping_selector" || $0.code == "unresolved_feature_tests" })

    // A genuinely stale head selector must still broaden selection.
    head.mappings = base.mappings
    let stale = XcodeSelector.select(current: head, previous: base, changes: [.init(path: "Tests/UI.swift")], baseRevision: "base")
    #expect(stale.selectedTests == [other])
    #expect(stale.diagnostics.contains { $0.code == "unresolved_mapping_selector" && $0.message.hasPrefix("head:") })
}

private func capturedConditionGraph(_ graph: XcodeTestGraph) -> XcodeTestGraph {
    var result = graph
    result.sources = Dictionary(uniqueKeysWithValues: graph.sources.map { path, source in
        let owner = graph.targets.first { $0.sourceFiles.contains(path) }!
        return (graph.modules[owner.name]! + ":" + path, source)
    })
    return result
}

@Test(arguments: ["App/A.swift", "App/*.swift", "App/**"])
func uiConditionSourcePathsResolveCapturedAndSavedSnapshotKeys(pattern: String) throws {
    let condition = UIFeatureMappings.Condition.sourceChanged(pattern)
    let base = capturedConditionGraph(conditionGraph(condition: condition))
    for value in [1, 2] {
        let fresh = capturedConditionGraph(conditionGraph(a: value, condition: condition))
        for head in [fresh, try GraphArchive.decode(GraphArchive.encode(fresh))] {
            let report = compareConditions(head, base)
            #expect(report.uiConditionDecisions?.allSatisfy { $0.result.status == (value == 1 ? .notMatched : .matched) } == true)
            #expect(report.selectedTests == (value == 1 ? [] : [conditionTest]))
            #expect(report.diagnostics.isEmpty)
        }
    }
}

@Test func uiConditionSourcePathsResolveEmptyCapturedFiles() {
    let path = "App/Empty.swift"
    var graph = capturedConditionGraph(conditionGraph(condition: .sourceChanged(path)))
    graph.targets[0].sourceFiles.insert(path)
    graph.sources["App:" + path] = SwiftSourceSnapshot.parse("// Only documentation", path: path, module: "App")
    let report = XcodeSelector.select(current: graph, previous: graph, changes: [], baseRevision: "base")
    #expect(report.uiConditionDecisions?.allSatisfy { $0.result.status == .notMatched } == true)
    #expect(report.selectedTests.isEmpty)
    #expect(report.diagnostics.isEmpty)
}

@Test func uiConditionSharedSourceNeedsEvidenceFromEveryOwningModule() {
    let path = "App/A.swift"
    var graph = capturedConditionGraph(conditionGraph(condition: .sourceChanged(path)))
    graph.targets.append(.init(name: "Other", productType: "com.apple.product-type.framework", sourceFiles: [path]))
    graph.modules["Other"] = "Other"
    graph.sources["Other:" + path] = SwiftSourceSnapshot.parse("func a() -> Int { 1 }", path: path, module: "Other")
    let complete = XcodeSelector.select(current: graph, previous: graph, changes: [], baseRevision: "base")
    #expect(complete.uiConditionDecisions?.allSatisfy { $0.result.status == .notMatched } == true)
    graph.sources.removeValue(forKey: "Other:" + path)
    let incomplete = XcodeSelector.select(current: graph, previous: graph, changes: [], baseRevision: "base")
    #expect(incomplete.uiConditionDecisions?.allSatisfy { $0.result.status == .unresolved } == true)
    #expect(incomplete.selectedTests == [conditionTest])
}
