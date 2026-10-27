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
    let unknownCategoryConstructor = "$sSo15XCUIApplicationC11reviewTokenABSS_tcfC"
    let symbols = [sdk, constructor, elementType, waiterWitness, foreign, unknownCategoryConstructor, unknownClang, "unresolved-symbol"]
    let output = try CommandRunner.run("xcrun", ["swift-demangle", "--expand", "--tree-only"],
        at: FileManager.default.temporaryDirectory, input: Data((symbols.joined(separator: "\n") + "\n").utf8)).text
    #expect(SILOwnership.declarationOwners(output)[unknownCategoryConstructor] == "__C")
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
    node.receiverTypeOrigins = []; node.receiverGenericCalls = []; node.compilerReferences = references ? ["external"] : nil
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
    #expect(!first && !cached)
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
    node.receiverTypeOrigins = []; node.receiverGenericCalls = []; node.compilerReferences = []
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


@Test(arguments: ["(XCUIApplication) -> ()", "((XCUIApplication) -> ())?", "inout XCUIApplication", "UnsafeMutablePointer<XCUIApplication>"])
func receiverDynamicOutputChannelsRequireProducerEdges(argument: String) {
    var node = FunctionNode(id: "caller", module: "UI", name: "caller", dependencies: ["direct"], dynamicDeclarations: ["Factory.provide"])
    node.receiverTypeOrigins = []; node.receiverGenericCalls = []; node.compilerReferences = ["direct"]
    node.dynamicCallSignatures = ["objc_method Factory.provide!foreign : (Factory.Type) -> (\(argument)) -> ()"]
    #expect(ExternalHelperEffects.receiverDependencies(node) == nil)
    node.resolvedDynamicDeclarations = ["Factory.provide"]
    node.dependencies.insert("producer")
    #expect(ExternalHelperEffects.receiverDependencies(node) == ["producer"])
}


@Test func rendererCallbackDoesNotGrantOutgoingEffectTrust() {
    var node = FunctionNode(id: "render", module: "UI", name: "render", dynamicDeclarations: ["UIGraphicsImageRenderer.image"])
    node.dynamicCallSignatures = ["objc_method UIGraphicsImageRenderer.image!foreign : (UIGraphicsImageRenderer) -> ((UIGraphicsImageRendererContext) -> ()) -> UIImage"]
    #expect(ExternalHelperEffects.receiverDependencies(node) == nil)
    #expect(ExternalHelperEffects.receiverDependencies(node, sourceCallShapes: ["image": [["<trailing>"]]]) == [])
    #expect(!ExternalHelperEffects.allowsDynamicCalls(node))
}

@Test(arguments: ["Bool", "Swift.Bool", "Void", "()", "Int", "String", "UIImage", "[String]", "(Bool, Int)", "Any?", "AppBox", "AppChoice"])
func opaqueDynamicResultsRequireImplementations(result: String) {
    var node = FunctionNode(id: "caller", module: "UI", name: "caller", dependencies: ["direct"], dynamicDeclarations: ["Factory.make"])
    node.receiverTypeOrigins = []; node.receiverGenericCalls = []; node.compilerReferences = ["direct"]
    node.dynamicCallSignatures = ["objc_method Factory.make!foreign : (Factory.Type) -> () -> \(result)"]
    #expect(ExternalHelperEffects.receiverDependencies(node) == nil)
    node.resolvedDynamicDeclarations = ["Factory.make"]
    node.dependencies.insert("producer")
    #expect(ExternalHelperEffects.receiverDependencies(node) == ["producer"])
}

@Test(arguments: ["literal", "mutable", "typed", "computed", "interpolated", "untrusted", "duplicate"])
func receiverStoredStateRequiresImmutableLiteralEvidence(kind: String) throws {
    let declarations: String
    switch kind {
    case "mutable": declarations = "var text = \"id\""
    case "typed": declarations = "let text: String = \"id\""
    case "computed": declarations = "var text: String { \"id\" }"
    case "interpolated": declarations = #"let text = "id \(make())""#
    case "duplicate": declarations = "let text = \"id\"; var text = \"other\""
    default: declarations = "let text = \"id\""
    }
    let source = (kind == "untrusted" ? "import Foreign\n" : "import XCTest\n") + "class Suite { \(declarations) }"
    let snapshot = SwiftSourceSnapshot.parse(source, path: "State.swift", module: "UI")
    #expect(snapshot.literalStoredProperties?["Suite.text"] == (kind == "literal"))
    var node = FunctionNode(id: "entry", module: "UI", name: "entry", regions: [.init(path: "State.swift", startLine: 2, endLine: 2)], uncertainties: ["Shared state access"])
    node.receiverTypeOrigins = []; node.receiverGenericCalls = []; node.compilerReferences = []; node.dynamicCallSignatures = []; node.stateAccesses = ["field:Suite.text"]
    var current = XcodeTestGraph(targets: [], tests: ["UI/Suite/test()"])
    current.sources = ["UI:State.swift": snapshot]
    current.dependencies = .init(functions: [node.id: node], tests: [current.tests[0]: [node.id]])
    let restored = try GraphArchive.decode(GraphArchive.encode(current))
    var origins = SDKReceiverOrigins()
    #expect(origins.proves(tests: Set(current.tests), current: restored, graph: restored.dependencies!) == (kind == "literal"))
    current.dependencies!.functions[node.id]!.stateAccesses = nil
    var legacy = SDKReceiverOrigins()
    #expect(legacy.blocker(tests: Set(current.tests), current: current, graph: current.dependencies!)?.contains("recapture") == true)
}

