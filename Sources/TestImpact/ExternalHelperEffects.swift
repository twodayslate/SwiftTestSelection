// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation

/// Missing SIL bodies are not evidence of harmless effects. Resolve external
/// declaration owners with the compiler, including extensions of SDK types.
/// Cache decisions for one immutable helper traversal and batch new symbols.
struct ExternalHelperEffects {
    private var trusted: [String: Bool] = [:]
    // Compiler-emitted actor isolation checks have C ABI names, not Swift
    // declaration trees. Keep this exact; an arbitrary swift_* name is opaque.
    private static let runtimeChecks: Set<String> = ["swift_task_isCurrentExecutor", "swift_task_reportUnexpectedExecutor"]

    mutating func allows(_ symbols: Set<String>, resolve: ([String]) -> String? = Self.resolve) -> Bool {
        let missing = symbols.filter { trusted[$0] == nil && !Self.runtimeChecks.contains($0) }.sorted()
        if !missing.isEmpty {
            let output = resolve(missing)
            let allowed = output.map(Self.trustedDeclarations) ?? []
            for symbol in missing { trusted[symbol] = allowed.contains(symbol) }
        }
        return symbols.allSatisfy { Self.runtimeChecks.contains($0) || trusted[$0] == true }
    }

    /// SIL's method display name omits argument labels and overload identity.
    /// Pair exact formal signatures with the source call-shape proof. Unknown
    /// dynamic calls are opaque even when no function_ref edge was emitted.
    static let sdkActions: Set<String> = ["tap", "doubleTap", "swipeUp", "swipeDown", "swipeLeft", "swipeRight", "typeText", "press"]
    static let sdkCallLabels: [String: Set<[String]>] = [
        "tap": [[]], "doubleTap": [[]], "swipeUp": [[]], "swipeDown": [[]], "swipeLeft": [[]], "swipeRight": [[]],
        "typeText": [["_"]], "press": [["forDuration"]], "screenshot": [[]], "waitForExistence": [["timeout"]], "waitForNonExistence": [["timeout"]],
        "descendants": [["matching"]], "children": [["matching"]],
        "matching": [["identifier"], ["_"], ["_", "identifier"]],
        "containing": [["_"], ["_", "identifier"]], "element": [["boundBy"]],
        "evaluate": [["with"]], "wait": [["for", "timeout"]], "add": [["_"]]
    ]

    static func allowsDynamicCalls(_ node: FunctionNode) -> Bool {
        if node.dynamicDeclarations.isEmpty { return true }
        guard let calls = node.dynamicCallSignatures,
              !node.uncertainties.contains(where: { $0.hasPrefix("Unresolved project dispatch:") || $0.hasPrefix("Imported conformance:") }) else { return false }
        var covered = Set<String>()
        for call in calls {
            let parts = call.split(separator: " ", maxSplits: 2)
            guard parts.count == 3 else { return false }
            let declaration = String(parts[1].split(separator: "!")[0])
            covered.insert(declaration)
            if sdkDynamicSignatures.contains(call) { continue }
            // Resolved project implementations still undergo the ordinary
            // dependency/effect walk. Imported conformances cannot grant this.
            guard node.resolvedDynamicDeclarations.contains(where: {
                $0 == declaration || $0.hasPrefix(declaration + "@witness:")
            }), !node.dependencies.isEmpty else { return false }
        }
        return Set(node.dynamicDeclarations.map { $0.components(separatedBy: "@witness:")[0] }).isSubset(of: covered)
    }

