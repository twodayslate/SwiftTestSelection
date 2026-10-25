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
        struct Node {
            var depth: Int
            var value: String

            var module: String? {
                guard value.hasPrefix("kind=Module, text=") else { return nil }
                let quoted = String(value.dropFirst("kind=Module, text=".count))
                guard let data = quoted.data(using: .utf8),
                      let owner = try? JSONDecoder().decode(String.self, from: data), !owner.isEmpty else { return nil }
                return owner
            }
        }
        func owner(_ nodes: [Node]) -> String? {
            guard nodes.first?.value == "kind=Global" else { return nil }
            var index = 0, depth = 0
            while index < nodes.count {
                let node = nodes[index]
                guard node.depth == depth else { return nil }
                // Dynamic dispatch is an attribute preceding the declaration.
                if depth == 1 && node.value == "kind=DynamicAttribute" { index += 1; continue }
                if let module = node.module { return module }
                if node.value == "kind=ProtocolWitness" {
                    index += 1
                    guard index < nodes.count, nodes[index].depth == depth + 1,
                          nodes[index].value == "kind=ProtocolConformance" else { return nil }
                    // The conformance's direct Module child owns the witness.
                    // Its type and protocol children can refer to other modules,
                    // particularly for retroactive conformances.
                    let conformanceDepth = nodes[index].depth
                    var modules: [Node] = []
                    for child in nodes.dropFirst(index + 1) {
                        if child.depth <= conformanceDepth { break }
                        if child.depth == conformanceDepth + 1 && child.value.hasPrefix("kind=Module") {
                            modules.append(child)
                        }
                    }
                    return modules.count == 1 ? modules[0].module : nil
                }
                // Follow only the declaration's first-child context. A module
                // found in parameter/result types is not its defining module.
                guard contexts.contains(String(node.value.dropFirst("kind=".count))) else { return nil }
                index += 1; depth += 1
            }
            return nil
        }
        var owners: [String: String] = [:]
        var symbol: String?, nodes: [Node] = []
        func finish() {
            if let symbol, let module = owner(nodes) { owners[symbol] = module }
        }
        for line in output.components(separatedBy: .newlines) {
            if line.hasPrefix("Demangling for ") {
                finish()
                symbol = String(line.dropFirst("Demangling for ".count))
                nodes.removeAll(keepingCapacity: true)
                continue
            }
            guard symbol != nil, !line.isEmpty else { continue }
            let indent = line.prefix { $0 == " " }.count
            let value = String(line.dropFirst(indent))
            guard indent.isMultiple(of: 2), value.hasPrefix("kind=") else { symbol = nil; continue }
            nodes.append(Node(depth: indent / 2, value: value))
        }
        finish()
        return owners
    }
}
