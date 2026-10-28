// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation
import Testing
@testable import TestImpact

private let identifierCall = "objc_method XCUIElementQuery.matching!foreign : (XCUIElementQuery) -> (String) -> XCUIElementQuery"
private let predicateCall = "objc_method XCUIElementQuery.matching!foreign : (XCUIElementQuery) -> (NSPredicate) -> XCUIElementQuery"

@Test(arguments: ["valid", "literalLocation", "crossed", "missing", "unknown", "partial", "value", "sourceLocation", "legacySource", "legacyProvenance", "otherFileRemap", "otherFileLegacy"])
func receiverCallSitePairsEveryOverload(kind: String) throws {
    var text = "import XCTest\nfunc caller() { query.matching(identifier: \"α\"); query.matching(NSPredicate(value: true)) }"
    if kind == "value" { text = text.replacingOccurrences(of: "query.matching(NSPredicate(value: true))", with: "query.matching(identifier:)") }
    if kind == "literalLocation" { text += "\nlet label = \"#sourceLocation\"\n" }
    if kind == "sourceLocation" { text += "\n#sourceLocation(file: \"Other.swift\", line: 1)\n" }
    var snapshot = SwiftSourceSnapshot.parse(text, path: "Tests.swift", module: "UI")
    let owner = try #require(snapshot.units.first { $0.kind == "function" })
    let positions = owner.receiverCallSites?.keys.sorted { Int($0.split(separator: "\t").last!)! < Int($1.split(separator: "\t").last!)! } ?? []
    var node = FunctionNode(id: "caller", module: "UI", name: "caller", regions: [owner.region])
    node.compilerReferences = []; node.receiverTypeOrigins = []; node.receiverGenericCalls = []
    node.dynamicDeclarations = ["XCUIElementQuery.matching"]
    node.dynamicCallSignatures = [identifierCall, predicateCall]
    if positions.count == 2 {
        node.dynamicCallSites = [identifierCall + "\t" + positions[kind == "crossed" ? 1 : 0], predicateCall + "\t" + positions[kind == "crossed" ? 0 : 1]]
    }
    if kind == "missing" { node.dynamicCallSites = nil }
    if kind == "partial" { node.dynamicCallSites = [identifierCall + "\t" + positions[0]] }
    if kind == "unknown" { node.dynamicCallSites!.insert(identifierCall + "\t<unknown>") }
    if kind == "legacySource" { for i in snapshot.units.indices { snapshot.units[i].receiverCallSites = nil } }
    var current = XcodeTestGraph(targets: [], tests: ["UI/Suite/test()"])
    if kind == "legacyProvenance" { snapshot.receiverPhysicalLocations = nil }
    current.sources = ["UI:Tests.swift": snapshot]
    if kind == "otherFileRemap" || kind == "otherFileLegacy" {
        var other = SwiftSourceSnapshot.parse("#sourceLocation(file: \"Tests.swift\", line: 2)\nfunc hidden() {}", path: "Other.swift", module: "UI")
        if kind == "otherFileLegacy" { other.receiverPhysicalLocations = nil }
        current.sources["UI:Other.swift"] = other
    }
    current.dependencies = .init(functions: [node.id: node], tests: [current.tests[0]: [node.id]])
    for data in [try GraphArchive.encode(current), try JSONEncoder().encode(current)] {
        let restored = try GraphArchive.decode(data)
        var proof = SDKReceiverOrigins()
        let blocker = proof.blocker(tests: Set(current.tests), current: restored, graph: restored.dependencies!)
        #expect((blocker == nil) == ["valid", "literalLocation"].contains(kind), "\(blocker ?? "no blocker")")
        #expect(restored.dependencies!.functions[node.id]?.dynamicCallSites == node.dynamicCallSites)
        #expect(restored.sources["UI:Tests.swift"]?.receiverPhysicalLocations == snapshot.receiverPhysicalLocations)
    }
}

@Test(arguments: [false, true])
func dynamicCallSitesRetainUnknownLocationsAndMerge(unknown: Bool) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let files = [root.appendingPathComponent("a.sil"), root.appendingPathComponent("b.sil")]
    for (index, file) in files.enumerated() {
        let loc = unknown && index == 1 ? "" : ", loc \"\(root.path)/Tests.swift\":2:\(index + 10)"
        let sil = """
        sil @caller : $@convention(thin) () -> () {
          %method = objc_method %query, #XCUIElementQuery.matching!foreign : (XCUIElementQuery) -> (String) -> XCUIElementQuery, $Function\(loc)
          return %nothing : $()
        } // end sil function 'caller'
        """
        try Data(sil.utf8).write(to: file)
    }
    let capture = CapturedSIL(modules: ["UI": files], fingerprints: [:], diagnostics: [])
    let node = try #require(capture.parse(module: "UI", sourceRoot: root)?.functions["caller"])
    #expect(node.dynamicCallSites == [identifierCall + "\tTests.swift\t2\t10", identifierCall + (unknown ? "\t<unknown>" : "\tTests.swift\t2\t11")])
}

@Test(arguments: [false, true], [false, true])
func dynamicCallSiteArchivesPreservePrecedingMissingEvidence(generics: Bool, sites: Bool) throws {
    var node = FunctionNode(id: "caller", module: "UI", name: "caller")
    node.receiverGenericCalls = generics ? [] : nil
    node.dynamicCallSites = sites ? [identifierCall + "\tTests.swift\t2\t10"] : nil
    var current = XcodeTestGraph(targets: [], tests: [])
    current.dependencies = .init(functions: [node.id: node])
    let restored = try #require(GraphArchive.decode(GraphArchive.encode(current)).dependencies?.functions[node.id])
    #expect(restored.receiverGenericCalls == node.receiverGenericCalls)
    #expect(restored.dynamicCallSites == node.dynamicCallSites)
    #expect(restored.receiverTypeOrigins == nil)
    #expect(restored.dynamicCallSignatures == nil)
}

@Test(arguments: ["import UncapturedLibrary", "import struct UncapturedLibrary.Optional", "@_exported import UncapturedLibrary"])
func receiverOriginDiagnosticsIdentifyUnsupportedImports(imported: String) throws {
    let source = SwiftSourceSnapshot.parse("import XCTest\n\(imported)\nfunc entry() {}", path: "Tests.swift", module: "UI")
    var node = FunctionNode(id: "entry", module: "UI", name: "entry", regions: [.init(path: "Tests.swift", startLine: 3, endLine: 3)])
    node.receiverTypeOrigins = ["enum:Optional.some"]; node.receiverGenericCalls = []
    node.compilerReferences = []; node.dynamicCallSignatures = []
    var current = XcodeTestGraph(targets: [], tests: ["UI/Suite/test()"])
    current.sources = ["UI:Tests.swift": source]
    current.dependencies = .init(functions: [node.id: node], tests: [current.tests[0]: [node.id]])
    current = try GraphArchive.decode(GraphArchive.encode(current))
    var proof = SDKReceiverOrigins()
    let result = proof.blocker(tests: Set(current.tests), current: current, graph: current.dependencies!)
    let blocker = try #require(result)
    #expect(blocker.contains(imported))
    #expect(blocker.contains("unsupported source imports"))
}
