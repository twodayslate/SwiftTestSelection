// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation
import Testing
@testable import TestImpact

@Test func externalHelperEffectsCheckCompilerDeclarationOwners() throws {
    let sdk = "$s6XCTest13XCTAssertTrue__4file4lineySbyKXK_SSyXKs12StaticStringVSutF"
    let constructor = "$sSo13XCTAttachmentC10screenshotABSo14XCUIScreenshotC_tcfCTO"
    let elementType = "$sSo15XCUIElementTypeV8rawValueSuvg"
    let waiterWitness = "$sSo15XCTWaiterResultVSQSCSQ2eeoiySbx_xtFZTW"
    let foreign = "$sSo15XCUIApplicationC17AttachmentSupportE14markReviewFlagSbyF"
    let unknownClang = "$sSo7UnknownCABycfC"
    let symbols = [sdk, constructor, elementType, waiterWitness, foreign, unknownClang, "unresolved-symbol"]
    let output = try CommandRunner.run("xcrun", ["swift-demangle", "--expand", "--tree-only"],
        at: FileManager.default.temporaryDirectory, input: Data((symbols.joined(separator: "\n") + "\n").utf8)).text
    #expect(ExternalHelperEffects.trustedDeclarations(output) == [sdk, constructor, elementType, waiterWitness])
    #expect(ExternalHelperEffects.trustedDeclarations("unrecognized output") == [])
}

@Test func externalHelperEffectsCacheBatchResultsIncludingFailures() {
    let sdk = "$s6XCTest13XCTAssertTrue__4file4lineySbyKXK_SSyXKs12StaticStringVSutF"
    let output = """
    Demangling for \(sdk)
    kind=Global
      kind=Function
        kind=Module, text="XCTest"
        kind=Identifier, text="XCTAssertTrue"
    """
    var proof = ExternalHelperEffects(), batches: [[String]] = []
    let resolve: ([String]) -> String? = { batches.append($0); return output }
    let initial = proof.allows([sdk, "unknown"], resolve: resolve)
    let cachedSDK = proof.allows([sdk], resolve: resolve)
    let cachedUnknown = proof.allows(["unknown"], resolve: resolve)
    #expect(!initial)
    #expect(cachedSDK)
    #expect(!cachedUnknown)
    #expect(batches.count == 1)
    #expect(Set(batches[0]) == [sdk, "unknown"])
    let unavailable = proof.allows(["unavailable"], resolve: { batches.append($0); return nil })
    let cachedUnavailable = proof.allows(["unavailable"], resolve: resolve)
    #expect(!unavailable)
    #expect(!cachedUnavailable)
    #expect(batches.count == 2)
}

