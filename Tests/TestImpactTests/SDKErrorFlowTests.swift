// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation
import Testing
@testable import TestImpact

@Test(arguments: ["plain", "throw", "throw_addr", "callback"])
func receiverErrorCaptureDistinguishesThrowingPaths(kind: String) throws {
    let body = kind == "throw" ? "throw %error : $any Error" : kind == "throw_addr" ? "throw_addr" : "return %nothing : $()"
    let block = kind == "callback" ? "bb0(%callback : $@noescape @callee_guaranteed () -> (Bool, @error any Error)):" : "bb0:"
    let sil = """
    sil @entry : $@convention(thin) () -> () {
    \(block)
      %literal = string_literal utf8 "throw %error @error"
      \(body)
    } // end sil function 'entry'
    """
    let parsed = SILParser.parse(sil, module: "UI", sourceRoot: URL(fileURLWithPath: "/tmp"))
    #expect(parsed.functions["entry"]?.receiverErrorEffects == (kind == "plain" ? [] : [kind.hasPrefix("throw") ? "throw" : "throwing callback parameter"]))
}

@Test(arguments: ["missing", "empty", "throw"])
func receiverErrorEvidencePreservesMissingPrecedingFields(kind: String) throws {
    var node = FunctionNode(id: "entry", module: "UI", name: "entry")
    node.receiverErrorEffects = kind == "missing" ? nil : kind == "empty" ? [] : ["throw"]
    var graph = XcodeTestGraph(targets: [], tests: [])
    graph.dependencies = .init(functions: [node.id: node])
    for data in [try GraphArchive.encode(graph), try JSONEncoder().encode(graph)] {
        let restored = try #require(try GraphArchive.decode(data).dependencies?.functions["entry"])
        #expect(restored.receiverErrorEffects == node.receiverErrorEffects)
        #expect(restored.dynamicCallSites == nil)
        #expect(restored.receiverGenericCalls == nil)
        #expect(restored.compilerReferences == nil)
    }
}

@Test func receiverErrorCaptureUnionsFragments() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let files = [root.appendingPathComponent("a.sil"), root.appendingPathComponent("b.sil")]
    for (index, file) in files.enumerated() {
        try Data("""
        sil @entry : $@convention(thin) () -> () {
        bb0:
          \(index == 0 ? "return %nothing : $()" : "throw %error : $any Error")
        } // end sil function 'entry'
        """.utf8).write(to: file)
    }
    let merged = try #require(try CapturedSIL(modules: ["UI": files], fingerprints: [:], diagnostics: []).parse(module: "UI", sourceRoot: root))
    #expect(merged.functions["entry"]?.receiverErrorEffects == ["throw"])
}

