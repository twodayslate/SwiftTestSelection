// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
import Foundation
import Testing
@testable import TestImpact

private func bindingContract(_ key: String, revision: String, helper: SourceUnit, current: XcodeTestGraph,
                             source: XcodeHeadOnlySources, imports: Bool = false) throws -> HelperBindingContract {
    let snapshot = try #require((revision == "head" ? current.sources : source.base)[key])
    let symbol = try #require(current.dependencies?.functions.values.first { node in
        node.module == String(helper.key.prefix { $0 != ":" }) && node.regions.contains {
            $0.path == helper.region.path && $0.startLine >= helper.region.startLine && $0.endLine <= helper.region.endLine
        }
    })
    return .init(id: revision + key, helper: helper.key, helperSymbol: symbol.id, revision: revision, sourceKey: key,
        baseRevision: "base", headRevision: "head",
        baseSources: HelperFormattingContracts.fingerprint(source.base, unowned: source.unownedBaseSources),
        headSources: HelperFormattingContracts.fingerprint(current.sources), buildContext: HelperFormattingContracts.buildContext(current),
        capturedInputs: current.buildArtifact!.helperBindingInputs!,
        constructs: (snapshot.helperDeclarationIssues ?? []).map {
            .init(issue: $0, identity: HelperBindingContracts.identities[$0.spelling]?.sorted().first ?? "Unknown", evidence: "Fixture review of this exact SDK declaration and its synthesized declarations.")
        }, imports: imports ? Set(snapshot.units.flatMap { $0.receiverUnsupportedImports ?? [] }).sorted() : [],
        bindings: HelperBindingContracts.bindingDigest(key: key, snapshot: snapshot, current: current),
        guarantees: HelperBindingContract.requiredGuarantees,
        evidence: "Fixture review: exact SDK and dependency identities, transitive exports and host inputs checked at both source revisions; no additional protected bindings. This grants no function effects.")
}

private func bindingArtifact(_ current: inout XcodeTestGraph) {
    var artifact = XcodeBuildArtifact(revision: "head", context: [:], toolchain: "fixture", buildLogDigest: "log", buildSettingsDigest: "settings",
        productsDirectory: "/tmp/binding-fixture", xctestrun: "Tests.xctestrun", products: [:])
    artifact.helperFormattingBuild = .init(fingerprint: "effective-build", buildLogDigest: "log", buildSettingsDigest: "settings")
    artifact.helperBindingBuild = .init(sourceInputs: "source-inputs", inputFiles: ["dependency": "bytes"], importedModules: ["UI": ["SwiftUI", "ReviewDependency"]],
        buildLogDigest: "log", buildSettingsDigest: "settings", productsDigest: try! XcodeGraphCache.key(artifact.products))
    artifact.helperBindingInputs = artifact.helperBindingBuild!.fingerprint
    current.buildArtifact = artifact
}

private let bindingBefore = """
import XCTest
@MainActor final class Suite: XCTestCase {
    func testConsumer() { candidate() }
    private func candidate() { XCTAssertTrue(true) }
}
@MainActor final class Other: XCTestCase {
    func testOther() { XCTAssertTrue(true) }
}
"""

