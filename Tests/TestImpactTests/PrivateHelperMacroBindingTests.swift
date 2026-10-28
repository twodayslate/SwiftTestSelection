// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation
import Testing
@testable import TestImpact

/// A native compiler plugin implementing the length-prefixed JSON protocol.
/// Fixed expansions keep this regression independent of a second SwiftSyntax
/// build, and run inside the compiler's normal plugin sandbox.
private func macroPlugin(expansion: String, root: URL) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .withoutEscapingSlashes
    func literal(_ response: [String: Any]) throws -> String {
        let json = String(decoding: try JSONSerialization.data(withJSONObject: response, options: .sortedKeys), as: UTF8.self)
        return String(decoding: try encoder.encode(json), as: UTF8.self)
    }
    let capability = try literal(["getCapabilityResult": ["capability": ["protocolVersion": 7]]])
    let freestanding = try literal(["expandFreestandingMacroResult": ["expandedSource": expansion, "diagnostics": []]])
    let attached = try literal(["expandAttachedMacroResult": ["expandedSources": [expansion], "diagnostics": []]])
    let source = """
    #include <stdint.h>
    #include <stdio.h>
    #include <stdlib.h>
    #include <string.h>
    int main(void) {
        uint64_t length;
        while (fread(&length, sizeof(length), 1, stdin) == 1) {
            if (length > 16 * 1024 * 1024) return 1;
            char *request = calloc(length + 1, 1);
            if (!request || fread(request, 1, length, stdin) != length) return 2;
            const char *response;
            if (strstr(request, "\\\"getCapability\\\"")) response = \(capability);
            else if (strstr(request, "\\\"expandFreestandingMacro\\\"")) response = \(freestanding);
            else if (strstr(request, "\\\"expandAttachedMacro\\\"")) response = \(attached);
            else return 3;
            free(request);
            length = strlen(response);
            fwrite(&length, sizeof(length), 1, stdout);
            fwrite(response, 1, length, stdout);
            fflush(stdout);
        }
        return 0;
    }
    """
    let path = root.appendingPathComponent("plugin.c")
    let executable = root.appendingPathComponent("ReviewMacros")
    try Data(source.utf8).write(to: path)
    _ = try CommandRunner.run("xcrun", ["clang", path.path, "-o", executable.path], at: root)
    return executable.path + "#ReviewMacros"
}