@Test(arguments: ["root", "NSObject", "nested", "sdk", "alias", "unknown", "cycle", "ambiguous", "qualified", "nestedAlias", "unrelatedNested", "lexical", "inheritedNested", "missing"])
func attachmentOverrideAuditUsesAncestryAtBothRevisions(scenario: String) {
    let definitions: String
    switch scenario {
    case "root": definitions = "class Base { var name: String { \"\" } }\nclass Child: Base { override var name: String { \"\" } }"
    case "NSObject": definitions = "import Foundation\nclass Child: NSObject { override var name: String { \"\" } }"
    case "nested": definitions = "struct Container { class Base { var name: String { \"\" } }; class Child: Base { override var name: String { \"\" } } }"
    case "sdk": definitions = "import XCTest\nclass Child: XCTestCase { override var name: String { \"\" } }"
    case "alias": definitions = "import XCTest\ntypealias Parent = XCTestCase\nclass Child: Parent { override var name: String { \"\" } }"
    case "nestedAlias": definitions = "class Parent {}\nenum Namespace { typealias Parent = XCTestCase; class Child: Parent { override var name: String { \"\" } } }"
    case "unrelatedNested": definitions = "struct Other { class NSObject {} }\nclass Child: NSObject { override var name: String { \"\" } }"
    case "lexical": definitions = "class Base: XCTestCase {}\nstruct Namespace { class Base {}; class Child: Base { override var name: String { \"\" } } }"
    case "inheritedNested": definitions = "class Parent {}\nclass Ancestor { class Parent: XCTestCase {} }\nclass Namespace: Ancestor { class Child: Parent { override var name: String { \"\" } } }"
    case "unknown": definitions = "class Child: Unavailable { override var name: String { \"\" } }"
    case "cycle": definitions = "class Base: Child {}\nclass Child: Base { override var name: String { \"\" } }"
    case "qualified": definitions = "class Root {}\nclass Child: Support.Base { override var name: String { \"\" } }"
    case "ambiguous": definitions = "class Base {}\nclass Base: XCTestCase {}\nclass Child: Base { override var name: String { \"\" } }"
    default: definitions = "class Child { var name: String { \"\" } }"
    }
    var snapshot = SwiftSourceSnapshot.parse(definitions, path: "Types.swift", module: "UI")
    if scenario == "missing" { snapshot.superclasses = nil }
    let empty = SwiftSourceSnapshot.parse("", path: "Types.swift", module: "UI")
    let safe = ["root", "NSObject", "nested", "lexical"].contains(scenario)
    let support = SwiftSourceSnapshot.parse("import XCTest\nclass Root: XCTestCase {}\nclass Base: Root {}", path: "Support.swift", module: "Support")
    let sources = scenario == "qualified" ? [snapshot, support] : [snapshot]
    for revisions in [[sources, [empty]], [[empty], sources]] {
        #expect(SDKTestHelperIsolation.overridesUnshadowed(revisions: revisions, members: ["name"], sdkReceivers: ["XCTestCase", "XCTAttachment"]) == safe)
    }
}

@Test func dynamicHelperEffectsRequireCompleteCallEvidence() throws {
    let call = "objc_method XCUIElement.exists!getter.foreign : (XCUIElement) -> () -> Bool"
    var node = FunctionNode(id: "helper", module: "UI", name: "helper", dynamicDeclarations: ["XCUIElement.exists"])
    #expect(!ExternalHelperEffects.allowsDynamicCalls(node))
    node.dynamicCallSignatures = []
    #expect(!ExternalHelperEffects.allowsDynamicCalls(node))
    node.dynamicCallSignatures = [call]
    #expect(ExternalHelperEffects.allowsDynamicCalls(node))
    node.dynamicCallSignatures = [call, "objc_method XCUIElement.exists!foreign : (XCUIElement) -> () -> Bool"]
    #expect(!ExternalHelperEffects.allowsDynamicCalls(node))
    node.dynamicCallSignatures = [call]
    node.uncertainties = ["Unresolved project dispatch: XCUIElement.exists"]
    #expect(!ExternalHelperEffects.allowsDynamicCalls(node))
}

@Test(arguments: [false, true]) func dynamicCallEvidenceSurvivesArchives(references: Bool) throws {
    var node = FunctionNode(id: "helper", module: "UI", name: "helper", dynamicDeclarations: ["XCUIElement.exists"])
    node.dynamicCallSignatures = ["objc_method XCUIElement.exists!getter.foreign : (XCUIElement) -> () -> Bool"]
    node.compilerReferences = references ? ["external"] : nil
    var graph = XcodeTestGraph(targets: [], tests: [])
    graph.dependencies = .init(functions: [node.id: node])
    for data in [try GraphArchive.encode(graph), try JSONEncoder().encode(graph)] {
        let restored = try #require(GraphArchive.decode(data).dependencies?.functions[node.id])
        #expect(restored.dynamicCallSignatures == node.dynamicCallSignatures)
        #expect(restored.compilerReferences == node.compilerReferences)
        #expect(ExternalHelperEffects.allowsDynamicCalls(restored))
    }
}

@Test func compilerActorChecksDoNotTrustArbitraryRuntimeNames() {
    var proof = ExternalHelperEffects()
    let supported = proof.allows(["swift_task_isCurrentExecutor", "swift_task_reportUnexpectedExecutor"], resolve: { _ in
        Issue.record("Compiler runtime checks do not require demangling")
        return nil
    })
    #expect(supported)
    let unknown = proof.allows(["swift_unrecognizedRuntimeEffect"], resolve: { _ in nil })
    #expect(!unknown)
}