@Test func bindingReviewDischargesOnlyReviewedSDKConstructsAndPreservesRawInventory() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let after = bindingBefore.replacingOccurrences(of: "private func candidate() { XCTAssertTrue(true) }", with: "private func candidate() { XCTAssertTrue(true); XCTAssertFalse(false) }")
    let tests = ["UI/Suite/testConsumer()", "UI/Other/testOther()"]
    var current = try boundaryGraph(["UI.swift": after], tests: tests, root: root)
    bindingArtifact(&current)
    // This unrelated SwiftUI source is not treated as a pure body. Only its
    // declaration synthesis is reviewed for this helper's binding audit.
    let wrapper = SwiftSourceSnapshot.parse("import SwiftUI\nstruct Screen { @State var count = 0 }", path: "Screen.swift", module: "App")
    current.sources["App:Screen.swift"] = wrapper
    var source = XcodeHeadOnlySources(base: current.sources, mappings: current.mappings)
    source.base["UI:UI.swift"] = .parse(bindingBefore, path: "UI.swift", module: "UI")
    let helper = try #require(current.sources["UI:UI.swift"]!.units.first { $0.helperCallableName == "candidate" })
    let baseline = XcodeHeadOnlySelector.select(current: current, source: source, changes: [.init(path: "UI.swift")], baseRevision: "base")
    #expect(baseline.selectedTests == tests.sorted())
    current.mappings!.helperBindingContracts = try ["head", "base"].map {
        try bindingContract("App:Screen.swift", revision: $0, helper: helper, current: current, source: source)
    }
    let reviewed = XcodeHeadOnlySelector.select(current: current, source: source, changes: [.init(path: "UI.swift")], baseRevision: "base")
    #expect(reviewed.selectedTests == [tests[0]], "\(reviewed.diagnostics)")
    #expect(reviewed.helperBindingDecisions?.contains { $0.status == "discharged" } == true)
    #expect(reviewed.helperDeclarationInventories?.count == 2)
    #expect(current.sources["App:Screen.swift"]!.helperDeclarationsComplete == false)
    #expect(reviewed.helperContractPreview?.removed == [tests[1]])
    #expect(reviewed.explanations.contains { $0.test == tests[0] && $0.kind == "dependency" })
    let headOnly = current.mappings!.helperBindingContracts!.filter { $0.revision == "head" }
    #expect(!HelperBindingEvaluation(contracts: headOnly, current: current, source: source).inventoryComplete(wrapper))
    var unownedCopy = source
    unownedCopy.unownedBaseSources["Screen.swift"] = wrapper
    #expect(!HelperBindingEvaluation(contracts: current.mappings!.helperBindingContracts!, current: current, source: unownedCopy).inventoryComplete(wrapper))
    // Even a renewed review cannot certify a source-visible alias as the SDK
    // declaration. Head and historical aliases both retain the fallback.
    for revision in ["head", "base", "unowned"] {
        var shadow = current, historical = source
        let alias = SwiftSourceSnapshot.parse("typealias State = ForeignWrapper", path: "Alias.swift", module: revision == "unowned" ? "" : "App")
        if revision == "head" { shadow.sources["App:Alias.swift"] = alias }
        else if revision == "base" { historical.base["App:Alias.swift"] = alias }
        else { historical.unownedBaseSources["Alias.swift"] = alias }
        shadow.mappings!.helperBindingContracts = try ["head", "base"].map {
            try bindingContract("App:Screen.swift", revision: $0, helper: helper, current: shadow, source: historical)
        }
        let rejected = XcodeHeadOnlySelector.select(current: shadow, source: historical, changes: [.init(path: "UI.swift")], baseRevision: "base")
        #expect(rejected.selectedTests == tests.sorted())
        #expect(rejected.helperBindingDecisions?.allSatisfy { $0.status == "invalid" && $0.failures.contains { $0.contains("shadows reviewed identity") } } == true)
    }
    for mutation in ["inputs", "build", "base", "binding", "identity", "guarantee", "duplicate", "metadata", "macro", "unowned", "shadow", "reexport", "products", "importMap", "inputRecord"] {
        var changed = current, old = source
        switch mutation {
        case "products": changed.buildArtifact!.products["Dependency.framework/Dependency"] = "changed"
        case "importMap": changed.buildArtifact!.helperBindingBuild!.importedModules = [:]
        case "inputRecord": changed.buildArtifact!.helperBindingBuild!.inputFiles = [:]
        case "inputs": changed.buildArtifact!.helperBindingInputs = "different-dependency-bytes"
        case "build": changed.buildArtifact!.buildLogDigest = "other-log"
        case "base": old.base["App:Screen.swift"] = .parse("import SwiftUI\nstruct Screen { @State var count = 1 }", path: "Screen.swift", module: "App")
        case "binding": changed.mappings!.helperBindingContracts![0].bindings = "stale"
        case "identity": changed.mappings!.helperBindingContracts![0].constructs[0].identity = "Foreign.State"
        case "guarantee": changed.mappings!.helperBindingContracts![0].guarantees = []
        case "duplicate": changed.mappings!.helperBindingContracts! += changed.mappings!.helperBindingContracts!
        case "metadata": changed.sources["App:Screen.swift"]!.helperWrittenOperators = nil
        case "macro": changed.sources["App:Screen.swift"] = .parse("@MakeMembers struct Screen {}", path: "Screen.swift", module: "App")
        case "unowned": old.unownedBaseSources["Old.swift"] = .parse("@State var hidden = 0", path: "Old.swift", module: "")
        case "shadow": old.base["UI:Alias.swift"] = .parse("typealias IntegerLiteralType = Foreign", path: "Alias.swift", module: "UI")
        default: changed.sources["App:Screen.swift"] = .parse("@_exported import Foreign\nstruct Screen { @State var count = 0 }", path: "Screen.swift", module: "App")
        }
        let rejected = XcodeHeadOnlySelector.select(current: changed, source: old, changes: [.init(path: "UI.swift")], baseRevision: "base")
        #expect(rejected.selectedTests == tests.sorted(), "\(mutation): \(rejected.diagnostics)")
    }
}

