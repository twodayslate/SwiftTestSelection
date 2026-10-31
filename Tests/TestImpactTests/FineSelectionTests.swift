// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation
import Testing
@testable import TestImpact

private let uiSource = """
import XCTest
class Sharing: XCTestCase {
    func testOne() { helper() }
    func testTwo() { helper() }
    func testThree() { helper() }
    func testIndependent() { XCTAssertEqual(1, 1) }
    func helper() { XCTAssertEqual(2, 2) }
    override func setUpWithError() throws { XCTAssertEqual(3, 3) }
}
class Notes: XCTestCase {
    func testNotes() { XCTAssertEqual(4, 4) }
}
"""
private let appSource = """
func sharing() -> Int { common() }
func notes() -> Int { common() }
func common() -> Int { 42 }
"""

private func model(ui: String = uiSource, app: String = appSource, uiPath: String = "Tests/UI.swift") -> XcodeTestGraph {
    let uiSnapshot = SwiftSourceSnapshot.parse(ui, path: uiPath, module: "UI")
    let appSnapshot = SwiftSourceSnapshot.parse(app, path: "App/Features.swift", module: "App")
    var graph = DependencyGraph()
    for (module, snapshot, source) in [("UI", uiSnapshot, ui), ("App", appSnapshot, app)] {
        let lines = source.components(separatedBy: .newlines)
        for unit in snapshot.units where unit.kind == "function" {
            let line = lines[unit.region.startLine - 1]
            let function = Pattern.groups(#"func ([A-Za-z]+)\("#, in: line)![0]
            let name = (unit.scope.isEmpty ? "" : unit.scope + ".") + function + "()"
            let id = module + "." + name
            var dependencies = Set<String>()
            if function.hasPrefix("test"), line.range(of: #"helper\(\s*\)"#, options: .regularExpression) != nil { dependencies.insert("UI.Sharing.helper()") }
            if module == "App", function != "common" { dependencies.insert("App.common()") }
            graph.functions[id] = FunctionNode(id: id, module: module, name: name, regions: [unit.region], dependencies: dependencies)
            if function.hasPrefix("test") { graph.tests["UI/" + unit.scope + "/" + function + "()"] = [id] }
        }
    }
    var snapshot = XcodeTestGraph(targets: [
        XcodeTarget(name: "UI", productType: "com.apple.product-type.bundle.ui-testing", sourceFiles: [uiPath]),
        XcodeTarget(name: "App", productType: "com.apple.product-type.application", sourceFiles: ["App/Features.swift"])
    ], tests: graph.tests.keys.sorted())
    snapshot.sources = [uiPath: uiSnapshot, "App/Features.swift": appSnapshot]
    snapshot.modules = ["UI": "UI", "App": "App"]
    XcodeCompilerGraph.bind(tests: snapshot.tests, modules: snapshot.modules, sources: snapshot.sources, graph: &graph)
    snapshot.dependencies = graph
    snapshot.mappings = UIFeatureMappings(fixtures: ["sharing": ["UI/Sharing"]], features: [
        .init(name: "sharing", symbols: ["App.sharing()"], fixtures: ["sharing"]),
        .init(name: "notes", symbols: ["App.notes()"], tests: ["UI/Notes/testNotes()"])
    ])
    return snapshot
}

private func selection(_ current: XcodeTestGraph, _ previous: XcodeTestGraph = model(), paths: [String] = ["Tests/UI.swift"]) -> ImpactReport {
    XcodeSelector.select(current: current, previous: previous, changes: paths.map { FileChange(path: $0) }, baseRevision: "base")
}

@Test func editedMethodSelectsOnlyThatMethodAmong393Tests() {
    var old = model(), current = model(ui: uiSource.replacingOccurrences(of: "XCTAssertEqual(1, 1)", with: "XCTAssertEqual(1, 2)"))
    for index in 0..<388 {
        let test = "UI/Unrelated/test\(index)()"
        old.tests.append(test); current.tests.append(test)
        let node = FunctionNode(id: test, module: "UI", name: test)
        old.dependencies!.functions[test] = node; current.dependencies!.functions[test] = node
        old.dependencies!.tests[test] = [test]; current.dependencies!.tests[test] = [test]
    }
    let report = selection(current, old)
    #expect(report.totalTests == 393)
    #expect(report.selectedTests == ["UI/Sharing/testIndependent()"])
    #expect(report.diagnostics.isEmpty)
    #expect(report.onlyTestingArguments == ["-only-testing:UI/Sharing/testIndependent()"])
}

@Test func sharedHelperSelectsThreeCallersWithinOneTarget() {
    let report = selection(model(ui: uiSource.replacingOccurrences(of: "XCTAssertEqual(2, 2)", with: "XCTAssertEqual(2, 3)")))
    #expect(report.selectedTests == ["UI/Sharing/testOne()", "UI/Sharing/testThree()", "UI/Sharing/testTwo()"])
    #expect(report.explanations.allSatisfy { $0.kind == "dependency" })
}

@Test func setupSelectsItsClassWithoutSelectingOtherClasses() {
    let report = selection(model(ui: uiSource.replacingOccurrences(of: "XCTAssertEqual(3, 3)", with: "XCTAssertEqual(3, 4)")))
    #expect(report.selectedTests.count == 4)
    #expect(report.selectedTests.allSatisfy { $0.hasPrefix("UI/Sharing/") })
}

@Test func semanticComparisonIgnoresTriviaAndMovesButPreservesLiteralChanges() {
    let formatted = uiSource.replacingOccurrences(of: "helper() }", with: "helper( ) /* comment */ }")
    let report = selection(model(ui: "// new header\n" + formatted))
    #expect(report.selectedTests.isEmpty)
    #expect(report.ignoredChanges == ["Tests/UI.swift"])
    #expect(selection(model(uiPath: "Moved/UI.swift"), paths: ["Moved/UI.swift", "Tests/UI.swift"]).selectedTests.isEmpty)
    let old = SwiftSourceSnapshot.parse("func value() { print(\"a b\") }", path: "A.swift", module: "A")
    let new = SwiftSourceSnapshot.parse("func value() { print(\"ab\") }", path: "A.swift", module: "A")
    #expect(old.units[0].fingerprint != new.units[0].fingerprint)
}

@Test func newTestsIncludedAndDeletedTestsExcluded() {
    let added = uiSource.replacingOccurrences(of: "func testIndependent()", with: "func testNew() { XCTAssertTrue(true) }\n    func testIndependent()")
    #expect(selection(model(ui: added)).selectedTests == ["UI/Sharing/testNew()"])
    let deleted = uiSource.replacingOccurrences(of: "    func testIndependent() { XCTAssertEqual(1, 1) }\n", with: "")
    #expect(!selection(model(ui: deleted)).selectedTests.contains("UI/Sharing/testIndependent()"))
}

@Test func productionDependencyPropagatesToBothMappedFeatures() {
    let report = selection(model(app: appSource.replacingOccurrences(of: "42", with: "43")), paths: ["App/Features.swift"])
    #expect(report.selectedTests == model().tests)
    #expect(report.diagnostics.isEmpty)
    #expect(Set(report.explanations.map(\.kind)) == ["explicitMapping"])
    let sharing = selection(model(app: appSource.replacingOccurrences(of: "sharing() -> Int { common() }", with: "sharing() -> Int { common() + 1 }")), paths: ["App/Features.swift"])
    #expect(sharing.selectedTests.count == 4)
    #expect(!sharing.selectedTests.contains("UI/Notes/testNotes()"))
}

@Test func missingMappingsAndOpaqueDependenciesAreExplicitFallbacks() {
    var current = model(app: appSource.replacingOccurrences(of: "42", with: "43"))
    current.mappings = nil
    let report = selection(current, paths: ["App/Features.swift"])
    #expect(report.selectedTests == current.tests)
    #expect(report.diagnostics.contains { $0.code == "missing_ui_mappings" })
    #expect(report.explanations.contains { $0.kind == "fallback" })
    current = model(ui: uiSource.replacingOccurrences(of: "XCTAssertEqual(2, 2)", with: "XCTAssertEqual(2, 3)"))
    current.dependencies!.functions["UI.Sharing.helper()"]!.uncertainties = ["Indirect function invocation"]
    #expect(selection(current).diagnostics.contains { $0.code == "unresolved_dependency" })
}

@Test func mappingValidationAndExplicitFeatureDependencies() throws {
    let invalid = UIFeatureMappings(features: [.init(name: "sharing", fixtures: ["missing"])])
    #expect(throws: ImpactError.self) { try invalid.validate() }
    var old = model(), current = model(app: appSource.replacingOccurrences(of: "sharing() -> Int { common() }", with: "sharing() -> Int { common() + 1 }"))
    let mappings = UIFeatureMappings(features: [
        .init(name: "sharing", symbols: ["App.sharing()"], tests: ["UI/Sharing"]),
        .init(name: "notes", symbols: ["App.notes()"], tests: ["UI/Notes"], dependsOn: ["sharing"])
    ])
    old.mappings = mappings; current.mappings = mappings
    #expect(selection(current, old, paths: ["App/Features.swift"]).selectedTests == current.tests)
}

@Test func conditionalCompilationChangesAreNotTreatedAsTrivia() {
    let before = SwiftSourceSnapshot.parse("#if FIRST\nfunc x() {}\n#endif", path: "A.swift", module: "A")
    let after = SwiftSourceSnapshot.parse("#if SECOND\nfunc x() {}\n#endif", path: "A.swift", module: "A")
    #expect(before.units.map(\.fingerprint) != after.units.map(\.fingerprint))
}

@Test func compiledResolutionChangesMatterEvenWithUnchangedSource() {
    var current = model()
    current.dependencies!.functions["UI.Sharing.testIndependent()"]!.dependencies.insert("UI.Sharing.helper()")
    let report = selection(current)
    #expect(report.selectedTests == ["UI/Sharing/testIndependent()"])
}

@Test func resourceMovesAreNotAssumedBehaviorPreserving() {
    let graph = model()
    var change = FileChange(path: "Resources/renamed.json")
    change.isPureMove = true
    change.previousPath = "Resources/original.json"
    let report = XcodeSelector.select(current: graph, previous: graph, changes: [change], baseRevision: "base")
    #expect(report.selectedTests == graph.tests)
    #expect(report.diagnostics.contains { $0.code == "unclassified_change" })
}

@Test func emptyKnownSuitesDoNotHideTopLevelSwiftTestingMethods() throws {
    let data = Data(#"{"errors":[],"values":[{"enabledTests":[{"identifier":"UI/Base"},{"identifier":"UnitTests/example()"},{"identifier":"UI/Suite/testA()"}]}]}"#.utf8)
    #expect(try XcodeTestEnumeration.parse(data, emptySuiteIdentifiers: ["UI/Base"]) == ["UI/Suite/testA()", "UnitTests/example()"])
    #expect(throws: ImpactError.self) { try XcodeTestEnumeration.parse(data) }
}

@Test func inheritedLifecycleRootsResolveAcrossKnownModulesAndDiagnoseUnknownParents() {
    let child = "class Child: Support.BaseCase { func testOne() {} }"
    let base = "class BaseCase: XCTestCase { func setUpWithError() throws {} }"
    let test = "UI/Child/testOne()"
    let sources = [
        "child": SwiftSourceSnapshot.parse(child, path: "Child.swift", module: "UI"),
        "base": SwiftSourceSnapshot.parse(base, path: "Base.swift", module: "Support")
    ]
    var graph = DependencyGraph(functions: [
        "entry": FunctionNode(id: "entry", module: "UI", name: "Child.testOne()", regions: [SourceRegion(path: "Child.swift", startLine: 1, endLine: 1)]),
        "hook": FunctionNode(id: "hook", module: "Support", name: "BaseCase.setUpWithError()", regions: [SourceRegion(path: "Base.swift", startLine: 1, endLine: 1)])
    ])
    XcodeCompilerGraph.bind(tests: [test], modules: ["UI": "UI"], sources: sources, graph: &graph)
    #expect(graph.tests[test] == ["entry", "hook"])
    #expect(graph.testDiagnostics[test] == nil)
    graph.testDiagnostics = [:]
    XcodeCompilerGraph.bind(tests: [test], modules: ["UI": "UI"], sources: ["child": sources["child"]!], graph: &graph)
    #expect(graph.testDiagnostics[test]?.isEmpty == false)
}

@Test func sourceLocationMacrosRemainSensitiveButCommentsAndStringsDoNot() {
    let source = "func x() { print(#line) }"
    let old = SwiftSourceSnapshot.parse(source, path: "A.swift", module: "A")
    let new = SwiftSourceSnapshot.parse("\n" + source, path: "A.swift", module: "A")
    #expect(old.units.first?.fingerprint != new.units.first?.fingerprint)
    let text = "func x() { print(\"#line\") } // #line"
    #expect(SwiftSourceSnapshot.parse(text, path: "A.swift", module: "A").units.first?.fingerprint == SwiftSourceSnapshot.parse("\n" + text, path: "A.swift", module: "A").units.first?.fingerprint)
}

@Test func topLevelCodeAndConditionalSuperclassDeclarationsArePreserved() {
    let source = "#if FIRST\nclass Child: BaseOne {}\n#else\nclass Child: BaseTwo {}\n#endif\nprint(1)"
    let parsed = SwiftSourceSnapshot.parse(source, path: "main.swift", module: "App")
    #expect(Set(parsed.inheritance["App.Child"] ?? []) == ["BaseOne", "BaseTwo"])
    #expect(parsed.units.contains { $0.kind == "topLevel" })
    let modified = SwiftSourceSnapshot.parse(source.replacingOccurrences(of: "print(1)", with: "print(2)"), path: "main.swift", module: "App")
    #expect(parsed.units.map(\.fingerprint) != modified.units.map(\.fingerprint))
}

// Model runtime uncertainties normally present in real XCTest/SDK code, including
// all tests' lifecycle roots. These must not broaden a proven test-entry edit.
private func withOpaqueDependencies(_ input: XcodeTestGraph) -> XcodeTestGraph {
    var result = input
    result.dependencies!.functions["opaque"] = FunctionNode(
        id: "opaque", module: "UI", name: "runtime()",
        regions: [SourceRegion(path: "Tests/Runtime.swift", startLine: 1, endLine: 1)],
        uncertainties: ["Indirect function invocation", "Raw pointer operation", "Global state access", "Unresolved project dispatch: XCTestCase.init"])
    for test in result.tests { result.dependencies!.tests[test]!.insert("opaque") }
    result.mappings = nil
    return result
}

@Test func testEntryEditDoesNotReachUnrelatedRuntimeUncertaintyOrMissingMappings() {
    let old = withOpaqueDependencies(model())
    let current = withOpaqueDependencies(model(ui: uiSource.replacingOccurrences(of: "XCTAssertEqual(1, 1)", with: "XCTAssertEqual(1, 2)")))
    let report = selection(current, old)
    #expect(report.selectedTests == ["UI/Sharing/testIndependent()"])
    #expect(report.explanations.allSatisfy { $0.kind == "dependency" })
    #expect(report.diagnostics.isEmpty)
    #expect(report.uiMappingCoverage?.unmappedTests.count == 5)
}

@Test func explicitCallersOfEditedTestEntriesRemainSelected() {
    var old = withOpaqueDependencies(model())
    var current = withOpaqueDependencies(model(ui: uiSource.replacingOccurrences(of: "XCTAssertEqual(1, 1)", with: "XCTAssertEqual(1, 2)")))
    old.dependencies!.functions["UI.Sharing.testOne()"]!.dependencies.insert("UI.Sharing.testIndependent()")
    current.dependencies!.functions["UI.Sharing.testOne()"]!.dependencies.insert("UI.Sharing.testIndependent()")
    #expect(selection(current, old).selectedTests == ["UI/Sharing/testIndependent()", "UI/Sharing/testOne()"])
}

@Test func entryAdditionsAndDeletionsDoNotSelectOpaqueNeighbors() {
    let old = withOpaqueDependencies(model())
    let added = uiSource.replacingOccurrences(of: "func testIndependent()", with: "func testNew() { XCTAssertTrue(true) }\n    func testIndependent()")
    #expect(selection(withOpaqueDependencies(model(ui: added)), old).selectedTests == ["UI/Sharing/testNew()"])
    let deleted = uiSource.replacingOccurrences(of: "    func testIndependent() { XCTAssertEqual(1, 1) }\n", with: "")
    #expect(selection(withOpaqueDependencies(model(ui: deleted)), old).selectedTests.isEmpty)
}

@Test func mixedHelperLifecycleAndProductionEditsKeepRuntimeFallbacks() {
    let old = withOpaqueDependencies(model())
    for (needle, replacement, production) in [
        ("XCTAssertEqual(2, 2)", "XCTAssertEqual(2, 3)", false),
        ("XCTAssertEqual(3, 3)", "XCTAssertEqual(3, 4)", false),
        ("42", "43", true)
    ] {
        let ui = uiSource.replacingOccurrences(of: "XCTAssertEqual(1, 1)", with: "XCTAssertEqual(1, 2)")
        let current = withOpaqueDependencies(model(
            ui: production ? ui : ui.replacingOccurrences(of: needle, with: replacement),
            app: production ? appSource.replacingOccurrences(of: needle, with: replacement) : appSource))
        let report = selection(current, old)
        #expect(report.selectedTests == current.tests)
        #expect(report.diagnostics.contains { $0.code == "unresolved_dependency" })
        if production { #expect(report.diagnostics.contains { $0.code == "missing_ui_mappings" }) }
    }
}

@Test func unresolvedChangedEntryRetainsConservativeSelection() {
    let old = withOpaqueDependencies(model())
    var current = withOpaqueDependencies(model(ui: uiSource.replacingOccurrences(of: "XCTAssertEqual(1, 1)", with: "XCTAssertEqual(1, 2)")))
    current.dependencies!.functions.removeValue(forKey: "UI.Sharing.testIndependent()")
    current.dependencies!.tests["UI/Sharing/testIndependent()"] = []
    let report = selection(current, old)
    #expect(report.selectedTests == current.tests)
    #expect(report.diagnostics.contains { $0.code == "unresolved_declaration" })
    #expect(report.diagnostics.contains { $0.code == "unresolved_test" })
}

@Test func importedSymbolAttributionAndSerializedBodiesDoNotCreateSourceChanges() {
    var old = withOpaqueDependencies(model()), current = old
    let id = "stdlib-string-literal"
    // Imported copies may carry locations in an owned file without being an
    // owned definition. Changing their serialized bodies is not a source edit.
    let region = old.dependencies!.functions["UI.Sharing.testIndependent()"]!.regions
    old.dependencies!.functions[id] = FunctionNode(id: id, module: "PackageA", name: "String.init()", regions: region, dependencies: ["implementationA"])
    current.dependencies!.functions[id] = FunctionNode(id: id, module: "PackageB", name: "String.init()", regions: region, dependencies: ["implementationB"])
    old.dependencies!.functions["UI.Sharing.testIndependent()"]!.dependencies.insert(id)
    current.dependencies!.functions["UI.Sharing.testIndependent()"]!.dependencies.insert(id)
    let report = selection(current, old)
    #expect(report.selectedTests.isEmpty)
    #expect(report.diagnostics.isEmpty)
    #expect(report.ignoredChanges == ["Tests/UI.swift"])
    // Even when import attribution is unchanged, a different serialized body
    // must not manufacture a changed declaration at its borrowed debug location.
    current.dependencies!.functions[id]!.module = "PackageA"
    #expect(selection(current, old).selectedTests.isEmpty)
    current.dependencies!.functions[id]!.module = "PackageB"
    // The real edit must still select exactly one method despite import drift.
    current.sources["Tests/UI.swift"] = SwiftSourceSnapshot.parse(uiSource.replacingOccurrences(of: "XCTAssertEqual(1, 1)", with: "XCTAssertEqual(1, 2)"), path: "Tests/UI.swift", module: "UI")
    #expect(selection(current, old).selectedTests == ["UI/Sharing/testIndependent()"])
}

@Test func overloadChangesWithIdenticalDisplayNamesRemainSemanticChanges() {
    var old = model(), current = old
    for id in ["overload-int", "overload-string"] {
        let node = FunctionNode(id: id, module: "UI", name: "overloaded(_:)")
        old.dependencies!.functions[id] = node; current.dependencies!.functions[id] = node
    }
    old.dependencies!.functions["UI.Sharing.testIndependent()"]!.dependencies.insert("overload-int")
    current.dependencies!.functions["UI.Sharing.testIndependent()"]!.dependencies.insert("overload-string")
    #expect(selection(current, old).selectedTests == ["UI/Sharing/testIndependent()"])
}

@Test func movedPrivateSymbolIDsDoNotChangeCallers() {
    var old = model(), current = model(uiPath: "Moved/UI.swift")
    for (isOld, id) in [(true, "private-old"), (false, "private-new")] {
        var snapshot = isOld ? old : current
        var helper = snapshot.dependencies!.functions.removeValue(forKey: "UI.Sharing.helper()")!
        helper.id = id
        snapshot.dependencies!.functions[id] = helper
        for symbol in snapshot.dependencies!.functions.keys {
            if snapshot.dependencies!.functions[symbol]!.dependencies.remove("UI.Sharing.helper()") != nil {
                snapshot.dependencies!.functions[symbol]!.dependencies.insert(id)
            }
        }
        if isOld { old = snapshot } else { current = snapshot }
    }
    #expect(selection(current, old, paths: ["Moved/UI.swift", "Tests/UI.swift"]).selectedTests.isEmpty)
}

@Test func testEntryEditStillReportsUnboundTestsAndUnknownInheritance() {
    let old = withOpaqueDependencies(model())
    var current = withOpaqueDependencies(model(ui: uiSource.replacingOccurrences(of: "XCTAssertEqual(1, 1)", with: "XCTAssertEqual(1, 2)")))
    current.dependencies!.tests["UI/Notes/testNotes()"] = []
    current.dependencies!.testDiagnostics["UI/Sharing/testOne()"] = ["Unknown superclass"]
    let report = selection(current, old)
    #expect(report.selectedTests == ["UI/Notes/testNotes()", "UI/Sharing/testIndependent()", "UI/Sharing/testOne()"])
    #expect(Set(report.diagnostics.map(\.code)) == ["unresolved_test", "unresolved_inheritance"])
}

@Test func inheritedEntryEditsSelectEveryDiscoveredSubclass() {
    var old = withOpaqueDependencies(model())
    var current = withOpaqueDependencies(model(ui: uiSource.replacingOccurrences(of: "XCTAssertEqual(1, 1)", with: "XCTAssertEqual(1, 2)")))
    let inherited = "UI/Child/testIndependent()"
    for isOld in [true, false] {
        var snapshot = isOld ? old : current
        snapshot.tests.append(inherited)
        snapshot.dependencies!.tests[inherited] = snapshot.dependencies!.tests["UI/Sharing/testIndependent()"]
        if isOld { old = snapshot } else { current = snapshot }
    }
    #expect(selection(current, old).selectedTests == [inherited, "UI/Sharing/testIndependent()"])
}

@Test func overlappingDebugLocationsCannotProveAnEntryOnlyEdit() {
    let source = uiSource.replacingOccurrences(of: " }\n    func helper()", with: " }; func helper()")
    let old = withOpaqueDependencies(model(ui: source))
    let current = withOpaqueDependencies(model(ui: source.replacingOccurrences(of: "XCTAssertEqual(1, 1)", with: "XCTAssertEqual(1, 2)")))
    #expect(current.sources.values.allSatisfy { $0.diagnostics.isEmpty })
    let report = selection(current, old)
    #expect(report.selectedTests == current.tests)
    #expect(report.diagnostics.contains { $0.code == "unresolved_dependency" })
}

// Model app startup and the UI runner's unrelated opaque SDK dependencies.
private func declaredRuntimeModel(app: String = appSource, ui: String = uiSource) -> XcodeTestGraph {
    var result = model(ui: ui, app: app + "\nfunc launch() {}")
    var mappings = result.mappings!
    mappings.runtimeDependencyPolicy = .declared
    mappings.features.append(.init(name: "launch", symbols: ["App.launch()"], tests: ["UI"]))
    result = withOpaqueDependencies(result)
    result.mappings = mappings
    result.dependencies!.functions["App.launch()"]!.uncertainties = ["Global state access"]
    // Unit-test runtime uncertainty is intentionally unaffected by the UI policy.
    result.targets.append(.init(name: "Unit", productType: "com.apple.product-type.bundle.unit-test", sourceFiles: []))
    result.tests.append("Unit/Value/testValue()")
    result.dependencies!.tests["Unit/Value/testValue()"] = ["opaque"]
    return result
}

@Test func declaredRuntimePolicyDoesNotSelectUnrelatedLaunchOrUIRunnerUncertainty() {
    let old = declaredRuntimeModel()
    let current = declaredRuntimeModel(app: appSource.replacingOccurrences(of: "sharing() -> Int { common() }", with: "sharing() -> Int { common() + 1 }"))
    let report = selection(current, old, paths: ["App/Features.swift"])
    #expect(report.selectedTests == old.tests.filter { !$0.hasPrefix("UI/Notes/") }.sorted())
    #expect(!report.diagnostics.contains { $0.code == "unresolved_feature_dependency" })
    #expect(report.diagnostics.contains { $0.code == "unresolved_dependency" && $0.tests == ["Unit/Value/testValue()"] })
    #expect(report.limitations.contains { $0.contains("runtime dependency policy is declared") })
}

@Test(arguments: [UIFeatureMappings.RuntimeDependencyPolicy.conservative, .declared])
func importedSDKHelperWithoutLocationsPreservesUIRuntimePolicy(policy: UIFeatureMappings.RuntimeDependencyPolicy) {
    func sdkModel(_ app: String) -> XcodeTestGraph {
        var result = model(app: app)
        result.mappings!.runtimeDependencyPolicy = policy
        result.dependencies!.functions["App.notes()"]!.dependencies.insert("sdk-helper")
        result.dependencies!.functions["sdk-helper"] = .init(id: "sdk-helper", module: "SDK", name: "equal()",
            uncertainties: ["Imported conformance: Equatable@witness:NSObject module Foundation"])
        return result
    }
    let old = sdkModel(appSource)
    let current = sdkModel(appSource.replacingOccurrences(of: "sharing() -> Int { common() }", with: "sharing() -> Int { common() + 1 }"))
    let report = selection(current, old, paths: ["App/Features.swift"])
    #expect(report.selectedTests.contains("UI/Notes/testNotes()") == (policy == .conservative))
    #expect(report.diagnostics.contains { $0.code == "unresolved_feature_dependency" } == (policy == .conservative))
}

@Test func declaredRuntimePolicyPreservesSharedAndExplicitFeatureDependencies() {
    let old = declaredRuntimeModel()
    let shared = declaredRuntimeModel(app: appSource.replacingOccurrences(of: "42", with: "43"))
    #expect(selection(shared, old, paths: ["App/Features.swift"]).selectedTests == old.tests.sorted())
    var before = old
    var after = declaredRuntimeModel(app: appSource.replacingOccurrences(of: "sharing() -> Int { common() }", with: "sharing() -> Int { common() + 1 }"))
    before.mappings!.features[1].dependsOn = ["sharing"]
    after.mappings!.features[1].dependsOn = ["sharing"]
    #expect(selection(after, before, paths: ["App/Features.swift"]).selectedTests == old.tests.sorted())
}

@Test func declaredRuntimePolicyRequiresBothRevisionsAndPreservesMissingCoverageFallbacks() {
    let old = declaredRuntimeModel()
    let current = declaredRuntimeModel(app: appSource.replacingOccurrences(of: "sharing() -> Int { common() }", with: "sharing() -> Int { common() + 1 }"))
    for side in ["base", "head"] {
        var before = old, after = current
        if side == "base" { before.mappings!.runtimeDependencyPolicy = nil }
        else { after.mappings!.runtimeDependencyPolicy = nil }
        #expect(selection(after, before, paths: ["App/Features.swift"]).selectedTests == old.tests.sorted())
    }
    for code in ["missing_ui_mappings", "unmapped_production_boundary", "unresolved_mapping_boundary", "unmapped_ui_tests"] {
        var before = old, after = current
        for head in [false, true] {
            var value = head ? after : before
            switch code {
            case "missing_ui_mappings": value.mappings = nil
            case "unmapped_production_boundary": value.mappings!.features.removeFirst()
            case "unresolved_mapping_boundary": value.mappings!.features[0].symbols = ["App.missing()"]
            default:
                value.mappings!.features.removeAll { $0.name == "notes" || $0.name == "launch" }
            }
            if head { after = value } else { before = value }
        }
        let report = selection(after, before, paths: ["App/Features.swift"])
        #expect(report.selectedTests == old.tests.sorted())
        #expect(report.diagnostics.contains { $0.code == code })
    }
}

@Test func declaredRuntimePolicyKeepsHelperAndLifecycleFallbacksAndMixedEntrySelection() {
    let old = declaredRuntimeModel()
    let app = appSource.replacingOccurrences(of: "sharing() -> Int { common() }", with: "sharing() -> Int { common() + 1 }")
    for literal in ["XCTAssertEqual(2, 2)", "XCTAssertEqual(3, 3)"] {
        let current = declaredRuntimeModel(app: app, ui: uiSource.replacingOccurrences(of: literal, with: "XCTAssertEqual(7, 7)"))
        #expect(selection(current, old, paths: ["App/Features.swift", "Tests/UI.swift"]).selectedTests == old.tests.sorted())
    }
    let current = declaredRuntimeModel(app: app, ui: uiSource.replacingOccurrences(of: "XCTAssertEqual(1, 1)", with: "XCTAssertEqual(7, 7)"))
    #expect(!selection(current, old, paths: ["App/Features.swift", "Tests/UI.swift"]).selectedTests.contains("UI/Notes/testNotes()"))
}

@Test func allowedDocumentationDoesNotBroadenMixedChanges() {
    var old = model(), current = model(ui: uiSource.replacingOccurrences(of: "XCTAssertEqual(1, 1)", with: "XCTAssertEqual(1, 2)"))
    let docs = ["AGENTS.md", "README.md", "Documentation/**.md"]
    old.mappings!.ignoredDocumentation = docs; current.mappings!.ignoredDocumentation = docs
    let report = selection(current, old, paths: ["Tests/UI.swift", "AGENTS.md", "Documentation/Nested/Guide.md"])
    #expect(report.selectedTests == ["UI/Sharing/testIndependent()"])
    #expect(report.ignoredChanges == ["AGENTS.md", "Documentation/Nested/Guide.md"])
    #expect(report.diagnostics.isEmpty)
    #expect(selection(old, old, paths: ["README.md"]).selectedTests.isEmpty)
    for path in ["Other.md", "Documentation/data.json", "project.pbxproj", "Resources/image.png"] {
        #expect(selection(current, old, paths: ["Tests/UI.swift", path]).selectedTests == old.tests)
    }
    old.mappings!.ignoredDocumentation = []
    #expect(selection(current, old, paths: ["Tests/UI.swift", "AGENTS.md"]).selectedTests == old.tests)
}

@Test func documentationExclusionsCannotHideSourceRenamesOrInvalidPatterns() throws {
    var graph = model()
    graph.mappings!.ignoredDocumentation = ["README.md"]
    var move = FileChange(path: "README.md")
    move.previousPath = "Tests/UI.swift"; move.isPureMove = true
    #expect(XcodeFineSelector.select(current: graph, previous: graph, changes: [move], baseRevision: "base").selectedTests == graph.tests)
    for pattern in ["App/*.swift", "../README.md", "/README.md", "**"] {
        graph.mappings!.ignoredDocumentation = [pattern]
        #expect(throws: ImpactError.self) { try graph.mappings!.validate() }
    }
    #expect(throws: (any Error).self) {
        try JSONDecoder().decode(UIFeatureMappings.self, from: Data(#"{"version":1,"features":[],"runtimeDependencyPolicy":"typo"}"#.utf8))
    }
}

@Test func mappingPatternsKeepLiteralCharactersAndPathComponentWildcardRules() {
    #expect(UIFeatureMappings.matches("App.Type.method(_:)", pattern: "App.Type.method(_:)"))
    #expect(!UIFeatureMappings.matches("AppXTypeXmethod(_:)", pattern: "App.Type.method(_:)"))
    #expect(UIFeatureMappings.matches("Documentation/Guide.md", pattern: "Documentation/*.md"))
    #expect(!UIFeatureMappings.matches("Documentation/Nested/Guide.md", pattern: "Documentation/*.md"))
    #expect(UIFeatureMappings.matches("Documentation/Nested/Guide.md", pattern: "Documentation/**.md"))
    #expect(UIFeatureMappings.matches("App/a?.swift", pattern: "App/*?.swift"))
    #expect(!UIFeatureMappings.matches("App/ab.swift", pattern: "App/*?.swift"))
}

@Test func indexedFineSelectionMatchesReferenceAcrossAllFixtureBoundaries() throws {
    let before = model()
    for (key, source) in before.sources {
        for i in source.units.indices {
            var after = before
            after.sources[key]!.units[i].fingerprint += "edit"
            let changes = [FileChange(path: source.units[i].region.path)]
            let actual = XcodeFineSelector.select(current: after, previous: before, changes: changes, baseRevision: "base")
            let expected = ReferenceXcodeFineSelector.select(current: after, previous: before, changes: changes, baseRevision: "base")
            let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
            #expect(try encoder.encode(actual) == encoder.encode(expected))
        }
    }
}

@Test func compilerOnlyOwnershipDoesNotEnableUIRuntimeExemptions() {
    var old = declaredRuntimeModel()
    var current = declaredRuntimeModel(app: appSource.replacingOccurrences(of: "sharing() -> Int { common() }", with: "sharing() -> Int { common() + 1 }"))
    for index in old.targets.indices where old.targets[index].name == "App" {
        old.targets[index].productType = XcodeSourceOwnership.productType
        current.targets[index].productType = XcodeSourceOwnership.productType
    }
    let report = selection(current, old, paths: ["App/Features.swift"])
    #expect(Set(report.selectedTests) == Set(old.tests))
    #expect(!report.diagnostics.contains { $0.code == "unclassified_change" })
    #expect(report.diagnostics.contains { $0.code == "unresolved_dependency" || $0.code == "unresolved_feature_dependency" })
}

@Test func unsupportedCompilerInputsFallBackForModuleChangesButPreserveUnrelatedEntryEdits() throws {
    var old = model()
    old.unsupportedSourceInputs = ["App": ["<DerivedData>/Generated.swift"]]
    var current = model(app: appSource.replacingOccurrences(of: "42", with: "43"))
    current.unsupportedSourceInputs = old.unsupportedSourceInputs
    let report = selection(current, old, paths: ["App/Features.swift"])
    #expect(report.selectedTests == old.tests)
    #expect(report.diagnostics.contains { $0.code == "unsupported_source_ownership" })
    #expect(!report.diagnostics.contains { $0.code == "unclassified_change" })
    var testOnly = model(ui: uiSource.replacingOccurrences(of: "XCTAssertEqual(1, 1)", with: "XCTAssertEqual(1, 2)"))
    testOnly.unsupportedSourceInputs = old.unsupportedSourceInputs
    let precise = selection(testOnly, old)
    #expect(precise.selectedTests == ["UI/Sharing/testIndependent()"])
    #expect(precise.diagnostics.isEmpty)
    #expect(try GraphArchive.decode(GraphArchive.encode(old)).unsupportedSourceInputs == old.unsupportedSourceInputs)
}

private let locationAwareTests = uiSource.replacingOccurrences(of: "func helper()", with: "func helper(file: StaticString = #filePath, line: UInt = #line)")
private func locationModel(_ source: String, diagnostic: Bool = false) -> XcodeTestGraph {
    var snapshot = withOpaqueDependencies(model(ui: source))
    snapshot.mappings = UIFeatureMappings(features: [], ignoredDocumentation: ["*.md", "**/*.md"])
    snapshot.mappings!.sourceLocationPolicy = diagnostic ? .diagnostic : .semantic
    return snapshot
}

@Test func nestedEntryEditWithLocationDefaultsDoesNotChangeLaterClasses() throws {
    let old = locationModel(locationAwareTests)
    let edited = locationAwareTests.replacingOccurrences(of: "XCTAssertEqual(1, 1)", with: """
    func waitForImageFrame() -> Int {
        return 1
    }
    XCTAssertEqual(waitForImageFrame(), 1)
    """)
    let current = locationModel(edited)
    for archive in [false, true] {
        let head = try archive ? GraphArchive.decode(GraphArchive.encode(current)) : current
        let report = selection(head, old, paths: ["Tests/UI.swift", "AGENTS.md", "docs/guide.md"])
        #expect(report.selectedTests == ["UI/Sharing/testIndependent()"])
        #expect(report.diagnostics.isEmpty)
        #expect(report.ignoredChanges == ["AGENTS.md", "docs/guide.md"])
        #expect(!report.explanations.contains { $0.reason.contains("Changed class state") })
    }
    var caller = current
    caller.dependencies!.functions["UI.Sharing.testOne()"]!.dependencies.insert("UI.Sharing.testIndependent()")
    #expect(selection(caller, old).selectedTests == ["UI/Sharing/testIndependent()", "UI/Sharing/testOne()"])
    for (before, after) in [("XCTAssertEqual(2, 2)", "XCTAssertEqual(2, 3)"),
                            ("XCTAssertEqual(3, 3)", "XCTAssertEqual(3, 4)"),
                            ("class Notes: XCTestCase", "class Notes: OtherCase")] {
        let report = selection(locationModel(edited.replacingOccurrences(of: before, with: after)), old)
        #expect(Set(report.selectedTests) == Set(old.tests))
    }
}

@Test(arguments: ["// line comment\n", "/* block\n comment */\n", "/// Documentation\n"])
func locationAwareCommentEditsAndMarkdownContributeNoTests(comment: String) {
    let old = locationModel(locationAwareTests, diagnostic: true)
    let documented = comment + locationAwareTests.replacingOccurrences(of: "class Notes", with: comment + "class Notes")
    for paths in [["Tests/UI.swift"], ["Tests/UI.swift", "AGENTS.md", "docs/guide.md"]] {
        #expect(selection(locationModel(documented, diagnostic: true), old, paths: paths).selectedTests.isEmpty)
    }
    let code = locationAwareTests.replacingOccurrences(of: "XCTAssertEqual(1, 1)", with: "XCTAssertEqual(1, 2)")
    let mixed = comment + code.replacingOccurrences(of: "class Notes", with: comment + "class Notes")
    #expect(selection(locationModel(mixed, diagnostic: true), old).selectedTests == selection(locationModel(code, diagnostic: true), old).selectedTests)
}

@Test func diagnosticLocationPolicyRequiresBothRevisionsAndKeepsExplicitSyntax() throws {
    let source = locationAwareTests.replacingOccurrences(of: "XCTAssertEqual(4, 4)", with: "print(#line)")
    let shifted = "// documentation\n" + source
    let old = locationModel(source, diagnostic: true)
    let current = locationModel(shifted, diagnostic: true)
    #expect(selection(current, old).selectedTests.isEmpty)
    #expect(!selection(locationModel(shifted), old).selectedTests.isEmpty)
    #expect(!selection(current, locationModel(source)).selectedTests.isEmpty)
    let code = source.replacingOccurrences(of: "XCTAssertEqual(1, 1)", with: "XCTAssertEqual(1, 2)")
    #expect(selection(locationModel("// comment\n" + code, diagnostic: true), old).selectedTests == ["UI/Sharing/testIndependent()"])
    #expect(!selection(locationModel(shifted.replacingOccurrences(of: "#line", with: "#column"), diagnostic: true), old).selectedTests.isEmpty)
    var legacy = current
    for key in legacy.sources.keys {
        for i in legacy.sources[key]!.units.indices { legacy.sources[key]!.units[i].syntaxFingerprint = nil }
    }
    #expect(!selection(legacy, old).selectedTests.isEmpty)
    let restored = try GraphArchive.decode(GraphArchive.encode(current))
    #expect(restored.mappings?.sourceLocationPolicy == .diagnostic)
    #expect(selection(restored, old).selectedTests.isEmpty)
}

@Test func callerLocationDefaultsSelectOnlyShiftedCompilerCallers() throws {
    let expected = ["UI/Sharing/testOne()", "UI/Sharing/testThree()", "UI/Sharing/testTwo()"]
    for macro in ["line", "column", "filePath", "fileID"] {
        let source = uiSource.replacingOccurrences(of: "func helper()", with: "func helper(location: Any = #\(macro))")
        let base = model(ui: source)
        let shifted = macro == "line" ? "// docs\n" + source :
            macro == "column" ? source.replacingOccurrences(of: "{ helper()", with: "{  helper()") : source
        let path = macro.hasPrefix("file") ? "Moved/Other.swift" : "Tests/UI.swift"
        let head = model(ui: shifted, uiPath: path)
        for reversed in [false, true] {
            let (before, after) = reversed ? (head, base) : (base, head)
            let report = selection(try GraphArchive.decode(GraphArchive.encode(after)), before,
                paths: ["Tests/UI.swift", path])
            #expect(report.selectedTests == expected, "\(macro): \(report.selectedTests)")
        }
        // Moving the declaration, without moving any caller, changes no value.
        let movedHelper = source.replacingOccurrences(of: "    func helper", with: "\n    func helper")
        #expect(selection(model(ui: movedHelper), base).selectedTests.isEmpty)
        if macro.hasPrefix("file") {
            #expect(selection(model(ui: "// docs\n" + source), base).selectedTests.isEmpty)
        }
        if macro == "fileID" {
            #expect(selection(model(ui: source, uiPath: "Moved/UI.swift"), base, paths: ["Moved/UI.swift"]).selectedTests.isEmpty)
        }
    }
}

private func lineColumnModel(_ source: String, path: String = "Tests/UI.swift", opaque: Bool = false) -> XcodeTestGraph {
    var graph = model(ui: source, uiPath: path)
    if opaque {
        let mappings = graph.mappings
        graph = withOpaqueDependencies(graph)
        graph.mappings = mappings
    }
    graph.mappings!.sourceLocationPolicy = .diagnosticLineColumn
    graph.mappings!.ignoredDocumentation = ["*.md", "**/*.md"]
    return graph
}

@Test(arguments: ["// docs\n", "/// docs\n", "/* docs\nmore docs */\n"])
func lineColumnPolicyIgnoresDiagnosticPositionsInMixedChanges(comment: String) throws {
    let source = locationAwareTests
        .replacingOccurrences(of: "line: UInt = #line", with: "line: UInt = #line, column: Int = #column")
        .replacingOccurrences(of: "XCTAssertEqual(1, 1)", with: "print(#line, #column, #filePath, #fileID); XCTAssertEqual(1, 1)")
    let old = lineColumnModel(source, opaque: true)
    let documented = comment + source.replacingOccurrences(of: "{ helper()", with: "{  helper()")
        .replacingOccurrences(of: "{ print(", with: "{  print(")
    let head = try GraphArchive.decode(GraphArchive.encode(lineColumnModel(documented, opaque: true)))
    #expect(head.mappings?.sourceLocationPolicy == .diagnosticLineColumn)
    let report = selection(head, old, paths: ["Tests/UI.swift", "AGENTS.md"])
    #expect(report.selectedTests.isEmpty)
    #expect(report.diagnostics.isEmpty)
    #expect(report.ignoredChanges == ["AGENTS.md", "Tests/UI.swift"])
    #expect(report.limitations.contains { $0.contains("diagnosticLineColumn") })
    let mixed = documented.replacingOccurrences(of: "XCTAssertEqual(1, 1)", with: "XCTAssertEqual(1, 2)")
    let changed = selection(lineColumnModel(mixed, opaque: true), old, paths: ["Tests/UI.swift", "AGENTS.md"])
    #expect(changed.selectedTests == ["UI/Sharing/testIndependent()"])
    #expect(changed.diagnostics.isEmpty)
}

@Test(arguments: ["file", "filePath", "fileID"])
func lineColumnPolicyKeepsBodyAndCallerFileMoves(macro: String) throws {
    for caller in [false, true] {
        let source = caller ? uiSource.replacingOccurrences(of: "func helper()", with: "func helper(file: StaticString = #\(macro), line: Int = #line, column: Int = #column)") :
            uiSource.replacingOccurrences(of: "XCTAssertEqual(1, 1)", with: "print(#line, #column); XCTAssertTrue(#\(macro).hasSuffix(\"Original.swift\"))")
        let old = lineColumnModel(source, path: "Tests/Original.swift")
        let head = try GraphArchive.decode(GraphArchive.encode(lineColumnModel(source, path: "Tests/Moved.swift")))
        var move = FileChange(path: "Tests/Moved.swift")
        move.previousPath = "Tests/Original.swift"; move.isPureMove = true
        let report = XcodeFineSelector.select(current: head, previous: old, changes: [move], baseRevision: "base")
        let expected = caller ? ["UI/Sharing/testOne()", "UI/Sharing/testThree()", "UI/Sharing/testTwo()"] : ["UI/Sharing/testIndependent()"]
        #expect(report.selectedTests == expected)
        #expect(report.diagnostics.isEmpty)
        #expect(report.ignoredChanges.isEmpty)
        if macro == "fileID" {
            let directoryMove = lineColumnModel(source, path: "Moved/Original.swift")
            #expect(selection(directoryMove, old, paths: ["Tests/Original.swift", "Moved/Original.swift"]).selectedTests.isEmpty)
        }
    }
}

@Test func lineColumnPolicyRequiresMatchingValidPoliciesAndRetainsLegacyEvidence() throws {
    let source = locationAwareTests.replacingOccurrences(of: "XCTAssertEqual(1, 1)", with: "print(#line, #column, #filePath)")
    let old = lineColumnModel(source), head = lineColumnModel("// docs\n" + source)
    for policy in [nil, .semantic, .diagnostic] as [UIFeatureMappings.SourceLocationPolicy?] {
        var other = old; other.mappings!.sourceLocationPolicy = policy
        #expect(!selection(head, other).selectedTests.isEmpty)
        other = head; other.mappings!.sourceLocationPolicy = policy
        #expect(!selection(other, old).selectedTests.isEmpty)
    }
    var invalid = old; invalid.mappings!.version = 999
    #expect(!selection(head, invalid).selectedTests.isEmpty)
    // Remove the newly added field from actual archives, as in older saved graphs.
    func legacy(_ graph: XcodeTestGraph) throws -> XcodeTestGraph {
        var graph = graph
        for path in graph.sources.keys {
            for i in graph.sources[path]!.units.indices { graph.sources[path]!.units[i].fileLocationValues = nil }
        }
        return try GraphArchive.decode(GraphArchive.encode(graph))
    }
    #expect(!selection(head, try legacy(old)).selectedTests.isEmpty)
    #expect(!selection(try legacy(head), old).selectedTests.isEmpty)
    #expect(!selection(try legacy(head), try legacy(old)).selectedTests.isEmpty)
    var noCallers = old
    for path in noCallers.sources.keys {
        for i in noCallers.sources[path]!.units.indices { noCallers.sources[path]!.units[i].callerLocations = nil }
    }
    let report = selection(head, noCallers)
    #expect(report.selectedTests == head.tests)
    #expect(report.diagnostics.contains { $0.code == "incomplete_caller_locations" })
}

@Test func lineColumnPolicyKeepsExplicitSyntaxAndDependencyChanges() {
    let source = uiSource.replacingOccurrences(of: "XCTAssertEqual(1, 1)", with: "print(#line, #column, #filePath); XCTAssertEqual(1, 1)")
    let old = lineColumnModel(source)
    for (before, after) in [("#line", "#column"), ("#filePath", "#fileID"), ("XCTAssertEqual(1, 1)", "XCTAssertEqual(1, 2)")] {
        #expect(selection(lineColumnModel(source.replacingOccurrences(of: before, with: after)), old).selectedTests == ["UI/Sharing/testIndependent()"])
    }
    let directed = "#sourceLocation(file: \"Generated.swift\", line: 100)\n" + source
    #expect(!selection(lineColumnModel(directed.replacingOccurrences(of: "100", with: "200")), lineColumnModel(directed)).selectedTests.isEmpty)
    var head = lineColumnModel("// docs\n" + source)
    head.dependencies!.functions["UI.Sharing.testIndependent()"]!.dependencies.insert("UI.Sharing.helper()")
    #expect(selection(head, old).selectedTests == ["UI/Sharing/testIndependent()"])
}

// Head-only mode deliberately receives source snapshots, never a base graph.
private func headOnlyModel(ui: String = uiSource, app: String = appSource) -> XcodeTestGraph {
    var value = model(ui: ui, app: app)
    value.mappings?.sourceLocationPolicy = .diagnosticLineColumn
    value.mappings?.runtimeDependencyPolicy = .declared
    value.mappings?.ignoredDocumentation = ["AGENTS.md"]
    return value
}
private func headOnlySelection(_ current: XcodeTestGraph, old: XcodeTestGraph = headOnlyModel(),
                               paths: [String] = ["Tests/UI.swift"], documentation: Set<String> = [],
                               failure: String? = nil) -> ImpactReport {
    XcodeHeadOnlySelector.select(current: current, source: .init(base: old.sources, mappings: old.mappings),
        changes: paths.map { FileChange(path: $0) }, baseRevision: "base", documentation: documentation, buildEvidenceFailure: failure)
}

@Test func headOnlyEditedMethodAndAllowedTriviaSelectExactlyOne() {
    let edit = uiSource.replacingOccurrences(of: "XCTAssertEqual(1, 1)", with: "XCTAssertEqual(1, 2)")
    let plain = headOnlySelection(headOnlyModel(ui: edit))
    let mixed = headOnlySelection(headOnlyModel(ui: "// header\n" + edit), paths: ["Tests/UI.swift", "AGENTS.md"], documentation: ["AGENTS.md"])
    #expect(plain.selectedTests == ["UI/Sharing/testIndependent()"])
    #expect(mixed.selectedTests == plain.selectedTests)
    #expect(mixed.diagnostics.isEmpty)
    #expect(mixed.analysisMode == "head-only-git-syntax")
    #expect(mixed.onlyTestingArguments == ["-only-testing:UI/Sharing/testIndependent()"])
    #expect(mixed.ignoredChanges == ["AGENTS.md"])
    #expect(headOnlySelection(headOnlyModel(ui: "// header\n" + uiSource)).selectedTests.isEmpty)
}

@Test func headOnlySharedHelperAndLifecycleSelectConsumers() {
    let helper = headOnlySelection(headOnlyModel(ui: uiSource.replacingOccurrences(of: "XCTAssertEqual(2, 2)", with: "XCTAssertEqual(2, 3)")))
    #expect(helper.selectedTests == ["UI/Sharing/testOne()", "UI/Sharing/testThree()", "UI/Sharing/testTwo()"])
    let lifecycle = headOnlySelection(headOnlyModel(ui: uiSource.replacingOccurrences(of: "XCTAssertEqual(3, 3)", with: "XCTAssertEqual(3, 4)")))
    #expect(lifecycle.selectedTests.count == 4)
    #expect(lifecycle.selectedTests.allSatisfy { $0.hasPrefix("UI/Sharing/") })
    let deletedLines = headOnlySelection(headOnlyModel(ui: uiSource.replacingOccurrences(of: "XCTAssertEqual(1, 1)", with: "")))
    #expect(deletedLines.selectedTests == ["UI/Sharing/testIndependent()"])
    #expect(deletedLines.fullRunReasons.isEmpty)
}

@Test func headOnlyStructuralChangesAlwaysRetainSurvivors() {
    let changes = [
        uiSource + "\nfunc newHelper() {}",
        uiSource.replacingOccurrences(of: "func testIndependent() { XCTAssertEqual(1, 1) }", with: ""),
        uiSource.replacingOccurrences(of: "testIndependent()", with: "testRenamed()"),
        uiSource.replacingOccurrences(of: "func helper()", with: "func helper(_ n: Int = 1)"),
        uiSource.replacingOccurrences(of: "class Sharing: XCTestCase", with: "class Sharing: OtherCase"),
        uiSource + "\nvar sharedState = 0",
        uiSource + "\n#if DEBUG\nfunc conditional() {}\n#endif",
        uiSource.replacingOccurrences(of: "func helper()", with: "@inline(__always) func helper()"),
        uiSource.replacingOccurrences(of: "func testIndependent()", with: "func testNew()").appending("\nclass Added: XCTestCase { func testAdded() {} }")
    ]
    for text in changes {
        let current = headOnlyModel(ui: text)
        let report = headOnlySelection(current)
        #expect(report.selectedTests == current.tests.sorted())
        #expect(report.diagnostics.contains { $0.code == "head_only_declaration_change" })
        #expect(!report.selectedTests.contains("UI/Sharing/testIndependent()") || current.tests.contains("UI/Sharing/testIndependent()"))
    }
}

@Test func headOnlyProductionUsesDeclaredUIAndSharedDependencies() {
    let sharing = headOnlySelection(headOnlyModel(app: appSource.replacingOccurrences(of: "func sharing() -> Int { common() }", with: "func sharing() -> Int { common() + 1 }")), paths: ["App/Features.swift"])
    #expect(sharing.selectedTests.count == 4)
    #expect(sharing.selectedTests.allSatisfy { $0.hasPrefix("UI/Sharing/") })
    #expect(sharing.diagnostics.isEmpty)
    let common = headOnlySelection(headOnlyModel(app: appSource.replacingOccurrences(of: "42", with: "43")), paths: ["App/Features.swift"])
    #expect(common.selectedTests.count == 5)
    #expect(common.explanations.allSatisfy { $0.kind == "explicitMapping" })
    var unmapped = headOnlyModel(app: appSource.replacingOccurrences(of: "42", with: "43"))
    unmapped.mappings = nil
    #expect(headOnlySelection(unmapped, paths: ["App/Features.swift"]).diagnostics.contains { $0.code == "head_only_missing_mappings" })
}

@Test func headOnlyHostlessAndHostedRuntimeStayDistinct() {
    func unitModel(_ text: String, hosted: Bool = false, opaque: Bool = false) -> XcodeTestGraph {
        var value = headOnlyModel(app: text)
        value.targets[0].productType = "com.apple.product-type.bundle.unit-test"
        value.mappings?.features = []
        value.runtimeInventory = .init(imports: [:], hosts: ["UI": hosted ? ["UI", "App"] : ["UI"]])
        value.dependencies!.functions["UI.Sharing.testIndependent()"]!.dependencies = ["App.sharing()"]
        if opaque { value.dependencies!.functions["UI.Notes.testNotes()"]!.uncertainties.insert("Global state access") }
        return value
    }
    let edit = appSource.replacingOccurrences(of: "func sharing() -> Int { common() }", with: "func sharing() -> Int { common() + 1 }")
    let focused = headOnlySelection(unitModel(edit), old: unitModel(appSource), paths: ["App/Features.swift"])
    #expect(focused.selectedTests == ["UI/Sharing/testIndependent()"])
    #expect(focused.diagnostics.isEmpty)
    let hosted = headOnlySelection(unitModel(edit, hosted: true), old: unitModel(appSource, hosted: true), paths: ["App/Features.swift"])
    #expect(hosted.selectedTests.count == 5)
    #expect(hosted.diagnostics.contains { $0.code == "head_only_test_host" })
    let opaque = headOnlySelection(unitModel(edit, opaque: true), old: unitModel(appSource), paths: ["App/Features.swift"])
    #expect(opaque.selectedTests == ["UI/Notes/testNotes()", "UI/Sharing/testIndependent()"])
    #expect(opaque.diagnostics.contains { $0.code == "head_only_runtime_uncertainty" })
}

@Test func headOnlyUncertainInputsCannotBecomeEmptySelections() {
    for path in ["AGENTS.md", "Assets/image.png", "Config.xcconfig", "Missing.swift", ".swift-test-selection.json"] {
        let report = headOnlySelection(headOnlyModel(), paths: [path])
        #expect(report.selectedTests.count == 5)
        #expect(report.diagnostics.contains { $0.code == "head_only_build_input" })
    }
    let failed = headOnlySelection(headOnlyModel(), failure: "Unknown generation script")
    #expect(failed.selectedTests.count == 5)
    #expect(failed.diagnostics.contains { $0.code == "head_only_build_evidence" })
    var missing = headOnlyModel(ui: uiSource.replacingOccurrences(of: "XCTAssertEqual(1, 1)", with: "XCTAssertEqual(1, 2)"))
    missing.dependencies!.functions.removeValue(forKey: "UI.Sharing.testIndependent()")
    #expect(headOnlySelection(missing).diagnostics.contains { $0.code == "head_only_unresolved_body" })
}

@Test func headOnlyLiteralOperatorAndLocationEditsStaySemantic() {
    for (before, after) in [
        (#"print("// literal")"#, #"print("// changed")"#),
        (##"print(#"/* literal */"#)"##, ##"print(#"/* changed */"#)"##),
        (#"print(/literal/)"#, #"print(/changed/)"#),
        ("print(1 + 2)", "print(1 - 2)")
    ] {
        let old = headOnlyModel(ui: uiSource.replacingOccurrences(of: "XCTAssertEqual(1, 1)", with: before))
        let new = headOnlyModel(ui: uiSource.replacingOccurrences(of: "XCTAssertEqual(1, 1)", with: after))
        #expect(headOnlySelection(new, old: old).selectedTests == ["UI/Sharing/testIndependent()"])
    }
    let source = uiSource.replacingOccurrences(of: "XCTAssertEqual(1, 1)", with: "print(#line, #column, #filePath)")
    #expect(headOnlySelection(headOnlyModel(ui: "// shift\n" + source), old: headOnlyModel(ui: source)).selectedTests.isEmpty)
    var moved = headOnlyModel(ui: source)
    moved.sources["Tests/UI.swift"] = SwiftSourceSnapshot.parse(source, path: "Other/UI.swift", module: "UI")
    var move = FileChange(path: "Other/UI.swift"); move.previousPath = "Tests/UI.swift"
    let report = XcodeHeadOnlySelector.select(current: moved, source: .init(base: headOnlyModel(ui: source).sources, mappings: moved.mappings),
        changes: [move], baseRevision: "base")
    #expect(report.selectedTests == moved.tests.sorted())
    #expect(report.diagnostics.contains { $0.code == "head_only_move" })
}

@Test func headOnlyUnsafeBodyAttributesAndUnknownMappingsBroaden() {
    for prefix in ["@inlinable ", "@inline(__always) ", "@CustomMacro "] {
        let oldText = appSource.replacingOccurrences(of: "func common", with: prefix + "func common")
        let report = headOnlySelection(headOnlyModel(app: oldText.replacingOccurrences(of: "42", with: "43")), old: headOnlyModel(app: oldText), paths: ["App/Features.swift"])
        #expect(report.selectedTests.count == 5)
        #expect(report.diagnostics.contains { $0.code == "head_only_unsupported_body" })
    }
    var value = headOnlyModel(app: appSource.replacingOccurrences(of: "42", with: "43"))
    value.mappings?.features[0].symbols = ["App.missing()"]
    #expect(headOnlySelection(value, paths: ["App/Features.swift"]).diagnostics.contains { $0.code == "head_only_unresolved_mapping" })
}

@Test func headOnlyUsesRealGitBaseSyntaxAndRejectsUnavailableBlobs() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    func git(_ args: [String]) throws -> String { try CommandRunner.run("git", args, at: root).text.trimmingCharacters(in: .whitespacesAndNewlines) }
    _ = try git(["init", "-q"])
    try FileManager.default.createDirectory(at: root.appendingPathComponent("Tests"), withIntermediateDirectories: true)
    try uiSource.write(to: root.appendingPathComponent("Tests/UI.swift"), atomically: true, encoding: .utf8)
    try JSONEncoder().encode(headOnlyModel().mappings).write(to: root.appendingPathComponent(".swift-test-selection.json"))
    _ = try git(["add", "."])
    _ = try git(["-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-qm", "base"])
    let base = try git(["rev-parse", "HEAD"])
    var current = headOnlyModel(ui: uiSource.replacingOccurrences(of: "XCTAssertEqual(1, 1)", with: "XCTAssertEqual(1, 2)"))
    current.sources = Dictionary(uniqueKeysWithValues: current.sources.map { key, snapshot in
        ((key.hasPrefix("Tests/") ? "UI:" : "App:") + key, snapshot)
    })
    let changes = [FileChange(path: "Tests/UI.swift")]
    let source = try XcodeHeadOnlySources.read(current: current, changes: changes, base: base, root: root, mappingPath: ".swift-test-selection.json")
    #expect(source.diagnostics.isEmpty)
    #expect(XcodeHeadOnlySelector.select(current: current, source: source, changes: changes, baseRevision: base).selectedTests == ["UI/Sharing/testIndependent()"])
    let invalid = try XcodeHeadOnlySources.read(current: current, changes: changes, base: "missing", root: root, mappingPath: ".swift-test-selection.json")
    #expect(!invalid.diagnostics.isEmpty)
    #expect(XcodeHeadOnlySelector.select(current: current, source: invalid, changes: changes, baseRevision: "missing").selectedTests.count == 5)
}

@Test func headOnlyEnclosingMacrosAndTestAttributesDoNotBypassUncertainty() {
    for replacement in ["@CustomMacro class Sharing", "@Observable class Sharing"] {
        let text = uiSource.replacingOccurrences(of: "class Sharing", with: replacement)
        let before = headOnlyModel(ui: text)
        let after = headOnlyModel(ui: text.replacingOccurrences(of: "XCTAssertEqual(1, 1)", with: "XCTAssertEqual(1, 2)"))
        let report = headOnlySelection(after, old: before)
        #expect(report.selectedTests.count == 5)
        #expect(report.diagnostics.contains { $0.code == "head_only_unsupported_body" })
    }
    let text = uiSource.replacingOccurrences(of: "func testIndependent", with: "@inline(__always) func testIndependent")
    #expect(headOnlySelection(headOnlyModel(ui: text.replacingOccurrences(of: "XCTAssertEqual(1, 1)", with: "XCTAssertEqual(1, 2)")), old: headOnlyModel(ui: text)).selectedTests.count == 5)
}

@Test func headOnlyCommentsInAnEmptyOwnedSwiftFileAreIgnored() {
    var before = headOnlyModel(), after = headOnlyModel()
    before.targets[0].sourceFiles.insert("Tests/Empty.swift")
    after.targets[0].sourceFiles.insert("Tests/Empty.swift")
    before.sources["UI:Tests/Empty.swift"] = SwiftSourceSnapshot.parse("// before", path: "Tests/Empty.swift", module: "UI")
    after.sources["UI:Tests/Empty.swift"] = SwiftSourceSnapshot.parse("// after", path: "Tests/Empty.swift", module: "UI")
    let report = headOnlySelection(after, old: before, paths: ["Tests/Empty.swift"])
    #expect(report.selectedTests.isEmpty)
    #expect(report.ignoredChanges == ["Tests/Empty.swift"])
}

@Test(arguments: ["XCTAssertEqual(2, 2)", "XCTAssertEqual(3, 3)"])
func headOnlyMixedProductionAndTestInfrastructureKeepRuntimeFallback(expression: String) {
    let uiEdit = uiSource.replacingOccurrences(of: expression, with: "XCTAssertEqual(2, 4)")
    let appEdit = appSource.replacingOccurrences(of: "func sharing() -> Int { common() }", with: "func sharing() -> Int { common() + 1 }")
    func withIndirectUI(_ ui: String, _ app: String) -> XcodeTestGraph {
        var value = headOnlyModel(ui: ui, app: app)
        value.dependencies!.functions["UI.Notes.testNotes()"]!.uncertainties.insert("Indirect function invocation")
        return value
    }
    let helper = headOnlySelection(withIndirectUI(uiEdit, appSource))
    let mixed = headOnlySelection(withIndirectUI(uiEdit, appEdit), paths: ["Tests/UI.swift", "App/Features.swift"])
    #expect(helper.selectedTests.contains("UI/Notes/testNotes()"))
    #expect(Set(mixed.selectedTests).isSuperset(of: helper.selectedTests))
    #expect(mixed.diagnostics.contains { $0.code == "head_only_runtime_uncertainty" && $0.tests.contains("UI/Notes/testNotes()") })

    // An app-only change, or one mixed with a proven independent test entry,
    // still uses the declared UI feature contract to exclude unrelated tests.
    let production = headOnlySelection(withIndirectUI(uiSource, appEdit), paths: ["App/Features.swift"])
    let entry = headOnlySelection(withIndirectUI(uiSource.replacingOccurrences(of: "XCTAssertEqual(1, 1)", with: "XCTAssertEqual(1, 2)"), appEdit),
        paths: ["Tests/UI.swift", "App/Features.swift"])
    #expect(production.selectedTests.count == 4)
    #expect(entry.selectedTests == production.selectedTests)
    #expect(entry.diagnostics.isEmpty)
}

@Test(arguments: ["some Equatable", "(some Equatable)?", "(some Equatable, Int)", "[some Equatable]", "[String: some Equatable]", "(any Equatable)?"])
func headOnlyNestedOpaqueResultsRequireFallback(result: String) throws {
    let before = "func common() -> \(result) { fatalError(\"before\") }"
    let after = before.replacingOccurrences(of: "before", with: "after")
    let snapshot = SwiftSourceSnapshot.parse(after, path: "App/Features.swift", module: "App")
    #expect(snapshot.diagnostics.isEmpty)
    #expect(try #require(snapshot.units.first).headOnlyBodySupported == false)
    let report = headOnlySelection(headOnlyModel(app: after), old: headOnlyModel(app: before), paths: ["App/Features.swift"])
    #expect(report.selectedTests.count == 5)
    #expect(report.diagnostics.contains { $0.code == "head_only_unsupported_body" })
}

@Test func headOnlySelectionScopesSeparateHelperImpactFromWholeReviewFallback() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("scoped-impact-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root.appendingPathComponent("Tests"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: root.appendingPathComponent("App"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    func git(_ args: [String]) throws -> String { try CommandRunner.run("git", args, at: root).text.trimmingCharacters(in: .whitespacesAndNewlines) }
    try uiSource.write(to: root.appendingPathComponent("Tests/UI.swift"), atomically: true, encoding: .utf8)
    try appSource.write(to: root.appendingPathComponent("App/Features.swift"), atomically: true, encoding: .utf8)
    try JSONEncoder().encode(headOnlyModel().mappings!).write(to: root.appendingPathComponent(".swift-test-selection.json"))
    _ = try git(["init", "-q"]); _ = try git(["config", "user.email", "test@example.invalid"]); _ = try git(["config", "user.name", "Test"])
    _ = try git(["add", "."]); _ = try git(["commit", "-qm", "base"]); let base = try git(["rev-parse", "HEAD"])
    let ui = uiSource.replacingOccurrences(of: "XCTAssertEqual(2, 2)", with: "XCTAssertEqual(2, 3)")
        .replacingOccurrences(of: "XCTAssertEqual(1, 1)", with: "XCTAssertEqual(1, 9)")
    try ui.write(to: root.appendingPathComponent("Tests/UI.swift"), atomically: true, encoding: .utf8)
    try "struct AddedProduction {}".write(to: root.appendingPathComponent("App/New.swift"), atomically: true, encoding: .utf8)
    _ = try git(["add", "."]); _ = try git(["commit", "-qm", "head"]); let head = try git(["rev-parse", "HEAD"])
    var current = headOnlyModel(ui: ui)
    current.sources = ["UI:Tests/UI.swift": current.sources["Tests/UI.swift"]!, "App:App/Features.swift": current.sources["App/Features.swift"]!,
                       "App:App/New.swift": SwiftSourceSnapshot.parse("struct AddedProduction {}", path: "App/New.swift", module: "App")]
    current.targets[1].sourceFiles.insert("App/New.swift")
    let changes = try GitChanges.readComparison(base: base, head: head, at: root)
    let cache = try XcodeBaseSourceCache(root: root, base: base)
    let source = try XcodeHeadOnlySources.read(current: current, changes: changes, base: base, root: root, mappingPath: ".swift-test-selection.json", cache: cache)
    let primary = XcodeHeadOnlySelector.select(current: current, source: source, changes: changes, baseRevision: base)
    #expect(primary.selectedTests == current.tests)
    let request = SelectionScopes(scopes: [.init(name: "helpers", paths: ["Tests/UI.swift"], excludedTestEntries: ["UI/Sharing/testIndependent()"]), .init(name: "empty", paths: []), .init(name: "overlap", paths: ["Tests/UI.swift"])])
    let initialCounts = cache.counts
    var events: [XcodeAnalysisEvent] = []
    let reports = try XcodeHeadOnlySelector.scopedReports(current: current, requests: request, changes: changes, baseRevision: base,
        headRevision: head, root: root, mappingPath: ".swift-test-selection.json", documentation: [], buildEvidenceFailure: nil, sourceCache: cache, measurement: { events.append($0) })
    #expect(cache.counts.blobReads == initialCounts.blobReads)
    #expect(cache.counts.parses == initialCounts.parses)
    #expect(cache.counts.parseHits > 0)
    #expect(events.map(\.phase) == Array(repeating: ["scopeSourceSyntax", "scopeSelection"], count: 3).flatMap { $0 })
    for result in reports {
        let filtered = changes.filter { result.scope.paths.contains($0.path) }
        let oldSource = try uncachedHeadOnlySources(current: current, changes: filtered, base: base, root: root, mappingPath: ".swift-test-selection.json")
        let oldReport = XcodeHeadOnlySelector.select(current: current, source: oldSource, changes: filtered, baseRevision: base, excludedTestEntries: Set(result.scope.excludedTestEntries))
        #expect(result.report.selectedTests == oldReport.selectedTests)
        #expect(try diagnosticJSON(result.report) == diagnosticJSON(oldReport))
    }
    #expect(reports[0].report.selectedTests == ["UI/Sharing/testOne()", "UI/Sharing/testThree()", "UI/Sharing/testTwo()"])
    #expect(reports[0].report.changedFiles == ["Tests/UI.swift"])
    #expect(reports[0].report.fullRunReasons.isEmpty)
    #expect(reports[0].report.headRevision == head)
    #expect(reports[1].report.selectedTests.isEmpty)
    #expect(primary.selectedTests == current.tests)
    var combined = primary; combined.selectionScopes = reports
    let decoded = try JSONDecoder().decode(ImpactReport.self, from: JSONEncoder().encode(combined))
    #expect(decoded.selectionScopes?.first?.report.selectedTests == reports[0].report.selectedTests)
    #expect(throws: (any Error).self) {
        try XcodeHeadOnlySelector.scopedReports(current: current, requests: .init(scopes: [.init(name: "bad", paths: ["Unchanged.swift"])]),
            changes: changes, baseRevision: base, headRevision: head, root: root, mappingPath: ".swift-test-selection.json", documentation: [], buildEvidenceFailure: nil)
    }
    current.dependencies!.functions["UI.Notes.testNotes()"]!.uncertainties.insert("Indirect function invocation")
    let uncertain = try XcodeHeadOnlySelector.scopedReports(current: current, requests: request, changes: changes, baseRevision: base,
        headRevision: head, root: root, mappingPath: ".swift-test-selection.json", documentation: [], buildEvidenceFailure: nil)
    #expect(uncertain[0].report.selectedTests.contains("UI/Notes/testNotes()"))
    #expect(uncertain[0].report.diagnostics.contains { $0.code == "head_only_runtime_uncertainty" })
}

@Test func headOnlyScopeDoesNotExcludeTestEntriesUsedAsHelpers() {
    let old = headOnlyModel()
    var current = headOnlyModel(ui: uiSource.replacingOccurrences(of: "XCTAssertEqual(1, 1)", with: "XCTAssertEqual(1, 9)"))
    current.dependencies!.functions["UI.Notes.testNotes()"]!.dependencies.insert("UI.Sharing.testIndependent()")
    let result = XcodeHeadOnlySelector.select(current: current, source: .init(base: old.sources, mappings: old.mappings),
        changes: [.init(path: "Tests/UI.swift")], baseRevision: "base", excludedTestEntries: ["UI/Sharing/testIndependent()"])
    #expect(result.selectedTests == ["UI/Notes/testNotes()", "UI/Sharing/testIndependent()"])
}

@Test func headOnlyScopeValidationRejectsAmbiguousAndEscapingInputs() {
    for request in [SelectionScopes(version: 2, scopes: []), .init(scopes: [.init(name: "same", paths: []), .init(name: "same", paths: [])]),
                    .init(scopes: [.init(name: "scope", paths: ["../outside"])]), .init(scopes: [.init(name: "scope", paths: ["/absolute"])]),
                    .init(scopes: [.init(name: "scope", paths: ["a", "a"])])] {
        #expect(throws: (any Error).self) { try request.validate() }
    }
}

@Test(arguments: ["enclosing-macro", "function-macro", "inline-attribute", "body-macro"])
func headOnlyScopeExclusionsPreserveUnsupportedBodyFallback(kind: String) {
    let text: String
    switch kind {
    case "enclosing-macro": text = uiSource.replacingOccurrences(of: "class Sharing", with: "@CustomMacro class Sharing")
    case "function-macro": text = uiSource.replacingOccurrences(of: "func testIndependent", with: "@CustomMacro func testIndependent")
    case "inline-attribute": text = uiSource.replacingOccurrences(of: "func testIndependent", with: "@inline(__always) func testIndependent")
    default: text = uiSource.replacingOccurrences(of: "XCTAssertEqual(1, 1)", with: "#customAssertion(1, 1)")
    }
    let old = headOnlyModel(ui: text)
    let current = headOnlyModel(ui: text.replacingOccurrences(of: "(1, 1)", with: "(1, 2)"))
    let primary = headOnlySelection(current, old: old)
    let scoped = XcodeHeadOnlySelector.select(current: current, source: .init(base: old.sources, mappings: old.mappings),
        changes: [.init(path: "Tests/UI.swift")], baseRevision: "base", excludedTestEntries: ["UI/Sharing/testIndependent()"])
    #expect(primary.selectedTests == current.tests)
    #expect(scoped.selectedTests == primary.selectedTests)
    #expect(scoped.diagnostics.contains { $0.code == "head_only_unsupported_body" })
}

@Test func headOnlyScopeExclusionsDoNotBypassStructuralFallback() {
    let old = headOnlyModel()
    let text = uiSource.replacingOccurrences(of: "func testIndependent()", with: "func testAdded() {}\n    func testIndependent()")
    let current = headOnlyModel(ui: text)
    let scoped = XcodeHeadOnlySelector.select(current: current, source: .init(base: old.sources, mappings: old.mappings),
        changes: [.init(path: "Tests/UI.swift")], baseRevision: "base", excludedTestEntries: ["UI/Sharing/testAdded()"])
    #expect(scoped.selectedTests == current.tests)
    #expect(scoped.diagnostics.contains { $0.code == "head_only_declaration_change" })
}

@Test(arguments: ["missing", "empty", "dangling", "partial", "lifecycle"])
func headOnlyScopeExclusionsRequireCompleteConsumerBindings(kind: String) {
    let old = headOnlyModel()
    var current = headOnlyModel(ui: uiSource.replacingOccurrences(of: "XCTAssertEqual(1, 1)", with: "XCTAssertEqual(1, 2)"))
    let entry = "UI/Sharing/testIndependent()", consumer = "UI/Notes/testNotes()"
    func scoped(_ graph: XcodeTestGraph) -> ImpactReport {
        XcodeHeadOnlySelector.select(current: graph, source: .init(base: old.sources, mappings: old.mappings),
            changes: [.init(path: "Tests/UI.swift")], baseRevision: "base", excludedTestEntries: [entry])
    }
    // A complete graph still permits a focused, valid empty scope when the
    // only edited body is an independent entry already run by caller policy.
    let control = scoped(current)
    #expect(control.selectedTests.isEmpty)
    #expect(control.diagnostics.isEmpty)
    switch kind {
    case "missing": current.dependencies!.tests.removeValue(forKey: consumer)
    case "empty": current.dependencies!.tests[consumer] = []
    case "dangling": current.dependencies!.tests[consumer] = ["missing-symbol"]
    case "partial": current.dependencies!.tests[consumer]!.insert("missing-symbol")
    default: current.dependencies!.testDiagnostics[consumer] = ["Cannot resolve inherited lifecycle/fixture type: ExternalBase"]
    }
    let result = scoped(current)
    #expect(result.selectedTests == [consumer, entry])
    #expect(result.diagnostics.contains { $0.code == "head_only_unresolved_test" && $0.tests.contains(consumer) })
    #expect(result.onlyTestingArguments == result.selectedTests.map { "-only-testing:" + $0 })
}

@Test func headOnlyScopedReportsKeepRetainedExecutionAfterSerialization() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("scoped-retained-" + UUID().uuidString)
        .standardizedFileURL.resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: root.appendingPathComponent("Tests"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    func git(_ args: [String]) throws -> String { try CommandRunner.run("git", args, at: root).text.trimmingCharacters(in: .whitespacesAndNewlines) }
    func commit() throws -> String {
        _ = try git(["add", "Tests/UI.swift", ".swift-test-selection.json"])
        _ = try git(["-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-qm", "fixture"])
        return try git(["rev-parse", "HEAD"])
    }
    try uiSource.write(to: root.appendingPathComponent("Tests/UI.swift"), atomically: true, encoding: .utf8)
    try JSONEncoder().encode(headOnlyModel().mappings!).write(to: root.appendingPathComponent(".swift-test-selection.json"))
    _ = try git(["init", "-q"])
    let base = try commit()
    let edited = uiSource.replacingOccurrences(of: "XCTAssertEqual(2, 2)", with: "XCTAssertEqual(2, 3)")
    try edited.write(to: root.appendingPathComponent("Tests/UI.swift"), atomically: true, encoding: .utf8)
    let head = try commit()
    var current = headOnlyModel(ui: edited)
    current.sources = ["UI:Tests/UI.swift": current.sources["Tests/UI.swift"]!, "App:App/Features.swift": current.sources["App/Features.swift"]!]
    var messages: [String] = []
    let analysis = XcodeAnalysis(options: .init(container: .project, path: root.appendingPathComponent("App.xcodeproj"),
        scheme: "Fixture", destination: "platform=macOS", configuration: "Debug", testPlan: "All"), progress: { messages.append($0) })

    // Publish a sealed fixture bundle without invoking a compiler or Xcode.
    let bundle = try RetainedXcodeBuild.create(at: root.appendingPathComponent("retained"), cache: root.appendingPathComponent("cache"))
    let products = bundle.appendingPathComponent("DerivedData/Build/Products")
    try FileManager.default.createDirectory(at: products, withIntermediateDirectories: true)
    let plist: [String: Any] = ["__xctestrun_metadata__": ["FormatVersion": 2], "TestPlan": ["Name": "All"],
        "TestConfigurations": [["TestTargets": [["TestBundlePath": "__TESTROOT__/Test.xctest"]]]]]
    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: products.appendingPathComponent("All.xctestrun"))
    let binary = products.appendingPathComponent("Test.xctest")
    try Data("original product".utf8).write(to: binary)
    try Data("fixture build log".utf8).write(to: bundle.appendingPathComponent("build.log"))
    let settings = Data(#"[{"buildSettings":{"CONFIGURATION":"Debug","SDK_NAME":"sdk","PLATFORM_NAME":"macosx","ARCHS":"arm64"}}]"#.utf8)
    let graphPath = try RetainedXcodeBuild.publish(graph: &current, revision: head, context: analysis.artifactContext(root: root),
        toolchain: "fixture", workspace: bundle, settings: settings, inputIdentity: [:]).path
    let reports = try XcodeHeadOnlySelector.scopedReports(current: current,
        requests: .init(scopes: [.init(name: "helpers", paths: ["Tests/UI.swift"]), .init(name: "empty", paths: [])]),
        changes: [.init(path: "Tests/UI.swift")], baseRevision: base, headRevision: head, root: root,
        mappingPath: ".swift-test-selection.json", documentation: [], buildEvidenceFailure: nil, retainedGraphPath: graphPath)
    let decoded = try JSONDecoder().decode([ScopedImpactReport].self, from: JSONEncoder().encode(reports))
    for scope in decoded {
        try #require(scope.report.buildArtifactPath == graphPath)
        #expect(scope.report.buildArtifactID == current.buildArtifact?.id)
        #expect(scope.report.headRevision == head)
    }
    #expect(decoded[0].report.selectedTests.count == 3)
    #expect(decoded[1].report.selectedTests.isEmpty)
    #expect(try analysis.run(decoded[1].report) == 0)

    // A nonempty scope must enter retained product verification. In particular,
    // it must not export the head into fresh DerivedData and rebuild via `test`.
    try Data("modified product".utf8).write(to: binary)
    do {
        _ = try analysis.run(decoded[0].report)
        Issue.record("Scoped execution accepted modified retained products")
    } catch let error as ImpactError {
        #expect(error.description.contains("Test products differ from the captured graph"))
    }
    #expect(!messages.contains { $0.hasPrefix("Running ") })
}

@Test func privateLoopDiagnosticsDoNotBroadenProductionSelection() throws {
    let before = """
    class Parent {}
    final class Worker: Parent {
        private func sharing() -> Int {
            for _ in 0..<2 { let value = 1; _ = value }
            return 42
        }
    }
    func notes() -> Int { common() }
    func common() -> Int { 42 }
    """
    let after = before.replacingOccurrences(of: "let value = 1", with: "let value = 2")
    func graph(_ text: String) -> XcodeTestGraph {
        var value = headOnlyModel(app: text)
        value.mappings!.features[0].symbols = ["App.Worker.sharing()"]
        value.dependencies!.functions["UI.Notes.testNotes()"]!.uncertainties.insert("Indirect function invocation")
        return value
    }
    let current = graph(after)
    let helper = try #require(current.sources.values.flatMap(\.units).first { $0.scope == "Worker" && $0.kind == "function" })
    #expect(helper.privateTestHelperBlocker != nil)
    #expect(helper.privateTestHelper == nil)
    let report = headOnlySelection(current, old: graph(before), paths: ["App/Features.swift"])
    #expect(report.selectedTests.count == 4)
    #expect(!report.selectedTests.contains("UI/Notes/testNotes()"))
    #expect(report.diagnostics.isEmpty, "\(report.diagnostics)")
}
