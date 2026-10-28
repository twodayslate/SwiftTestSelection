// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation
import Testing
@testable import TestImpact

private func precisionRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("precision-tickets-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

@Test(arguments: [false, true])
func survivingPrivateHelperLimitationsPreserveDependencySelection(opaqueOther: Bool) throws {
    let root = try precisionRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let before = """
    import XCTest
    final class Suite: XCTestCase {
        func testConsumer() { _ = candidate() }
        private func candidate() -> Int {
            if true { let value = 1; return value }
            return 0
        }
    }
    final class Other: XCTestCase {
        func testOther() { \(opaqueOther ? "_ = evaluate { true }" : "") }
    }
    func evaluate(_ body: () -> Bool) -> Bool { body() }
    """
    let after = before.replacingOccurrences(of: "let value = 1", with: "let value = 2")
    let tests = ["UI/Suite/testConsumer()", "UI/Other/testOther()"]
    let current = try boundaryGraph(["UI.swift": after], tests: tests, root: root)
    let helper = try #require(current.sources["UI:UI.swift"]?.units.first { $0.helperCallableName == "candidate" })
    #expect(helper.privateTestHelper == nil)
    #expect(helper.privateTestHelperBlocker?.contains("Nested local declaration") == true)
    let report = XcodeHeadOnlySelector.select(current: current,
        source: .init(base: ["UI:UI.swift": .parse(before, path: "UI.swift", module: "UI")], mappings: current.mappings),
        changes: [.init(path: "UI.swift")], baseRevision: "base")
    #expect(report.selectedTests == (opaqueOther ? tests.sorted() : [tests[0]]))
    #expect(report.explanations.contains { $0.test == tests[0] && $0.kind == "dependency" })
    if opaqueOther {
        #expect(report.diagnostics.contains { $0.code == "head_only_runtime_uncertainty" && $0.tests.contains(tests[1]) })
    } else {
        #expect(report.diagnostics.isEmpty)
    }
}

@Test(arguments: ["sdk", "namesake", "escapedNamesake", "alias", "escapedAlias", "foreign", "overload", "comparisonOverride"])
func gestureVelocityRequiresAuthenticatedSDKIdentity(kind: String) throws {
    let root = try precisionRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    var before = """
    import XCTest
    @MainActor final class Suite: XCTestCase {
        func testConsumer() {
            let app = XCUIApplication()
            let coordinate = app.coordinate(withNormalizedOffset: .zero)
            for velocity: XCUIGestureVelocity in [.slow, .fast] {
                coordinate.press(forDuration: velocity == .slow ? 0.1 : 0, thenDragTo: coordinate, withVelocity: velocity, thenHoldForDuration: 0)
            }
            candidate()
        }
        private func candidate() { XCTAssertTrue(true) }
    }
    @MainActor final class Other: XCTestCase { func testOther() { XCTAssertTrue(true) } }
    """
    let shadow = "struct XCUIGestureVelocity: Equatable { static let slow = Self(); static let fast = Self() }"
    let overload = """
    extension XCUICoordinate {
        func press(forDuration: Double, thenDragTo: XCUICoordinate, withVelocity: XCUIGestureVelocity, thenHoldForDuration: Int) { UserDefaults.standard.set(true, forKey: "overload-state") }
    }
    """
    var arguments: [String] = []
    switch kind {
    case "namesake": before += "\n" + shadow + "\n" + overload
    case "escapedNamesake": before += "\n" + shadow.replacingOccurrences(of: "struct XCUIGestureVelocity", with: "struct `XCUIGestureVelocity`") + "\n" + overload
    case "escapedAlias": before += "\nstruct CustomVelocity: Equatable { static let slow = Self(); static let fast = Self() }\ntypealias `XCUIGestureVelocity` = CustomVelocity\n" + overload
    case "comparisonOverride": before += "\nextension XCUIGestureVelocity { static func == (lhs: Self, rhs: Self) -> Bool { UserDefaults.standard.set(true, forKey: \"comparison\"); return true } }"
    case "alias": before += "\nstruct CustomVelocity: Equatable { static let slow = Self(); static let fast = Self() }\ntypealias XCUIGestureVelocity = CustomVelocity\n" + overload
    case "foreign":
        let file = root.appendingPathComponent("Foreign.swift")
        try Data("public struct XCUIGestureVelocity: Equatable { public static let slow = Self(); public static let fast = Self() }".utf8).write(to: file)
        _ = try CommandRunner.run("xcrun", ["swiftc", "-emit-module", "-module-name", "Foreign", file.path, "-emit-module-path", root.appendingPathComponent("Foreign.swiftmodule").path], at: root)
        before = before.replacingOccurrences(of: "import XCTest", with: "import XCTest\nimport Foreign")
            .replacingOccurrences(of: "for velocity: XCUIGestureVelocity", with: "for velocity: Foreign.XCUIGestureVelocity")
        before += "\nextension XCUICoordinate { func press(forDuration: Double, thenDragTo: XCUICoordinate, withVelocity: Foreign.XCUIGestureVelocity, thenHoldForDuration: Int) {} }"
        arguments = ["-I", root.path]
    case "overload": before += "\n" + overload
    default: break
    }
    let after = before.replacingOccurrences(of: "private func candidate() { XCTAssertTrue(true) }", with: "private func candidate() { XCTAssertTrue(true); XCTAssertFalse(false) }")
    let tests = ["UI/Suite/testConsumer()", "UI/Other/testOther()"]
    let current = try boundaryGraph(["UI.swift": after], tests: tests, root: root, compilerArguments: arguments)
    let consumer = try #require(current.dependencies?.functions.values.first { $0.name == "Suite.testConsumer()" })
    if kind == "sdk" {
        #expect(consumer.receiverTypeOrigins?.contains("literal:XCUIGestureVelocity") == true)
        #expect(consumer.stateAccesses?.isSuperset(of: ["global:XCUIGestureVelocitySlow", "global:XCUIGestureVelocityFast"]) == true)
    }
    let report = XcodeHeadOnlySelector.select(current: current,
        source: .init(base: ["UI:UI.swift": .parse(before, path: "UI.swift", module: "UI")], mappings: current.mappings),
        changes: [.init(path: "UI.swift")], baseRevision: "base")
    #expect(report.selectedTests == (kind == "sdk" ? [tests[0]] : tests.sorted()), "\(report.diagnostics)")
    if kind == "sdk" { #expect(report.diagnostics.isEmpty) }
}

@Test(arguments: ["swift", "objc", "default", "sdkOwner", "alias", "unresolved", "legacy"])
func protocolInitializerRequirementsKeepImplementationChecks(kind: String) throws {
    let requirement = kind == "objc"
        ? "import Foundation\n@objc protocol TouchPath: NSObjectProtocol { @objc(initForTouchAtPoint:offset:) init(point: CGPoint, offset: TimeInterval) }"
        : "protocol TouchPath { init(point: Int) }"
    var snapshot = SwiftSourceSnapshot.parse(requirement, path: "Touch.swift", module: "UI")
    var sources = [snapshot]
    switch kind {
    case "default": sources.append(.parse("extension TouchPath { init(point: Int) { self.init(point: point) } }", path: "Default.swift", module: "UI"))
    case "sdkOwner": sources = [.parse("protocol XCUIElement { init(point: Int) }", path: "Shadow.swift", module: "UI")]
    case "alias": sources.append(.parse("typealias TouchPath = XCUIElement", path: "Alias.swift", module: "UI"))
    case "unresolved": sources = [.parse("extension Unknown { init(point: Int) {} }", path: "Unknown.swift", module: "UI")]
    case "legacy":
        for i in snapshot.units.indices { snapshot.units[i].bodylessProtocolRequirement = nil }
        sources = [snapshot]
    default: break
    }
    for revisions in [[sources, []], [[], sources]] {
        let restored = try JSONDecoder().decode([[SwiftSourceSnapshot]].self, from: JSONEncoder().encode(revisions))
        let blocker = SDKTestHelperIsolation.memberBindingBlocker(revisions: restored, members: ["init"], sdkOwners: ["XCUIElement", "NSObject", "NSObjectProtocol"])
        #expect((blocker == nil) == ["swift", "objc"].contains(kind), "\(blocker ?? "none")")
        if !["swift", "objc"].contains(kind) { #expect(blocker?.contains(".init at") == true) }
    }
}

@Test(arguments: ["swift", "objc", "default", "baseDefault"])
func compiledProtocolInitializerDoesNotBroadenPrivateHelper(kind: String) throws {
    let root = try precisionRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let before = """
    import XCTest
    @MainActor final class Suite: XCTestCase {
        func testConsumer() { candidate(in: XCUIApplication()) }
        private func candidate(in app: XCUIApplication) { XCTAssertTrue(app.waitUntilExists(timeout: 3)) }
    }
    @MainActor final class Other: XCTestCase { func testOther() { XCTAssertTrue(true) } }
    extension XCUIElement {
        func waitUntilExists(timeout: TimeInterval) -> Bool { exists || waitForExistence(timeout: timeout) }
    }
    """
    let requirement = kind == "objc"
        ? "import Foundation\n@objc protocol TouchPath: NSObjectProtocol { @objc(initForTouchAtPoint:offset:) init(point: CGPoint, offset: TimeInterval) }"
        : "protocol TouchPath { init(point: Int) }"
    let after = before.replacingOccurrences(of: "XCTAssertTrue(app.waitUntilExists(timeout: 3))", with: "XCTAssertTrue(app.waitUntilExists(timeout: 3)); XCTAssertFalse(false)")
    let tests = ["UI/Suite/testConsumer()", "UI/Other/testOther()"]
    let implementation = "extension TouchPath { init(point: Int) { self.init(point: point) } }"
    var files = ["UI.swift": after, "Touch.swift": requirement]
    if kind == "default" { files["Default.swift"] = implementation }
    let current = try boundaryGraph(files, tests: tests, root: root)
    #expect(current.sources["UI:UI.swift"]?.units.contains { $0.privateTestHelper?.name == "candidate" } == true)
    var base = current.sources
    if kind == "baseDefault" { base["UI:Default.swift"] = .parse(implementation, path: "Default.swift", module: "UI") }
    base["UI:UI.swift"] = .parse(before, path: "UI.swift", module: "UI")
    let report = XcodeHeadOnlySelector.select(current: current, source: .init(base: base, mappings: current.mappings), changes: [.init(path: "UI.swift")], baseRevision: "base")
    if ["swift", "objc"].contains(kind) {
        #expect(report.selectedTests == [tests[0]], "\(report.diagnostics)")
        #expect(report.diagnostics.isEmpty)
        #expect(report.explanations.contains { $0.reason.contains("private helper isolation") })
    } else {
        #expect(report.selectedTests == tests.sorted())
        #expect(report.diagnostics.contains { $0.code == "head_only_helper_callee_effects" && $0.message.contains("TouchPath.init at Default.swift:") }, "\(report.diagnostics)")
    }
}

@Test(arguments: ["entries", "helper", "escape", "lifecycle", "state", "defaultEffect", "nestedLocal", "overload", "binding"])
func compiledExtensionEntriesAndHelpersRequireIsolation(kind: String) throws {
    let root = try precisionRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let before = """
    import XCTest
    @MainActor final class Suite: XCTestCase {
        func testExisting() { XCTAssertTrue(true) }
    }
    @MainActor final class Other: XCTestCase { func testOther() { XCTAssertTrue(true) } }
    """
    var helper = kind == "entries" ? "" : "private func check(_ value: Bool = false) { XCTAssertFalse(value) }"
    var call = kind == "entries" ? "XCTAssertTrue(true)" : "check()"
    switch kind {
    case "escape": call = "let callback = check; callback(false)"
    case "state": helper = "private func check(_ value: Bool = false) { UserDefaults.standard.set(value, forKey: \"shared\") }"
    case "defaultEffect": helper = "private func check(_ value: Bool = UserDefaults.standard.bool(forKey: \"shared\")) { XCTAssertFalse(value) }"
    case "nestedLocal": helper = "private func check(_ value: Bool = false) { for _ in 0..<2 { let flag = value; XCTAssertFalse(flag) } }"
    case "overload": helper += "\nprivate func check(_ value: Int = 0) { XCTAssertEqual(value, 0) }"; call = "check(false)"
    default: break
    }
    var after = before + """
    
    extension Suite {
        \(helper)
        func testAdded() { \(call) }
    }
    extension Suite {
        func testSecond() { XCTAssertTrue(true) }
    }
    """
    if kind == "lifecycle" { after = after.replacingOccurrences(of: "func testExisting() {", with: "override func setUp() { check();") }
    let tests = (["UI/Suite/testExisting()", "UI/Suite/testAdded()", "UI/Suite/testSecond()", "UI/Other/testOther()"]).filter { kind != "lifecycle" || !$0.contains("testExisting") }
    var current = try boundaryGraph(["UI.swift": after], tests: tests, root: root)
    if kind == "binding" { current.dependencies?.tests["UI/Suite/testAdded()"] = [] }
    current = try GraphArchive.decode(GraphArchive.encode(current))
    let source = XcodeHeadOnlySources(base: ["UI:UI.swift": .parse(before, path: "UI.swift", module: "UI")], mappings: current.mappings)
    let excluded: Set<String> = ["UI/Suite/testAdded()", "UI/Suite/testSecond()"]
    let report = XcodeHeadOnlySelector.select(current: current, source: source, changes: [.init(path: "UI.swift")], baseRevision: "base", excludedTestEntries: excluded)
    if ["entries", "helper"].contains(kind) {
        #expect(report.selectedTests == (kind == "entries" ? [] : ["UI/Suite/testAdded()"]), "\(report.diagnostics)")
        #expect(report.diagnostics.isEmpty, "\(report.diagnostics)")
        let primary = XcodeHeadOnlySelector.select(current: current, source: source, changes: [.init(path: "UI.swift")], baseRevision: "base")
        #expect(excluded.isSubset(of: Set(primary.selectedTests)))
    } else {
        #expect(report.selectedTests.contains("UI/Other/testOther()"), "\(report)")
        #expect(!report.diagnostics.isEmpty)
        if kind == "nestedLocal" { #expect(report.diagnostics.contains { $0.message.contains("Nested local declaration") }) }
        if kind == "defaultEffect" { #expect(report.diagnostics.contains { $0.message.contains("Default argument") }) }
    }
}

@Test(arguments: ["plain", "attribute", "conformance", "conditional", "nonfinal", "alias", "ambiguous", "missingBase", "legacy"])
func extensionHeadersRequireExistingFinalUnambiguousOwner(kind: String) throws {
    var text = "import XCTest\nfinal class Suite: XCTestCase {}\nextension Suite {}\nextension Suite {}"
    switch kind {
    case "attribute": text = text.replacingOccurrences(of: "extension Suite", with: "@MainActor extension Suite")
    case "conformance": text += "\nprotocol P {}\nextension Suite: P {}"
    case "conditional": text += "\n#if DEBUG\nextension Suite {}\n#endif"
    case "nonfinal": text = text.replacingOccurrences(of: "final class", with: "class")
    case "alias": text += "\ntypealias Suite = Another"
    case "ambiguous": text += "\nfinal class Suite: XCTestCase {}"
    default: break
    }
    var snapshot = SwiftSourceSnapshot.parse(text, path: "UI.swift", module: "UI")
    if kind == "legacy" { for i in snapshot.units.indices { snapshot.units[i].plainExtension = nil } }
    var current = XcodeTestGraph(targets: [], tests: [])
    current.sources = ["UI:UI.swift": snapshot]
    let units = snapshot.units.filter { $0.kind == "extension" }
    let base = kind == "missingBase" ? [:] : current.sources
    #expect(PrivateTestHelperIsolation.provesExtensionHeaders(units, current: current, base: base) == (kind == "plain"))
}

@Test func gestureVelocityContractIsOnlyTheSDKEqualityWitness() throws {
    let witness = "$sSo19XCUIGestureVelocityaSQSCSQ2eeoiySbx_xtFZTW"
    let rawValue = "$sSo19XCUIGestureVelocityaSYSCSY8rawValue03RawD0QzvgTW"
    let constructor = "$sSo19XCUIGestureVelocitya8rawValueAB12CoreGraphics7CGFloatV_tcfC"
    let symbols = [witness, rawValue, constructor]
    let output = try CommandRunner.run("xcrun", ["swift-demangle", "--expand", "--tree-only"] + symbols,
        at: FileManager.default.temporaryDirectory).text
    #expect(ExternalHelperEffects.trustedDeclarations(output, receiverOrigins: true) == [witness])
    #expect(ExternalHelperEffects.trustedDeclarations(output.replacingOccurrences(of: "__C_Synthesized", with: "Foreign"), receiverOrigins: true).isEmpty)
}