    private static let sdkDynamicSignatures: Set<String> = {
        var calls: Set<String> = [
            "XCUIElement.screenshot!foreign : (XCUIElement) -> () -> XCUIScreenshot",
            "XCUIElement.waitForExistence!foreign : (XCUIElement) -> (Double) -> Bool",
            "XCUIElement.waitForNonExistence!foreign : (XCUIElement) -> (Double) -> Bool",
            "XCTAttachment.init!allocator.foreign : (XCTAttachment.Type) -> (XCUIScreenshot) -> XCTAttachment",
            "XCTAttachment.name!setter.foreign : (XCTAttachment) -> (String?) -> ()",
            "XCTAttachment.lifetime!setter.foreign : (XCTAttachment) -> (XCTAttachment.Lifetime) -> ()",
            "XCTestCase.add!foreign : (XCTestCase) -> (XCTAttachment) -> ()",
            "NSPredicate.evaluate!foreign : (NSPredicate) -> (Any?) -> Bool",
            "NSPredicate.init!allocator.foreign : (NSPredicate.Type) -> (@escaping (Any?, [String : Any]?) -> Bool) -> NSPredicate",
            "XCTNSPredicateExpectation.init!initializer.foreign : (XCTNSPredicateExpectation.Type) -> (NSPredicate, Any?) -> XCTNSPredicateExpectation",
            "XCTWaiter.wait!foreign : (XCTWaiter.Type) -> ([XCTestExpectation], Double) -> XCTWaiter.Result",
            "XCUIElementQuery.subscript!getter.foreign : (XCUIElementQuery) -> (String) -> XCUIElement",
            "XCUIElementQuery.element!foreign : (XCUIElementQuery) -> (Int) -> XCUIElement",
            "XCUIElementQuery.matching!foreign : (XCUIElementQuery) -> (String) -> XCUIElementQuery",
            "XCUIElementQuery.matching!foreign : (XCUIElementQuery) -> (NSPredicate) -> XCUIElementQuery",
            "XCUIElementQuery.containing!foreign : (XCUIElementQuery) -> (NSPredicate) -> XCUIElementQuery"
        ]
        // Navigation effects are admitted only as preserved standalone source
        // statements, never as effects hidden inside an added assertion.
        for action in ["tap", "doubleTap", "swipeUp", "swipeDown", "swipeLeft", "swipeRight"] {
            calls.insert("XCUIElement.\(action)!foreign : (XCUIElement) -> () -> ()")
        }
        calls.insert("XCUIElement.typeText!foreign : (XCUIElement) -> (String) -> ()")
        calls.insert("XCUIElement.press!foreign : (XCUIElement) -> (Double) -> ()")
        for owner in ["XCUIElement", "XCUIElementQuery"] {
            for name in ["buttons", "staticTexts", "textFields", "secureTextFields", "textViews", "cells", "tables", "collectionViews", "scrollViews", "navigationBars", "tabBars", "toolbars", "otherElements", "images", "switches", "sliders", "steppers", "searchFields", "segmentedControls", "sheets", "alerts", "windows", "webViews", "keyboards", "datePickers", "pickerWheels", "popovers", "progressIndicators"] {
                calls.insert("\(owner).\(name)!getter.foreign : (\(owner)) -> () -> XCUIElementQuery")
            }
            calls.insert("\(owner).firstMatch!getter.foreign : (\(owner)) -> () -> XCUIElement")
        }
        for (name, type) in ["exists": "Bool", "isEnabled": "Bool", "isHittable": "Bool", "isSelected": "Bool", "value": "Any?", "label": "String", "identifier": "String", "debugDescription": "String"] {
            calls.insert("XCUIElement.\(name)!getter.foreign : (XCUIElement) -> () -> \(type)")
        }
        for name in ["descendants", "children"] {
            calls.insert("XCUIElement.\(name)!foreign : (XCUIElement) -> (XCUIElement.ElementType) -> XCUIElementQuery")
        }
        for name in ["matching", "containing"] {
            calls.insert("XCUIElementQuery.\(name)!foreign : (XCUIElementQuery) -> (XCUIElement.ElementType, String?) -> XCUIElementQuery")
        }
        calls.insert("XCUIElementQuery.count!getter.foreign : (XCUIElementQuery) -> () -> Int")
        return Set(calls.map { "objc_method " + $0 })
    }()

    private static func resolve(_ symbols: [String]) -> String? {
        try? CommandRunner.run("xcrun", ["swift-demangle", "--expand", "--tree-only"],
            at: FileManager.default.temporaryDirectory,
            input: Data((symbols.joined(separator: "\n") + "\n").utf8)).text
    }

    static func trustedDeclarations(_ output: String) -> Set<String> {
        let owners = SILOwnership.declarationOwners(output)
        let modules = SDKTestHelperSyntax.trustedCallerModules
        // Clang-imported constructor thunks use __C rather than their framework
        // module. Require a known receiver type, not just the shared __C owner.
        let importedTypes: Set<String> = ["XCTAttachment", "XCUIApplication", "XCUIElement", "XCUIElementType", "XCUIScreenshot",
            "XCTestCase", "XCTest", "NSPredicate", "XCTNSPredicateExpectation", "XCTWaiter", "XCTWaiterResult"]
        var accepted = Set(owners.filter { modules.contains($0.value) }.keys)
        for block in output.components(separatedBy: "Demangling for ").dropFirst() {
            let lines = block.components(separatedBy: .newlines)
            guard let symbol = lines.first, ["__C", "__C_Synthesized"].contains(owners[symbol] ?? ""),
                  let module = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "kind=Module, text=\"__C\"" }),
                  module + 1 < lines.count else { continue }
            let prefix = lines[module].prefix { $0 == " " }
            let identifier = lines[module + 1]
            guard identifier.hasPrefix(prefix + "kind=Identifier, text="),
                  let data = String(identifier.dropFirst((prefix + "kind=Identifier, text=").count)).data(using: .utf8),
                  let type = try? JSONDecoder().decode(String.self, from: data), importedTypes.contains(type) else { continue }
            // The importer synthesizes the standard enum conformances. Never
            // extend this exception to user/retroactive conformance modules.
            if owners[symbol] == "__C_Synthesized" && type != "XCTWaiterResult" { continue }
            accepted.insert(symbol)
        }
        return accepted
    }
}