@Test(arguments: 0..<8)
func stateAccessEvidenceRoundTripsWithOptionalCallEvidence(bits: Int) throws {
    let references = bits & 1 != 0, calls = bits & 2 != 0, state = bits & 4 != 0
    var node = FunctionNode(id: "entry", module: "UI", name: "entry")
    node.receiverTypeOrigins = []; node.receiverGenericCalls = []; node.compilerReferences = references ? [] : nil
    node.dynamicCallSignatures = calls ? [] : nil
    node.stateAccesses = state ? ["global:shared", "field:Suite.app"] : nil
    node.receiverTypeOrigins = ["literal:XCUIApplication", "input:ForeignApp", "enum:Int.foreignCase"]; node.receiverGenericCalls = []
    var graph = XcodeTestGraph(targets: [], tests: [])
    graph.dependencies = .init(functions: [node.id: node])
    let restored = try GraphArchive.decode(GraphArchive.encode(graph)).dependencies!.functions[node.id]!
    #expect(restored.compilerReferences == node.compilerReferences)
    #expect(restored.dynamicCallSignatures == node.dynamicCallSignatures)
    #expect(restored.stateAccesses == node.stateAccesses)
    #expect(restored.receiverTypeOrigins == node.receiverTypeOrigins)
}

@Test(arguments: ["Imported conformance: Foreign", "Unresolved project dispatch: Factory.make"])
func resolvedOriginEdgesDoNotHideUnresolvedDispatch(uncertainty: String) {
    var node = FunctionNode(id: "caller", module: "UI", name: "caller", dependencies: ["producer"], uncertainties: [uncertainty], dynamicDeclarations: ["Factory.make"])
    node.receiverTypeOrigins = []; node.receiverGenericCalls = []; node.compilerReferences = []; node.dynamicCallSignatures = ["class_method Factory.make : (Factory) -> () -> XCUIApplication"]
    node.resolvedDynamicDeclarations = ["Factory.make"]
    #expect(ExternalHelperEffects.receiverDependencies(node) == nil)
}

@Test(arguments: ["XCUIGestureVelocityFast", "XCUIKeyboardKeyDelete", "XCUIKeyboardKeyForged", "sharedReceiver"])
func receiverGlobalsRequireExactSDKContracts(name: String) {
    var node = FunctionNode(id: "entry", module: "UI", name: "entry", regions: [.init(path: "Tests.swift", startLine: 1, endLine: 1)], uncertainties: ["Global state access", "Shared state access"])
    node.receiverTypeOrigins = []; node.receiverGenericCalls = []; node.compilerReferences = []; node.dynamicCallSignatures = []; node.stateAccesses = ["global:" + name]
    var current = XcodeTestGraph(targets: [], tests: ["UI/Suite/test()"])
    current.sources["UI:Tests.swift"] = .parse("func test() {}", path: "Tests.swift", module: "UI")
    let graph = DependencyGraph(functions: [node.id: node], tests: [current.tests[0]: [node.id]])
    var origins = SDKReceiverOrigins()
    #expect(origins.proves(tests: Set(current.tests), current: current, graph: graph) == ["XCUIGestureVelocityFast", "XCUIKeyboardKeyDelete"].contains(name))
}

