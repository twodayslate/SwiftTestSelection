// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// Client-emitted bodies use `shared` in both the defining and importing module.
/// Resolve their declaration context, including extensions, with the compiler's
/// demangler rather than guessing an owner from a mangled prefix or source path.
enum SILOwnership {
    static func resolve(_ input: SILModule, module: String, compiler: String, directory: URL) throws -> SILModule {
        let symbols = (input.sharedSymbols ?? []).filter { input.functions[$0]?.regions.isEmpty == false }.sorted()
        var result = input
        result.sharedSymbols = nil
        guard !symbols.isEmpty else { return result }
        let demangler = compiler.hasPrefix("/")
            ? URL(fileURLWithPath: compiler).deletingLastPathComponent().appendingPathComponent("swift-demangle").path
            : "swift-demangle"
        let output = try CommandRunner.run(demangler, ["--expand", "--tree-only"], at: directory,
            input: Data((symbols.joined(separator: "\n") + "\n").utf8)).text
        let owners = declarationOwners(output)
        for symbol in symbols {
            guard let owner = owners[symbol] else {
                throw ImpactError("Cannot resolve defining module for client-emitted SIL symbol \(symbol)")
            }
            if result.importedSymbols == nil { result.importedSymbols = [] }
            if owner != module { result.importedSymbols!.insert(symbol) }
        }
        // Resolved provenance is already in importedSymbols. Cache hits need no
        // demangler process; raw parser fragments retain the pending inventory.
        return result
    }

    static func declarationOwners(_ output: String) -> [String: String] {
        let contexts: Set<String> = ["Global", "Static", "Function", "Variable", "Subscript",
            "Getter", "Setter", "ReadAccessor", "ModifyAccessor", "Allocator", "Constructor",
            "Destructor", "Deallocator", "DefaultArgumentInitializer", "ExplicitClosure", "ImplicitClosure", "Structure", "Class", "Enum", "Protocol", "Extension"]
        var owners: [String: String] = [:]
        var symbol: String?, depth = 0
        for line in output.components(separatedBy: .newlines) {
            if line.hasPrefix("Demangling for ") {
                symbol = String(line.dropFirst("Demangling for ".count)); depth = 0
                continue
            }
            guard let current = symbol else { continue }
            let indent = line.prefix { $0 == " " }.count
            let node = String(line.dropFirst(indent))
            guard indent == depth * 2, node.hasPrefix("kind="),
                  depth != 0 || node == "kind=Global" else { symbol = nil; continue }
            if node.hasPrefix("kind=Module, text=") {
                // The demangler prints quoted strings; reject unknown encodings.
                let quoted = String(node.dropFirst("kind=Module, text=".count))
                if let data = quoted.data(using: .utf8), let owner = try? JSONDecoder().decode(String.self, from: data), !owner.isEmpty {
                    owners[current] = owner
                }
                symbol = nil
            } else if contexts.contains(String(node.dropFirst("kind=".count))) {
                // Follow only the declaration's first-child context. A module
                // found in parameter/result types is not its defining module.
                depth += 1
            } else { symbol = nil }
        }
        return owners
    }
}
