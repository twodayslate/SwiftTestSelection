// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: AGPL-3.0-only

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
    let old = locationModel(locationAwareTests)
    let documented = comment + locationAwareTests.replacingOccurrences(of: "class Notes", with: comment + "class Notes")
    for paths in [["Tests/UI.swift"], ["Tests/UI.swift", "AGENTS.md", "docs/guide.md"]] {
        #expect(selection(locationModel(documented), old, paths: paths).selectedTests.isEmpty)
    }
    let code = locationAwareTests.replacingOccurrences(of: "XCTAssertEqual(1, 1)", with: "XCTAssertEqual(1, 2)")
    let mixed = comment + code.replacingOccurrences(of: "class Notes", with: comment + "class Notes")
    #expect(selection(locationModel(mixed), old).selectedTests == selection(locationModel(code), old).selectedTests)
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
