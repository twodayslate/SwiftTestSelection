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
