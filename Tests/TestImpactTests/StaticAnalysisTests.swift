// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation
import Testing
@testable import TestImpact

private func region(_ start: Int, _ end: Int? = nil, path: String = "Sources/Shop.swift") -> SourceRegion {
    SourceRegion(path: path, startLine: start, endLine: end ?? start)
}

private func exampleGraph() -> DependencyGraph {
    DependencyGraph(functions: [
        "testCheckout": FunctionNode(id: "testCheckout", module: "Tests", name: "testCheckout()", dependencies: ["closure"]),
        "closure": FunctionNode(id: "closure", module: "Tests", name: "assertion closure", dependencies: ["checkout"]),
        "checkout": FunctionNode(id: "checkout", module: "Shop", name: "checkout()", regions: [region(5, 8)], dependencies: ["tax"]),
        "tax": FunctionNode(id: "tax", module: "Shop", name: "tax()", regions: [region(1, 3)]),
        "testGreeting": FunctionNode(id: "testGreeting", module: "Tests", name: "testGreeting()", dependencies: ["greeting"]),
        "greeting": FunctionNode(id: "greeting", module: "Shop", name: "greeting()", regions: [region(10, 12)])
    ], tests: ["Tests.Checkout/testCheckout": ["testCheckout"], "Tests.Greeting/testGreeting": ["testGreeting"]])
}

@Test func selectsThroughAnAssertionClosureWithoutCoverage() {
    let graph = exampleGraph()
    let report = StaticSelector.select(current: graph, previous: graph, changes: [
        FileChange(path: "Sources/Shop.swift", oldRegions: [region(2)], newRegions: [region(2)])
    ], baseRevision: "base")
    #expect(report.selectedTests == ["Tests.Checkout/testCheckout"])
    #expect(report.fullRunReasons.isEmpty)
    #expect(report.explanations.first?.path == ["Tests.testCheckout()", "Tests.assertion closure", "Shop.checkout()", "Shop.tax()"])
}

@Test func discoversNewFunctionsWithoutCoverage() {
    let old = exampleGraph()
    var current = old
    current.functions["newTax"] = FunctionNode(id: "newTax", module: "Shop", name: "newTax()", regions: [region(14, 17)])
    current.functions["checkout"]!.dependencies = ["newTax"]
    let report = StaticSelector.select(current: current, previous: old, changes: [
        FileChange(path: "Sources/Shop.swift", newRegions: [region(14, 17)])
    ], baseRevision: "base")
    #expect(report.selectedTests == ["Tests.Checkout/testCheckout"])
    #expect(report.fullRunReasons.isEmpty)
}

@Test func usesOldGraphForDeletedFunctions() {
    let old = exampleGraph()
    var current = old
    current.functions.removeValue(forKey: "tax")
    current.functions["checkout"]!.dependencies = []
    let report = StaticSelector.select(current: current, previous: old, changes: [
        FileChange(path: "Sources/Shop.swift", oldRegions: [region(1, 3)])
    ], baseRevision: "base")
    #expect(report.selectedTests == ["Tests.Checkout/testCheckout"])
    #expect(report.explanations.first?.revision == "base")
}

@Test func declarationsAndResourcesFallBackToAllTests() {
    let graph = exampleGraph()
    for change in [
        FileChange(path: "Sources/Shop.swift", newRegions: [region(4)]),
        FileChange(path: "Package.swift", requiresFallback: true),
        FileChange(path: "Resources/prices.json", requiresFallback: true)
    ] {
        let report = StaticSelector.select(current: graph, previous: graph, changes: [change], baseRevision: "base")
        #expect(report.selectedTests == graph.tests.keys.sorted())
        #expect(!report.fullRunReasons.isEmpty)
    }
}

@Test func partialRegionMappingDoesNotSilentlySkipDeclarationChanges() {
    let graph = exampleGraph()
    let report = StaticSelector.select(current: graph, previous: graph, changes: [
        FileChange(path: "Sources/Shop.swift", newRegions: [region(2, 6)])
    ], baseRevision: "base")
    #expect(!report.fullRunReasons.isEmpty)
}

@Test func uncertaintySelectsItsCallersEvenWithoutAChangedDependency() {
    var graph = exampleGraph()
    graph.functions["greeting"]!.uncertainties = ["Indirect function invocation"]
    let report = StaticSelector.select(current: graph, previous: graph, changes: [
        FileChange(path: "Sources/Shop.swift", newRegions: [region(2)])
    ], baseRevision: "base")
    #expect(report.selectedTests.count == 2)
    #expect(report.explanations.contains { $0.reason.contains("Indirect function") })
}

@Test func noDiffDoesNotSelectTestsOrProduceAFilter() {
    let graph = exampleGraph()
    let report = StaticSelector.select(current: graph, previous: graph, changes: [], baseRevision: "base")
    #expect(report.selectedTests.isEmpty)
    #expect(report.filter == nil)
}

