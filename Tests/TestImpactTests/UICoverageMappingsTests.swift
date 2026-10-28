// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation
import Testing
@testable import TestImpact

private let sharing = "UI/Sharing/testScreen()"
private let notes = "UI/Notes/testScreen()"
private let coverageDevice = UICoverageTestResults.Device(deviceId: "test", deviceName: "Phone",
    architecture: "arm64", modelName: "iPhone 17 Pro", platform: "iOS Simulator", osVersion: "26.5", osBuildNumber: "23F77")

private func coverageGraph() -> XcodeTestGraph {
    let paths = ["App/Sharing.swift", "App/Notes.swift", "App/Common.swift"]
    var graph = XcodeTestGraph(targets: [
        .init(name: "App", productType: "com.apple.product-type.application", sourceFiles: Set(paths)),
        .init(name: "UI", productType: "com.apple.product-type.bundle.ui-testing", sourceFiles: ["UITests.swift"])
    ], tests: [sharing, notes])
    graph.dependencies = DependencyGraph(functions: Dictionary(uniqueKeysWithValues: paths.map { path in
        (path, FunctionNode(id: path, module: "App", name: path, regions: [.init(path: path, startLine: 1, endLine: 10)]))
    }))
    for path in paths { graph.sources["App:" + path] = SwiftSourceSnapshot.parse("func title() -> String { \"Title\" }", path: path, module: "App") }
    graph.buildArtifact = XcodeBuildArtifact(revision: "revision", context: ["destination": "platform=iOS Simulator,id=test", "configuration": "Debug"],
        toolchain: "Swift 6", buildLogDigest: "log", buildSettingsDigest: "settings", productsDirectory: "/build",
        xctestrun: "App.xctestrun", products: ["App.app/App": "digest"])
    return graph
}

private func session(_ graph: XcodeTestGraph, test: String = sharing, path: String = "Sharing") throws -> UICoverageArtifact.Session {
    .init(id: path, identity: try UICoverageMappings.identity(for: graph), sourceRoot: "/repo", enabledTests: graph.tests,
          selectedSuites: [test.split(separator: "/").prefix(2).joined(separator: "/")], appTargets: ["App"], resultBundle: path + ".xcresult", status: "complete",
          testResults: .init(devices: [coverageDevice], testNodes: [.init(nodeType: "Test Case", name: "testScreen()", nodeIdentifier: test, result: "Passed")]),
          coverage: .init(targets: [.init(name: "App", executableLines: 20, files: [path, "Common"].map {
              .init(path: "/repo/App/" + $0 + ".swift", functions: [.init(name: "title()", lineNumber: 2, executionCount: 1)])
          })]))
}

private func propose(_ graph: XcodeTestGraph, _ sessions: [UICoverageArtifact.Session], existing: UIFeatureMappings? = nil) throws -> UICoverageProposal {
    try UICoverageMappings.propose(graph: graph, artifact: .init(schemaVersion: 1, sessions: sessions), existing: existing)
}

@Test func coverageIsolatedSuitesRetainSharedDependencyAndApplyOffline() throws {
    var graph = coverageGraph()
    let result = try propose(graph, [session(graph), session(graph, test: notes, path: "Notes")])
    #expect(result.validationPassed)
    #expect(result.additions.count == 3)
    #expect(result.additions.first { $0.sources == ["App/Common.swift"] }?.tests == ["UI/Notes", "UI/Sharing"])
    #expect(result.additions.first { $0.sources == ["App/Sharing.swift"] }?.tests == ["UI/Sharing"])
    #expect(result.evidence.allSatisfy { $0.attribution == "isolatedSuite" && !$0.expansion.isEmpty })
    #expect(result.unmappedSuites.isEmpty)
    #expect(result.mappings.runtimeDependencyPolicy == nil)
    try result.mappings.validate()
    graph.mappings = result.mappings
    // Only the selection configuration survives; no coverage file is consulted.
    let previous = graph
    graph.sources["App:App/Common.swift"] = SwiftSourceSnapshot.parse("func title() -> String { \"Changed\" }", path: "App/Common.swift", module: "App")
    let selected = XcodeSelector.select(current: graph, previous: previous, changes: [.init(path: "App/Common.swift")], baseRevision: "base")
    #expect(selected.selectedTests == [notes, sharing])
}

