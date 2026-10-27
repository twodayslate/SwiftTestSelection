// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation
import SwiftParser
import SwiftSyntax
import Testing
@testable import TestImpact

@Test(arguments: [40, 100, 200])
func localHelperReferenceAnalysisHasBoundedWork(depth: Int) {
    let functions = (0..<depth).map { i in
        "func local\(i)() -> Bool { \(i == 0 ? "query()" : "local\(i-1)()") }"
    }.joined(separator: "\n")
    let source = "import XCTest\nfunc outer() {\n\(functions)\nXCTAssertTrue(local\(depth-1)())\n}"
    let start = Date()
    let snapshot = SwiftSourceSnapshot.parse(source, path: "Calls.swift", module: "UI")
    print("Local helper source parse:", depth, "functions,", source.utf8.count, "bytes,", Date().timeIntervalSince(start), "seconds")
    #expect(snapshot.diagnostics.isEmpty)
    #expect(snapshot.helperReferences?["query"]?.unsupported == false)
    #expect(snapshot.helperReferences?["query"]?.callers == [2])

    // Deterministic work bounds catch repeated subtree analysis without a
    // machine-dependent time limit. Exercise both name and signature lookups.
    let tree = Parser.parse(source: source)
    let identifiers = Dictionary(grouping: tree.tokens(viewMode: .sourceAccurate).filter { $0.identifier != nil }, by: { $0.identifier!.name })
    let analysis = SDKHelperReferenceAnalysis(identifiers: identifiers, locations: .init(fileName: "Calls.swift", tree: tree), callerImportsSupported: true)
    for tokens in identifiers.values {
        _ = analysis.references(tokens)
        for signature in Set(tokens.compactMap(SDKTestHelperSyntax.referenceKey)) { _ = analysis.references(tokens, matching: signature) }
    }
    #expect(analysis.localFunctionEvaluationCount == depth)
    #expect(analysis.classifiedTokenCount <= identifiers.values.reduce(0) { $0 + $1.count })
}

@Test(arguments: ["chain", "cycle", "diamond", "nested", "escaped", "shadowed", "attributed", "untrusted"])
func localHelperReferencesPreserveEscapeAndScopeChecks(scenario: String) {
    var body: String
    switch scenario {
    case "nested": body = "func a() -> Bool { func b() -> Bool { query() }; return b() }; XCTAssertTrue(a())"
    case "shadowed": body = "func a() -> Bool { query() }; if true { func a() -> Bool { false }; XCTAssertTrue(a()) }; XCTAssertTrue(a())"
    case "diamond": body = "func a() -> Bool { query() }; func b() -> Bool { a() }; func c() -> Bool { a() }; func d() -> Bool { if b() { return c() }; return false }; XCTAssertTrue(d())"
    default:
        body = "func a() -> Bool { query() }; func b() -> Bool { a() }; XCTAssertTrue(b())"
    }
    if scenario == "cycle" { body = body.replacingOccurrences(of: "{ query() }", with: "{ query(); return b() }") }
    if scenario == "escaped" { body += "; let callback = b" }
    if scenario == "attributed" { body = body.replacingOccurrences(of: "func a()", with: "@MainActor func a()") }
    let source = "import XCTest\n" + (scenario == "untrusted" ? "import External\n" : "") + "func outer() { \(body) }"
    let snapshot = SwiftSourceSnapshot.parse(source, path: "Calls.swift", module: "UI")
    #expect(snapshot.diagnostics.isEmpty)
    let supported = ["chain", "diamond", "nested"].contains(scenario)
    #expect(snapshot.helperReferences?["query"]?.unsupported == !supported)
    if supported { #expect(snapshot.helperReferences?["query"]?.callers == [2]) }
    if scenario == "untrusted" { #expect(snapshot.helperReferences?["query"]?.untrustedWrapperImports == true) }
}
