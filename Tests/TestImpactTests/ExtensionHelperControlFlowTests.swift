// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation
import Testing
@testable import TestImpact

private let scrollingHelper = #"""
    private func revealInboxFilter(_ identifier: String, in app: XCUIApplication, towardLeading: Bool = false) {
        let bar = app.scrollViews["notification-inbox-filters"]
        XCTAssertTrue(bar.waitForExistence(timeout: 3), "The inbox filter bar should be visible before scrolling.")
        let button = app.buttons[identifier]
        for _ in 0..<8 {
            let top = app.navigationBars.firstMatch.frame.maxY
            let frame = bar.frame
            let viewport = frame.intersection(CGRect(x: frame.minX + 8, y: top,
                                                     width: frame.width - 16, height: max(0, frame.maxY - top)))
            if button.exists {
                let buttonFrame = button.frame
                if !buttonFrame.isEmpty, viewport.contains(buttonFrame), button.isHittable { return }
            }
            // SwiftUI includes the navigation safe area in the scroll view's AX
            // frame. Drag the visible chips, not the navigation bar above them.
            let origin = app.coordinate(withNormalizedOffset: .zero)
            let start = origin.withOffset(CGVector(dx: viewport.midX, dy: viewport.midY))
            let end = start.withOffset(CGVector(dx: viewport.width * (towardLeading ? 0.35 : -0.35), dy: 0))
            start.press(forDuration: 0.01, thenDragTo: end)
        }
        XCTFail("The inbox filter \(identifier) should become fully visible.")
    }