@Test func coverageRejectsAggregateWithoutExecutionEvidenceAndLabelsCoarseReports() throws {
    let graph = coverageGraph()
    var combined = try session(graph)
    combined.testResults = nil
    #expect(try propose(graph, [combined]).diagnostics.contains { $0.code == "missing_execution_evidence" })
    combined.testResults = .init(devices: [coverageDevice], testNodes: [sharing, notes].map { .init(nodeType: "Test Case", name: "test", nodeIdentifier: $0, result: "Passed") })
    combined.selectedSuites = ["UI/Sharing", "UI/Notes"]
    let result = try propose(graph, [combined])
    #expect(result.evidence.allSatisfy { $0.attribution == "coarseMultipleSuites" && $0.suites.count == 2 })
    #expect(result.diagnostics.contains { $0.code == "coarse_multi_suite_attribution" })
    combined.selectedSuites = ["UI/Sharing"]
    #expect(try propose(graph, [combined]).additions.isEmpty)
}

@Test func coverageDiagnosesIncompleteFailedCrashedAndPartialSuites() throws {
    var graph = coverageGraph()
    for status in ["incomplete", "failed", "crashed"] {
        var value = try session(graph); value.status = status
        let result = try propose(graph, [value])
        #expect(result.additions.isEmpty)
        #expect(result.diagnostics.contains { $0.code == "collection_" + status })
    }
    graph.tests.append("UI/Sharing/testOther()")
    #expect(try propose(graph, [session(graph)]).diagnostics.contains { $0.code == "partial_suite_execution" })
}

@Test func coverageRejectsIncompatibleIdentityAndInventories() throws {
    let graph = coverageGraph()
    for field in ["revision", "sourceIdentity", "buildIdentity", "toolchain", "configuration", "destination", "graphID"] {
        var value = try session(graph); value.identity[field] = "other"
        let result = try propose(graph, [value])
        #expect(result.additions.isEmpty)
        #expect(result.diagnostics.contains { $0.code == "incompatible_artifact" && $0.message.contains(field) })
    }
    var value = try session(graph); value.enabledTests = [sharing]
    #expect(try propose(graph, [value]).additions.isEmpty)
}

@Test func coverageDistinguishesAbsentRunnerOnlyAndMeasuredEmpty() throws {
    let graph = coverageGraph()
    var value = try session(graph); value.coverage = nil
    #expect(try propose(graph, [value]).diagnostics.contains { $0.code == "coverage_unavailable" })
    value = try session(graph); value.coverage!.targets[0].name = "UI"
    #expect(try propose(graph, [value]).diagnostics.contains { $0.code == "missing_app_instrumentation" })
    value = try session(graph)
    for index in value.coverage!.targets[0].files.indices { value.coverage!.targets[0].files[index].functions[0].executionCount = 0 }
    let result = try propose(graph, [value])
    #expect(result.additions.isEmpty)
    #expect(result.diagnostics.contains { $0.code == "measured_empty" })
    #expect(!result.diagnostics.contains { $0.code == "missing_app_instrumentation" })
}

@Test func coveragePreservesUserMappingsAndPolicyAndIsIdempotent() throws {
    let graph = coverageGraph()
    var existing = UIFeatureMappings(features: [.init(name: "user", sources: ["NeverObserved.swift"], tests: ["UI/Notes"])], runtimeDependencyPolicy: .declared)
    existing.sourceLocationPolicy = .diagnostic
    let result = try propose(graph, [session(graph)], existing: existing)
    #expect(result.mappings.features.first?.name == "user")
    #expect(result.mappings.features.first?.sources == ["NeverObserved.swift"])
    #expect(result.mappings.runtimeDependencyPolicy == .declared)
    #expect(result.mappings.sourceLocationPolicy == .diagnostic)
    let repeated = try propose(graph, [session(graph)], existing: result.mappings)
    #expect(repeated.additions.isEmpty)
    #expect(repeated.mappings.features.count == result.mappings.features.count)
}

@Test func coverageNormalizesPathsAndDiagnosesGeneratedExternalAndAmbiguousFunctions() throws {
    var graph = coverageGraph()
    graph.dependencies!.functions["another"] = .init(id: "another", module: "App", name: "overload", regions: [.init(path: "App/Sharing.swift", startLine: 1, endLine: 10)])
    var value = try session(graph)
    value.coverage!.targets[0].files += ["/repo/../outside.swift", "/repo/Generated.swift", "/repo-other/File.swift"].map {
        .init(path: $0, functions: [.init(name: "generated", lineNumber: 1, executionCount: 1)])
    }
    value.coverage!.targets[0].files[0].path = "/repo/App/../App/Sharing.swift"
    let result = try propose(graph, [value])
    #expect(result.diagnostics.contains { $0.code == "ambiguous_compiler_identity" })
    #expect(result.diagnostics.filter { $0.code == "external_source" }.count == 2)
    #expect(result.diagnostics.contains { $0.code == "generated_or_unowned_source" })
    #expect(result.additions.allSatisfy { ($0.symbols ?? []).isEmpty })
}

