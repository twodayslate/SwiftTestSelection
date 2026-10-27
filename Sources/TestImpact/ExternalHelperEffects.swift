// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation

/// Missing SIL bodies are not evidence of harmless effects. Resolve external
/// declaration owners with the compiler, including extensions of SDK types.
/// Cache decisions for one immutable helper traversal and batch new symbols.
struct ExternalHelperEffects {
    private var trusted: [String: Bool] = [:]

    mutating func allows(_ symbols: Set<String>, resolve: ([String]) -> String? = Self.resolve) -> Bool {
        let missing = symbols.filter { trusted[$0] == nil }.sorted()
        if !missing.isEmpty {
            let output = resolve(missing)
            let allowed = output.map(Self.trustedDeclarations) ?? []
            for symbol in missing { trusted[symbol] = allowed.contains(symbol) }
        }
        return symbols.allSatisfy { trusted[$0] == true }
    }

    private static func resolve(_ symbols: [String]) -> String? {
        try? CommandRunner.run("xcrun", ["swift-demangle", "--expand", "--tree-only"],
            at: FileManager.default.temporaryDirectory,
            input: Data((symbols.joined(separator: "\n") + "\n").utf8)).text
    }

    static func trustedDeclarations(_ output: String) -> Set<String> {
        let owners = SILOwnership.declarationOwners(output)
        let modules = SDKTestHelperSyntax.trustedCallerModules
        // Clang-imported constructor thunks use __C rather than their framework
        // module. Require a known receiver type, not just the shared __C owner.
        let importedTypes: Set<String> = ["XCTAttachment", "XCUIApplication", "XCUIElement", "XCUIElementType", "XCUIScreenshot",
            "XCTestCase", "XCTest", "NSPredicate", "XCTNSPredicateExpectation", "XCTWaiter"]
        var accepted = Set(owners.filter { modules.contains($0.value) }.keys)
        for block in output.components(separatedBy: "Demangling for ").dropFirst() {
            let lines = block.components(separatedBy: .newlines)
            guard let symbol = lines.first, owners[symbol] == "__C",
                  let module = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "kind=Module, text=\"__C\"" }),
                  module + 1 < lines.count else { continue }
            let prefix = lines[module].prefix { $0 == " " }
            let identifier = lines[module + 1]
            guard identifier.hasPrefix(prefix + "kind=Identifier, text="),
                  let data = String(identifier.dropFirst((prefix + "kind=Identifier, text=").count)).data(using: .utf8),
                  let type = try? JSONDecoder().decode(String.self, from: data), importedTypes.contains(type) else { continue }
            accepted.insert(symbol)
        }
        return accepted
    }
}