@Test(arguments: ["final", "open", "missing", "wrongBody"])
func finalXCTestConstructorClosesOnlyDescendantWarnings(kind: String) {
    var snapshot = SwiftSourceSnapshot.parse("import XCTest\n\(kind == "open" ? "" : "final ")class Suite: XCTestCase {}", path: "Tests.swift", module: "UI")
    if kind == "missing" { snapshot.classFinality = nil }
    let region = SourceRegion(path: "Tests.swift", startLine: 2, endLine: 2)
    var node = FunctionNode(id: "allocator", module: "UI", name: kind == "wrongBody" ? "Suite.make()" : "Suite.__allocating_init()", regions: [region], dependencies: ["initializer"], uncertainties: ["Unresolved project dispatch: Suite.init (incomplete override ancestry)"], dynamicDeclarations: ["Suite.init"])
    node.receiverTypeOrigins = []; node.receiverGenericCalls = []; node.compilerReferences = []; node.dynamicCallSignatures = ["objc_method Suite.init!initializer.foreign : (Suite.Type) -> () -> Suite"]
    node.resolvedDynamicDeclarations = ["Suite.init"]
    var initializer = FunctionNode(id: "initializer", module: "UI", name: "Suite.init()", regions: [region])
    initializer.receiverTypeOrigins = []; initializer.receiverGenericCalls = []; initializer.compilerReferences = []; initializer.dynamicCallSignatures = []
    var current = XcodeTestGraph(targets: [], tests: ["UI/Suite/test()"])
    current.sources = ["UI:Tests.swift": snapshot]
    let graph = DependencyGraph(functions: [node.id: node, initializer.id: initializer], tests: [current.tests[0]: [node.id]])
    var origins = SDKReceiverOrigins()
    #expect(origins.proves(tests: Set(current.tests), current: current, graph: graph) == (kind == "final"))
}

@Test(arguments: ["synthetic", "called", "missingBody", "nonfinal"])
func ancestorAllocationRootsRequireFinalConcreteTest(kind: String) {
    let source = "import XCTest\nclass Parent: XCTestCase {}\n\(kind == "nonfinal" ? "" : "final ")class Suite: Parent {}"
    let snapshot = SwiftSourceSnapshot.parse(source, path: "Tests.swift", module: "UI")
    let region = SourceRegion(path: "Tests.swift", startLine: 2, endLine: 2)
    var allocator = FunctionNode(id: "allocator", module: "UI", name: "Parent.__allocating_init()", regions: [region], dependencies: ["initializer"], uncertainties: ["Unresolved project dispatch: Parent.init (incomplete override ancestry)"], dynamicDeclarations: ["Parent.init"])
    allocator.receiverTypeOrigins = []; allocator.receiverGenericCalls = []; allocator.compilerReferences = []; allocator.dynamicCallSignatures = ["objc_method Parent.init!initializer.foreign : (Parent.Type) -> () -> Parent"]
    allocator.resolvedDynamicDeclarations = ["Parent.init"]
    var initializer = FunctionNode(id: "initializer", module: "UI", name: "Parent.init()", regions: [region])
    initializer.receiverTypeOrigins = []; initializer.receiverGenericCalls = []; initializer.compilerReferences = []; initializer.dynamicCallSignatures = []
    var entry = FunctionNode(id: "entry", module: "UI", name: "Suite.test()", regions: [.init(path: "Tests.swift", startLine: 3, endLine: 3)])
    entry.receiverTypeOrigins = []; entry.receiverGenericCalls = []; entry.compilerReferences = kind == "called" ? ["allocator"] : []; entry.dynamicCallSignatures = []; entry.dependencies = entry.compilerReferences!
    var current = XcodeTestGraph(targets: [], tests: ["UI/Suite/test()"])
    current.modules = ["UI": "UI"]; current.sources = ["UI:Tests.swift": snapshot]
    let roots: Set<String> = kind == "missingBody" ? ["entry", "allocator"] : ["entry", "allocator", "initializer"]
    let graph = DependencyGraph(functions: [entry.id: entry, allocator.id: allocator, initializer.id: initializer], tests: [current.tests[0]: roots])
    var origins = SDKReceiverOrigins()
    #expect(origins.proves(tests: Set(current.tests), current: current, graph: graph) == (kind == "synthetic"))
}

@Test(arguments: ["literal:XCUIApplication", "literal:Array<String>", "literal:ForeignApp", "input:XCUIApplication", "dynamic", "enum:Int.foreignCase", "enum:Optional.none", "missing"])
func receiverNominalEvidenceRejectsErasedTypeIdentity(origin: String) {
    var node = FunctionNode(id: "entry", module: "UI", name: "entry", regions: [.init(path: "Tests.swift", startLine: 2, endLine: 2)])
    node.compilerReferences = []; node.dynamicCallSignatures = []
    node.receiverTypeOrigins = origin == "missing" ? nil : [origin]; node.receiverGenericCalls = []
    var current = XcodeTestGraph(targets: [], tests: ["UI/Suite/test()"])
    current.sources["UI:Tests.swift"] = .parse("import XCTest\nfunc entry() {}", path: "Tests.swift", module: "UI")
    let graph = DependencyGraph(functions: [node.id: node], tests: [current.tests[0]: [node.id]])
    var origins = SDKReceiverOrigins()
    #expect(origins.proves(tests: Set(current.tests), current: current, graph: graph) == ["literal:XCUIApplication", "literal:Array<String>", "enum:Optional.none"].contains(origin))
}

