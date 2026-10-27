// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation
import Testing
@testable import TestImpact

@Test func sdkModuleOwnershipDoesNotGrantReceiverContracts() {
    let reflection = "$ss11_typeByNameyypXpSgSSF"
    let symbols: Set<String> = [reflection, "futureSwiftFactory", "foundationDecoder", "futureXCTestFactory"]
    var proof = ExternalHelperEffects()
    let unproven = proof.unprovenReceiverOrigins(symbols) { batch in
        batch.map { symbol in
            let module = symbol == "foundationDecoder" ? "Foundation" : symbol == "futureXCTestFactory" ? "XCTest" : "Swift"
            return "Demangling for \(symbol)\nkind=Global\n  kind=Function\n    kind=Module, text=\"\(module)\"\n    kind=Identifier, text=\"factory\"\n"
        }.joined()
    }
    #expect(unproven == symbols)
}

@Test func genericReceiverContractsRequireClosedConcreteWitnesses() {
    let iterator = "$ss16IndexingIteratorV4next7ElementQzSgyF"
    for arguments in ["[XCUIElement]", "Array<XCUIElement>", "Range<Int>", "[String: XCUIElement]", "Array<ForeignApp>", "Array<Condition>, () -> Bool, Never", "Array<XCUIApplication.Type>", "Array<() -> Bool>", "[() -> Bool]", "[String: () -> Bool]"] {
        #expect(SDKReceiverContracts.allows(arguments, for: iterator))
    }
    for arguments in ["ForeignCollection", "XCUIApplication", "Range<XCUIApplication>", "ReversedCollection<XCUIApplication>", "Array<", "[String:", "Array<>Extra", "(XCUIApplication) -> String"] {
        #expect(!SDKReceiverContracts.allows(arguments, for: iterator))
    }
    let equal = "$s6XCTest14XCTAssertEqual___4file4lineyxyKXK_xyKXKSSyXKs12StaticStringVSutSQRzlF"
    #expect(SDKReceiverContracts.allows("[String: Int?]", for: equal))
    #expect(!SDKReceiverContracts.allows("[XCUIElement]", for: equal))
    let bridge = "$ss27_bridgeAnythingToObjectiveCyyXlxlF"
    #expect(SDKReceiverContracts.allows("XCUIApplication", for: bridge))
    #expect(!SDKReceiverContracts.allows("Any", for: bridge))
    #expect(!SDKReceiverContracts.allows("[Any]", for: bridge))
    #expect(SDKReceiverContracts.typeNames(String(repeating: "Array<", count: 40) + "String" + String(repeating: ">", count: 40)) == nil)
}

@Test func genericReceiverCaptureRetainsEveryInstantiationAndConversion() {
    let sil = """
    sil @caller : $@convention(thin) () -> () {
    bb0:
      %f = function_ref @$ss16IndexingIteratorV4next7ElementQzSgyF : $Function
      %copy = copy_value %f : $Function
      %literal = string_literal utf8 "apply %f<FakeCollection>()"
      %a = apply %f<[XCUIElement]>(%input) : $Function
      %b = partial_apply [callee_guaranteed] %copy<ForeignCollection>(%input) : $Function
      %c = apply %f<Array<Condition>, () -> Bool, Never>(%input) : $Function
      try_apply %f<Range<Int>>(%input) : $Function, normal bb1, error bb2
      return %nothing : $()
    } // end sil function 'caller'
    """
    let graph = SILParser.parse(sil, module: "UI", sourceRoot: URL(fileURLWithPath: "/tmp"))
    #expect(graph.functions["caller"]?.receiverGenericCalls == [
        "$ss16IndexingIteratorV4next7ElementQzSgyF\t[XCUIElement]",
        "$ss16IndexingIteratorV4next7ElementQzSgyF\tForeignCollection",
        "$ss16IndexingIteratorV4next7ElementQzSgyF\tRange<Int>",
        "$ss16IndexingIteratorV4next7ElementQzSgyF\tArray<Condition>, () -> Bool, Never"
    ])
    let unknown = SILParser.parse(sil.replacingOccurrences(of: "%copy<ForeignCollection>", with: "%copy<ForeignCollection"), module: "UI", sourceRoot: URL(fileURLWithPath: "/tmp"))
    #expect(unknown.functions["caller"]?.receiverGenericCalls == nil)
}

