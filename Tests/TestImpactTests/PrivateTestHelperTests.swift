// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation
import Testing
@testable import TestImpact

private let navigationHelper = """
private func navigationTab(_ title: String, in app: XCUIApplication) -> XCUIElement {
    app.descendants(matching: .any).matching(NSPredicate(
        format: "label == %@ AND elementType IN %@",
        argumentArray: [title, [XCUIElement.ElementType.button.rawValue, XCUIElement.ElementType.radioButton.rawValue]]
    )).firstMatch
}
"""
private let sharingHelper = """
private func assertShareOptions(in app: XCUIApplication) {
    XCTAssertTrue(app.buttons["Link"].waitUntilExists(timeout: 5), "Expected Share → Link.")
    XCTAssertTrue(app.buttons["Content"].exists, "Expected Share → Content.")
    XCTAssertFalse(app.buttons["Copy Link"].exists, "Copy Link should not appear in the Share menu.")
}
"""
private func helperFixture(_ helper: String, call: String) -> String {
    """
    import XCTest
    @MainActor
    final class NoteLinks: UITestCase {
        func testSharing() {
            let app = XCUIApplication()
            \(call)
        }
        func testSharingAgain() {
            let app = XCUIApplication()
            \(call)
        }
        func testUnrelated() { XCTAssertTrue(true) }
        \(helper)
    }
    """
}
private let helperSupport = """
import XCTest
@MainActor
class UITestCase: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        continueAfterFailure = false
    }
}
func evaluate(_ condition: () -> Bool) -> Bool { condition() }
extension XCUIElement {
    func waitUntilExists(timeout: TimeInterval) -> Bool { exists || waitForExistence(timeout: timeout) }
}
@MainActor
final class Calendar: UITestCase {
    func testCalendar() { XCTAssertTrue(evaluate { true }) }
}
"""

