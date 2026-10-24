// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import Testing
@testable import TestImpact

private let checkoutID = "CheckoutUITests/CheckoutUITests/testCheckoutScreen()"
private let greetingID = "GreetingUITests/GreetingUITests/testGreetingScreen()"

private func uiGraph() -> XcodeTestGraph {
    XcodeTestGraph(targets: [
        XcodeTarget(name: "App", productType: "com.apple.product-type.application", sourceFiles: ["App.swift"]),
        XcodeTarget(name: "CheckoutUITests", productType: "com.apple.product-type.bundle.ui-testing", sourceFiles: ["Checkout.swift", "Shared.swift"]),
        XcodeTarget(name: "GreetingUITests", productType: "com.apple.product-type.bundle.ui-testing", sourceFiles: ["Greeting.swift", "Shared.swift"])
    ], tests: [checkoutID, greetingID])
}

@Test func uiTestSourceChangesSelectOwningTargets() {
    let graph = uiGraph()
    for (path, expected) in [("Checkout.swift", [checkoutID]), ("Shared.swift", [checkoutID, greetingID])] {
        let report = XcodeSelector.select(current: graph, previous: graph, changes: [FileChange(path: path)], baseRevision: "base")
        #expect(report.selectedTests == expected)
        #expect(report.fullRunReasons.isEmpty)
    }
}

@Test func uiAppResourceAndUnclassifiedChangesSelectEveryTest() {
    let graph = uiGraph()
    for path in ["App.swift", "Assets.xcassets/Contents.json", "Unknown.swift", "Project.xcodeproj/project.pbxproj"] {
        let report = XcodeSelector.select(current: graph, previous: graph, changes: [FileChange(path: path)], baseRevision: "base")
        #expect(report.selectedTests == graph.tests)
        #expect(!report.fullRunReasons.isEmpty)
    }
    var sharedWithApp = graph
    sharedWithApp.targets[0].sourceFiles.insert("Checkout.swift")
    let report = XcodeSelector.select(current: sharedWithApp, previous: graph, changes: [FileChange(path: "Checkout.swift")], baseRevision: "base")
    #expect(report.selectedTests == graph.tests)
    #expect(!report.fullRunReasons.isEmpty)
}

@Test func uiSelectionRetainsPreviousFileOwnership() {
    let previous = uiGraph()
    var current = previous
    current.targets[1].sourceFiles.remove("Checkout.swift")
    let report = XcodeSelector.select(current: current, previous: previous, changes: [FileChange(path: "Checkout.swift")], baseRevision: "base")
    #expect(report.selectedTests == [checkoutID])
    #expect(report.fullRunReasons.isEmpty)
}

@Test func uiSelectionIncludesNewTestsAndExcludesDeletedOnes() {
    let previous = uiGraph()
    var current = previous
    current.tests = [checkoutID, "GreetingUITests/GreetingUITests/testNew()"]
    let report = XcodeSelector.select(current: current, previous: previous, changes: [FileChange(path: "Checkout.swift")], baseRevision: "base")
    #expect(report.selectedTests == current.tests)
    #expect(!report.selectedTests.contains(greetingID))
}

@Test func uiMissingOwnershipOrBaseFallsBack() {
    let graph = uiGraph()
    var incomplete = graph
    incomplete.diagnostics = ["Missing test target source ownership"]
    for previous in [nil, incomplete] as [XcodeTestGraph?] {
        let report = XcodeSelector.select(current: graph, previous: previous, changes: [FileChange(path: "Checkout.swift")], baseRevision: "base")
        #expect(report.selectedTests == graph.tests)
        #expect(!report.fullRunReasons.isEmpty)
    }
}

@Test func uiEmptySelectionDoesNotInvokeXcode() throws {
    let graph = uiGraph()
    let report = XcodeSelector.select(current: graph, previous: graph, changes: [], baseRevision: "base")
    #expect(report.selectedTests.isEmpty)
    let configuration = XcodeConfiguration(container: .project, path: URL(fileURLWithPath: "/nonexistent.xcodeproj"), scheme: "App", destination: "platform=macOS")
    #expect(try XcodeAnalysis(options: configuration).run(report) == 0)
}

@Test func xcodeEnumerationUsesEnabledLeafIdentifiersAcrossPlans() throws {
    let json = #"{"errors":[],"values":[{"enabledTests":[{"identifier":"UI/Suite/testA()"}],"disabledTests":[{"identifier":"UI/Suite/testDisabled()"}]},{"enabledTests":[{"identifier":"UI/Suite/testB()"},{"identifier":"UI/Suite/testA()"}]}]}"#
    #expect(try XcodeTestEnumeration.parse(Data(json.utf8)) == ["UI/Suite/testA()", "UI/Suite/testB()"])
}

@Test func xcodeEnumerationRejectsIncompleteDiscoveryEvenWithSuccessfulExit() {
    for json in [
        #"{"errors":["Timed out while enabling automation mode"],"values":[{"enabledTests":[{"identifier":"UI/Suite/testA()"}]}]}"#,
        #"{"errors":[],"values":[{"enabledTests":[{"identifier":"UI"}]}]}"#,
        #"{"errors":[],"values":[{"enabledTests":[]}]}"#
    ] {
        #expect(throws: ImpactError.self) { try XcodeTestEnumeration.parse(Data(json.utf8)) }
    }
}

@Test func xcodeExecutionPreservesConfigurationAndLiteralTestIDs() throws {
    let temporary = FileManager.default.temporaryDirectory
    for container in [XcodeConfiguration.Container.project, .workspace] {
        let configuration = XcodeConfiguration(container: container, path: temporary.appendingPathComponent("App with spaces"), scheme: "UI Scheme", destination: "platform=iOS Simulator,name=iPhone 17 Pro", configuration: "Debug", testPlan: "Smoke Tests")
        let args = try configuration.executionArguments(tests: [checkoutID], derivedData: temporary, resultBundle: temporary.appendingPathComponent("results.xcresult"))
        #expect(args.first == "test")
        #expect(args.contains("-" + container.rawValue))
        #expect(args.contains("Smoke Tests"))
        #expect(args.contains(configuration.destination))
        #expect(args.last == "-only-testing:" + checkoutID)
        #expect(throws: ImpactError.self) { try configuration.executionArguments(tests: [], derivedData: temporary, resultBundle: temporary) }
        #expect(throws: ImpactError.self) { try configuration.executionArguments(tests: ["CheckoutUITests"], derivedData: temporary, resultBundle: temporary) }
    }
}

@Test func xcodeSourceListsDecodeEscapedAndQuotedPaths() throws {
    let input = #"""
    /tmp/App\ with\ spaces/Sources/File.swift
    "/tmp/Quoted App/Tests.swift"
    /tmp/Back\\slash/Tests.swift
    /tmp/A\'postrophe/Tests.swift
    """#
    #expect(try XcodeSourceFileList.parse(input) == [
        "/tmp/App with spaces/Sources/File.swift", "/tmp/Quoted App/Tests.swift",
        #"/tmp/Back\slash/Tests.swift"#, "/tmp/A'postrophe/Tests.swift"
    ])
    #expect(throws: ImpactError.self) { try XcodeSourceFileList.parse("\"unfinished path") }
}