@Test func queryOverloadsRequireCompatibleSourceShapes() {
    let prefix = "objc_method XCUIElementQuery.matching!foreign : (XCUIElementQuery) -> "
    var node = FunctionNode(id: "helper", module: "UI", name: "helper", dynamicDeclarations: ["XCUIElementQuery.matching"])
    node.dynamicCallSignatures = [prefix + "(String) -> XCUIElementQuery"]
    #expect(!ExternalHelperEffects.allowsDynamicCalls(node))
    #expect(!ExternalHelperEffects.allowsDynamicCalls(node, sourceCallShapes: ["matching": [["_"]]]))
    #expect(!ExternalHelperEffects.allowsDynamicCalls(node, sourceCallShapes: ["matching": [["_"], ["identifier"]]]))
    #expect(ExternalHelperEffects.allowsDynamicCalls(node, sourceCallShapes: ["matching": [["identifier"]]]))
    node.dynamicCallSignatures = [prefix + "(NSPredicate) -> XCUIElementQuery"]
    #expect(!ExternalHelperEffects.allowsDynamicCalls(node, sourceCallShapes: ["matching": [["identifier"]]]))
    #expect(ExternalHelperEffects.allowsDynamicCalls(node, sourceCallShapes: ["matching": [["_"]]]))
}

@Test func privateHelperPreservesTransitiveQueryBindingEvidence() throws {
    let source = """
    import XCTest
    @MainActor final class Suite: XCTestCase {
        func testCapture() { capture(XCUIApplication()) }
        private func capture(_ app: XCUIApplication) { check(app) }
        private func check(_ app: XCUIApplication) {
            XCTAssertTrue(app.buttons["item"].exists)
            XCTAssertTrue(app.buttons.`matching`(`identifier`: "item").firstMatch.exists)
        }
    }
    """
    let snapshot = SwiftSourceSnapshot.parse(source, path: "Tests.swift", module: "UI")
    let proof = try #require(snapshot.units.first { $0.privateTestHelper?.name == "capture" }?.privateTestHelper)
    #expect(proof.calleeEffectsSupported == true)
    #expect(proof.sdkEffectMembers?.contains("subscript") == true)
    #expect(proof.sdkCallShapes?["matching"] == [["identifier"]])
    let restored = try JSONDecoder().decode(PrivateTestHelperSyntax.self, from: JSONEncoder().encode(proof))
    #expect(restored.sdkCallShapes == proof.sdkCallShapes)
    // A deleted project subscript must be audited even when the surviving head
    // expression now resolves to the ordinary SDK identifier getter.
    let old = SwiftSourceSnapshot.parse("extension XCUIElementQuery { subscript(_ id: String) -> XCUIElement { effect() } }", path: "Old.swift", module: "UI")
    let empty = SwiftSourceSnapshot.parse("", path: "Old.swift", module: "UI")
    for revisions in [[[old], [empty]], [[empty], [old]]] {
        #expect(!SDKTestHelperIsolation.memberBindingsUnshadowed(revisions: revisions,
            members: proof.sdkEffectMembers!, sdkOwners: ["XCUIElementQuery"]))
    }
}

@Test func receiverOriginDemanglingUsesTheOuterResult() {
    let tree = """
    kind=Global
      kind=Function
        kind=Module, text="Factory"
        kind=Identifier, text="run"
        kind=Type
          kind=FunctionType
            kind=ArgumentTuple
              kind=Type
                kind=FunctionType
                  kind=ArgumentTuple
                    kind=Type
                      kind=Tuple
                  kind=ReturnType
                    kind=Type
                      kind=Class
                        kind=Module, text="Factory"
                        kind=Identifier, text="CustomApp"
            kind=ReturnType
              kind=Type
                kind=Tuple
    """
    #expect(ExternalHelperEffects.nonReceiverResult(ArraySlice(tree.components(separatedBy: .newlines))))
    var returnsOpaque = tree
    returnsOpaque.replaceSubrange(tree.range(of: "kind=Tuple", options: .backwards)!, with: "kind=ProtocolList")
    #expect(!ExternalHelperEffects.nonReceiverResult(ArraySlice(returnsOpaque.components(separatedBy: .newlines))))
}