@Test(arguments: ["operator", "global", "peer", "member"])
func compiledPrivateHelperMacrosRequireCompleteInventories(scenario: String) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("helper-macro-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let isOperator = scenario == "operator" || scenario == "peer"
    let expansion = isOperator ? """
    func ..< (lhs: Int, rhs: Int) -> Range<Int> {
        UserDefaults.standard.set(true, forKey: "shared")
        return .init(uncheckedBounds: (lhs, rhs))
    }
    """ : scenario == "member" ? """
    mutating func appendInterpolation(_ value: String) {
        UserDefaults.standard.set(true, forKey: "shared")
        appendLiteral(value)
    }
    """ : """
    func max(_ lhs: Int, _ rhs: Int) -> Int {
        UserDefaults.standard.set(true, forKey: "shared")
        return lhs
    }
    """
    let plugin = try macroPlugin(expansion: expansion, root: root)
    let body = isOperator ? "for _ in 0..<2 { let value = 1; XCTAssertTrue(true) }"
        : scenario == "member" ? #"let value = "value"; let message = "prefix \(value)"; XCTAssertTrue(true, message)"#
        : "let value = max(0, 1); XCTAssertTrue(true)"
    let before = """
    import XCTest
    func evaluate(_ body: () -> Void) { body() }
    @MainActor final class Suite: XCTestCase {
        func testConsumer() { candidate() }
        private func candidate() {
            \(body)
        }
    }
    @MainActor final class Other: XCTestCase {
        func testReader() { evaluate { XCTAssertFalse(UserDefaults.standard.bool(forKey: "shared")) } }
    }
    """
    let after = before.replacingOccurrences(of: "private func candidate() {", with: "private func candidate() { XCTAssertTrue(true)")
    let extra = """
    import XCTest
    @\(scenario == "peer" ? "attached(peer" : scenario == "member" ? "attached(member" : "freestanding(declaration"), names: named(\(isOperator ? "..<" : scenario == "member" ? "appendInterpolation" : "max")))
    macro makeBindings() = #externalMacro(module: "ReviewMacros", type: "MakeBindings")
    \(scenario == "peer" ? "@makeBindings struct Anchor {}" : scenario == "member" ? "@makeBindings extension DefaultStringInterpolation {}" : "#makeBindings()")
    """
    let tests = ["UI/Suite/testConsumer()", "UI/Other/testReader()"]
    let old = try boundaryGraph(["UI.swift": before, "Extra.swift": extra], tests: tests, root: root,
        compilerArguments: ["-load-plugin-executable", plugin])
    let current = try boundaryGraph(["UI.swift": after], tests: tests, root: root)
    let graph = try #require(old.dependencies)
    let generated = Set(graph.functions.filter { $0.value.module == "UI" && $0.value.name.contains(isOperator ? "..<" : scenario == "member" ? "appendInterpolation(" : "max(") }.keys)
    try #require(!generated.isEmpty)
    try #require(DependencyIndex(graph).paths(to: generated).path(from: graph.tests[tests[0]] ?? []) != nil)
    #expect(old.sources["UI:Extra.swift"]?.helperDeclarationsComplete == false)
    #expect(old.sources["UI:Extra.swift"]?.helperOperatorDeclarations == nil)
    let archivedOld = try GraphArchive.decode(GraphArchive.encode(old))
    #expect(archivedOld.sources["UI:Extra.swift"]?.helperDeclarationsComplete == false)
    let roundTripped = try GraphArchive.decode(GraphArchive.encode(current))
    for unowned in [false, true] {
        var source = XcodeHeadOnlySources(base: archivedOld.sources, mappings: current.mappings)
        if unowned { source.unownedBaseSources["Extra.swift"] = source.base.removeValue(forKey: "UI:Extra.swift") }
        let report = XcodeHeadOnlySelector.select(current: roundTripped, source: source,
            changes: [.init(path: "UI.swift")], baseRevision: "base")
        #expect(report.selectedTests == tests.sorted(), "\(report.diagnostics)")
        #expect(report.diagnostics.contains { $0.code == "head_only_helper_callee_effects" && $0.message.contains("macros") })
    }
    let cleanBase = ["UI:UI.swift": SwiftSourceSnapshot.parse(before, path: "UI.swift", module: "UI")]
    let clean = XcodeHeadOnlySelector.select(current: current, source: .init(base: cleanBase, mappings: current.mappings),
        changes: [.init(path: "UI.swift")], baseRevision: "base")
    #expect(clean.selectedTests == [tests[0]], "\(clean.diagnostics)")
    #expect(clean.diagnostics.isEmpty)
    // Legacy completeness metadata must fail even if the other inventories
    // and operator-use proof are present. Cover both saved revisions.
    for head in [false, true] {
        var broken = roundTripped, base = cleanBase
        if head { broken.sources["UI:UI.swift"]!.helperDeclarationsComplete = nil }
        else { base["UI:UI.swift"]!.helperDeclarationsComplete = nil }
        let report = XcodeHeadOnlySelector.select(current: broken, source: .init(base: base, mappings: current.mappings),
            changes: [.init(path: "UI.swift")], baseRevision: "base")
        #expect(report.selectedTests == tests.sorted())
        #expect(report.diagnostics.contains { $0.message.contains("declaration inventories") })
    }
    // Head-only and unchanged macro expansions also cannot grant isolation.
    let expanded = try boundaryGraph(["UI.swift": after, "Extra.swift": extra], tests: tests, root: root,
        compilerArguments: ["-load-plugin-executable", plugin])
    for base in [cleanBase, old.sources] {
        let report = XcodeHeadOnlySelector.select(current: expanded, source: .init(base: base, mappings: current.mappings),
            changes: [.init(path: "UI.swift")], baseRevision: "base")
        #expect(report.selectedTests == tests.sorted())
    }
}

@Test func privateHelperMacroInventoryChecksAllSyntax() throws {
    let opaque = [
        "#makeBindings()",
        "let value = #makeValue()",
        "#if CUSTOM\n#makeBindings()\n#endif",
        "@MakeMembers struct Holder {}",
        "struct Holder { @MakePeer func method() {} }",
        "@MakeExtension struct Holder {}",
        "@MakeAccessors var value: Int",
        "@Macros.MakeMembers extension String {}",
        "@MainActor @MakeMembers final class Holder {}",
        "import CustomMacros\n@MainActor struct Holder {}",
        "@freestanding(declaration) macro unused() = #externalMacro(module: \"Macros\", type: \"Unused\")",
        "@attached(peer) macro MainActor() = #externalMacro(module: \"Macros\", type: \"Peer\")"
    ]
    for text in opaque {
        let source = SwiftSourceSnapshot.parse(text, path: "Extra.swift", module: "UI")
        #expect(source.helperDeclarationsComplete == false, "\(text)")
        #expect(source.helperOperatorDeclarations == nil, "\(text)")
    }
    let source = SwiftSourceSnapshot.parse("""
    import XCTest
    @available(macOS 13, *) @MainActor final class Suite: XCTestCase {
        func check(file: StaticString = #filePath, line: UInt = #line) {
            let values = (#file, #fileID, #filePath, #line, #column, #function, #dsohandle)
        }
    }
    """, path: "UI.swift", module: "UI")
    #expect(source.helperDeclarationsComplete == true)
    #expect(source.helperOperatorDeclarations == [])
    let restored = try JSONDecoder().decode(SwiftSourceSnapshot.self, from: JSONEncoder().encode(source))
    #expect(restored.helperDeclarationsComplete == true)
}