@Test(arguments: [false, true], [false, true])
func genericReceiverEvidenceRoundTripsWithoutFillingMissingSlots(origins: Bool, calls: Bool) throws {
    var node = FunctionNode(id: "entry", module: "UI", name: "entry")
    node.receiverTypeOrigins = origins ? [] : nil
    node.receiverGenericCalls = calls ? ["symbol\tArray<String>"] : nil
    var graph = XcodeTestGraph(targets: [], tests: [])
    graph.dependencies = .init(functions: [node.id: node])
    for data in [try GraphArchive.encode(graph), try JSONEncoder().encode(graph)] {
        let restored = try #require(GraphArchive.decode(data).dependencies?.functions[node.id])
        #expect(restored.receiverTypeOrigins == node.receiverTypeOrigins)
        #expect(restored.receiverGenericCalls == node.receiverGenericCalls)
        #expect(restored.compilerReferences == nil)
        #expect(restored.dynamicCallSignatures == nil)
    }
}

@Test(arguments: ["valid", "missing", "foreign", "mixed", "shadowed", "escapedShadow", "escapedAlias"])
func savedReceiverProofChecksGenericCallsBeforeSkippingSDKBody(kind: String) {
    let iterator = "$ss16IndexingIteratorV4next7ElementQzSgyF"
    var node = FunctionNode(id: "entry", module: "UI", name: "entry", regions: [.init(path: "Tests.swift", startLine: 2, endLine: 2)])
    node.receiverTypeOrigins = []; node.dynamicCallSignatures = []; node.compilerReferences = [iterator]
    node.receiverGenericCalls = [iterator + "\t[String]"]
    if kind == "missing" { node.receiverGenericCalls = nil }
    if kind == "foreign" { node.receiverGenericCalls = [iterator + "\tForeignCollection"] }
    if kind == "mixed" { node.receiverGenericCalls!.insert(iterator + "\tForeignCollection") }
    var current = XcodeTestGraph(targets: [], tests: ["UI/Suite/test()"])
    let shadow = ["shadowed": "struct Array {}", "escapedShadow": "struct `Array` {}", "escapedAlias": "typealias `Array` = ForeignCollection"][kind] ?? ""
    current.sources = ["UI:Tests.swift": SwiftSourceSnapshot.parse("import XCTest\nfunc entry() {}\n" + shadow, path: "Tests.swift", module: "UI")]
    let graph = DependencyGraph(functions: [node.id: node], tests: [current.tests[0]: [node.id]])
    var proof = SDKReceiverOrigins()
    #expect(proof.proves(tests: Set(current.tests), current: current, graph: graph) == (kind == "valid"))
}

@Test(arguments: [false, true]) func genericReceiverCaptureMergesFragmentsConservatively(unknown: Bool) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let symbol = "$ss16IndexingIteratorV4next7ElementQzSgyF"
    let files = [root.appendingPathComponent("a.sil"), root.appendingPathComponent("b.sil")]
    for (index, file) in files.enumerated() {
        let closing = unknown && index == 1 ? "" : ">"
        let type = index == 0 ? "[String]" : "ForeignCollection"
        let sil = """
        sil @entry : $@convention(thin) () -> () {
          %f = function_ref @\(symbol) : $Function
          %a = apply %f<\(type)\(closing)(%input) : $Function
          return %nothing : $()
        } // end sil function 'entry'
        """
        try Data(sil.utf8).write(to: file)
    }
    let capture = CapturedSIL(modules: ["UI": files], fingerprints: [:], diagnostics: [])
    let node = try #require(capture.parse(module: "UI", sourceRoot: root)?.functions["entry"])
    #expect(node.receiverGenericCalls == (unknown ? nil : [symbol + "\t[String]", symbol + "\tForeignCollection"]))
}