@Test(arguments: ["boundBy", "other", "value", "mixed"])
func receiverOverloadIdentityRequiresEverySourceUse(kind: String) throws {
    let body = kind == "value" ? "let f = query.element(boundBy:)" : kind == "mixed" ? "query.element(boundBy: 0); query.element(other: 0)" : "query.element(\(kind): 0)"
    let source = SwiftSourceSnapshot.parse("func entry() { \(body) }", path: "Tests.swift", module: "UI")
    let shapes = try #require(source.units.first { $0.kind == "function" }?.receiverCallShapes)
    var node = FunctionNode(id: "entry", module: "UI", name: "entry", dynamicDeclarations: ["XCUIElementQuery.element"])
    node.dynamicCallSignatures = ["objc_method XCUIElementQuery.element!foreign : (XCUIElementQuery) -> (Int) -> XCUIElement"]
    #expect(ExternalHelperEffects.receiverDependencies(node) == nil)
    #expect((ExternalHelperEffects.receiverDependencies(node, sourceCallShapes: shapes) != nil) == (kind == "boundBy"))
}

@Test(arguments: [false, true])
func receiverSynthesizedOriginsCoverMemberDeclarations(enumGetter: Bool) {
    let source = enumGetter ? "import XCTest\nenum Value: String {\n    case first = \"a\"\n    case second = \"b\"\n}" : "import XCTest\nfinal class Suite: XCTestCase {\n    let first = \"a\"\n    let second = \"b\"\n}"
    var node = FunctionNode(id: "init", module: "UI", name: enumGetter ? "Value.rawValue.getter" : "Suite.init(invocation:)", regions: [.init(path: "Tests.swift", startLine: 2, endLine: 4)])
    node.compilerReferences = []; node.dynamicCallSignatures = []; node.receiverTypeOrigins = ["literal:String"]; node.receiverGenericCalls = []
    var current = XcodeTestGraph(targets: [], tests: ["UI/Suite/test()"])
    current.sources["UI:Tests.swift"] = .parse(source, path: "Tests.swift", module: "UI")
    let graph = DependencyGraph(functions: [node.id: node], tests: [current.tests[0]: [node.id]])
    var origins = SDKReceiverOrigins()
    let proven = origins.proves(tests: Set(current.tests), current: current, graph: graph)
    #expect(proven)
    current.sources["UI:Tests.swift"] = .parse("import Foreign\n" + source, path: "Tests.swift", module: "UI")
    var opaque = SDKReceiverOrigins()
    let opaqueProven = opaque.proves(tests: Set(current.tests), current: current, graph: graph)
    #expect(!opaqueProven)
}

@Test(arguments: ["struct", "enum", "class", "shadow", "alias", "missing"], [false, true])
func receiverValueMetatypesRequireCapturedNonSDKIdentity(kind: String, input: Bool) {
    let declaration: String
    switch kind {
    case "struct": declaration = "struct Value {}"
    case "enum": declaration = "enum Value { case sample }"
    case "class": declaration = "class Value: XCUIApplication {}"
    case "shadow": declaration = "struct Int {}"
    case "alias": declaration = "typealias Value = XCUIApplication"
    default: declaration = ""
    }
    let name = kind == "shadow" ? "Int" : "Value"
    var node = FunctionNode(id: "entry", module: "UI", name: "entry", regions: [.init(path: "Tests.swift", startLine: 3, endLine: 3)])
    node.compilerReferences = []; node.dynamicCallSignatures = []; node.receiverTypeOrigins = [(input ? "input:" : "literal:") + name]; node.receiverGenericCalls = []
    var current = XcodeTestGraph(targets: [], tests: ["UI/Suite/test()"])
    current.sources["UI:Tests.swift"] = .parse("import XCTest\n" + declaration + "\nfunc entry() {}", path: "Tests.swift", module: "UI")
    let graph = DependencyGraph(functions: [node.id: node], tests: [current.tests[0]: [node.id]])
    var origins = SDKReceiverOrigins()
    let proven = origins.proves(tests: Set(current.tests), current: current, graph: graph)
    #expect(proven == ["struct", "enum"].contains(kind))
}
