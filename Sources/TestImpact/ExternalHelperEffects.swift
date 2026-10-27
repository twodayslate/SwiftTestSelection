// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation

/// Missing SIL bodies are not evidence of harmless effects. Resolve external
/// declaration owners with the compiler, including extensions of SDK types.
/// Cache decisions for one immutable helper traversal and batch new symbols.
struct ExternalHelperEffects {
    private var trusted: [String: Bool] = [:]
    private var receiverSDK: [String: Bool] = [:]
    // Compiler-emitted actor isolation checks have C ABI names, not Swift
    // declaration trees. Keep this exact; an arbitrary swift_* name is opaque.
    private static let runtimeChecks: Set<String> = ["swift_task_isCurrentExecutor", "swift_task_reportUnexpectedExecutor"]

    mutating func allows(_ symbols: Set<String>, resolve: ([String]) -> String? = Self.resolve) -> Bool {
        let missing = symbols.filter { trusted[$0] == nil && !Self.runtimeChecks.contains($0) }.sorted()
        if !missing.isEmpty {
            let output = resolve(missing)
            let allowed = output.map { Self.trustedDeclarations($0) } ?? []
            for symbol in missing { trusted[symbol] = allowed.contains(symbol) }
        }
        return symbols.allSatisfy { Self.runtimeChecks.contains($0) || trusted[$0] == true }
    }

    private static let receiverRuntime = runtimeChecks.union(["swift_getAtKeyPath", "$sSo7NSErrorCSgIeyBhy_ytTZ_", "$sSo7NSErrorCSgIeyBhy_ytTz_"])

    mutating func sdkReceiverDeclarations(_ symbols: Set<String>, resolve: ([String]) -> String? = Self.resolve) -> Set<String> {
        resolveReceiverDeclarations(symbols, resolve: resolve)
        return Set(symbols.filter { Self.receiverRuntime.contains($0) || receiverSDK[$0] == true })
    }

    mutating func allowsReceiverOrigins(_ symbols: Set<String>, resolve: ([String]) -> String? = Self.resolve) -> Bool {
        unprovenReceiverOrigins(symbols, resolve: resolve).isEmpty
    }

    mutating func unprovenReceiverOrigins(_ symbols: Set<String>, resolve: ([String]) -> String? = Self.resolve) -> Set<String> {
        symbols.subtracting(sdkReceiverDeclarations(symbols, resolve: resolve))
    }