@Test func coverageRejectsFailedUnknownAndSkippedResultEvidence() throws {
    let graph = coverageGraph()
    for status in ["Failed", "Skipped", "unknown", "Expected Failure"] {
        var value = try session(graph); value.testResults!.testNodes[0].result = status
        #expect(try propose(graph, [value]).diagnostics.contains { $0.code == "unsuccessful_or_unknown_tests" })
    }
}

@Test func coveragePlanUsesOneExecutionPerSuiteAndReusesBuild() throws {
    var graph = coverageGraph(); graph.tests.append("UI/Sharing/testOther()")
    let plan = try UICoverageMappings.plan(graph: graph, suites: ["UI/Sharing", "UI/Notes"], appTargets: ["App"])
    #expect(plan.executions.count == 2)
    #expect(plan.executions.first { $0.suite == "UI/Sharing" }?.expectedTests.count == 2)
    #expect(plan.executions.allSatisfy { $0.arguments.first == "test-without-building" && $0.arguments.contains(plan.xctestrun) })
    #expect(throws: ImpactError.self) { try UICoverageMappings.plan(graph: graph, suites: [sharing], appTargets: ["App"]) }
    #expect(throws: ImpactError.self) { try UICoverageMappings.plan(graph: graph, suites: ["UI/Sharing"], appTargets: ["UI"]) }
}

@Test func coverageUnderstandsXcodeBundleAndTestResultNames() throws {
    let graph = coverageGraph()
    var value = try session(graph)
    value.coverage!.targets[0].name = "App.app"
    value.testResults = .init(devices: [coverageDevice], testNodes: [.init(nodeType: "Test Plan", name: "All tests", children: [
        .init(nodeType: "UI test bundle", name: "UI.xctest", children: [
            .init(nodeType: "Test Suite", name: "Sharing", children: [
                .init(nodeType: "Test Case", name: "testScreen()", nodeIdentifier: "Sharing/testScreen()", result: "Passed")
            ])
        ])
    ])])
    #expect(try propose(graph, [value]).additions.count == 2)
}

@Test func coverageUnresolvedLocationsAreNeverExactSymbolsAndInvalidBoundariesFailValidation() throws {
    var graph = coverageGraph()
    var value = try session(graph)
    value.coverage!.targets[0].files[0].functions[0].lineNumber = 100
    let result = try propose(graph, [value])
    #expect(result.diagnostics.contains { $0.code == "unresolved_compiler_identity" })
    #expect(result.evidence.first { $0.path == "App/Sharing.swift" }?.compilerCandidates.isEmpty == true)
    #expect(result.validationPassed)
    graph.dependencies!.functions.removeValue(forKey: "App/Sharing.swift")
    #expect(try propose(graph, [value]).validationPassed == false)
}

@Test func coverageEmptyArtifactRetainsMappingsAndReportsUnmappedSuites() throws {
    let graph = coverageGraph()
    let existing = UIFeatureMappings(features: [.init(name: "manual", sources: ["App/Sharing.swift"], tests: ["UI/Sharing"])])
    let result = try propose(graph, [], existing: existing)
    #expect(result.additions.isEmpty)
    #expect(result.mappings.features.count == 1)
    #expect(result.unmappedSuites == ["UI/Notes", "UI/Sharing"])
    #expect(!result.diagnostics.contains { $0.code == "measured_empty" })
}


@Test func coverageRejectsEveryIncompleteTestCaseWithoutLosingOtherSuites() throws {
    let graph = coverageGraph()
    for malformed in [
        UICoverageTestResults.Node(nodeType: "Test Case", name: "notes", nodeIdentifier: notes),
        .init(nodeType: "Test Case", name: "notes", result: "Failed"),
        .init(nodeType: "Test Case", name: "notes", nodeIdentifier: "", result: "Passed"),
        .init(nodeType: "Test Case", name: "notes", nodeIdentifier: notes, result: ""),
        .init(nodeType: "Test Case", name: "notes", nodeIdentifier: "UI//notes", result: "Passed")
    ] {
        var value = try session(graph)
        // The second suite's coverage cannot become isolated Sharing evidence
        // just because its test-case record cannot be decoded into an execution.
        value.coverage!.targets[0].files.append(.init(path: "/repo/App/Notes.swift",
            functions: [.init(name: "notes()", lineNumber: 2, executionCount: 1)]))
        value.testResults!.testNodes.append(.init(nodeType: "Test Suite", name: "Notes", children: [malformed]))
        let result = try propose(graph, [value])
        #expect(!result.validationPassed)
        #expect(result.additions.isEmpty && result.evidence.isEmpty)
        #expect(result.diagnostics.contains { $0.code == "invalid_execution_evidence" && $0.severity == "error" })
    }
}