@Test func newTestsAreIncludedAndDeletedTestsAreExcluded() {
    let old = exampleGraph()
    var current = old
    current.tests.removeValue(forKey: "Tests.Greeting/testGreeting")
    current.tests["Tests.Checkout/newTest()"] = ["testCheckout"]
    let report = StaticSelector.select(current: current, previous: old, changes: [
        FileChange(path: "Sources/Shop.swift", newRegions: [region(10)])
    ], baseRevision: "base")
    #expect(report.selectedTests == ["Tests.Checkout/newTest()"])
}

@Test func recursiveGraphsTerminateAndFiltersEscapeRegexMetacharacters() throws {
    var graph = exampleGraph()
    graph.functions["tax"]!.dependencies = ["checkout"]
    #expect(graph.dependencyPath(from: ["testCheckout"], to: ["missing"]) == nil)
    let report = StaticSelector.select(current: graph, previous: nil, changes: [FileChange(path: "Package.swift")], baseRevision: "base")
    let filter = try #require(report.filter)
    let regex = try NSRegularExpression(pattern: filter)
    let correct = "Tests.Checkout/testCheckout"
    let wrong = "TestsXCheckout/testCheckoutExtra"
    #expect(regex.firstMatch(in: correct, range: NSRange(correct.startIndex..., in: correct)) != nil)
    #expect(regex.firstMatch(in: wrong, range: NSRange(wrong.startIndex..., in: wrong)) == nil)
}

@Test func parsesZeroLengthAndSingleLineDiffHunks() {
    let parsed = GitChanges.parseHunks("""
    @@ -2,0 +3,2 @@
    +new
    +new
    @@ -10 +12 @@
    -old
    +new
    @@ -20,2 +21,0 @@
    -gone
    -gone
    """, path: "Sources/Shop.swift")
    #expect(parsed.oldRegions == [region(10), region(20, 21)])
    #expect(parsed.newRegions == [region(3, 4), region(12)])
    #expect(!parsed.requiresFallback)
}

@Test func swiftTestingFiltersAcceptRuntimeSourceLocationSuffixes() throws {
    var graph = exampleGraph()
    graph.tests = ["Tests.Greetings/saysHello()": ["testGreeting"]]
    let report = StaticSelector.select(current: graph, previous: nil, changes: [FileChange(path: "Package.swift")], baseRevision: "base")
    let filter = try #require(report.filter)
    let regex = try NSRegularExpression(pattern: filter)
    for id in ["Tests.Greetings/saysHello()", "Tests.Greetings/saysHello()/Tests/Greeting.swift:12:6"] {
        #expect(regex.firstMatch(in: id, range: NSRange(id.startIndex..., in: id)) != nil)
    }
    let wrong = "Tests.Greetings/saysHelloExtra()/Tests/Greeting.swift:12:6"
    #expect(regex.firstMatch(in: wrong, range: NSRange(wrong.startIndex..., in: wrong)) == nil)
}

@Test func parsesSILLocationsCallbacksDispatchAndUncertainty() throws {
    let text = #"""
    // caller(), loc "/project/Sources/Shop.swift":1:1, scope 0
    // Isolation: unspecified
    sil hidden @caller : $@convention(thin) () -> () {
      %0 = function_ref @callback : $@convention(thin) () -> (), loc "/project/Sources/Shop.swift":2:4
      %1 = thin_to_thick_function %0 to $@callee_guaranteed () -> ()
      %2 = apply %1() : $@callee_guaranteed () -> (), loc "/project/Sources/Shop.swift":3:4
      return %2 : $(), loc "/project/Sources/Shop.swift":4:1
    } // end sil function 'caller'
    // callback(), loc "/project/Sources/Shop.swift":6:1, scope 1
    sil hidden @callback : $@convention(thin) () -> () {
      %0 = witness_method $T, #Price.value : $@convention(witness_method: Price) () -> ()
      %1 = apply %0() : $@convention(thin) () -> ()
      return %1 : $(), loc "/project/Sources/Shop.swift":8:1
    } // end sil function 'callback'
    sil_witness_table hidden RealPrice: Price module Shop {
      method #Price.value: <Self where Self : Price> (Self) -> () -> Int : @implementation
    }
    """#
    let parsed = SILParser.parse(text, module: "Shop", sourceRoot: URL(fileURLWithPath: "/project"))
    let caller = try #require(parsed.functions["caller"])
    #expect(caller.name == "caller()")
    #expect(caller.regions == [region(1, 4)])
    #expect(caller.dependencies == ["callback"])
    #expect(caller.uncertainties.isEmpty)
    #expect(parsed.functions["callback"]?.dynamicDeclarations == ["Price.value"])
    #expect(parsed.functions["callback"]?.uncertainties.isEmpty == false)
    #expect(parsed.dispatchTargets["Price.value"] == ["implementation"])
}

@Test func largeProcessOutputDoesNotDeadlock() throws {
    let output = try CommandRunner.run("/bin/sh", ["-c", "i=0; while [ $i -lt 5000 ]; do echo 'long standard output line'; echo 'long standard error line' >&2; i=$((i + 1)); done"], at: FileManager.default.temporaryDirectory)
    #expect(output.stdout.count > 65536)
    #expect(output.stderr.count > 65536)
}