    private mutating func resolveReceiverDeclarations(_ symbols: Set<String>, resolve: ([String]) -> String?) {
        // Key-path getter references are retained by SILParser. The completion
        // adapter transports NSError to a void callback, not an SDK receiver.
        let missing = symbols.subtracting(Self.receiverRuntime).filter { receiverSDK[$0] == nil }
        guard !missing.isEmpty else { return }
        let output = resolve(missing.sorted())
        let sdk = output.map { Self.trustedDeclarations($0, receiverOrigins: true) } ?? []
        for symbol in missing {
            receiverSDK[symbol] = sdk.contains(symbol)
        }
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

    static func allowsDynamicCalls(_ node: FunctionNode, sourceCallShapes: [String: Set<[String]>]? = nil) -> Bool {
        if node.dynamicDeclarations.isEmpty { return node.dynamicCallSignatures?.isEmpty ?? true }
        guard let calls = node.dynamicCallSignatures,
              !node.uncertainties.contains(where: { $0.hasPrefix("Unresolved project dispatch:") || $0.hasPrefix("Imported conformance:") }) else { return false }
        var covered = Set<String>()
        for call in calls {
            let parts = call.split(separator: " ", maxSplits: 2)
            guard parts.count == 3 else { return false }
            guard let name = parts[1].split(separator: "!").first else { return false }
            let declaration = String(name)
            covered.insert(declaration)
            if sdkDynamicSignatures.contains(call) {
                if let signatures = queryOverloadShapes[declaration] {
                    guard let shapes = sourceCallShapes?[declaration.components(separatedBy: ".").last!],
                          !shapes.isEmpty,
                          shapes.allSatisfy({ signatures[$0]?.contains(call) == true }) else { return false }
                }
                continue
            }
            // Resolved project implementations still undergo the ordinary
            // dependency/effect walk. Imported conformances cannot grant this.
            guard node.resolvedDynamicDeclarations.contains(where: {
                $0 == declaration || $0.hasPrefix(declaration + "@witness:")
            }), !node.dependencies.isEmpty else { return false }
        }
        return Set(node.dynamicDeclarations.map { $0.components(separatedBy: "@witness:")[0] }).isSubset(of: covered)
    }

    /// Require each possible source shape to agree with the compiled overload.
    /// Unioning labels and types separately accepts foreign cross-product
    /// overloads. Receiver proofs may use complete captured call-site identities;
    /// otherwise every shape must match. One valid call cannot mask an unknown call.
    static let queryOverloadShapes: [String: [[String]: Set<String>]] = {
        var result: [String: [[String]: Set<String>]] = [:]
        for name in ["matching", "containing"] {
            let prefix = "objc_method XCUIElementQuery.\(name)!foreign : (XCUIElementQuery) -> "
            let predicate = prefix + "(NSPredicate) -> XCUIElementQuery"
            let element = prefix + "(XCUIElement.ElementType, String?) -> XCUIElementQuery"
            var shapes: [[String]: Set<String>] = [["_"]: [predicate], ["_", "identifier"]: [element]]
            if name == "matching" { shapes[["identifier"]] = [prefix + "(String) -> XCUIElementQuery"] }
            result["XCUIElementQuery." + name] = shapes
        }
        return result
    }()

    static func allowsDynamicReceiverOrigins(_ node: FunctionNode) -> Bool { receiverDependencies(node) != nil }

    /// An opaque function can deliver receivers through returned aggregates,
    /// thrown errors, callbacks or mutations of reachable state. Neither its
    /// result spelling nor a consumer's callback syntax proves these channels
    /// closed. Only explicit SDK contracts or resolved implementation edges do.
    static func receiverDependencies(_ node: FunctionNode, sourceCallShapes: [String: Set<[String]>]? = nil) -> Set<String>? {
        try? receiverProof(node, sourceCallShapes: sourceCallShapes).get()
    }

    static func receiverProof(_ node: FunctionNode, sourceCallShapes: [String: Set<[String]>]? = nil, pairedCallShapes: [String: Set<[String]>] = [:]) -> Result<Set<String>, ImpactError> {
        if let imported = node.uncertainties.sorted().first(where: { $0.hasPrefix("Imported conformance:") }) {
            return .failure(ImpactError(imported))
        }
        let unresolved = node.uncertainties.filter { $0.hasPrefix("Unresolved project dispatch:") }.sorted()
        guard let calls = node.dynamicCallSignatures else { return .failure(ImpactError("Missing dynamic-call signatures")) }
        var needsTargets = false
        var covered = Set<String>()
        for call in calls.sorted() {
            let parts = call.split(separator: " ", maxSplits: 2)
            guard parts.count == 3, let name = parts[1].split(separator: "!").first else {
                return .failure(ImpactError("Malformed dynamic-call signature: " + call))
            }
            let declaration = String(name)
            covered.insert(declaration)
            if sdkDynamicSignatures.contains(call) || receiverSDKSignatures.contains(call) {
                // Initializers are checked through metatype provenance. Property
                // access has no argument labels; methods must match source shapes.
                if declaration.hasSuffix(".subscript") || (!call.contains("!getter") && !call.contains("!setter") && !call.contains("!initializer") &&
                   !call.contains("!allocator") && !call.contains("!deallocator")) {
                    let name = declaration.components(separatedBy: ".").last!
                    let shapes = pairedCallShapes[call] ?? sourceCallShapes?[name]
                    let valid: Bool
                    if let signatures = queryOverloadShapes[declaration] {
                        valid = shapes?.isEmpty == false && shapes!.allSatisfy { signatures[$0]?.contains(call) == true }
                    } else {
                        let expected = receiverCallLabels[name]
                        valid = shapes?.isEmpty == false && expected != nil && shapes!.isSubset(of: expected!)
                    }
                    guard valid else { return .failure(ImpactError("Missing or unproven SDK overload identity for " + call)) }
                }
                continue
            }
            if let reason = unresolved.first(where: { $0 == "Unresolved project dispatch: " + declaration || $0.hasPrefix("Unresolved project dispatch: " + declaration + " (") }) {
                return .failure(ImpactError(reason))
            }
            guard node.resolvedDynamicDeclarations.contains(where: { $0 == declaration || $0.hasPrefix(declaration + "@witness:") }),
                  !node.dependencies.isEmpty else {
                return .failure(ImpactError("Missing implementation or SDK origin contract for " + call))
            }
            needsTargets = true
        }
        if let reason = unresolved.first(where: { reason in
            !covered.contains { reason == "Unresolved project dispatch: " + $0 || reason.hasPrefix("Unresolved project dispatch: " + $0 + " (") }
        }) { return .failure(ImpactError(reason)) }
        guard Set(node.dynamicDeclarations.map { $0.components(separatedBy: "@witness:")[0] }).isSubset(of: covered),
              !node.dynamicDeclarations.isEmpty || calls.isEmpty else {
            return .failure(ImpactError("Incomplete dynamic-call declarations/signatures"))
        }
        return .success(needsTargets ? node.dependencies.subtracting(node.compilerReferences ?? []) : [])
    }

    // These labels describe the explicit origin contracts below. Unknown shapes
    // and method values remain opaque, including in otherwise trusted callers.
    static let receiverCallLabels: [String: Set<[String]>] = sdkCallLabels.merging([
        "subscript": [["_"]], "image": [["actions"], ["<trailing>"]], "snapshot": [[]], "fulfill": [[]],
        "launch": [[]], "terminate": [[]], "setUp": [[]], "tearDown": [[]],
        "open": [["_"]], "coordinate": [["withNormalizedOffset"]], "withOffset": [["_"]],
        "swipeUp": [[], ["velocity"]], "swipeDown": [[], ["velocity"]],
        "press": [["forDuration"], ["forDuration", "thenDragTo"], ["forDuration", "thenDragTo", "withVelocity", "thenHoldForDuration"]],
        "jsonObject": [["with"], ["with", "options"]]
    ], uniquingKeysWith: { _, new in new })

    // Origin contracts only: these SDK operations do not inject a foreign
    // XCTest receiver. They do not grant outgoing effect purity to a helper.
    // No project declaration or return-type spelling belongs in this allowlist.
    private static let receiverSDKSignatures: Set<String> = [
                // UIKit supplies an unrelated renderer context, never an XCTest receiver.
                "objc_method UIGraphicsImageRenderer.image!foreign : (UIGraphicsImageRenderer) -> ((UIGraphicsImageRendererContext) -> ()) -> UIImage",
                "objc_method XCUIApplication.init!initializer.foreign : (XCUIApplication.Type) -> () -> XCUIApplication",
                "objc_method XCUIApplication.init!initializer.foreign : (XCUIApplication.Type) -> (String) -> XCUIApplication",
                "objc_super_method XCTestCase.init!initializer.foreign : (XCTestCase.Type) -> () -> XCTestCase",
                "objc_super_method XCTestCase.init!initializer.foreign : (XCTestCase.Type) -> (Selector) -> XCTestCase",
                "objc_super_method XCTestCase.init!initializer.foreign : (XCTestCase.Type) -> (NSInvocation?) -> XCTestCase",
                "objc_method NSPredicate.init!allocator.foreign : (NSPredicate.Type) -> (Bool) -> NSPredicate",
                "objc_method NSPredicate.init!allocator.foreign : (NSPredicate.Type) -> (String, [Any]?) -> NSPredicate",
                "objc_method XCUIScreen.screenshot!foreign : (XCUIScreen) -> () -> XCUIScreenshot",
                "objc_method XCTAttachment.init!allocator.foreign : (XCTAttachment.Type) -> (String) -> XCTAttachment",
                "objc_method XCUIElementQuery.allElementsBoundByIndex!getter.foreign : (XCUIElementQuery) -> () -> [XCUIElement]",
                "objc_method XCUIElementQuery.allElementsBoundByAccessibilityElement!getter.foreign : (XCUIElementQuery) -> () -> [XCUIElement]",
                "objc_method XCUIElement.snapshot!foreign : (XCUIElement) -> () throws -> any XCUIElementSnapshot",
                "objc_method XCUIElementAttributes.value!getter.foreign : <Self where Self : XCUIElementAttributes> (Self) -> () -> Any?",
                "objc_method XCUIElementSnapshot.children!getter.foreign : <Self where Self : XCUIElementSnapshot> (Self) -> () -> [any XCUIElementSnapshot]",
                "objc_method JSONSerialization.jsonObject!foreign : (JSONSerialization.Type) -> (Data, JSONSerialization.ReadingOptions) throws -> Any",
                "objc_super_method XCTestCase.deinit!deallocator.foreign : (XCTestCase) -> () -> ()",
                "objc_super_method XCTest.setUp!foreign : (XCTest) -> () async throws -> ()",
                "objc_super_method XCTest.tearDown!foreign : (XCTest) -> () async throws -> ()",
                "objc_method XCTestCase.continueAfterFailure!setter.foreign : (XCTestCase) -> (Bool) -> ()",
                "objc_method XCTestExpectation.fulfill!foreign : (XCTestExpectation) -> () -> ()",
                "objc_method XCUIApplication.launch!foreign : (XCUIApplication) -> () -> ()",
                "objc_method XCUIApplication.terminate!foreign : (XCUIApplication) -> () -> ()",
                "objc_method XCUIApplication.launchEnvironment!getter.foreign : (XCUIApplication) -> () -> [String : String]",
                "objc_method XCUIApplication.launchEnvironment!setter.foreign : (XCUIApplication) -> ([String : String]) -> ()",
                "objc_method XCUIApplication.launchArguments!getter.foreign : (XCUIApplication) -> () -> [String]",
                "objc_method XCUIApplication.launchArguments!setter.foreign : (XCUIApplication) -> ([String]) -> ()",
                "objc_method XCUIApplication.state!getter.foreign : (XCUIApplication) -> () -> XCUIApplication.State",
                "objc_method XCUIDevice.shared!getter.foreign : (XCUIDevice.Type) -> () -> XCUIDevice",
                "objc_method XCUIDevice.orientation!getter.foreign : (XCUIDevice) -> () -> UIDeviceOrientation",
                "objc_method XCUIDevice.orientation!setter.foreign : (XCUIDevice) -> (UIDeviceOrientation) -> ()",
                "objc_method XCUIDevice.system!getter.foreign : (XCUIDevice) -> () -> XCUISystem",
                "objc_method XCUISystem.open!foreign : (XCUISystem) -> (URL) -> ()",
                "objc_method XCUIScreen.main!getter.foreign : (XCUIScreen.Type) -> () -> XCUIScreen",
                "objc_method XCUIElement.coordinate!foreign : (XCUIElement) -> (CGVector) -> XCUICoordinate",
                "objc_method XCUIElement.frame!getter.foreign : (XCUIElement) -> () -> CGRect",
                "objc_method XCUIElement.swipeDown!foreign : (XCUIElement) -> (XCUIGestureVelocity) -> ()",
                "objc_method XCUIElement.swipeUp!foreign : (XCUIElement) -> (XCUIGestureVelocity) -> ()",
                "objc_method XCUICoordinate.tap!foreign : (XCUICoordinate) -> () -> ()",
                "objc_method XCUICoordinate.press!foreign : (XCUICoordinate) -> (Double) -> ()",
                "objc_method XCUICoordinate.press!foreign : (XCUICoordinate) -> (Double, XCUICoordinate) -> ()",
                "objc_method XCUICoordinate.press!foreign : (XCUICoordinate) -> (Double, XCUICoordinate, XCUIGestureVelocity, Double) -> ()",
                "objc_method XCUICoordinate.screenPoint!getter.foreign : (XCUICoordinate) -> () -> CGPoint",
                "objc_method XCUICoordinate.withOffset!foreign : (XCUICoordinate) -> (CGVector) -> XCUICoordinate"
    ]

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

    // Clang categories share __C and the extended class name with the SDK.
    // The class owner alone therefore cannot authenticate an imported thunk.
    // Keep exact native constructor identities; new SDK spellings fall back.
    private static let importedClassContracts: Set<String> = [
        "$sSo15XCUIApplicationCABycfC", "$sSo15XCUIApplicationCABycfcTO",
        "$sSo15XCUIApplicationC16bundleIdentifierABSS_tcfC", "$sSo15XCUIApplicationC16bundleIdentifierABSS_tcfcTO",
        "$sSo13XCTAttachmentC10screenshotABSo14XCUIScreenshotC_tcfCTO",
        "$sSo13XCTAttachmentC14contentsOfFileAB10Foundation3URLV_tcfCTO",
        "$sSo13XCTAttachmentC4data21uniformTypeIdentifierAB10Foundation4DataV_SStcfCTO",
        "$sSo13XCTAttachmentC4dataAB10Foundation4DataV_tcfCTO", "$sSo13XCTAttachmentC6stringABSS_tcfCTO",
        "$sSo13XCTAttachmentC21uniformTypeIdentifier4name7payload8userInfoABSSSg_AG10Foundation4DataVSgSDys11AnyHashableVypGSgtcfC",
        "$sSo13XCTAttachmentC21uniformTypeIdentifier4name7payload8userInfoABSSSg_AG10Foundation4DataVSgSDys11AnyHashableVypGSgtcfcTO",
        "$sSo11NSPredicateC6format13argumentArrayABSS_SayypGSgtcfCTO",
        "$sSo11NSPredicateC5blockABSbypSg_SDySSypGSgtc_tcfCTO", "$sSo11NSPredicateC5valueABSb_tcfCTO",
        "$sSo17XCTestExpectationC11descriptionABSS_tcfC", "$sSo17XCTestExpectationC11descriptionABSS_tcfcTO",
        "$sSo25XCTNSPredicateExpectationC9predicate6objectABSo11NSPredicateC_ypSgtcfC",
        "$sSo25XCTNSPredicateExpectationC9predicate6objectABSo11NSPredicateC_ypSgtcfcTO"
    ]

    static func trustedDeclarations(_ output: String, receiverOrigins: Bool = false) -> Set<String> {
        let owners = SILOwnership.declarationOwners(output)
        let modules = SDKTestHelperSyntax.trustedCallerModules.union(receiverOrigins ? ["CoreGraphics"] : [])
        // Clang-imported constructor thunks use __C rather than their framework
        // module. Require a known receiver type, not just the shared __C owner.
        var importedTypes: Set<String> = ["XCTAttachment", "XCUIApplication", "XCUIElement", "XCUIElementType", "XCUIScreenshot",
            "XCTestCase", "XCTest", "NSPredicate", "XCTNSPredicateExpectation", "XCTWaiter", "XCTWaiterResult"]
        if receiverOrigins {
            importedTypes.formUnion(["XCTestExpectation", "NSDateFormatter", "UIDeviceOrientation", "XCUIKeyboardKey", "UIContentSizeCategory",
                "UIGraphicsImageRenderer", "UIGraphicsImageRendererFormat", "CGRect", "CGSize", "CGPoint", "CGVector", "XCUIApplicationState"])
        }
        var accepted = Set(owners.filter { modules.contains($0.value) &&
            (!receiverOrigins || SDKReceiverContracts.declarations.contains($0.key)) }.keys)
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
            if owners[symbol] == "__C_Synthesized" && !(receiverOrigins ? ["XCTWaiterResult", "XCUIApplicationState", "XCUIElementType"] : ["XCTWaiterResult"]).contains(type) { continue }
            if module > 0, lines[module - 1].trimmingCharacters(in: .whitespaces) == "kind=Class",
               !importedClassContracts.contains(symbol) { continue }
            accepted.insert(symbol)
        }
        return accepted
    }
}