@Test func coverageRejectsMissingAndMultipleResultDestinations() throws {
    let graph = coverageGraph()
    for devices in [nil, [], [coverageDevice, coverageDevice]] as [[UICoverageTestResults.Device]?] {
        var value = try session(graph); value.testResults!.devices = devices
        let result = try propose(graph, [value])
        #expect(!result.validationPassed && result.additions.isEmpty)
        #expect(result.diagnostics.contains { $0.code == "invalid_destination_evidence" })
    }
}

@Test func coverageValidatesDeclaredDestinationFields() throws {
    for destination in ["platform=iOS Simulator,id=test", "platform=iOS Simulator,name=Phone,OS=26.5,arch=arm64"] {
        var graph = coverageGraph(); graph.buildArtifact!.context["destination"] = destination
        let good = try session(graph)
        #expect(try propose(graph, [good]).validationPassed)
        for field in ["platform", "id", "name", "OS", "arch"] where destination.contains(field + "=") {
            var value = good
            switch field {
            case "id": value.testResults!.devices![0].deviceId = "another-device"
            case "platform": value.testResults!.devices![0].platform = "macOS"
            case "name": value.testResults!.devices![0].deviceName = "Other phone"
            case "OS": value.testResults!.devices![0].osVersion = "99.0"
            default: value.testResults!.devices![0].architecture = "x86_64"
            }
            let result = try propose(graph, [value])
            #expect(!result.validationPassed && result.additions.isEmpty)
            #expect(result.diagnostics.contains { $0.code == "incompatible_destination" })
        }
    }
}

@Test func coverageRetainsDeviceEvidenceAndRejectsIncompatibleSessions() throws {
    let graph = coverageGraph()
    let first = try session(graph)
    var second = try session(graph, test: notes, path: "Notes")
    second.testResults!.devices![0].osVersion = "99.0"
    let result = try propose(graph, [first, second])
    #expect(!result.validationPassed)
    #expect(result.diagnostics.contains { $0.code == "incompatible_destination" })
    let encoded = try JSONEncoder().encode(result)
    let decoded = try JSONDecoder().decode(UICoverageProposal.self, from: encoded)
    #expect(decoded.provenance[0].testResults?.devices == [coverageDevice])
    #expect(decoded.provenance[1].testResults?.devices?[0].osVersion == "99.0")
}

@Test func coverageAcceptsLatestAndEquivalentOSVersions() throws {
    for os in ["latest", "26.5.0"] {
        var graph = coverageGraph(); graph.buildArtifact!.context["destination"] = "platform=iOS Simulator,id=TEST,OS=" + os
        #expect(try propose(graph, [session(graph)]).validationPassed)
    }
}

@Test func coverageRunsStrictSymbolValidationOnPreservedMappings() throws {
    let graph = coverageGraph()
    let valid = UIFeatureMappings(features: [.init(name: "manual", symbols: ["App.App/Sharing.swift"], tests: ["UI/Sharing"])])
    #expect(try propose(graph, [session(graph)], existing: valid).validationPassed)
    var invalid = valid; invalid.features[0].symbols!.append("App.missing")
    let result = try propose(graph, [session(graph)], existing: invalid)
    #expect(!result.validationPassed)
    #expect(result.mappingValidationDiagnostics.count == 1)
    #expect(result.mappingValidationDiagnostics.first?.code == "unresolved_mapping_symbol")
    #expect(result.mappingValidationDiagnostics.first?.pattern == "App.missing")
    #expect(result.diagnostics.contains { $0.code == "strict_mapping_validation_failed" })
    #expect(result.mappings.features[0].symbols == invalid.features[0].symbols)
}

@Test func coverageDoesNotReplaceDiscardedInvalidMappingsUnlessExplicitlySupplied() throws {
    for legacy in [false, true] {
        var graph = coverageGraph()
        if legacy { graph.diagnostics.append("Invalid UI mappings: invalid JSON") }
        else { graph.mappingLoadError = "invalid JSON" }
        let result = try propose(graph, [session(graph)])
        #expect(!result.validationPassed)
        #expect(result.mappingValidationDiagnostics.first?.code == "invalid_mapping_file")
        let repaired = try propose(graph, [session(graph)], existing: UIFeatureMappings(features: []))
        #expect(repaired.validationPassed)
    }
}


@Test func coverageRejectsIncompleteNestedTestCaseEvidence() throws {
    let graph = coverageGraph()
    var value = try session(graph)
    value.testResults!.testNodes[0].children = [.init(nodeType: "Test Case", name: "incomplete", result: "Failed")]
    let result = try propose(graph, [value])
    #expect(!result.validationPassed && result.additions.isEmpty)
    #expect(result.diagnostics.contains { $0.code == "invalid_execution_evidence" })
}