@Test(arguments: ["Class", "DependentGenericParamType", "ProtocolList", "BuiltinTypeName", "TypeAlias", "OpaqueReturnTypeOf", "UnknownFutureType"])
func receiverOriginRejectsWrappedOpaqueResults(kind: String) {
    let tree = """
    kind=Global
      kind=Function
        kind=Module, text="Factory"
        kind=Identifier, text="make"
        kind=Type
          kind=FunctionType
            kind=ArgumentTuple
              kind=Type
                kind=Tuple
            kind=ReturnType
              kind=Type
                kind=BoundGenericEnum
                  kind=Type
                    kind=Enum
                      kind=Module, text="Swift"
                      kind=Identifier, text="Optional"
                  kind=TypeList
                    kind=Type
                      kind=\(kind)
                        kind=Module, text="Factory"
                        kind=Identifier, text="CustomApp"
    """
    #expect(!ExternalHelperEffects.nonReceiverResult(ArraySlice(tree.components(separatedBy: .newlines))))
}

@Test func receiverOriginCacheDoesNotGrantEffectTrust() {
    let output = """
    Demangling for foreign-value
    kind=Global
      kind=Function
        kind=Module, text="Foreign"
        kind=Identifier, text="value"
        kind=Type
          kind=FunctionType
            kind=ArgumentTuple
              kind=Type
                kind=Tuple
            kind=ReturnType
              kind=Type
                kind=Structure
                  kind=Module, text="Swift"
                  kind=Identifier, text="Bool"
    """
    var proof = ExternalHelperEffects(), calls = 0
    let resolve: ([String]) -> String? = { _ in calls += 1; return output }
    let first = proof.allowsReceiverOrigins(["foreign-value"], resolve: resolve)
    let cached = proof.allowsReceiverOrigins(["foreign-value"], resolve: resolve)
    let effect = proof.allows(["foreign-value"], resolve: resolve)
    #expect(first && cached)
    #expect(!effect)
    #expect(calls == 2)
}

@Test(arguments: ["subscript(safe index: Int) -> Int { 0 }", "subscript(index: Int) -> Int { 0 }", "subscript(_ index: Int, flag: Bool = false) -> Int { 0 }", "subscript(_ indices: Int...) -> Int { 0 }"])
func subscriptBindingEvidenceAccountsForImplicitLabelsAndDefaults(declaration: String) throws {
    let snapshot = SwiftSourceSnapshot.parse("extension Collection { \(declaration) }", path: "Types.swift", module: "UI")
    let unit = try #require(snapshot.units.first { $0.kind == "state" })
    #expect(unit.subscriptAcceptsSingleUnlabeledArgument == !declaration.contains("safe index"))
}

@Test func receiverOriginsRequireCompleteSavedBodies() {
    var node = FunctionNode(id: "$s2UI5entryyyF", module: "UI", name: "entry", regions: [.init(path: "Tests.swift", startLine: 1, endLine: 1)], dynamicDeclarations: ["XCUIApplication.factory"])
    node.compilerReferences = []
    node.dynamicCallSignatures = []
    #expect(!ExternalHelperEffects.allowsDynamicReceiverOrigins(node))
    node.dynamicCallSignatures = ["objc_method XCUIApplication.factory!foreign : (XCUIApplication.Type) -> () -> XCUIApplication"]
    #expect(!ExternalHelperEffects.allowsDynamicReceiverOrigins(node))
    node.dynamicCallSignatures = ["objc_method XCUIApplication.factory!foreign : (XCUIApplication.Type) -> () -> ForeignApp"]
    #expect(!ExternalHelperEffects.allowsDynamicReceiverOrigins(node))
    node.dynamicDeclarations = []
    node.dynamicCallSignatures = nil
    var origins = SDKReceiverOrigins()
    let graph = DependencyGraph(functions: [node.id: node], tests: ["UI/Suite/test()": [node.id]])
    var current = XcodeTestGraph(targets: [], tests: ["UI/Suite/test()"])
    current.sources["UI:Tests.swift"] = SwiftSourceSnapshot.parse("func entry() {}", path: "Tests.swift", module: "UI")
    let complete = origins.proves(tests: ["UI/Suite/test()"], current: current, graph: graph)
    #expect(!complete)
}

