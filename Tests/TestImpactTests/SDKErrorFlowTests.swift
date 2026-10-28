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

@Test(arguments: ["valid", "missingCaller", "missingInput", "throw", "opaque", "indirect"])
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
    var current = XcodeTestGraph(targets: [], tests: ["UI/Suite/test()"])
    current.sources["UI:Tests.swift"] = .parse("import XCTest\nfunc entry() {}\nfunc input() {}", path: "Tests.swift", module: "UI")
    current.dependencies = .init(functions: [caller.id: caller, input.id: input], tests: [current.tests[0]: [caller.id]])
    for data in [try GraphArchive.encode(current), try JSONEncoder().encode(current)] {
        let restored = try GraphArchive.decode(data)
        var proof = SDKReceiverOrigins()
        let blocker = proof.blocker(tests: Set(restored.tests), current: restored, graph: restored.dependencies!)
        #expect((blocker == nil) == (kind == "valid"), "\(blocker ?? "no blocker")")
        if kind.hasPrefix("missing") { #expect(blocker?.contains("sealed SIL") == true) }
    }
}
