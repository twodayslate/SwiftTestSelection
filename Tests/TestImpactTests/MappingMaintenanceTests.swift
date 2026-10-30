// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
import Foundation
import Testing
@testable import TestImpact

private func maintenanceGraph(value: Int = 1) -> XcodeTestGraph {
    let files = ["App.swift": "func checkout() -> Int { shared() + \(value) }\nfunc shared() -> Int { 1 }",
                 "UI.swift": "import XCTest\nfinal class Checkout: XCTestCase { func testBuy() {} }\nfinal class Login: XCTestCase { func testLogin() {} }\nfinal class NewSuite: XCTestCase { func testNew() {} }"]
    var graph = XcodeTestGraph(targets: [.init(name: "App", productType: "com.apple.product-type.application", sourceFiles: ["App.swift"]),
        .init(name: "UI", productType: "com.apple.product-type.bundle.ui-testing", sourceFiles: ["UI.swift"])],
        tests: ["UI/Checkout/testBuy()", "UI/Login/testLogin()", "UI/NewSuite/testNew()"])
    graph.modules = ["App": "App", "UI": "UI"]
    var dependencies = DependencyGraph()
    dependencies.compilerImplicitImports = ["App": [], "UI": []]
    for (path, text) in files {
        let module = path == "App.swift" ? "App" : "UI"
        let source = SwiftSourceSnapshot.parse(text, path: path, module: module)
        graph.sources[module + ":" + path] = source
        for unit in source.units where unit.kind == "function" {
            let name = module == "App" ? (unit.region.startLine == 1 ? "checkout()" : "shared()") : unit.scope + "." + unit.helperCallableName! + "()"
            let id = module + "." + name
            dependencies.functions[id] = .init(id: id, module: module, name: name, regions: [unit.region], dependencies: name == "checkout()" ? ["App.shared()"] : [])
        }
    }
    for test in graph.tests {
        let parts = test.split(separator: "/")
        dependencies.tests[test] = ["UI." + parts[1] + "." + parts[2]]
    }
    graph.dependencies = dependencies
    graph.mappings = .init(fixtures: ["checkout": ["UI/Checkout"]], features: [
        .init(name: "checkout", symbols: ["App.checkout()"], fixtures: ["checkout"]),
        .init(name: "authentication", symbols: ["App.shared()"], tests: ["UI/Login"], dependsOn: ["checkout"])
    ], runtimeDependencyPolicy: .declared)
    return graph
}

@Test func mappingMaintenanceRepairsStaleEntriesAndPreservesPolicies() throws {
    var graph = maintenanceGraph()
    graph.mappings!.features[0].symbols = ["App.checkout()", "App.oldName()"]
    let audit = MappingMaintenance.inspect(graph)
    #expect(!audit.valid)
    #expect(audit.rules.first { $0.name == "checkout" }?.unresolvedEntries == ["symbols: App.oldName()"])
    #expect(audit.unmappedUITests == ["UI/NewSuite/testNew()"])
    var proposed = graph.mappings!
    proposed.features[0].symbols = ["App.checkout()"]
    proposed.features.append(.init(name: "new-suite", symbols: ["App.shared()"], tests: ["UI/NewSuite"]))
    let review = MappingMaintenance.review(current: graph, proposed: proposed)
    #expect(review.proposed?.valid == true)
    #expect(review.proposed?.unmappedUITests.isEmpty == true)
    #expect(review.preview == nil)
    #expect(graph.mappings!.features.count == 2)
    #expect(proposed.runtimeDependencyPolicy == graph.mappings!.runtimeDependencyPolicy)
    #expect(proposed.fixtures == graph.mappings!.fixtures)
    #expect(proposed.features[1].dependsOn == graph.mappings!.features[1].dependsOn)
    _ = try JSONDecoder().decode(MappingMaintenance.self, from: JSONEncoder().encode(review))
}

@Test func mappingMaintenancePreviewsWideningNarrowingAndExplainsSharedPaths() throws {
    var base = maintenanceGraph(), head = maintenanceGraph(value: 2)
    let newSuite = UIFeatureMappings.Feature(name: "new-suite", symbols: ["App.shared()"], tests: ["UI/NewSuite"])
    base.mappings!.features.append(newSuite)
    head.mappings!.features.append(newSuite)
    var broad = head.mappings!
    broad.features[0].tests = ["UI"]
    let changes = [FileChange(path: "App.swift")]
    let widened = try #require(MappingMaintenance.review(current: head, proposed: broad, previous: base, changes: changes).preview)
    #expect(widened.addedTests == ["UI/NewSuite/testNew()"])
    #expect(widened.removedTests.isEmpty)
    #expect(widened.after.explanations.contains { $0.kind == "explicitMapping" })
    var broadHead = head; broadHead.mappings = broad
    let narrowed = try #require(MappingMaintenance.review(current: broadHead, proposed: head.mappings, previous: base, changes: changes).preview)
    #expect(narrowed.removedSuites == ["UI/NewSuite"])
    #expect(MappingMaintenance.inspect(broadHead).suggestions.contains { $0.contains("75%") })
    #expect(MappingMaintenance.inspect(broadHead).suggestions.contains { $0.contains("overlaps") })
    // An unresolved operand is preserved in the real selector's condition output.
    var condition = head.mappings!
    condition.version = 2
    condition.features[0] = .init(name: "checkout", tests: ["UI/Checkout"], when: .all([.symbolChanged("App.checkout()"), .symbolChanged("App.missing()")]))
    let uncertain = MappingMaintenance.review(current: head, proposed: condition, previous: base, changes: changes)
    #expect(uncertain.proposed?.valid == false)
    #expect(uncertain.preview?.after.uiConditionDecisions?.isEmpty == false)
    #expect(uncertain.preview?.newFallbacks.isEmpty == false)
}