@Test func malformedDynamicReceiverEvidenceFallsBack() {
    var node = FunctionNode(id: "helper", module: "UI", name: "helper", dynamicDeclarations: ["XCUIApplication.factory"])
    node.dynamicCallSignatures = ["objc_method ! : () -> Bool"]
    #expect(!ExternalHelperEffects.allowsDynamicReceiverOrigins(node))
    #expect(!ExternalHelperEffects.allowsDynamicCalls(node))
    node.dynamicDeclarations = []
    node.dynamicCallSignatures = ["objc_method XCUIApplication.factory!foreign : (XCUIApplication.Type) -> () -> XCUIApplication"]
    #expect(!ExternalHelperEffects.allowsDynamicReceiverOrigins(node))
    #expect(!ExternalHelperEffects.allowsDynamicCalls(node))
}


@Test(arguments: [false, true]) func receiverOriginChecksCallbackArguments(opaque: Bool) {
    let argument = opaque ? "Class" : "Structure"
    let module = opaque ? "Foreign" : "Swift"
    let name = opaque ? "CustomApp" : "Bool"
    let tree = """
    kind=Global
      kind=Function
        kind=Module, text="Foreign"
        kind=Identifier, text="provide"
        kind=Type
          kind=FunctionType
            kind=ArgumentTuple
              kind=Type
                kind=NoEscapeFunctionType
                  kind=ArgumentTuple
                    kind=Type
                      kind=\(argument)
                        kind=Module, text="\(module)"
                        kind=Identifier, text="\(name)"
                  kind=ReturnType
                    kind=Type
                      kind=Tuple
            kind=ReturnType
              kind=Type
                kind=Tuple
    """
    #expect(ExternalHelperEffects.nonReceiverResult(ArraySlice(tree.components(separatedBy: .newlines))) == !opaque)
}

@Test(arguments: ["(XCUIApplication) -> ()", "((XCUIApplication) -> ())?", "inout XCUIApplication", "UnsafeMutablePointer<XCUIApplication>"])
func receiverDynamicOutputChannelsRequireProducerEdges(argument: String) {
    var node = FunctionNode(id: "caller", module: "UI", name: "caller", dependencies: ["direct"], dynamicDeclarations: ["Factory.provide"])
    node.compilerReferences = ["direct"]
    node.dynamicCallSignatures = ["objc_method Factory.provide!foreign : (Factory.Type) -> (\(argument)) -> ()"]
    #expect(ExternalHelperEffects.receiverDependencies(node) == nil)
    node.resolvedDynamicDeclarations = ["Factory.provide"]
    node.dependencies.insert("producer")
    #expect(ExternalHelperEffects.receiverDependencies(node) == ["producer"])
}