@Test(arguments: ["valid", "missingCaller", "missingInput", "throw", "opaque", "indirect", "nonthrowingInput", "nonthrowingCaller", "mixedIndirect", "throwDespitePredicate"])
func savedReceiverProofRequiresErrorFlowEvidence(kind: String) throws {
    let assertion = "$s6XCTest13XCTAssertTrue__4file4lineySbyKXK_SSyXKs12StaticStringVSutF"
    var caller = FunctionNode(id: "$s2UI5entryyyF", module: "UI", name: "entry", regions: [.init(path: "Tests.swift", startLine: 2, endLine: 2)])
    caller.compilerReferences = [assertion, "$s2UI5inputyyF"]
    caller.receiverTypeOrigins = []; caller.receiverGenericCalls = []; caller.dynamicCallSignatures = []
    caller.receiverErrorEffects = kind == "missingCaller" ? nil : []
    var input = FunctionNode(id: "$s2UI5inputyyF", module: "UI", name: "input", regions: [.init(path: "Tests.swift", startLine: 3, endLine: 3)])
    input.compilerReferences = []; input.receiverTypeOrigins = []; input.receiverGenericCalls = []; input.dynamicCallSignatures = []
    input.receiverErrorEffects = kind == "missingInput" ? nil : kind == "throw" ? ["throw"] : []
    if kind == "opaque" { caller.receiverErrorEffects = ["throwing callback parameter"] }
    if kind == "indirect" { input.uncertainties = ["Indirect function invocation"] }
    if ["nonthrowingInput", "mixedIndirect", "throwDespitePredicate"].contains(kind) {
        input.uncertainties = ["Indirect function invocation"]
        input.receiverIndirectErrorEffects = kind == "mixedIndirect" ? ["unproven"] : []
        if kind == "throwDespitePredicate" { input.receiverErrorEffects = ["throw"] }
    }
    if kind == "nonthrowingCaller" {
        caller.uncertainties = ["Indirect function invocation"]
        caller.receiverIndirectErrorEffects = []
    }
    var current = XcodeTestGraph(targets: [], tests: ["UI/Suite/test()"])
    current.sources["UI:Tests.swift"] = .parse("import XCTest\nfunc entry() {}\nfunc input() {}", path: "Tests.swift", module: "UI")
    current.dependencies = .init(functions: [caller.id: caller, input.id: input], tests: [current.tests[0]: [caller.id]])
    for data in [try GraphArchive.encode(current), try JSONEncoder().encode(current)] {
        let restored = try GraphArchive.decode(data)
        var proof = SDKReceiverOrigins()
        let blocker = proof.blocker(tests: Set(restored.tests), current: restored, graph: restored.dependencies!)
        #expect((blocker == nil) == (["valid", "nonthrowingInput", "nonthrowingCaller"].contains(kind)), "\(blocker ?? "no blocker")")
        if kind == "indirect" { #expect(blocker?.contains("missing indirect-call error evidence") == true) }
        if kind == "mixedIndirect" { #expect(blocker?.contains("unproven") == true) }
        if kind.hasPrefix("missing") { #expect(blocker?.contains("sealed SIL") == true) }
    }
}

@Test(arguments: ["predicate", "indirectResult", "noescape", "throwing", "nothrowAttribute", "coroutine", "unknown", "missingType", "mixed", "misleadingLiteral"])
func receiverIndirectErrorCapture(kind: String) throws {
    let call: String
    switch kind {
    case "indirectResult": call = "%r = apply %callback(%out) : $@callee_guaranteed () -> @out Bool"
    case "noescape": call = "%r = apply %callback() : $@noescape @callee_guaranteed () -> Bool, loc \"/tmp/Tests.swift\":2:3 // id: %r"
    case "nothrowAttribute": call = "%r = apply [nothrow] %callback() : $@callee_guaranteed () -> (Bool, @error any Error)"
    case "missingType": call = "%r = apply %callback()"
    case "throwing": call = "try_apply %callback() : $@callee_guaranteed () -> (Bool, @error any Error), normal bb1, error bb2"
    case "coroutine": call = "%r = begin_apply %callback() : $@callee_guaranteed () -> Bool"
    case "unknown": call = "%r = apply %callback() : $@callee_guaranteed () -> Any"
    case "mixed": call = "%r = apply %callback() : $@callee_guaranteed () -> Bool\n%bad = apply %other() : $@callee_guaranteed () -> Any"
    case "misleadingLiteral": call = #"%text = string_literal utf8 "apply %callback() : $@callee_guaranteed () -> Bool""#
    default: call = "%r = apply %callback() : $@callee_guaranteed () -> Bool"
    }
    let parsed = SILParser.parse("""
    sil @entry : $@convention(thin) () -> () {
    bb0:
      \(call)
      return %nothing : $()
    } // end sil function 'entry'
    """, module: "UI", sourceRoot: URL(fileURLWithPath: "/tmp"))
    let node = try #require(parsed.functions["entry"])
    #expect(node.receiverIndirectErrorEffects?.isEmpty == ["predicate", "indirectResult", "noescape"].contains(kind))
    // This proof must not remove dependency-selection uncertainty.
    #expect(node.uncertainties.contains("Indirect function invocation"))
}

@Test(arguments: ["missing", "empty", "unknown"])
func receiverIndirectErrorEvidenceRoundTrips(kind: String) throws {
    var node = FunctionNode(id: "entry", module: "UI", name: "entry")
    node.receiverIndirectErrorEffects = kind == "missing" ? nil : kind == "empty" ? [] : ["unproven"]
    var graph = XcodeTestGraph(targets: [], tests: [])
    graph.dependencies = .init(functions: [node.id: node])
    for data in [try GraphArchive.encode(graph), try JSONEncoder().encode(graph)] {
        let restored = try #require(try GraphArchive.decode(data).dependencies?.functions["entry"])
        #expect(restored.receiverIndirectErrorEffects == node.receiverIndirectErrorEffects)
        #expect(restored.receiverErrorEffects == nil)
        #expect(restored.dynamicCallSites == nil)
        #expect(restored.compilerReferences == nil)
    }
}

@Test func receiverIndirectErrorCaptureUnionsFragments() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let files = [root.appendingPathComponent("a.sil"), root.appendingPathComponent("b.sil")]
    for (index, file) in files.enumerated() {
        try Data("""
        sil @entry : $@convention(thin) () -> () {
        bb0:
          %r = apply %callback() : $@callee_guaranteed () -> \(index == 0 ? "Bool" : "Any")
          return %nothing : $()
        } // end sil function 'entry'
        """.utf8).write(to: file)
    }
    let merged = try #require(try CapturedSIL(modules: ["UI": files], fingerprints: [:], diagnostics: []).parse(module: "UI", sourceRoot: root))
    #expect(merged.functions["entry"]?.receiverIndirectErrorEffects?.count == 1)
}
