// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
import Foundation
import Testing
@testable import TestImpact

private let formattingBefore = """
import XCTest
@MainActor final class Suite: XCTestCase {
    func testConsumer() { let value: String? = "ready"; XCTAssertEqual(value, "ready"); candidate() }
    func testSecondConsumer() { candidate() }
    private func candidate() { XCTAssertTrue(true) }
}
@MainActor final class Other: XCTestCase {
    func testOther() { XCTAssertTrue(true) }
}
"""
private let formattingAfter = formattingBefore.replacingOccurrences(of: "private func candidate() { XCTAssertTrue(true) }", with: "private func candidate() { XCTAssertTrue(true); XCTAssertFalse(false) }")
private let formattingTests = ["UI/Suite/testConsumer()", "UI/Suite/testSecondConsumer()", "UI/Other/testOther()"]

func reviewedFormattingContract(_ boundary: FormattingBoundary, current: XcodeTestGraph,
                                source: XcodeHeadOnlySources, baseRevision: String = "base", id: String = "optional-string-formatting") throws -> HelperFormattingContract {
    let unit = try #require(current.sources.values.flatMap(\.units).first { $0.key == boundary.helper })
    let symbols = current.dependencies!.functions.values.filter { node in
        node.module == String(unit.key.prefix { $0 != ":" }) && node.regions.contains {
            $0.path == unit.region.path && $0.startLine >= unit.region.startLine && $0.endLine <= unit.region.endLine
        }
    }.sorted { $0.id < $1.id }
    let symbol = try #require(symbols.first { !$0.name.contains("closure") } ?? symbols.first)
    return .init(id: id, helper: boundary.helper, helperSymbol: symbol.id,
        producer: boundary.producer, producerSymbol: boundary.producerSymbol,
        assertionSymbol: boundary.assertionSymbol, substitutions: boundary.substitutions,
        baseRevision: baseRevision,
        baseSources: HelperFormattingContracts.fingerprint(source.base, unowned: source.unownedBaseSources),
        headSources: HelperFormattingContracts.fingerprint(current.sources),
        toolchain: current.buildArtifact?.toolchain ?? current.dependencies!.toolchain,
        buildContext: HelperFormattingContracts.buildContext(current), guarantees: HelperFormattingContract.requiredGuarantees,
        rationale: "Reviewed fixture: Optional<String> contains only a literal string; no project formatting/reflection conformances, state mutation, resources, callback registration or receiver production. XCTest reports failure only to the invoking test.")
}

// Synthetic provenance for compiled selector fixtures; product verification is
// covered separately by retained-build tests and the real-capture replay.
private func formattingArtifact(toolchain: String) -> XcodeBuildArtifact {
    var artifact = XcodeBuildArtifact(revision: "head", context: ["configuration": "Debug", "sdkAndArchitecture": "macosx|arm64"],
          toolchain: toolchain, buildLogDigest: "fixture-compiler-invocations", buildSettingsDigest: "fixture-settings",
          productsDirectory: "/tmp/formatting-fixture", xctestrun: "Tests.xctestrun", products: [:])
    artifact.helperFormattingBuild = .init(fingerprint: "fixture-effective-build-inputs", buildLogDigest: artifact.buildLogDigest, buildSettingsDigest: artifact.buildSettingsDigest)
    return artifact
}

private func formattingFixture(assertion: String? = nil) throws -> (URL, XcodeTestGraph, XcodeHeadOnlySources, HelperFormattingContract) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("formatting-contract-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let before = assertion.map { formattingBefore.replacingOccurrences(of: "let value: String? = \"ready\"; XCTAssertEqual(value, \"ready\")", with: "let value: CGFloat = 1; " + $0 + "(value, CGFloat(0))") } ?? formattingBefore
    let after = before.replacingOccurrences(of: "private func candidate() { XCTAssertTrue(true) }", with: "private func candidate() { XCTAssertTrue(true); XCTAssertFalse(false) }")
    var current = try boundaryGraph(["UI.swift": after], tests: formattingTests, root: root)
    current.dependencies!.toolchain = try CommandRunner.run("xcrun", ["swiftc", "--version"], at: root).text
    current.buildArtifact = formattingArtifact(toolchain: current.dependencies!.toolchain)
    let source = XcodeHeadOnlySources(base: ["UI:UI.swift": .parse(before, path: "UI.swift", module: "UI")], mappings: current.mappings)
    let baseline = XcodeHeadOnlySelector.select(current: current, source: source, changes: [.init(path: "UI.swift")], baseRevision: "base")
    try #require(baseline.selectedTests == formattingTests.sorted())
    let boundary = try #require(baseline.formattingBoundaries?.first, "\(baseline.diagnostics)")
    return (root, current, source, try reviewedFormattingContract(boundary, current: current, source: source))
}