@Test func sourceImportReviewDoesNotGrantExternalEffectsOrHistoricalBodyChanges() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("public func importedEffect() {}".utf8).write(to: root.appendingPathComponent("Dependency.swift"))
    _ = try CommandRunner.run("xcrun", ["swiftc", "-emit-module", "-module-name", "ReviewDependency", "Dependency.swift", "-emit-module-path", "ReviewDependency.swiftmodule"], at: root)
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
    import ReviewDependency
    @MainActor final class Suite: XCTestCase {
        func testConsumer() { let app = XCUIApplication(); XCTAssertTrue(app.buttons["toggle"].checkValue("1")) }
    }
    @MainActor final class Other: XCTestCase {
        func testOther() { XCTAssertTrue(true) }
    }
    """
    let tests = ["UI/Suite/testConsumer()", "UI/Other/testOther()"]
    var current = try boundaryGraph(["Waiting.swift": after, "UI.swift": callers], tests: tests, root: root, compilerArguments: ["-I", root.path])
    bindingArtifact(&current)
    var source = XcodeHeadOnlySources(base: current.sources, mappings: current.mappings)
    source.base["UI:Waiting.swift"] = .parse(before, path: "Waiting.swift", module: "UI")
    let helper = try #require(current.sources["UI:Waiting.swift"]!.units.first { $0.helperCallableName == "checkValue" })
    let baseline = XcodeHeadOnlySelector.select(current: current, source: source, changes: [.init(path: "Waiting.swift")], baseRevision: "base")
    #expect(baseline.selectedTests == tests.sorted())
    current.mappings!.helperBindingContracts = try ["head", "base"].map {
        try bindingContract("UI:UI.swift", revision: $0, helper: helper, current: current, source: source, imports: true)
    }
    let reviewed = XcodeHeadOnlySelector.select(current: current, source: source, changes: [.init(path: "Waiting.swift")], baseRevision: "base")
    #expect(reviewed.selectedTests == [tests[0]], "\(reviewed.diagnostics)")
    #expect(current.sources["UI:UI.swift"]!.units.first!.receiverImportsSupported == false)
    #expect(reviewed.helperDeclarationInventories?.count == 2)
    #expect(reviewed.limitations.contains { $0.contains("Scoped source identity boundaries") })
    var effectful = try boundaryGraph(["Waiting.swift": after, "UI.swift": callers.replacingOccurrences(of: "let app =", with: "importedEffect(); let app =")], tests: tests, root: root, compilerArguments: ["-I", root.path])
    bindingArtifact(&effectful)
    var effectSource = XcodeHeadOnlySources(base: effectful.sources, mappings: effectful.mappings)
    effectSource.base["UI:Waiting.swift"] = source.base["UI:Waiting.swift"]
    effectful.mappings!.helperBindingContracts = try ["head", "base"].map {
        try bindingContract("UI:UI.swift", revision: $0, helper: helper, current: effectful, source: effectSource, imports: true)
    }
    let opaque = XcodeHeadOnlySelector.select(current: effectful, source: effectSource, changes: [.init(path: "Waiting.swift")], baseRevision: "base")
    #expect(opaque.selectedTests == tests.sorted())
    #expect(opaque.diagnostics.contains { $0.message.contains("importedEffect") || $0.message.contains("external") })
    // Renewing identity review must not erase historical writes, stored values,
    // lifecycle effects, or any compiler-observed external call.
    source.base["UI:UI.swift"] = .parse(callers.replacingOccurrences(of: "let app = XCUIApplication();", with: "UserDefaults.standard.set(true, forKey: \"effect\"); let app = XCUIApplication();"), path: "UI.swift", module: "UI")
    current.mappings!.helperBindingContracts = try ["head", "base"].map {
        try bindingContract("UI:UI.swift", revision: $0, helper: helper, current: current, source: source, imports: true)
    }
    let changed = XcodeHeadOnlySelector.select(current: current, source: source, changes: [.init(path: "Waiting.swift")], baseRevision: "base")
    #expect(changed.selectedTests == tests.sorted())
    #expect(changed.diagnostics.contains { $0.message.contains("historical caller body effects") })
}

@Test func bindingDigestsSurviveArchivesAndDoNotTurnMacrosIntoImportEvidence() throws {
    let original = SwiftSourceSnapshot.parse("import Foreign\n@MainActor class Suite {}\nfunc f() { a(); b(); c() }", path: "UI.swift", module: "UI")
    let copy = try JSONDecoder().decode(SwiftSourceSnapshot.self, from: JSONEncoder().encode(original))
    #expect(HelperBindingContracts.snapshotDigest(original) == HelperBindingContracts.snapshotDigest(copy))
    let reordered = SwiftSourceSnapshot.parse("import Foreign\n@MainActor class Suite {}\nfunc f() { c(); b(); a() }", path: "UI.swift", module: "UI")
    #expect(HelperBindingContracts.snapshotDigest(original) != HelperBindingContracts.snapshotDigest(reordered))
    #expect(HelperBindingContracts.identities["@MakeMembers"] == nil)
    #expect(HelperBindingContracts.identities["#makeCallbacks"] == nil)
}

@Test func committedBindingOverlayReusesExactHeadWithoutRebuilding() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("binding-overlay-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    func git(_ args: [String]) throws -> String {
        try CommandRunner.run("git", args, at: root).text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    func commit(_ message: String) throws -> String {
        _ = try git(["-c", "user.name=Tests", "-c", "user.email=tests@example.invalid", "commit", "-qm", message])
        return try git(["rev-parse", "HEAD"])
    }
    let tests = ["UI/Suite/testConsumer()", "UI/Other/testOther()"]
    let after = bindingBefore.replacingOccurrences(of: "private func candidate() { XCTAssertTrue(true) }", with: "private func candidate() { XCTAssertTrue(true); XCTAssertFalse(false) }")
    var current = try boundaryGraph(["UI.swift": after], tests: tests, root: root)
    bindingArtifact(&current)
    let wrapperText = "import SwiftUI\nstruct Screen { @State var count = 0 }"
    current.sources["App:Screen.swift"] = .parse(wrapperText, path: "Screen.swift", module: "App")
    let encoder = JSONEncoder()
    try encoder.encode(current.mappings).write(to: root.appendingPathComponent(".swift-test-selection.json"))
    try Data(wrapperText.utf8).write(to: root.appendingPathComponent("Screen.swift"))
    try Data(bindingBefore.utf8).write(to: root.appendingPathComponent("UI.swift"))
    _ = try git(["init", "-q"])
    _ = try git(["add", "UI.swift", "Screen.swift", ".swift-test-selection.json"])
    let base = try commit("base")
    try Data(after.utf8).write(to: root.appendingPathComponent("UI.swift"))
    _ = try git(["add", "UI.swift"])
    let head = try commit("helper change")
    let configuration = XcodeConfiguration(container: .project, path: root.appendingPathComponent("Fixture.xcodeproj"), scheme: "Fixture", destination: "fixture")
    let analysis = XcodeAnalysis(options: configuration)
    current.buildArtifact!.revision = head
    current.buildArtifact!.context = try analysis.artifactContext(root: root)
    current.buildArtifact!.context["sdkAndArchitecture"] = "fixture"
    current.buildArtifact!.products = ["Tests.xctestrun": "fixture"]
    current.buildArtifact!.helperBindingBuild!.productsDigest = try XcodeGraphCache.key(current.buildArtifact!.products)
    current.buildArtifact!.helperBindingInputs = current.buildArtifact!.helperBindingBuild!.fingerprint
    current.buildArtifact!.headOnlyBuildEvidence = .init(buildLogDigest: "log", buildSettingsDigest: "settings", documentation: [], uncertainty: nil)
    let source = try XcodeHeadOnlySources.read(current: current, changes: [.init(path: "UI.swift")], base: base, root: root, mappingPath: configuration.mappingsPath)
    let helper = try #require(current.sources["UI:UI.swift"]!.units.first { $0.helperCallableName == "candidate" })
    var contracts = try ["head", "base"].map { try bindingContract("App:Screen.swift", revision: $0, helper: helper, current: current, source: source) }
    for i in contracts.indices { contracts[i].baseRevision = base; contracts[i].headRevision = head }
    let graphPath = root.appendingPathComponent("capture.stigraph"), policyPath = root.appendingPathComponent("reviews.json")
    let original = try GraphArchive.encode(current)
    try original.write(to: graphPath)
    try encoder.encode(contracts).write(to: policyPath)
    _ = try git(["add", "reviews.json"])
    let policyCommit = try commit("review captured helper bindings")
    #expect(policyCommit != head)
    let loaded = try XcodeAnalysis.executionGraph(at: graphPath)
    let scopes = SelectionScopes(scopes: [.init(name: "helper", paths: ["UI.swift"])])
    let baseline = try analysis.selectHeadOnly(base: base, head: head, headGraph: loaded)
    #expect(baseline.selectedTests == tests.sorted())
    let reviewed = try analysis.selectHeadOnly(base: base, head: head, headGraph: loaded, bindingReviews: contracts, selectionScopes: scopes)
    #expect(reviewed.selectedTests == [tests[0]], "\(reviewed.diagnostics)")
    #expect(reviewed.selectionScopes?.first?.report.selectedTests == [tests[0]])
    #expect(reviewed.appliedHelperBindingReviews == contracts)
    #expect(loaded.mappings!.helperBindingContracts == nil)
    #expect(try Data(contentsOf: graphPath) == original)
    #expect(throws: ImpactError.self) { try analysis.selectHeadOnly(base: base, head: policyCommit, headGraph: loaded, bindingReviews: contracts) }
    for mutation in ["missing", "log", "settings", "uncertainty"] {
        var changed = loaded
        switch mutation {
        case "missing": changed.buildArtifact!.headOnlyBuildEvidence = nil
        case "log": changed.buildArtifact!.headOnlyBuildEvidence!.buildLogDigest = "stale"
        case "settings": changed.buildArtifact!.headOnlyBuildEvidence!.buildSettingsDigest = "stale"
        default: changed.buildArtifact!.headOnlyBuildEvidence!.uncertainty = "Unbounded script inputs"
        }
        if mutation == "uncertainty" {
            let fallback = try analysis.selectHeadOnly(base: base, head: head, headGraph: changed, bindingReviews: contracts, selectionScopes: scopes)
            #expect(fallback.selectedTests == tests.sorted())
            #expect(fallback.selectionScopes?.first?.report.selectedTests == tests.sorted())
            #expect(fallback.diagnostics.contains { $0.code == "head_only_build_evidence" })
        } else {
            #expect(throws: ImpactError.self) { try analysis.selectHeadOnly(base: base, head: head, headGraph: changed, bindingReviews: contracts) }
        }
    }
    // Exercise the public CLI with the policy committed *after* the captured
    // head. No Xcode project/build is available in this fixture.
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    #if DEBUG
    let tool = repository.appendingPathComponent(".build/debug/swift-test-impact")
    #else
    let tool = repository.appendingPathComponent(".build/release/swift-test-impact")
    #endif
    let args = ["select", "--project", configuration.path.path, "--scheme", "Fixture", "--destination", "fixture", "--head-only", "--base", base, "--head", head,
        "--head-graph", graphPath.path, "--helper-binding-reviews", policyPath.path, "--format", "json", "--strict-mappings"]
    let output = try CommandRunner.run(tool.path, args, at: root)
    let report = try JSONDecoder().decode(ImpactReport.self, from: output.stdout)
    #expect(report.selectedTests == [tests[0]])
    #expect(report.headRevision == head)
    #expect(report.appliedHelperBindingReviews == contracts)
    #expect(try Data(contentsOf: graphPath) == original)
    for path in [graphPath, policyPath] {
        let invalid = try CommandRunner.run(tool.path, args + ["--output", path.path], at: root, allowFailure: true)
        #expect(invalid.status != 0)
    }
    var stale = contracts; stale[0].capturedInputs = "stale"
    try encoder.encode(stale).write(to: policyPath)
    let rejected = try CommandRunner.run(tool.path, args, at: root)
    let rejectedReport = try JSONDecoder().decode(ImpactReport.self, from: rejected.stdout)
    #expect(rejectedReport.selectedTests == tests.sorted())
    #expect(rejectedReport.helperBindingDecisions?.contains { $0.status == "invalid" } == true)
}