@Test func privateHelperSyntaxRejectsEscapesStateAndDynamicExposure() throws {
    let valid = helperFixture(sharingHelper, call: "assertShareOptions(in: app)")
    let parse: (String) -> SwiftSourceSnapshot = { SwiftSourceSnapshot.parse($0, path: "UI.swift", module: "UI") }
    let evidence = try #require(parse(valid).units.compactMap(\.privateTestHelper).first)
    #expect(evidence.name == "assertShareOptions")
    #expect(evidence.callerLines.count == 2)
    let unsafe = [
        valid.replacingOccurrences(of: "assertShareOptions(in: app)", with: "let callback = assertShareOptions; callback(app)"),
        valid.replacingOccurrences(of: "assertShareOptions(in: app)", with: "Task { assertShareOptions(in: app) }"),
        valid.replacingOccurrences(of: "assertShareOptions(in: app)", with: "defer { assertShareOptions(in: app) }"),
        valid.replacingOccurrences(of: "private func", with: "@objc private func"),
        valid.replacingOccurrences(of: "private func", with: "private dynamic func"),
        valid.replacingOccurrences(of: "final class", with: "class"),
        valid.replacingOccurrences(of: "XCTAssertTrue(app.buttons[\"Content\"].exists", with: "XCTAssertTrue(sharedApp.buttons[\"Content\"].exists"),
        valid.replacingOccurrences(of: "XCTAssertFalse(app.buttons[\"Copy Link\"].exists", with: "XCTAssertFalse(self.sharedApp.buttons[\"Copy Link\"].exists"),
        valid.replacingOccurrences(of: "private func assertShareOptions(in app: XCUIApplication) {", with: "private func assertShareOptions(in app: XCUIApplication) { shared = app;"),
        valid.replacingOccurrences(of: "func testSharingAgain()", with: "override func setUp()"),
        valid + "\nextension NoteLinks { func extra() { assertShareOptions(in: XCUIApplication()) } }",
        valid.replacingOccurrences(of: "assertShareOptions(in: app)", with: "record(assertShareOptions(in: app))"),
        valid.replacingOccurrences(of: "XCTAssertTrue(app.buttons[\"Content\"].exists", with: "XCTAssertTrue(super.isEqual(app)"),
        valid.replacingOccurrences(of: "private func assertShareOptions(in app: XCUIApplication) {", with: "private func assertShareOptions(in app: XCUIApplication) { struct Nested {}"),
        valid.replacingOccurrences(of: "private func assertShareOptions(in app: XCUIApplication) {", with: "private func assertShareOptions(in app: XCUIApplication) { let shared = shared;"),
        valid.replacingOccurrences(of: "private func assertShareOptions(in app: XCUIApplication)", with: "private func assertShareOptions(in app: inout XCUIApplication)")
    ]
    for text in unsafe { #expect(parse(text).units.compactMap(\.privateTestHelper).isEmpty, "\(text)") }
}

@Test(arguments: [false, true], ["plain", "escape", "objc", "state", "lifecycle"])
func compiledPrivateXCTestHelpersSelectOnlyProvenConsumers(added: Bool, safety: String) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("private-helper-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let helper = added ? navigationHelper : sharingHelper
    let call = added ? "let tab = navigationTab(\"Settings\", in: app); XCTAssertTrue(tab.exists)" : "assertShareOptions(in: app)"
    var before = helperFixture(added ? "" : helper, call: added ? "XCTAssertTrue(app.buttons[\"Settings\"].exists)" : call)
    var after = helperFixture(added ? helper : helper.replacingOccurrences(of: "    XCTAssertTrue(app.buttons[\"Content\"]", with: "    XCTAssertTrue(app.buttons[\"Send in Messages\"].exists, \"Expected a direct Messages card action.\")\n    XCTAssertTrue(app.buttons[\"Content\"]"), call: call)
    func unsafe(_ text: String) -> String {
        switch safety {
        case "escape": return text.replacingOccurrences(of: call, with: "_ = { [self] in " + call + " }")
        case "objc": return text.replacingOccurrences(of: "private func", with: "@objc private func")
        case "state":
            let declaration = added ? "-> XCUIElement {" : "private func assertShareOptions(in app: XCUIApplication) {"
            return "@MainActor var sharedState = false\n" + text.replacingOccurrences(of: declaration, with: declaration + "\nsharedState = true\n" + (added ? "return " : ""))
        case "lifecycle": return text.replacingOccurrences(of: "func testSharingAgain()", with: "override func setUp()")
        default: return text
        }
    }
    before = unsafe(before); after = unsafe(after)
    let files = ["UI.swift": after, "Support.swift": helperSupport, "Empty.swift": "// No declarations"]
    for (path, text) in files { try Data(text.utf8).write(to: root.appendingPathComponent(path)) }
    let platform = try CommandRunner.run("xcrun", ["--sdk", "macosx", "--show-sdk-platform-path"], at: root).text.trimmingCharacters(in: .whitespacesAndNewlines)
    let sil = root.appendingPathComponent("UI.sil")
    _ = try CommandRunner.run("xcrun", ["swiftc", "-emit-sil", "-whole-module-optimization", "-Onone", "-g", "-module-name", "UI",
        "-F", platform + "/Developer/Library/Frameworks", "-I", platform + "/Developer/usr/lib",
        root.appendingPathComponent("UI.swift").path, root.appendingPathComponent("Support.swift").path, root.appendingPathComponent("Empty.swift").path, "-o", sil.path], at: root)
    let parsed = try SILParser.parse(file: sil, module: "UI", sourceRoot: root)
    var graph = DependencyGraph(functions: parsed.functions)
    XcodeCompilerGraph.resolveDispatch(&graph, tables: parsed.dispatchTargets)
    let tests = ["UI/NoteLinks/testSharing()", "UI/NoteLinks/testSharingAgain()", "UI/NoteLinks/testUnrelated()", "UI/Calendar/testCalendar()"].filter { safety != "lifecycle" || !$0.contains("testSharingAgain") }
    var current = XcodeTestGraph(targets: [.init(name: "UI", productType: "com.apple.product-type.bundle.ui-testing", sourceFiles: Set(files.keys))], tests: tests)
    current.modules = ["UI": "UI"]
    current.sources = Dictionary(uniqueKeysWithValues: files.map { ("UI:" + $0.key, SwiftSourceSnapshot.parse($0.value, path: $0.key, module: "UI")) })
    current.mappings = UIFeatureMappings(features: [])
    current.mappings?.sourceLocationPolicy = .diagnosticLineColumn
    XcodeCompilerGraph.bind(tests: tests, modules: current.modules, sources: current.sources, graph: &graph)
    current.dependencies = graph
    // Evidence must survive the graph/archive JSON boundary used by consumers.
    current = try JSONDecoder().decode(XcodeTestGraph.self, from: JSONEncoder().encode(current))
    var base = current.sources
    base["UI:UI.swift"] = SwiftSourceSnapshot.parse(before, path: "UI.swift", module: "UI")
    let source = XcodeHeadOnlySources(base: base, mappings: current.mappings)
    let opaque = DependencyIndex(graph).paths(to: Set(graph.functions.values.filter(\.hasOpaqueRuntimeDependency).map(\.id)))
    let unrelated = "UI/Calendar/testCalendar()"
    #expect(opaque.path(from: graph.tests[unrelated] ?? []) != nil)
    func select(_ head: XcodeTestGraph, base: XcodeHeadOnlySources = source, paths: [String] = ["UI.swift"]) -> ImpactReport {
        XcodeHeadOnlySelector.select(current: head, source: base, changes: paths.map { .init(path: $0) }, baseRevision: "base", excludedTestEntries: Set(tests.prefix(2)))
    }
    let report = select(current)
    if safety != "plain" {
        #expect(report.selectedTests.contains(unrelated))
        #expect(report.diagnostics.contains { $0.code == (added ? "head_only_declaration_change" : safety == "objc" ? "head_only_unsupported_body" : "head_only_runtime_uncertainty") })
        return
    }
    let helperUnit = try #require(current.sources["UI:UI.swift"]?.units.first { $0.privateTestHelper != nil })
    #expect(PrivateTestHelperIsolation.proves(helperUnit, previous: base["UI:UI.swift"]?.units.first { $0.key == helperUnit.key }, current: current, base: base, graph: graph, index: DependencyIndex(graph)))
    #expect(report.selectedTests == Array(tests.prefix(2)))
    #expect(report.onlyTestingArguments == Array(tests.prefix(2)).map { "-only-testing:" + $0 })
    #expect(report.diagnostics.isEmpty, "\(String(describing: report.diagnostics))")
    #expect(report.explanations.allSatisfy { $0.kind == "dependency" && $0.reason.contains("private helper isolation") })

    // Incomplete roots, old archives and shared-state callees must never gain
    // precision from the absence of evidence.
    var missing = current
    missing.dependencies!.tests.removeValue(forKey: tests[3])
    #expect(select(missing).selectedTests.contains(tests[3]))
    var legacy = current
    legacy.sources["UI:UI.swift"]!.identifierNames = nil
    #expect(select(legacy).selectedTests.contains(tests[3]))
    var legacyProof = current
    for i in legacyProof.sources["UI:UI.swift"]!.units.indices {
        legacyProof.sources["UI:UI.swift"]!.units[i].privateTestHelper?.statements = nil
    }
    legacyProof = try JSONDecoder().decode(XcodeTestGraph.self, from: JSONEncoder().encode(legacyProof))
    #expect(select(legacyProof).selectedTests.contains(tests[3]))
    for version in [nil, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, PrivateTestHelperSyntax.currentProofVersion + 1] as [Int?] {
        var staleProof = current
        for i in staleProof.sources["UI:UI.swift"]!.units.indices {
            staleProof.sources["UI:UI.swift"]!.units[i].privateTestHelper?.proofVersion = version
        }
        staleProof = try JSONDecoder().decode(XcodeTestGraph.self, from: JSONEncoder().encode(staleProof))
        #expect(select(staleProof).selectedTests.contains(tests[3]))
    }
    var missingEffects = current
    for i in missingEffects.sources["UI:UI.swift"]!.units.indices {
        missingEffects.sources["UI:UI.swift"]!.units[i].privateTestHelper?.calleeEffectsSupported = nil
    }
    #expect(select(missingEffects).selectedTests == tests.sorted())
    #expect(select(missingEffects).diagnostics.contains { $0.code == "head_only_helper_callee_effects" })
    var state = current
    let helperIDs = graph.functions.values.filter { $0.name.contains(added ? ".navigationTab(" : ".assertShareOptions(") }.map(\.id)
    #expect(!helperIDs.isEmpty)
    for id in helperIDs { state.dependencies!.functions[id]!.uncertainties.insert("Global state access") }
    #expect(select(state).selectedTests.contains(tests[3]))

    for (path, text) in [
        ("Shadow.swift", "typealias String = () -> Void"),
        ("Other.swift", "func " + (added ? "navigationTab" : "assertShareOptions") + "() {}"),
        ("Extension.swift", "@MainActor extension NoteLinks {}")
    ] {
        var ambiguous = current
        ambiguous.sources["UI:" + path] = SwiftSourceSnapshot.parse(text, path: path, module: "UI")
        #expect(select(ambiguous).selectedTests.contains(unrelated))
    }
    var exposed = current
    exposed.sources["UI:Support.swift"] = SwiftSourceSnapshot.parse(helperSupport.replacingOccurrences(of: "class UITestCase", with: "@objcMembers class UITestCase"), path: "Support.swift", module: "UI")
    #expect(select(exposed).selectedTests.contains(unrelated))
    var incomplete = current
    incomplete.dependencies!.testDiagnostics[tests[3]] = ["Incomplete lifecycle binding"]
    #expect(select(incomplete).selectedTests.contains(unrelated))

    var mixed = current
    mixed.targets.append(.init(name: "App", productType: "com.apple.product-type.application", sourceFiles: ["App.swift"]))
    mixed.modules["App"] = "App"
    mixed.sources["App:App.swift"] = SwiftSourceSnapshot.parse("func newProduction() {}", path: "App.swift", module: "App")
    #expect(select(mixed, paths: ["UI.swift", "App.swift"]).selectedTests == tests.sorted())
    #expect(select(mixed).selectedTests == report.selectedTests)

    // Exercise the public scope machinery with actual base Git syntax, one
    // already compiled head graph, and an unrelated structural production edit.
    try Data(before.utf8).write(to: root.appendingPathComponent("UI.swift"))
    try JSONEncoder().encode(current.mappings).write(to: root.appendingPathComponent(".swift-test-selection.json"))
    _ = try CommandRunner.run("git", ["init", "-q"], at: root)
    _ = try CommandRunner.run("git", ["add", "UI.swift", "Support.swift", ".swift-test-selection.json"], at: root)
    _ = try CommandRunner.run("git", ["-c", "user.name=Tests", "-c", "user.email=tests@example.invalid", "commit", "-qm", "base"], at: root)
    let baseRevision = try CommandRunner.run("git", ["rev-parse", "HEAD"], at: root).text.trimmingCharacters(in: .whitespacesAndNewlines)
    try Data(after.utf8).write(to: root.appendingPathComponent("UI.swift"))
    let scopes = try XcodeHeadOnlySelector.scopedReports(current: mixed,
        requests: .init(scopes: [.init(name: "helpers", paths: ["UI.swift"], excludedTestEntries: Array(tests.prefix(2)))]),
        changes: [.init(path: "UI.swift"), .init(path: "App.swift")], baseRevision: baseRevision, headRevision: "head",
        root: root, mappingPath: ".swift-test-selection.json", documentation: [], buildEvidenceFailure: nil)
    #expect(scopes.first?.report.selectedTests == report.selectedTests)
    #expect(scopes.first?.report.diagnostics.isEmpty == true)

    // A surviving app edit uses its ordinary mapping; helper isolation must
    // neither erase that selection nor import unrelated UI runtime uncertainty.
    mixed.sources["App:App.swift"] = SwiftSourceSnapshot.parse("func feature() -> Int { 2 }", path: "App.swift", module: "App")
    var mixedBase = base
    mixedBase["App:App.swift"] = SwiftSourceSnapshot.parse("func feature() -> Int { 1 }", path: "App.swift", module: "App")
    mixed.dependencies!.functions["feature"] = FunctionNode(id: "feature", module: "App", name: "feature()", regions: [.init(path: "App.swift", startLine: 1, endLine: 1)])
    mixed.mappings = UIFeatureMappings(features: [.init(name: "feature", sources: ["App.swift"], tests: [unrelated]),
        .init(name: "other", tests: Array(tests.prefix(3)))])
    mixed.mappings?.sourceLocationPolicy = .diagnosticLineColumn
    mixed.mappings?.runtimeDependencyPolicy = .declared
    let mixedReport = select(mixed, base: .init(base: mixedBase, mappings: mixed.mappings), paths: ["UI.swift", "App.swift"])
    #expect(mixedReport.selectedTests == (Array(tests.prefix(2)) + [unrelated]).sorted())
    #expect(mixedReport.explanations.contains { $0.test == unrelated && $0.kind == "explicitMapping" })
    #expect(mixedReport.diagnostics.isEmpty)
}

// The reopened #55 case combines three private helpers, a local screenshot
// attachment, and a separately executed added entry in the same review scope.
@Test(arguments: ["plain", "escape", "lifecycle", "state", "cycle", "changedAncestor"])
func compiledPrivateHelperChainAndAddedEntry(safety: String) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("helper-chain-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let newEntry = """
        func testUnavailableMessagesStillOffersLinkSharing() {
            let app = XCUIApplication()
            app.launchEnvironment["COC_UI_TEST_NOTE_MESSAGE_CARD_AVAILABLE"] = "0"
            app.launch()
            openNoteShareMenu(in: app)
            XCTAssertFalse(app.buttons["Send in Messages"].isEnabled)
            XCTAssertTrue(app.buttons["Link"].isEnabled)
        }
    """
    let fixture = """
    import XCTest
    @MainActor final class NoteLinks: UITestCase {
        func testDirect() { assertShareOptions(in: XCUIApplication()) }
        func testSubmenu() { openShareSubmenu(in: XCUIApplication()) }
        func testOuter() { openNoteShareMenu(in: XCUIApplication()) }
        func testUnrelated() { XCTAssertTrue(true) }
        private func openNoteShareMenu(in app: XCUIApplication) {
            let options = app.buttons["note-navigation-menu"]
            XCTAssertTrue(options.waitUntilExists(timeout: 5))
            options.tap()
            let menu = XCTAttachment(screenshot: app.screenshot())
            menu.name = "Note options with Outline Activity and Share"
            menu.lifetime = .keepAlways
            add(menu)
            openShareSubmenu(in: app)
        }
        private func openShareSubmenu(in app: XCUIApplication) {
            let share = app.buttons["Share"]
            XCTAssertTrue(share.waitUntilExists(timeout: 5))
            XCTAssertFalse(app.buttons["Copy Link"].exists)
            share.tap()
            assertShareOptions(in: app)
        }
        \(sharingHelper)
        // NEW_ENTRY
    }
    """
    func variant(_ text: String) -> String {
        switch safety {
        case "escape": return text.replacingOccurrences(of: "openShareSubmenu(in: app)", with: "let callback = { [self] in openShareSubmenu(in: app) }; callback()")
        case "lifecycle": return text.replacingOccurrences(of: "func testOuter()", with: "override func setUp()")
        case "state": return "@MainActor var shared = false\n" + text.replacingOccurrences(of: "share.tap()", with: "shared = true; share.tap()")
        case "cycle": return text.replacingOccurrences(of: "share.tap()", with: "share.tap(); openNoteShareMenu(in: app)")
        default: return text
        }
    }
    var before = variant(fixture)
    let after = variant(fixture.replacingOccurrences(of: "// NEW_ENTRY", with: newEntry)
        .replacingOccurrences(of: "    XCTAssertTrue(app.buttons[\"Content\"]", with: "    XCTAssertTrue(app.buttons[\"Send in Messages\"].exists)\n    XCTAssertTrue(app.buttons[\"Content\"]"))
    if safety == "changedAncestor" { before = before.replacingOccurrences(of: "share.tap()", with: "share.doubleTap()") }
    let files = ["UI.swift": after, "Support.swift": helperSupport]
    for (path, source) in files { try Data(source.utf8).write(to: root.appendingPathComponent(path)) }
    let platform = try CommandRunner.run("xcrun", ["--sdk", "macosx", "--show-sdk-platform-path"], at: root).text.trimmingCharacters(in: .whitespacesAndNewlines)
    let sil = root.appendingPathComponent("UI.sil")
    _ = try CommandRunner.run("xcrun", ["swiftc", "-emit-sil", "-whole-module-optimization", "-Onone", "-g", "-module-name", "UI",
        "-F", platform + "/Developer/Library/Frameworks", "-I", platform + "/Developer/usr/lib",
        root.appendingPathComponent("UI.swift").path, root.appendingPathComponent("Support.swift").path, "-o", sil.path], at: root)
    let parsed = try SILParser.parse(file: sil, module: "UI", sourceRoot: root)
    var graph = DependencyGraph(functions: parsed.functions)
    XcodeCompilerGraph.resolveDispatch(&graph, tables: parsed.dispatchTargets)
    let added = "UI/NoteLinks/testUnavailableMessagesStillOffersLinkSharing()"
    let consumers = ["UI/NoteLinks/testDirect()", "UI/NoteLinks/testSubmenu()", "UI/NoteLinks/testOuter()", added]
    let unrelated = "UI/Calendar/testCalendar()"
    let tests = (consumers + ["UI/NoteLinks/testUnrelated()", unrelated]).filter { safety != "lifecycle" || !$0.contains("testOuter") }.sorted()
    var current = XcodeTestGraph(targets: [.init(name: "UI", productType: "com.apple.product-type.bundle.ui-testing", sourceFiles: Set(files.keys))], tests: tests)
    current.modules = ["UI": "UI"]
    current.sources = Dictionary(uniqueKeysWithValues: files.map { ("UI:" + $0.key, SwiftSourceSnapshot.parse($0.value, path: $0.key, module: "UI")) })
    current.mappings = UIFeatureMappings(features: [])
    current.mappings?.sourceLocationPolicy = .diagnosticLineColumn
    XcodeCompilerGraph.bind(tests: tests, modules: current.modules, sources: current.sources, graph: &graph)
    #expect(tests.allSatisfy { graph.tests[$0]?.isEmpty == false && graph.testDiagnostics[$0]?.isEmpty ?? true })
    current.dependencies = graph
    current = try JSONDecoder().decode(XcodeTestGraph.self, from: JSONEncoder().encode(current))
    var base = current.sources
    base["UI:UI.swift"] = SwiftSourceSnapshot.parse(before, path: "UI.swift", module: "UI")
    let selfBase = base
    func select(_ head: XcodeTestGraph, base: [String: SwiftSourceSnapshot]? = nil, excluded: Set<String> = [added]) -> ImpactReport {
        XcodeHeadOnlySelector.select(current: head, source: .init(base: base ?? selfBase, mappings: current.mappings),
            changes: [.init(path: "UI.swift")], baseRevision: "base", excludedTestEntries: excluded)
    }
    let report = select(current)
    if safety != "plain" {
        #expect(report.selectedTests.contains(unrelated), "\(safety): \(report)")
        #expect(!report.diagnostics.isEmpty)
        return
    }
    #expect(report.selectedTests == consumers.sorted(), "\(report)")
    #expect(report.onlyTestingArguments == consumers.sorted().map { "-only-testing:" + $0 })
    #expect(report.diagnostics.isEmpty, "\(report.diagnostics)")
    #expect(report.explanations.allSatisfy { $0.kind == "dependency" && $0.reason.contains("private helper isolation") })
    #expect(select(current, excluded: []).selectedTests == tests) // primary includes new entries

    // Added-entry-only diff is already covered by the consumer's separate run.
    var entryBase = base
    entryBase["UI:UI.swift"] = SwiftSourceSnapshot.parse(after.replacingOccurrences(of: newEntry, with: ""), path: "UI.swift", module: "UI")
    #expect(select(current, base: entryBase).selectedTests.isEmpty)
    #expect(select(current, base: entryBase).diagnostics.isEmpty)
    for fault in ["legacy", "missingRoot", "unknownConsumer", "ancestorState", "baseName", "otherFileName", "nonfinal", "unsupported", "attachmentAPI", "legacyAttachment"] {
        var broken = current, old = entryBase
        switch fault {
        case "legacy":
            for i in broken.sources["UI:UI.swift"]!.units.indices { broken.sources["UI:UI.swift"]!.units[i].independentAddedTestEntry = nil }
        case "missingRoot": broken.dependencies!.tests[unrelated] = []
        case "unknownConsumer": broken.dependencies!.functions[graph.tests[unrelated]!.first!]!.dependencies.formUnion(graph.tests[added]!)
        case "ancestorState":
            for id in graph.functions.keys where graph.functions[id]!.name.contains(".openShareSubmenu(") {
                broken.dependencies!.functions[id]!.uncertainties.insert("Global state access")
            }
            old = base
        case "attachmentAPI":
            broken.sources["UI:Support.swift"] = SwiftSourceSnapshot.parse(helperSupport + "\nfunc add(_ attachment: XCTAttachment) {}", path: "Support.swift", module: "UI")
            old = base
        case "legacyAttachment": broken.sources["UI:Support.swift"]!.attachmentAddUnshadowed = nil; old = base
        case "baseName": old["UI:Collision.swift"] = SwiftSourceSnapshot.parse("func testUnavailableMessagesStillOffersLinkSharing() {}", path: "Collision.swift", module: "UI")
        case "otherFileName": broken.sources["UI:Collision.swift"] = SwiftSourceSnapshot.parse("func testUnavailableMessagesStillOffersLinkSharing() {}", path: "Collision.swift", module: "UI")
        case "nonfinal": broken.sources["UI:UI.swift"] = SwiftSourceSnapshot.parse(after.replacingOccurrences(of: "final class NoteLinks", with: "class NoteLinks"), path: "UI.swift", module: "UI")
        default: broken.sources["UI:UI.swift"] = SwiftSourceSnapshot.parse(after.replacingOccurrences(of: "func testUnavailable", with: "@objc func testUnavailable"), path: "UI.swift", module: "UI")
        }
        #expect(select(broken, base: old).selectedTests.contains(unrelated), "\(fault)")
    }
    // The public scope path reads actual base Git syntax and preserves retained
    // graph identity, so this is the same query a consumer makes after capture.
    try Data(before.utf8).write(to: root.appendingPathComponent("UI.swift"))
    try JSONEncoder().encode(current.mappings).write(to: root.appendingPathComponent(".swift-test-selection.json"))
    _ = try CommandRunner.run("git", ["init", "-q"], at: root)
    _ = try CommandRunner.run("git", ["add", "UI.swift", "Support.swift", ".swift-test-selection.json"], at: root)
    _ = try CommandRunner.run("git", ["-c", "user.name=Tests", "-c", "user.email=tests@example.invalid", "commit", "-qm", "base"], at: root)
    try Data(after.utf8).write(to: root.appendingPathComponent("UI.swift"))
    let scopes = try XcodeHeadOnlySelector.scopedReports(current: current,
        requests: .init(scopes: [.init(name: "helpers", paths: ["UI.swift"], excludedTestEntries: [added])]),
        changes: [.init(path: "UI.swift")], baseRevision: "HEAD", headRevision: "head", root: root,
        mappingPath: ".swift-test-selection.json", documentation: [], buildEvidenceFailure: nil, retainedGraphPath: "/retained/head.json")
    let scoped = try #require(scopes.first?.report)
    #expect(scoped.selectedTests == report.selectedTests)
    #expect(scoped.diagnostics.isEmpty)
    #expect(scoped.buildArtifactPath == "/retained/head.json")
    #expect(scoped.headRevision == "head")
}

@Test func attachmentProofDistinguishesLocalNamesFromShadowedAPIs() {
    for text in ["func add(_ value: Int) {}", "let add = 1", "class Base { let add = 1 }", "extension XCTestCase { func add(_ value: Int) {} }"] {
        #expect(SwiftSourceSnapshot.parse(text, path: "UI.swift", module: "UI").attachmentAddUnshadowed == false, "\(text)")
    }
    #expect(SwiftSourceSnapshot.parse("func unrelated() { let add = 1 }", path: "UI.swift", module: "UI").attachmentAddUnshadowed == true)
    let body = """
    private func captureMenuAttachment(in app: XCUIApplication) {
        let menu = XCTAttachment(screenshot: app.screenshot())
        menu.name = "Menu"
        menu.lifetime = .keepAlways
        add(menu)
    }
    """
    let valid = helperFixture(body, call: "captureMenuAttachment(in: app)")
    #expect(SwiftSourceSnapshot.parse(valid, path: "UI.swift", module: "UI").units.compactMap(\.privateTestHelper).first?.localAttachmentState == true)
    for text in [valid.replacingOccurrences(of: "let menu = XCTAttachment(screenshot: app.screenshot())", with: "let menu = sharedAttachment"),
                 valid.replacingOccurrences(of: "menu.name =", with: "app.name ="),
                 valid.replacingOccurrences(of: "add(menu)", with: "add(app)"),
                 valid.replacingOccurrences(of: "let menu =", with: "var menu ="),
                 valid.replacingOccurrences(of: "menu.name =", with: "let menu = app; menu.name =")] {
        #expect(SwiftSourceSnapshot.parse(text, path: "UI.swift", module: "UI").units.compactMap(\.privateTestHelper).isEmpty, "\(text)")
    }
}