@Test(arguments: ["assertion", "stored", "forwarded", "cast", "returned", "implicit", "untrusted", "mixed", "reported", "forwardedMessage"])
func callbackInputEvidenceRequiresDirectNilAssertions(kind: String) {
    let closure: String
    switch kind {
    case "stored": closure = "value in saved = value"
    case "forwarded": closure = "value in consume(value)"
    case "cast": closure = "value in XCTAssertNil(value as? XCUIApplication)"
    case "returned": closure = "value in return value"
    case "implicit": closure = "XCTAssertNil($0)"
    case "reported": closure = #"value in if let value { XCTFail("Failed: \(value)") }; finished.fulfill()"#
    case "forwardedMessage": closure = #"value in XCTFail("Failed: \(consume(value))")"#
    default: closure = "value in XCTAssertNil(value); finished.fulfill()"
    }
    let other = kind == "mixed" ? "Factory.run { value in saved = value }" : ""
    let source = "import XCTest\n" + (kind == "untrusted" ? "import Foreign\n" : "") + "func test() { Factory.run { \(closure) }; \(other) }"
    let snapshot = SwiftSourceSnapshot.parse(source, path: "Tests.swift", module: "UI")
    let evidence = snapshot.units.first { $0.helperCallableName == "test" }?.assertedCallbackInputs
    #expect((evidence?["run"]?.isEmpty == false) == ["assertion", "reported"].contains(kind))
}

@Test(arguments: ["sdk", "external", "missing", "unrelatedClosure"])
func callbackInputEvidenceRequiresCompilerBindings(kind: String) throws {
    let source = "import XCTest\nfunc test() { Factory.run { value in XCTAssertNil(value) } }"
    var snapshot = SwiftSourceSnapshot.parse(source, path: "Tests.swift", module: "UI")
    if kind == "missing" { for i in snapshot.units.indices { snapshot.units[i].assertedCallbackInputs = nil } }
    let region = SourceRegion(path: "Tests.swift", startLine: 2, endLine: 2)
    var caller = FunctionNode(id: "caller", module: "UI", name: "test", regions: [region], dependencies: ["callback"], dynamicDeclarations: ["Factory.run"])
    caller.compilerReferences = ["callback"]
    caller.dynamicCallSignatures = ["objc_method Factory.run!foreign : (Factory.Type) -> ((XCUIApplication) -> ()) -> ()"]
    let assertion = kind == "external" ? "$s7Foreign7consumeyyF" : "$s6XCTest13XCTAssertTrue__4file4lineySbyKXK_SSyXKs12StaticStringVSutF"
    var callback = FunctionNode(id: "callback", module: "UI", name: "closure #1", regions: [region], dependencies: [assertion])
    callback.compilerReferences = [assertion]; callback.dynamicCallSignatures = []
    var functions = [caller.id: caller, callback.id: callback]
    if kind == "unrelatedClosure" {
        // An implicit assertion can inherit earlier capture locations, spanning
        // the real completion despite calling unrelated project helpers.
        var other = FunctionNode(id: "other", module: "UI", name: "implicit closure #1", regions: [.init(path: "Tests.swift", startLine: 1, endLine: 2)], dependencies: ["$s7Foreign7consumeyyF"])
        other.compilerReferences = other.dependencies; other.dynamicCallSignatures = []
        functions[other.id] = other
        functions[caller.id]!.compilerReferences!.insert(other.id)
        functions[caller.id]!.dependencies.insert(other.id)
    }
    let graph = DependencyGraph(functions: functions, tests: ["UI/Suite/test()": [caller.id]])
    var current = XcodeTestGraph(targets: [], tests: ["UI/Suite/test()"])
    current.sources = ["UI:Tests.swift": snapshot]; current.dependencies = graph
    let restored = try GraphArchive.decode(GraphArchive.encode(current))
    var origins = SDKReceiverOrigins()
    let safe = origins.proves(tests: Set(current.tests), current: restored, graph: try #require(restored.dependencies))
    #expect(safe == (["sdk", "unrelatedClosure"].contains(kind)))
}


@Test func rendererCallbackDoesNotGrantOutgoingEffectTrust() {
    var node = FunctionNode(id: "render", module: "UI", name: "render", dynamicDeclarations: ["UIGraphicsImageRenderer.image"])
    node.dynamicCallSignatures = ["objc_method UIGraphicsImageRenderer.image!foreign : (UIGraphicsImageRenderer) -> ((UIGraphicsImageRendererContext) -> ()) -> UIImage"]
    #expect(ExternalHelperEffects.receiverDependencies(node) == [])
    #expect(!ExternalHelperEffects.allowsDynamicCalls(node))
}