@Test func reviewedFormattingPreservesEveryKnownConsumerAndReportsPreview() throws {
    let (root, fixture, source, contract) = try formattingFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    var current = fixture
    current.mappings!.helperFormattingContracts = [contract]
    let report = XcodeHeadOnlySelector.select(current: current, source: source, changes: [.init(path: "UI.swift")], baseRevision: "base")
    #expect(report.selectedTests == Array(formattingTests.prefix(2)).sorted(), "\(report.diagnostics)")
    #expect(report.diagnostics.isEmpty)
    #expect(report.helperContractDecisions?.first?.status == "discharged")
    #expect(report.helperContractPreview?.removed == [formattingTests[2]])
    #expect(report.helperContractPreview?.added == [])
    for test in formattingTests.prefix(2) { #expect(report.explanations.contains { $0.test == test && $0.kind == "dependency" }) }
    // Compiler evidence contradicting a handwritten expectation still wins.
    let helper = contract.helperSymbol
    let rootID = try #require(current.dependencies!.tests[formattingTests[2]]?.first)
    current.dependencies!.functions[rootID]!.dependencies.insert(helper)
    let contradicted = XcodeHeadOnlySelector.select(current: current, source: source, changes: [.init(path: "UI.swift")], baseRevision: "base")
    #expect(contradicted.selectedTests == formattingTests.sorted())
    #expect(contradicted.explanations.contains { $0.test == formattingTests[2] && $0.kind == "dependency" })
}

@Test func formattingContractsRejectStaleAmbiguousAndIncompleteEvidence() throws {
    let (root, fixture, source, contract) = try formattingFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    for kind in ["baseRevision", "baseSources", "headSources", "toolchain", "buildContext", "helper", "producer", "overload", "substitutions", "guarantees", "duplicate", "ambiguous", "incomplete"] {
        var current = fixture, declaration = contract
        switch kind {
        case "baseRevision": declaration.baseRevision = "other"
        case "baseSources": declaration.baseSources = "stale"
        case "headSources": declaration.headSources = "stale"
        case "toolchain": declaration.toolchain = "other"
        case "buildContext": declaration.buildContext = "other"
        case "helper": declaration.helperSymbol = "missing"
        case "producer": declaration.producerSymbol = "missing"
        case "overload": declaration.assertionSymbol = "unknown"
        case "substitutions": declaration.substitutions = "Optional<Int>"
        case "guarantees": declaration.guarantees.removeLast()
        case "ambiguous": current.sources["UI:UI.swift"]!.units.append(current.sources["UI:UI.swift"]!.units.first { $0.key == contract.helper }!)
        case "incomplete": current.dependencies!.diagnostics.append("Missing captured compiler job")
        default: break
        }
        current.mappings!.helperFormattingContracts = kind == "duplicate" ? [declaration, declaration] : [declaration]
        let report = XcodeHeadOnlySelector.select(current: current, source: source, changes: [.init(path: "UI.swift")], baseRevision: "base")
        #expect(report.selectedTests == formattingTests.sorted(), "\(kind): \(report.diagnostics)")
        #expect(report.helperContractDecisions?.contains { $0.status == "invalid" } == true, "\(kind)")
        #expect(report.helperContractPreview?.removed.isEmpty == true)
    }
}

@Test func formattingContractCommentsAreNativeParsedAndSemantic() throws {
    let (root, fixture, source, contract) = try formattingFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let payload = String(decoding: try JSONEncoder().encode(contract), as: UTF8.self)
    let comment = "// swift-test-helper-formatting: " + payload + "\n"
    var central = fixture; central.mappings!.helperFormattingContracts = [contract]
    var inline = fixture
    // Trailing comment preserves physical call locations in the captured graph.
    inline.sources["UI:UI.swift"] = .parse(formattingAfter + "\n" + comment, path: "UI.swift", module: "UI")
    let a = XcodeHeadOnlySelector.select(current: central, source: source, changes: [.init(path: "UI.swift")], baseRevision: "base")
    let b = XcodeHeadOnlySelector.select(current: inline, source: source, changes: [.init(path: "UI.swift")], baseRevision: "base")
    #expect(a.selectedTests == b.selectedTests)
    #expect(b.helperContractDecisions?.first?.status == "discharged")
    let prose = SwiftSourceSnapshot.parse(formattingAfter + "\n// ordinary comment", path: "UI.swift", module: "UI")
    #expect(HelperFormattingContracts.fingerprint(["UI:UI.swift": prose]) == contract.headSources)
    let string = SwiftSourceSnapshot.parse("let text = #\"" + comment.trimmingCharacters(in: .newlines) + "\"#", path: "String.swift", module: "UI")
    #expect(string.helperContracts?.contracts.isEmpty == true)
    let malformed = SwiftSourceSnapshot.parse("// swift-test-helper-formatting: {}\n" + formattingAfter, path: "UI.swift", module: "UI")
    #expect(malformed.helperContracts?.diagnostics.isEmpty == false)
    var unchanged = source; unchanged.base = fixture.sources
    var policy = contract; policy.baseSources = contract.headSources
    inline.sources["UI:UI.swift"] = .parse(formattingAfter + "\n// swift-test-helper-formatting: " + String(decoding: try JSONEncoder().encode(policy), as: UTF8.self), path: "UI.swift", module: "UI")
    let edited = XcodeHeadOnlySelector.select(current: inline, source: unchanged, changes: [.init(path: "UI.swift")], baseRevision: "base")
    #expect(!edited.selectedTests.isEmpty)
    #expect(!edited.ignoredChanges.contains("UI.swift"))
    let noOp = XcodeHeadOnlySelector.select(current: fixture, source: unchanged, changes: [.init(path: "UI.swift")], baseRevision: "base")
    #expect(noOp.selectedTests.isEmpty)
    // A dedicated comment-only Swift file is a semantic policy input, even
    // though it has no source units or compiler region of its own.
    let policyPath = "FormattingPolicy.swift"
    unchanged.base["UI:" + policyPath] = .parse("// Review declarations\n", path: policyPath, module: "UI")
    inline = fixture
    inline.sources["UI:" + policyPath] = unchanged.base["UI:" + policyPath]
    policy.baseSources = HelperFormattingContracts.fingerprint(unchanged.base)
    policy.headSources = HelperFormattingContracts.fingerprint(inline.sources)
    inline.sources["UI:" + policyPath] = .parse("// swift-test-helper-formatting: " + String(decoding: try JSONEncoder().encode(policy), as: UTF8.self), path: policyPath, module: "UI")
    let dedicated = XcodeHeadOnlySelector.select(current: inline, source: unchanged, changes: [.init(path: policyPath)], baseRevision: "base")
    #expect(!dedicated.selectedTests.isEmpty)
    #expect(!dedicated.ignoredChanges.contains(policyPath))
    #expect(HelperFormattingContracts.changedPolicyPaths(base: unchanged.base, head: inline.sources) == [policyPath])
    // A declaration for another helper scope does not create a change root.
    let separate = XcodeHeadOnlySelector.select(current: central, source: unchanged, changes: [], baseRevision: "base")
    #expect(separate.selectedTests.isEmpty)
}

@Test func formattingDischargeCannotEraseIndependentStructuralOrHistoricalFallback() throws {
    let (root, fixture, originalSource, contract) = try formattingFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    for kind in ["declaration", "removedCaller", "missingBase", "sharedState", "callback", "lifecycle", "inventory", "missingCompiler"] {
        var current = fixture, source = originalSource, declaration = contract
        switch kind {
        case "declaration":
            source.base["UI:UI.swift"] = .parse(formattingBefore + "\nstruct Removed {}", path: "UI.swift", module: "UI")
        case "removedCaller":
            source.base["UI:UI.swift"] = .parse(formattingBefore.replacingOccurrences(of: "func testConsumer()", with: "func testDeleted()"), path: "UI.swift", module: "UI")
        case "missingBase": source.base.removeValue(forKey: "UI:UI.swift"); source.unownedBaseSources["UI.swift"] = .parse(formattingBefore, path: "UI.swift", module: "")
        case "inventory": current.sources["UI:UI.swift"]!.helperDeclarationsComplete = false
        case "sharedState": current.dependencies!.functions[contract.helperSymbol]!.uncertainties.insert("Global state access")
        case "callback":
            source.base["UI:UI.swift"] = .parse(formattingBefore.replacingOccurrences(of: "candidate() }", with: "let escaped = candidate; escaped() }"), path: "UI.swift", module: "UI")
        case "lifecycle":
            source.base["UI:UI.swift"] = .parse(formattingBefore.replacingOccurrences(of: "func testConsumer()", with: "override func setUp()"), path: "UI.swift", module: "UI")
        default: current.dependencies!.functions[contract.producerSymbol]!.compilerReferences = nil
        }
        // Even an explicitly renewed declaration cannot override another check.
        declaration.baseSources = HelperFormattingContracts.fingerprint(source.base, unowned: source.unownedBaseSources)
        declaration.headSources = HelperFormattingContracts.fingerprint(current.sources)
        current.mappings!.helperFormattingContracts = [declaration]
        let report = XcodeHeadOnlySelector.select(current: current, source: source, changes: [.init(path: "UI.swift")], baseRevision: "base")
        #expect(report.selectedTests == formattingTests.sorted(), "\(kind): \(report.diagnostics)")
        #expect(!report.diagnostics.isEmpty)
        if kind == "inventory" {
            #expect(report.diagnostics.contains { $0.message.contains("head:UI:UI.swift") && $0.fallback?.resolution == "compilerEvidence" })
        }
        if kind == "declaration" {
            #expect(report.helperContractDecisions?.first?.status == "discharged")
            #expect(report.diagnostics.contains { $0.code == "head_only_declaration_change" })
            #expect(report.helperContractPreview?.removed.isEmpty == true)
        }
    }
}

@Test func formattingContractCannotAuthorizeProjectFormattingConformance() throws {
    let (root, fixture, originalSource, contract) = try formattingFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let conformance = """
    import Foundation
    extension Optional: @retroactive CustomStringConvertible {
        public var description: String {
            UserDefaults.standard.set(true, forKey: "formatting-effect")
            return "formatted"
        }
    }
    """
    var current = try boundaryGraph(["UI.swift": formattingAfter, "Conformance.swift": conformance], tests: formattingTests, root: root)
    current.dependencies!.toolchain = fixture.dependencies!.toolchain
    current.buildArtifact = fixture.buildArtifact
    var source = originalSource
    source.base["UI:Conformance.swift"] = .parse(conformance, path: "Conformance.swift", module: "UI")
    var declaration = contract
    declaration.baseSources = HelperFormattingContracts.fingerprint(source.base)
    declaration.headSources = HelperFormattingContracts.fingerprint(current.sources)
    current.mappings!.helperFormattingContracts = [declaration]
    let report = XcodeHeadOnlySelector.select(current: current, source: source, changes: [.init(path: "UI.swift")], baseRevision: "base")
    #expect(report.helperContractDecisions?.first?.failures.contains { $0.contains("Project formatting conformance") } == true)
    #expect(report.selectedTests == formattingTests.sorted())
}

@Test func formattingContractsRemainLocalToIndependentHelperScopes() throws {
    let (root, fixture, originalSource, contract) = try formattingFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let secondBefore = formattingBefore.replacingOccurrences(of: "candidate", with: "otherCandidate").replacingOccurrences(of: "Suite", with: "Second").replacingOccurrences(of: "Other", with: "Unrelated")
    let secondAfter = formattingAfter.replacingOccurrences(of: "candidate", with: "otherCandidate").replacingOccurrences(of: "Suite", with: "Second").replacingOccurrences(of: "Other", with: "Unrelated")
    let secondTests = formattingTests.map { $0.replacingOccurrences(of: "Suite", with: "Second").replacingOccurrences(of: "Other", with: "Unrelated") }
    var current = try boundaryGraph(["UI.swift": formattingAfter, "Second.swift": secondAfter], tests: formattingTests + secondTests, root: root)
    current.dependencies!.toolchain = fixture.dependencies!.toolchain
    current.buildArtifact = fixture.buildArtifact
    var source = originalSource
    source.base["UI:Second.swift"] = .parse(secondBefore, path: "Second.swift", module: "UI")
    var declaration = contract
    declaration.baseSources = HelperFormattingContracts.fingerprint(source.base)
    declaration.headSources = HelperFormattingContracts.fingerprint(current.sources)
    current.mappings!.helperFormattingContracts = [declaration]
    let first = XcodeHeadOnlySelector.select(current: current, source: source, changes: [.init(path: "UI.swift")], baseRevision: "base")
    let second = XcodeHeadOnlySelector.select(current: current, source: source, changes: [.init(path: "Second.swift")], baseRevision: "base")
    let mixed = XcodeHeadOnlySelector.select(current: current, source: source, changes: [.init(path: "UI.swift"), .init(path: "Second.swift")], baseRevision: "base")
    #expect(first.selectedTests == Array(formattingTests.prefix(2)).sorted(), "\(first.diagnostics)")
    #expect(second.selectedTests == current.tests.sorted())
    #expect(second.helperContractDecisions?.first?.status == "valid-unused")
    #expect(mixed.selectedTests == current.tests.sorted())
    #expect(mixed.helperContractDecisions?.first?.status == "discharged")
    #expect(mixed.diagnostics.contains { $0.fallback?.category == "assertionFormatting" && $0.message.contains("Second.swift") })
    #expect(mixed.diagnostics.contains { !($0.fallback?.overlappingPositiveTests.isEmpty ?? true) })
}

@Test func centralFormattingPolicyEditsParticipateAndMarkdownRemainsInert() throws {
    let (root, fixture, originalSource, contract) = try formattingFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    var source = originalSource, current = fixture, declaration = contract
    source.base = current.sources
    declaration.baseSources = declaration.headSources
    current.mappings!.helperFormattingContracts = [declaration]
    let adoption = XcodeHeadOnlySelector.select(current: current, source: source,
        changes: [.init(path: ".swift-test-selection.json")], baseRevision: "base")
    #expect(adoption.selectedTests == Array(formattingTests.prefix(2)).sorted())
    #expect(adoption.helperContractDecisions?.first?.status == "discharged")
    source.mappings = current.mappings
    current.mappings!.helperFormattingContracts = nil
    let removal = XcodeHeadOnlySelector.select(current: current, source: source,
        changes: [.init(path: ".swift-test-selection.json")], baseRevision: "base")
    #expect(removal.selectedTests == formattingTests.sorted())
    source.mappings!.ignoredDocumentation = ["README.md"]
    current.mappings!.ignoredDocumentation = ["README.md"]
    let docs = XcodeHeadOnlySelector.select(current: current, source: source,
        changes: [.init(path: "README.md")], baseRevision: "base", documentation: ["README.md"])
    #expect(docs.selectedTests.isEmpty)
    #expect(docs.ignoredChanges == ["README.md"])
}

@Test func reviewedFormattingRetainsMixedProductionMappingReasons() throws {
    let (root, fixture, originalSource, contract) = try formattingFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    var current = fixture, source = originalSource, declaration = contract
    current.targets.append(.init(name: "App", productType: "com.apple.product-type.application", sourceFiles: ["App.swift"]))
    current.modules["App"] = "App"
    current.sources["App:App.swift"] = .parse("func render() -> Bool { true }", path: "App.swift", module: "App")
    source.base["App:App.swift"] = .parse("func render() -> Bool { false }", path: "App.swift", module: "App")
    current.dependencies!.functions["app-render"] = .init(id: "app-render", module: "App", name: "render()", regions: [.init(path: "App.swift", startLine: 1, endLine: 1)])
    current.mappings!.features = [.init(name: "App", sources: ["App.swift"], tests: [formattingTests[2]])]
    current.mappings!.runtimeDependencyPolicy = .declared
    source.mappings = current.mappings
    declaration.baseSources = HelperFormattingContracts.fingerprint(source.base)
    declaration.headSources = HelperFormattingContracts.fingerprint(current.sources)
    current.mappings!.helperFormattingContracts = [declaration]
    let mixed = XcodeHeadOnlySelector.select(current: current, source: source,
        changes: [.init(path: "UI.swift"), .init(path: "App.swift")], baseRevision: "base")
    #expect(mixed.selectedTests == formattingTests.sorted())
    #expect(mixed.helperContractDecisions?.first?.status == "discharged")
    #expect(mixed.explanations.contains { $0.test == formattingTests[2] && $0.kind == "explicitMapping" })
    let helper = XcodeHeadOnlySelector.select(current: current, source: source,
        changes: [.init(path: "UI.swift")], baseRevision: "base")
    #expect(helper.selectedTests == Array(formattingTests.prefix(2)).sorted())
}

@Test(arguments: ["plain", "qualified", "nested", "namespace", "chained", "escaped", "unrelated"], ["head", "base", "unownedBase"])
func formattingContractsRejectAliasedSDKConformances(spelling: String, revision: String) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("review82-sdk-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let before = """
    import XCTest
    @MainActor extension XCUIElement {
        func checkValue(_ expected: String, timeout: TimeInterval = 3) -> Bool {
            if value as? String == expected { return true }
            let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", expected), object: self)
            return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
        }
    }
    """
    let after = """
    import XCTest
    @MainActor extension XCUIElement {
        func checkValue(_ expected: String, timeout: TimeInterval = 3) -> Bool {
            let matches = NSPredicate { _, _ in self.exists && self.value as? String == expected }
            if matches.evaluate(with: self) { return true }
            let expectation = XCTNSPredicateExpectation(predicate: matches, object: self)
            return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
        }
    }
    """
    let callers = """
    import XCTest
    @MainActor final class Suite: XCTestCase {
        func testConsumer() { let value: String? = "ready"; XCTAssertEqual(value, "ready"); XCTAssertTrue(XCUIApplication().buttons["toggle"].checkValue("1")) }
    }
    @MainActor final class Other: XCTestCase {
        func testOther() { XCTAssertFalse(UserDefaults.standard.bool(forKey: "formatting-effect")) }
    }
    """
    let declaration: String, owner: String
    switch spelling {
    case "nested": declaration = "enum Namespace { typealias Maybe<Wrapped> = Optional<Wrapped> }"; owner = "Namespace.Maybe"
    case "namespace": declaration = "enum Namespace { typealias Maybe<Wrapped> = Optional<Wrapped> }; typealias Scope = Namespace"; owner = "Scope.Maybe"
    case "chained": declaration = "typealias Maybe<Wrapped> = Optional<Wrapped>; typealias OtherMaybe<Wrapped> = Maybe<Wrapped>"; owner = "OtherMaybe"
    case "unrelated": declaration = "typealias Maybe<Wrapped> = Optional<Wrapped>; struct Marker {}"; owner = "Marker"
    default: declaration = "typealias Maybe<Wrapped> = Optional<Wrapped>"; owner = spelling == "qualified" ? "UI.Maybe" : spelling == "escaped" ? "`Maybe`" : "Maybe"
    }
    let conformance = """
    import Foundation
    \(declaration)
    extension \(owner): CustomStringConvertible {
        public var description: String {
            UserDefaults.standard.set(true, forKey: "formatting-effect")
            return "formatted"
        }
    }
    """
    let tests = ["UI/Suite/testConsumer()", "UI/Other/testOther()"]
    var files = ["Waiting.swift": after, "UI.swift": callers]
    if revision == "head" { files["Conformance.swift"] = conformance }
    var current = try boundaryGraph(files, tests: tests, root: root)
    current.dependencies!.toolchain = "compiled-fixture"
    current.buildArtifact = formattingArtifact(toolchain: current.dependencies!.toolchain)
    var source = XcodeHeadOnlySources(base: ["UI:Waiting.swift": .parse(before, path: "Waiting.swift", module: "UI"), "UI:UI.swift": .parse(callers, path: "UI.swift", module: "UI")], mappings: current.mappings)
    if revision == "head" {
        source.base["UI:Conformance.swift"] = .parse(conformance, path: "Conformance.swift", module: "UI")
    }
    let baseline = XcodeHeadOnlySelector.select(current: current, source: source, changes: [.init(path: "Waiting.swift")], baseRevision: "base")
    let boundary = try #require(baseline.formattingBoundaries?.first)
    if revision == "base" {
        source.base["UI:Conformance.swift"] = .parse(conformance, path: "Conformance.swift", module: "UI")
    } else if revision == "unownedBase" {
        source.unownedBaseSources["Conformance.swift"] = .parse(conformance, path: "Conformance.swift", module: "")
    }
    let contract = try reviewedFormattingContract(boundary, current: current, source: source)
    current.mappings!.helperFormattingContracts = [contract]
    let report = XcodeHeadOnlySelector.select(current: current, source: source, changes: [.init(path: "Waiting.swift")], baseRevision: "base")
    if spelling == "unrelated" {
        #expect(report.helperContractDecisions?.first?.status == (revision == "base" ? "valid-unused" : "discharged"))
        if revision == "head" { #expect(report.selectedTests == ["UI/Suite/testConsumer()"]) }
    } else {
        #expect(report.selectedTests == tests.sorted())
        #expect(report.helperContractDecisions?.first?.status == "invalid")
        #expect(report.helperContractDecisions?.first?.failures.contains { $0.contains("aliased conformance owner") } == true)
    }
}

@Test(arguments: ["settings", "compilerLog", "missingArtifact", "missingSettings", "missingLog", "missingAliases", "missingConformances", "missingBuildInputs", "legacyBuildInputs", "unchanged"])
func formattingContractsRequireCompleteBuildAndConformanceEvidence(change: String) throws {
    let (root, fixture, source, contract) = try formattingFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    var current = fixture, declaration = contract
    switch change {
    case "settings":
        current.buildArtifact!.buildSettingsDigest = "different-effective-flags"
        current.buildArtifact!.helperFormattingBuild!.buildSettingsDigest = "different-effective-flags"
        current.buildArtifact!.helperFormattingBuild!.fingerprint = "different-effective-inputs"
    case "compilerLog": current.buildArtifact!.buildLogDigest = "different-compiler-invocations"
    case "missingArtifact": current.buildArtifact = nil
    case "missingBuildInputs": current.buildArtifact!.helperFormattingBuild = nil
    case "legacyBuildInputs": current.buildArtifact!.helperFormattingBuild!.version = 1
    case "missingSettings": current.buildArtifact!.buildSettingsDigest = ""
    case "missingLog": current.buildArtifact!.buildLogDigest = ""
    case "missingAliases": current.sources["UI:UI.swift"]!.typeAliases = nil
    case "missingConformances":
        let i = try #require(current.sources["UI:UI.swift"]!.units.firstIndex { $0.kind == "type" })
        current.sources["UI:UI.swift"]!.units[i].helperInheritedTypes = nil
    default: break
    }
    // A newly authored digest cannot bless missing evidence either.
    if change.hasPrefix("missing") { declaration.buildContext = HelperFormattingContracts.buildContext(current) }
    current.mappings!.helperFormattingContracts = [declaration]
    let report = XcodeHeadOnlySelector.select(current: current, source: source, changes: [.init(path: "UI.swift")], baseRevision: "base")
    if change == "unchanged" {
        #expect(report.helperContractDecisions?.first?.status == "discharged")
        #expect(report.selectedTests == Array(formattingTests.prefix(2)).sorted())
    } else {
        #expect(report.helperContractDecisions?.first?.status == "invalid")
        #expect(report.selectedTests == formattingTests.sorted())
        #expect(report.helperContractPreview?.removed.isEmpty == true)
    }
}

@Test(arguments: ["XCTAssertGreaterThan", "XCTAssertGreaterThanOrEqual", "XCTAssertLessThan", "XCTAssertLessThanOrEqual"])
func relationalFormattingContractsRequireExactReviewedBoundaries(assertion: String) throws {
    let (root, fixture, source, original) = try formattingFixture(assertion: assertion)
    defer { try? FileManager.default.removeItem(at: root) }
    var contract = original
    contract.rationale = "Reviewed fixture: SDK CGFloat scalar comparison of local constants; no project printing/reflection conformances. Failure formatting has no shared effects, escaping callbacks or receiver production."
    #expect(contract.substitutions == "CGFloat")
    #expect(SDKReceiverContracts.missingWitnessProof(contract.substitutions, for: contract.assertionSymbol)?.contains("Comparable") == true)
    // This adds a reviewable boundary, never an unconditional SDK exemption.
    #expect(!SDKReceiverContracts.allows("CGFloat", for: contract.assertionSymbol))
    for mutation in ["none", "overload", "substitution", "source", "toolchain", "build", "witness", "compiler", "state", "inventory", "conformance", "historicalAlias"] {
        var current = fixture, review = contract, historical = source
        switch mutation {
        case "overload": review.assertionSymbol = "$s6XCTest14XCTAssertEqual___4file4lineyxyKXK_xyKXKSSyXKs12StaticStringVSutSQRzlF"
        case "substitution": review.substitutions = "Int"
        case "source": review.headSources = "stale"
        case "toolchain": review.toolchain = "stale"
        case "build": current.buildArtifact!.helperFormattingBuild = nil
        case "witness": review.substitutions = "ForeignComparable"
        case "compiler": current.dependencies!.functions[review.producerSymbol]!.receiverGenericCalls = nil
        case "state": current.dependencies!.functions[review.helperSymbol]!.uncertainties.insert("Global state access")
        case "inventory": current.sources["UI:UI.swift"]!.helperDeclarationsComplete = false
        case "conformance", "historicalAlias":
            let declaration = mutation == "historicalAlias"
                ? "typealias Scalar = CGFloat; extension Scalar: CustomReflectable { var customMirror: Mirror { fatalError() } }"
                : "extension CGFloat: CustomReflectable { var customMirror: Mirror { fatalError() } }"
            historical.unownedBaseSources["Removed.swift"] = .parse("import Foundation\n" + declaration, path: "Removed.swift", module: "")
            review.baseSources = HelperFormattingContracts.fingerprint(historical.base, unowned: historical.unownedBaseSources)
        default: break
        }
        current.mappings!.helperFormattingContracts = [review]
        let report = XcodeHeadOnlySelector.select(current: current, source: historical, changes: [.init(path: "UI.swift")], baseRevision: "base")
        if mutation == "none" {
            #expect(report.selectedTests == Array(formattingTests.prefix(2)).sorted(), "\(report.diagnostics)")
            #expect(report.helperContractDecisions?.first?.status == "discharged")
            #expect(report.helperContractPreview?.removed == [formattingTests[2]])
            for test in formattingTests.prefix(2) { #expect(report.explanations.contains { $0.test == test && $0.kind == "dependency" }) }
        } else {
            #expect(report.selectedTests == formattingTests.sorted(), "\(mutation): \(report.diagnostics)")
            #expect(report.helperContractPreview?.removed.isEmpty == true)
        }
    }
}

@Test func relationalReviewDoesNotAuthorizeUnknownComparableWitnesses() {
    let symbol = "$s6XCTest27XCTAssertGreaterThanOrEqual___4file4lineyxyKXK_xyKXKSSyXKs12StaticStringVSutSLRzlF"
    for type in ["ForeignComparable", "Optional<CGFloat>", "Array<CGFloat>", "CGFloat, CGFloat", "UI.CGFloat", "CGFloat<", "XCTWaiter.Result"] {
        #expect(SDKReceiverContracts.missingWitnessProof(type, for: symbol) == nil)
        #expect(!SDKReceiverContracts.allows(type, for: symbol))
    }
    #expect(SDKReceiverContracts.missingWitnessProof("CGFloat", for: symbol + "unknown-overload") == nil)
}

@Test func declarationInventoryReportsEverySourceWithoutChangingSelection() throws {
    let (root, fixture, original, contract) = try formattingFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    var current = fixture, source = original, review = contract
    for index in 0..<520 {
        let path = "App/View\(index).swift"
        let snapshot = SwiftSourceSnapshot.parse("import SwiftUI\nstruct View\(index) { @State var value = 1 }", path: path, module: "App")
        current.sources["App:" + path] = snapshot
        source.base["App:" + path] = snapshot
    }
    source.unownedBaseSources["Removed.swift"] = .parse("@MakeLifecycle final class Removed {}", path: "Removed.swift", module: "")
    review.baseSources = HelperFormattingContracts.fingerprint(source.base, unowned: source.unownedBaseSources)
    review.headSources = HelperFormattingContracts.fingerprint(current.sources)
    current.mappings!.helperFormattingContracts = [review]
    let report = XcodeHeadOnlySelector.select(current: current, source: source, changes: [.init(path: "UI.swift")], baseRevision: "base")
    #expect(report.selectedTests == formattingTests.sorted())
    let inventories = try #require(report.helperDeclarationInventories)
    #expect(inventories.count == 1041)
    #expect(inventories.contains { $0.revision == "unowned base" && $0.sourceKey == "Removed.swift" && $0.issues.contains { $0.spelling == "@MakeLifecycle" } })
    #expect(inventories.filter { $0.issues.contains { $0.spelling == "@State" && $0.line == 2 } }.count == 1040)
    #expect(report.helperDeclarationAudits?.map(\.helper) == [contract.helper])
    #expect(report.helperDeclarationAudits?.first?.protectedBindings.contains("XCTest lifecycle and callbacks") == true)
    let decoded = try JSONDecoder().decode(ImpactReport.self, from: JSONEncoder().encode(report))
    #expect(decoded.helperDeclarationInventories == inventories)
    #expect(decoded.helperDeclarationAudits == report.helperDeclarationAudits)
    #expect(report.helperContractPreview?.removed.isEmpty == true)
}

@Test func sdkHelperRelationalFormattingPreservesReceiverAndHistoricalChecks() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("relational-sdk-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let before = """
    import XCTest
    @MainActor extension XCUIElement {
        func checkValue(_ expected: String, timeout: TimeInterval = 3) -> Bool {
            if value as? String == expected { return true }
            let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", expected), object: self)
            return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
        }
    }
    """
    let after = """
    import XCTest
    @MainActor extension XCUIElement {
        func checkValue(_ expected: String, timeout: TimeInterval = 3) -> Bool {
            let matches = NSPredicate { _, _ in self.exists && self.value as? String == expected }
            if matches.evaluate(with: self) { return true }
            let expectation = XCTNSPredicateExpectation(predicate: matches, object: self)
            return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
        }
    }
    """
    let callers = """
    import XCTest
    @MainActor final class Suite: XCTestCase {
        func testConsumer() {
            let app = XCUIApplication()
            XCTAssertGreaterThanOrEqual(app.buttons["a"].frame.minY, app.buttons["b"].frame.maxY)
            XCTAssertTrue(app.buttons["toggle"].checkValue("1"))
        }
    }
    @MainActor final class Other: XCTestCase {
        func testOther() { XCTAssertTrue(true) }
    }
    """
    let tests = ["UI/Suite/testConsumer()", "UI/Other/testOther()"]
    var current = try boundaryGraph(["Waiting.swift": after, "UI.swift": callers], tests: tests, root: root)
    current.dependencies!.toolchain = try CommandRunner.run("xcrun", ["swiftc", "--version"], at: root).text
    current.buildArtifact = formattingArtifact(toolchain: current.dependencies!.toolchain)
    var source = XcodeHeadOnlySources(base: current.sources, mappings: current.mappings)
    source.base["UI:Waiting.swift"] = .parse(before, path: "Waiting.swift", module: "UI")
    let baseline = XcodeHeadOnlySelector.select(current: current, source: source, changes: [.init(path: "Waiting.swift")], baseRevision: "base")
    let boundary = try #require(baseline.formattingBoundaries?.first, "\(baseline.diagnostics)")
    #expect(boundary.substitutions == "CGFloat")
    #expect(boundary.diagnosticCode == "head_only_sdk_helper_boundary")
    var contract = try reviewedFormattingContract(boundary, current: current, source: source)
    contract.rationale = "Fixture review: frame coordinates use SDK CGFloat comparison and formatting, with no project formatting witnesses, shared state, callback registration or receiver production."
    current.mappings!.helperFormattingContracts = [contract]
    let reviewed = XcodeHeadOnlySelector.select(current: current, source: source, changes: [.init(path: "Waiting.swift")], baseRevision: "base")
    #expect(reviewed.selectedTests == [tests[0]], "\(reviewed.diagnostics)")
    #expect(reviewed.helperContractDecisions?.first?.status == "discharged")
    for kind in ["callback", "lifecycle", "headAlias", "missingReceiver"] {
        var candidate = current, historical = source, renewed = contract
        switch kind {
        case "callback":
            historical.base["UI:UI.swift"] = .parse(callers.replacingOccurrences(of: "XCTAssertTrue(app.buttons[\"toggle\"].checkValue(\"1\"))", with: "let escaped = app.buttons[\"toggle\"].checkValue; XCTAssertTrue(escaped(\"1\", 3))"), path: "UI.swift", module: "UI")
        case "lifecycle":
            historical.base["UI:UI.swift"] = .parse(callers.replacingOccurrences(of: "func testConsumer()", with: "override func setUp()"), path: "UI.swift", module: "UI")
        case "headAlias":
            let alias = SwiftSourceSnapshot.parse("typealias CGFloat = Double", path: "Alias.swift", module: "UI")
            candidate.sources["UI:Alias.swift"] = alias
            historical.base["UI:Alias.swift"] = alias
        default: candidate.dependencies!.functions[contract.producerSymbol]!.receiverTypeOrigins = nil
        }
        renewed.baseSources = HelperFormattingContracts.fingerprint(historical.base, unowned: historical.unownedBaseSources)
        renewed.headSources = HelperFormattingContracts.fingerprint(candidate.sources)
        candidate.mappings!.helperFormattingContracts = [renewed]
        let report = XcodeHeadOnlySelector.select(current: candidate, source: historical, changes: [.init(path: "Waiting.swift")], baseRevision: "base")
        #expect(report.selectedTests == tests.sorted(), "\(kind): \(report.diagnostics)")
        #expect(report.helperContractPreview?.removed.isEmpty == true)
    }
}