@Test func receiverCaptureRetainsImplicitBridgeAndMetatypeCasts() {
    let sil = """
    sil @entry : $@convention(thin) () -> () {
      unconditional_checked_cast_addr Any in %0 to XCUIApplication in %1
      checked_cast_addr_br take_always Any in %0 to String in %1, bb1, bb2
      %2 = unconditional_checked_cast %0 to XCUIApplication.Type
      %3 = unchecked_ref_cast %0 : $AnyObject to $XCUIElement
      checked_cast_addr_br take_always Any in %0 to Dictionary<String, Int> in %1, bb1, bb2
      return %nothing : $()
    } // end sil function 'entry'
    """
    let graph = SILParser.parse(sil, module: "UI", sourceRoot: URL(fileURLWithPath: "/tmp"))
    #expect(graph.functions["entry"]?.receiverTypeOrigins == ["cast:XCUIApplication", "cast:String", "cast:XCUIApplication.Type", "cast:Dictionary<String, Int>"])
}

@Test(arguments: ["String", "XCUIApplication", "XCUIApplication.Type", "missing"])
func receiverCastProofRequiresCurrentCaptureAndValueDestinations(target: String) {
    var node = FunctionNode(id: "entry", module: "UI", name: "entry", regions: [.init(path: "Tests.swift", startLine: 2, endLine: 2)])
    node.receiverTypeOrigins = target == "missing" ? [] : ["cast:" + target]
    node.receiverGenericCalls = target == "missing" ? nil : []
    node.compilerReferences = []; node.dynamicCallSignatures = []
    var current = XcodeTestGraph(targets: [], tests: ["UI/Suite/test()"])
    current.sources = ["UI:Tests.swift": SwiftSourceSnapshot.parse("import XCTest\nfunc entry() {}", path: "Tests.swift", module: "UI")]
    let graph = DependencyGraph(functions: [node.id: node], tests: [current.tests[0]: [node.id]])
    var proof = SDKReceiverOrigins()
    let blocker = proof.blocker(tests: Set(current.tests), current: current, graph: graph)
    #expect((blocker == nil) == (target == "String"))
    if target == "missing" { #expect(blocker?.contains("recapture") == true) }
}

@Test(arguments: ["nil", "mutated", "aliased", "predecessors", "live", "mixed"])
func erasedBridgeExemptionRequiresAnUnreachableLiteralNilBlock(kind: String) {
    let symbol = SDKReceiverContracts.objectBridge
    let other = kind == "aliased" ? "%other" : "%slot"
    let mutation = kind == "mutated" ? "apply %mutate(%slot) : $Function" : ""
    let predecessors = kind == "predecessors" ? "bb0 bb2" : "bb0"
    let enumeration = kind == "live" ? "some" : "none"
    let live = kind == "mixed" ? "%f2 = function_ref @\(symbol) : $Function\n%real = apply %f2<Any>(%input) : $Function" : ""
    let sil = """
    sil @entry : $@convention(thin) () -> () {
    bb0:
      %slot = alloc_stack $Optional<Any>, loc "source.swift":1:1
      inject_enum_addr \(other), #Optional.\(enumeration)!enumelt, loc "source.swift":1:1
      \(mutation)
      switch_enum_addr %slot, case #Optional.some!enumelt: bb1, case #Optional.none!enumelt: bb2, loc "source.swift":1:1
    bb1: // Preds: \(predecessors)
      %f = function_ref @\(symbol) : $Function
      %r = apply %f<Any>(%input) : $Function
      br bb2
    bb2: // Preds: bb0 bb1
      \(live)
      return %nothing : $()
    } // end sil function 'entry'
    """
    let node = SILParser.parse(sil, module: "UI", sourceRoot: URL(fileURLWithPath: "/tmp")).functions["entry"]!
    let calls = node.receiverGenericCalls!
    let marker = symbol + "\t" + SDKReceiverContracts.unreachableNil
    #expect(calls.contains(marker) == ["nil", "mixed"].contains(kind))
    #expect(calls.contains(symbol + "\tAny") == (kind != "nil"))
    #expect(calls.allSatisfy { SDKReceiverContracts.allows(String($0.dropFirst(symbol.count + 1)), for: symbol) } == (kind == "nil"))
}
