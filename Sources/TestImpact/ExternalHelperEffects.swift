// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation

/// Missing SIL bodies are not evidence of harmless effects. Resolve external
/// declaration owners with the compiler, including extensions of SDK types.
/// Cache decisions for one immutable helper traversal and batch new symbols.
struct ExternalHelperEffects {
    private var trusted: [String: Bool] = [:]
    private var receiverTrusted: [String: Bool] = [:]
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
        resolveReceiverDeclarations(symbols, resolve: resolve)
        return symbols.allSatisfy { Self.receiverRuntime.contains($0) || receiverTrusted[$0] == true }
    }

    private mutating func resolveReceiverDeclarations(_ symbols: Set<String>, resolve: ([String]) -> String?) {
        // Key-path getter references are retained by SILParser. The completion
        // adapter transports NSError to a void callback, not an SDK receiver.
        let missing = symbols.subtracting(Self.receiverRuntime).filter { receiverTrusted[$0] == nil }
        guard !missing.isEmpty else { return }
        let output = resolve(missing.sorted())
        let sdk = output.map { Self.trustedDeclarations($0, receiverOrigins: true) } ?? []
        var allowed = sdk
        for block in (output ?? "").components(separatedBy: "Demangling for ").dropFirst() {
            let lines = block.components(separatedBy: .newlines)
            guard let symbol = lines.first, !allowed.contains(symbol), Self.nonReceiverResult(lines.dropFirst()) else { continue }
            allowed.insert(symbol)
        }
        for symbol in missing {
            receiverSDK[symbol] = sdk.contains(symbol)
            receiverTrusted[symbol] = allowed.contains(symbol)
        }
    }

    /// Check values leaving an opaque call: its result and callback arguments.
    /// A void-returning factory can still supply a receiver through a callback.
    /// Foreign reference, existential, generic and pointer results cannot prove
    /// a receiver's class. Value results are inspected through generic wrappers
    /// such as Optional/Array so they cannot hide an imported subclass.
    static func nonReceiverResult(_ lines: ArraySlice<String>) -> Bool {
        let nodes = lines.filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("kind=") }
        let values = nodes.map { $0.trimmingCharacters(in: .whitespaces) }
        let depths = nodes.map { $0.prefix { $0 == " " }.count }
        guard values.first == "kind=Global", values.count > 1,
              !values.contains("kind=InOut"),
              !values.contains(where: { $0.contains("Pointer") || $0.contains("Unmanaged") }) else { return false }
        func subtree(_ i: Int) -> Range<Int> {
            var end = i + 1
            while end < values.count && depths[end] > depths[i] { end += 1 }
            return i..<end
        }
        let roots = values.indices.filter { depths[$0] == 2 }
        let wrappers: Set<String> = ["kind=Function", "kind=Static", "kind=Getter", "kind=UnsafeMutableAddressor",
            "kind=Allocator", "kind=Constructor", "kind=DefaultArgumentInitializer", "kind=KeyPathGetterThunkHelper",
            "kind=ReabstractionThunkHelper"]
        guard !roots.isEmpty, roots.allSatisfy({ wrappers.contains(values[$0]) || ["kind=ObjCAttribute", "kind=NonObjCAttribute"].contains(values[$0]) }) else { return false }
        if roots.count == 1, values[roots[0]] == "kind=ReabstractionThunkHelper" {
            let signatures = subtree(roots[0]).filter { values[$0] == "kind=Type" && depths[$0] == depths[roots[0]] + 2 }
            return signatures.count == 2 && signatures.allSatisfy { i in
                i + 1 < values.count && values[i + 1] == "kind=ImplFunctionType" &&
                    !subtree(i).contains(where: { ["kind=ImplResult", "kind=ImplErrorResult", "kind=ImplYield"].contains(values[$0]) })
            }
        }
        let candidates = values.indices.filter { values[$0] == "kind=ReturnType" }
        var result: Range<Int>?
        if values.contains("kind=DefaultArgumentInitializer") {
            guard let arguments = values.indices.filter({ values[$0] == "kind=ArgumentTuple" }).min(by: { depths[$0] < depths[$1] }),
                  let number = values.last(where: { $0.hasPrefix("kind=Number, index=") }),
                  let parameter = Int(number.components(separatedBy: "=").last!), arguments + 2 < values.count,
                  values[arguments + 2] == "kind=Tuple" else { return false }
            let elements = subtree(arguments + 2).filter { values[$0] == "kind=TupleElement" && depths[$0] == depths[arguments + 2] + 2 }
            guard elements.indices.contains(parameter) else { return false }
            result = subtree(elements[parameter])
        } else if let variable = values.firstIndex(of: "kind=Variable") {
            guard let type = subtree(variable).first(where: { values[$0] == "kind=Type" && depths[$0] == depths[variable] + 2 }) else { return false }
            result = subtree(type)
        } else if let returned = candidates.min(by: { depths[$0] < depths[$1] }) {
            result = subtree(returned)
        }
        guard let result else { return false }
        let opaque = ["DependentGeneric", "ProtocolList", "BuiltinTypeName", "Metatype", "DynamicSelf", "TypeAlias"]
        let typeKinds: Set<String> = ["kind=Structure", "kind=Enum", "kind=BoundGenericStructure", "kind=BoundGenericEnum",
            "kind=Tuple", "kind=Class", "kind=FunctionType", "kind=AutoClosureType", "kind=NoEscapeFunctionType"]
        // The shallowest argument tuple belongs to the declaration. Deeper
        // tuples belong to callbacks it can invoke, including callbacks wrapped
        // in Optional/collections. Their arguments flow back into the caller.
        let arguments = values.indices.filter { values[$0] == "kind=ArgumentTuple" }
        let argumentDepth = arguments.map { depths[$0] }.min()
        let outputs = [result] + arguments.filter { depths[$0] > (argumentDepth ?? Int.max) }.map(subtree)
        for output in outputs {
            for i in output {
                if values[i] == "kind=Type", i + 1 >= output.upperBound || !typeKinds.contains(values[i + 1]) { return false }
                if opaque.contains(where: { values[i].contains($0) }) { return false }
                if values[i] == "kind=Class" {
                    // These SDK classes cannot be subclasses of XCTest receivers.
                    guard i + 2 < output.upperBound, values[i + 1] == "kind=Module, text=\"__C\"",
                          ["UIImage", "UIView", "NSError", "UIGraphicsImageRendererContext"].contains(where: {
                              values[i + 2] == "kind=Identifier, text=\"" + $0 + "\""
                          }) else { return false }
                }
                if values[i].contains("Pointer") || values[i].contains("Unmanaged") { return false }
            }
        }
        return true
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
    /// overloads. Mixed shapes remain conservative until call-site identities
    /// are available; one legitimate call must not mask an unproven call.
    private static let queryOverloadShapes: [String: [[String]: Set<String>]] = {
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

    private static let nonReceiverTypes: Set<String> = ["String", "Bool", "Int", "UInt", "Int64", "UInt64", "Double", "Float", "CGFloat", "Void",
            "CGRect", "CGSize", "CGPoint", "CGVector", "TimeInterval", "Selector", "URL", "Date", "Data", "NSRange",
            "UIDeviceOrientation", "UIContentSizeCategory", "XCUIKeyboardKey", "XCUIDevice", "UIDevice", "XCUIScreen", "XCUICoordinate",
            "UIImage", "UIView", "UIApplication", "UIWindow", "UIScreen", "UIColor", "UserDefaults", "XCUISystem", "XCTestExpectation", "UIGraphicsImageRenderer", "UIGraphicsImageRendererFormat",
            "UIGraphicsImageRendererContext", "NSFormatter", "NSDateFormatter", "DateFormatter", "ProcessInfo", "Optional", "Array", "Dictionary",
            "Swift", "Foundation", "UIKit", "CoreGraphics", "XCTest"]

    /// Follow concrete producer edges, not broad scalar-returning protocol
    /// dispatch candidates (e.g. every Equatable implementation in the graph).
    static func receiverDependencies(_ node: FunctionNode, assertedCallbacks: Set<String> = []) -> Set<String>? {
        guard !node.dynamicDeclarations.isEmpty else { return (node.dynamicCallSignatures?.isEmpty ?? true) ? [] : nil }
        guard let calls = node.dynamicCallSignatures else { return nil }
        var needsTargets = false
        var covered = Set<String>()
        for call in calls {
            let parts = call.split(separator: " ", maxSplits: 2)
            guard parts.count == 3 else { return nil }
            guard let name = parts[1].split(separator: "!").first else { return nil }
            let declaration = String(name)
            covered.insert(declaration)
            guard let result = call.components(separatedBy: " -> ").last else { return nil }
            let words = Set(result.split { !$0.isLetter && !$0.isNumber && $0 != "_" }.map(String.init))
            // The first two arrows separate the receiver, arguments and result.
            // Any additional arrow denotes a function-valued channel. Do not
            // infer safety from a scalar result when callbacks or output buffers
            // can deliver receivers. Known SDK contracts below remain explicit;
            // resolved project implementations are followed normally.
            let arrowParts = call.components(separatedBy: " -> ").count
            let checkedCallback = arrowParts == 4 && assertedCallbacks.contains(declaration.components(separatedBy: ".").last ?? "")
            let directOnly = (arrowParts == 3 || checkedCallback) &&
                !call.contains("inout ") && !call.contains("Pointer") && !call.contains("Unmanaged")
            if directOnly && (words.isSubset(of: nonReceiverTypes) || ["XCUIApplication.State", "XCUIElement.ElementType", "XCTWaiter.Result"].contains(result)) { continue }
            if sdkDynamicSignatures.contains(call) || [
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
                "objc_method JSONSerialization.jsonObject!foreign : (JSONSerialization.Type) -> (Data, JSONSerialization.ReadingOptions) throws -> Any"

            ].contains(call) { continue }
            guard node.resolvedDynamicDeclarations.contains(where: { $0 == declaration || $0.hasPrefix(declaration + "@witness:") }),
                  !node.dependencies.isEmpty else { return nil }
            needsTargets = true
        }
        guard Set(node.dynamicDeclarations.map { $0.components(separatedBy: "@witness:")[0] }).isSubset(of: covered) else { return nil }
        return needsTargets ? node.dependencies.subtracting(node.compilerReferences ?? []) : []
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
            if owners[symbol] == "__C_Synthesized" && !(receiverOrigins ? ["XCTWaiterResult", "XCUIApplicationState", "XCUIElementType"] : ["XCTWaiterResult"]).contains(type) { continue }
            accepted.insert(symbol)
        }
        return accepted
    }
}