"""#

@Test(arguments: ["scroll", "state", "escape", "lifecycle", "overload", "binding", "legacy", "shadow", "sibling", "initializer", "mutable", "callback", "unbounded", "geometryOverload", "coordinateOverload", "missingDynamic", "pattern", "moduleCollision", "optionalString", "optionalFormatting"])
func compiledExtensionScrollingHelperRequiresCompleteEffects(kind: String) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("extension-loop-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let before = """
    import XCTest
    @MainActor final class Suite: XCTestCase { func testExisting() { XCTAssertTrue(true) } }
    @MainActor final class Other: XCTestCase { func testOther() { XCTAssertTrue(true) } }
    """
    var helper = scrollingHelper
    var call = "revealInboxFilter(\"filter\", in: XCUIApplication())"
    var extra = ""
    switch kind {
    case "state": helper = helper.replacingOccurrences(of: "let top =", with: "UserDefaults.standard.set(true, forKey: \"shared\"); let top =")
    case "escape": call = "let callback = revealInboxFilter; callback(\"filter\", XCUIApplication(), false)"
    case "lifecycle": extra = "extension Suite { override func setUp() { revealInboxFilter(\"filter\", in: XCUIApplication()) } }"
    case "overload": extra = "extension Suite { private func revealInboxFilter(_ value: Int) {} }"
    case "shadow": helper = helper.replacingOccurrences(of: "let top =", with: "let app = XCUIApplication(); let top =")
    case "sibling":
        helper = helper.replacingOccurrences(of: "let buttonFrame = button.frame", with: "let buttonFrame = button.frame; let marker = true")
            .replacingOccurrences(of: "let origin =", with: "XCTAssertTrue(marker); let origin =")
        extra = "extension Suite { var marker: Bool { UserDefaults.standard.bool(forKey: \"shared\") } }"
    case "initializer":
        helper = helper.replacingOccurrences(of: "let top =", with: "let marker = marker; XCTAssertTrue(marker); let top =")
        extra = "extension Suite { var marker: Bool { UserDefaults.standard.bool(forKey: \"shared\") } }"
    case "mutable": helper = helper.replacingOccurrences(of: "let top =", with: "var flag = false; flag = true; XCTAssertTrue(flag); let top =")
    case "callback": helper = helper.replacingOccurrences(of: "let top =", with: "addTeardownBlock { UserDefaults.standard.set(true, forKey: \"shared\") }; let top =")
    case "optionalString", "optionalFormatting":
        call += "; let value = XCUIApplication().buttons[\"filter\"].value as? String; XCTAssertEqual(value, \"Read\")"
        if kind == "optionalFormatting" {
            extra = """
            extension Optional: @retroactive TextOutputStreamable {
                public func write<Target: TextOutputStream>(to target: inout Target) {
                    UserDefaults.standard.set(true, forKey: "formatting-effect")
                    target.write("formatted")
                }
            }
            """
        }
    case "geometryOverload":
        extra = "extension CGRect { func intersection(_ other: CGRect) -> CGRect { UserDefaults.standard.set(true, forKey: \"shared\"); return self } }"
    case "coordinateOverload":
        extra = "extension XCUICoordinate { func press(forDuration: Double, thenDragTo: XCUICoordinate) { UserDefaults.standard.set(true, forKey: \"shared\") } }"
    case "pattern": helper = helper.replacingOccurrences(of: "if button.exists {", with: "if case let button = button {")
    case "unbounded": helper = helper.replacingOccurrences(of: "for _ in 0..<8", with: "for _ in 0..<app.buttons.count")
    default: break
    }
    let after = before + "\nextension Suite {\n" + helper + "\nfunc testAdded() { " + call + " }\n}\nextension Suite { func testSecond() { XCTAssertTrue(true) } }\n" + extra
    let tests = ["UI/Suite/testExisting()", "UI/Suite/testAdded()", "UI/Suite/testSecond()", "UI/Other/testOther()"]
    var current = try boundaryGraph(["UI.swift": after], tests: tests, root: root)
    if kind == "moduleCollision" { current.modules["Shadow"] = "CoreGraphics" }
    if kind == "missingDynamic" {
        for id in current.dependencies!.functions.keys where current.dependencies!.functions[id]!.name.contains("revealInboxFilter") {
            current.dependencies!.functions[id]!.dynamicCallSignatures = nil
        }
    }
    if kind == "binding" { current.dependencies?.tests[tests[1]] = [] }
    if kind == "legacy" {
        for i in current.sources["UI:UI.swift"]!.units.indices {
            current.sources["UI:UI.swift"]!.units[i].privateTestHelper?.proofVersion = 10
        }
    }
    current = try GraphArchive.decode(GraphArchive.encode(current))
    let source = XcodeHeadOnlySources(base: ["UI:UI.swift": .parse(before, path: "UI.swift", module: "UI")], mappings: current.mappings)
    let report = XcodeHeadOnlySelector.select(current: current, source: source,
        changes: [.init(path: "UI.swift")], baseRevision: "base", excludedTestEntries: [tests[1], tests[2]])
    if kind == "scroll" {
        #expect(report.selectedTests == [tests[1]], "\(report.diagnostics)")
        #expect(report.diagnostics.isEmpty, "\(report.diagnostics)")
        let helper = try #require(current.sources["UI:UI.swift"]?.units.first { $0.privateTestHelper?.name == "revealInboxFilter" })
        #expect(helper.privateTestHelper?.calleeEffectsSupported == true)
        #expect(current.dependencies?.functions.values.contains { $0.name.contains("default argument") && $0.name.contains("revealInboxFilter") } == true)
    } else {
        #expect(report.selectedTests.contains(tests[3]), "\(report.diagnostics)")
        #expect(!report.diagnostics.isEmpty)
        if ["optionalString", "optionalFormatting"].contains(kind) {
            #expect(report.diagnostics.contains { $0.message.contains("Optional<String>") }, "\(report.diagnostics)")
            #expect(current.sources["UI:UI.swift"]?.units.first { $0.privateTestHelper?.name == "revealInboxFilter" }?.privateTestHelper?.calleeEffectsSupported == true)
        }
    }
}

@Test func scrollingGeometryContractsAuthenticateExactSDKSymbols() throws {
    let symbols: Set<String> = [
        "$sSo6CGRectV12CoreGraphicsE12intersectionyA2BF",
        "$sSo6CGRectV12CoreGraphicsE7isEmptySbvg"
    ]
    let output = try CommandRunner.run("xcrun", ["swift-demangle", "--expand", "--tree-only"] + symbols.sorted(),
        at: FileManager.default.temporaryDirectory).text
    #expect(ExternalHelperEffects.trustedDeclarations(output) == symbols)
    #expect(ExternalHelperEffects.trustedDeclarations(output, receiverOrigins: true) == symbols)
    let foreign = output.replacingOccurrences(of: "CoreGraphics", with: "Foreign")
    #expect(ExternalHelperEffects.trustedDeclarations(foreign).isEmpty)
    #expect(ExternalHelperEffects.trustedDeclarations(foreign, receiverOrigins: true).isEmpty)
}

@Test(arguments: ["max", "CGRect", "CGVector"])
func compiledScrollingGlobalsRequireBothRevisionBindings(name: String) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("extension-global-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let expression: String
    let declaration: String
    switch name {
    case "CGRect":
        expression = "CGRect(x: 0, y: 0, width: 1, height: 1)"
        declaration = "func CGRect(x: Double, y: Double, width: Double, height: Double) -> CoreGraphics.CGRect"
    case "CGVector":
        expression = "CGVector(dx: 1, dy: 1)"
        declaration = "func CGVector(dx: Double, dy: Double) -> CoreGraphics.CGVector"
    default:
        expression = "max(1, 2)"
        declaration = "func max(_ lhs: Int, _ rhs: Int) -> Int"
    }
    let before = """
    import XCTest
    @MainActor final class Suite: XCTestCase {
        func testConsumer() { candidate() }
        private func candidate() {
            let value = \(expression)
            XCTAssertTrue(true)
        }
    }
    @MainActor final class Other: XCTestCase {
        func testReader() { XCTAssertFalse(UserDefaults.standard.bool(forKey: "shared")) }
    }
    """
    let after = before.replacingOccurrences(of: "XCTAssertTrue(true)", with: "XCTAssertTrue(true); XCTAssertFalse(false)")
    let extra = """
    import XCTest
    import CoreGraphics
    \(declaration) {
        UserDefaults.standard.set(true, forKey: "shared")
        return \(name == "max" ? "Swift.max(lhs, rhs)" : "CoreGraphics." + expression)
    }
    """
    let tests = ["UI/Suite/testConsumer()", "UI/Other/testReader()"]
    let old = try boundaryGraph(["UI.swift": before, "Extra.swift": extra], tests: tests, root: root)
    let current = try boundaryGraph(["UI.swift": after], tests: tests, root: root)
    // Confirm the old compiled helper really reaches the project overload;
    // preserving source statements cannot preserve this removed binding.
    let oldGraph = try #require(old.dependencies)
    let projectOverloads = Set(oldGraph.functions.filter { $0.value.regions.contains { $0.path == "Extra.swift" } }.keys)
    #expect(DependencyIndex(oldGraph).paths(to: projectOverloads).path(from: oldGraph.tests[tests[0]] ?? []) != nil)
    for unowned in [false, true] {
        var source = XcodeHeadOnlySources(base: old.sources, mappings: current.mappings)
        if unowned {
            source.unownedBaseSources["Extra.swift"] = source.base.removeValue(forKey: "UI:Extra.swift")
        }
        let report = XcodeHeadOnlySelector.select(current: current, source: source,
            changes: [.init(path: "UI.swift")], baseRevision: "base")
        #expect(report.selectedTests == tests.sorted(), "\(name), unowned=\(unowned): \(report.diagnostics)")
        #expect(!report.diagnostics.isEmpty)
    }
    let changed = try boundaryGraph(["UI.swift": after, "Extra.swift": extra], tests: tests, root: root)
    let report = XcodeHeadOnlySelector.select(current: changed,
        source: .init(base: ["UI:UI.swift": .parse(before, path: "UI.swift", module: "UI")], mappings: current.mappings),
        changes: [.init(path: "UI.swift")], baseRevision: "base")
    #expect(report.selectedTests == tests.sorted())
    #expect(!report.diagnostics.isEmpty)
}
