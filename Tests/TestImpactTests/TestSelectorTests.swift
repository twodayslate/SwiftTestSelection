// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: AGPL-3.0-only

import Testing
@testable import TestImpact

private let price = FunctionID(path: "Sources/Checkout.swift", symbol: "Shop.total()")
private let login = FunctionID(path: "Sources/Auth.swift", symbol: "Shop.login()")
private let baseline = CoverageBaseline(
    revision: "base", configuration: "macOS-debug",
    functionsByTest: ["checkout": [price], "receipt": [price], "login": [login]]
)
private let allTests: Set<String> = ["checkout", "receipt", "login"]

@Test func selectsEveryTestThatExecutedTheChangedFunction() {
    let result = TestSelector.select(
        availableTests: allTests, baseline: baseline,
        changes: ChangeSet(baseRevision: "base", configuration: "macOS-debug", changedFunctions: [price])
    )
    #expect(result.selectedTests == ["checkout", "receipt"])
    #expect(result.reasonsByTest["checkout"] == [.coversChangedFunction(price)])
    #expect(result.fullRunReasons.isEmpty)
}

@Test func includesNewAndModifiedTests() {
    let result = TestSelector.select(
        availableTests: allTests.union(["newTest"]), baseline: baseline,
        changes: ChangeSet(baseRevision: "base", configuration: "macOS-debug", changedTests: ["login"])
    )
    #expect(result.selectedTests == ["login", "newTest"])
    #expect(result.reasonsByTest["newTest"] == [.missingTestCoverage])
    #expect(result.reasonsByTest["login"] == [.testChanged])
}

@Test func noChangesSelectsNoMeasuredTests() {
    let result = TestSelector.select(
        availableTests: allTests, baseline: baseline,
        changes: ChangeSet(baseRevision: "base", configuration: "macOS-debug")
    )
    #expect(result.selectedTests.isEmpty)
    #expect(result.fullRunReasons.isEmpty)
}

@Test func missingBaselineRunsEverything() {
    let result = TestSelector.select(
        availableTests: allTests, baseline: nil,
        changes: ChangeSet(baseRevision: "base", configuration: "macOS-debug")
    )
    #expect(result.selectedTests == allTests.sorted())
    #expect(!result.fullRunReasons.isEmpty)
}

@Test(arguments: [
    ChangeSet(baseRevision: "different", configuration: "macOS-debug"),
    ChangeSet(baseRevision: "base", configuration: "iOS-debug"),
    ChangeSet(baseRevision: "base", configuration: "macOS-debug", unresolvedReasons: ["Package.swift changed"]),
    ChangeSet(baseRevision: "base", configuration: "macOS-debug", changedFunctions: [
        FunctionID(path: "Sources/New.swift", symbol: "Shop.newFunction()")
    ])
])
func uncertaintyRunsEverything(changes: ChangeSet) {
    let result = TestSelector.select(availableTests: allTests, baseline: baseline, changes: changes)
    #expect(result.selectedTests == allTests.sorted())
    #expect(!result.fullRunReasons.isEmpty)
}

@Test func deletedTestsAreNotScheduled() {
    let result = TestSelector.select(
        availableTests: ["checkout", "login"], baseline: baseline,
        changes: ChangeSet(baseRevision: "base", configuration: "macOS-debug", changedFunctions: [price])
    )
    #expect(result.selectedTests == ["checkout"])
}
