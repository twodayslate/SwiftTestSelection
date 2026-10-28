// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

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
        let owners = ownerships(output)
        let unresolved = symbols.filter { owners[$0] == nil }
        guard unresolved.isEmpty else {
            let examples = unresolved.prefix(16).joined(separator: ", ")
            let remaining = unresolved.count > 16 ? " (and \(unresolved.count - 16) more)" : ""
            throw ImpactError("Cannot resolve defining module for client-emitted SIL symbol \(examples)\(remaining)")
        }
        var adapters: [String: String] = [:]
        for symbol in symbols {
            let owner = owners[symbol]!
            if result.importedSymbols == nil { result.importedSymbols = [] }
            switch owner {
            case .declaration(let owner):
                if owner != module { result.importedSymbols!.insert(symbol) }
            case .adapter:
                // These type-only symbols have no lexical declaration owner. Keep
                // each emitter's body/edges separate, including runtime uncertainty.
                // Their debug locations identify a conversion site, not a shared
                // source declaration that every user of the adapter depends on.
                adapters[symbol] = symbol + "@emitted:" + module
            }
        }
        if !adapters.isEmpty {
            let adapterSymbols = Set(adapters.keys)
            func renamed(_ symbols: Set<String>) -> Set<String> {
                guard !symbols.isDisjoint(with: adapterSymbols) else { return symbols }
                return Set(symbols.map { adapters[$0] ?? $0 })
            }
            for symbol in Array(result.functions.keys) {
                var node = result.functions[symbol]!
                guard adapters[symbol] != nil || !node.dependencies.isDisjoint(with: adapterSymbols)
                    || node.compilerReferences.map({ !$0.isDisjoint(with: adapterSymbols) }) == true else { continue }
                node.dependencies = renamed(node.dependencies)
                node.compilerReferences = node.compilerReferences.map(renamed)
                if let local = adapters[symbol] {
                    result.functions.removeValue(forKey: symbol)
                    node.id = local
                    node.regions = []
                }
                result.functions[node.id] = node
            }
            result.dispatchTargets = result.dispatchTargets.mapValues(renamed)
            result.importedSymbols = result.importedSymbols.map(renamed)
        }
        // Resolved provenance is already in importedSymbols. Cache hits need no
        // demangler process; raw parser fragments retain the pending inventory.
        return result
    }

    private enum Ownership {
        case declaration(String)
        case adapter
    }

    static func declarationOwners(_ output: String) -> [String: String] {
        ownerships(output).compactMapValues {
            if case .declaration(let owner) = $0 { return owner }
            return nil
        }
    }

    private static func ownerships(_ output: String) -> [String: Ownership] {
        let contexts: Set<String> = ["Global", "Static", "Function", "Variable", "Subscript",
            "Getter", "Setter", "ReadAccessor", "ModifyAccessor", "Allocator", "Constructor",
            "Destructor", "Deallocator", "DefaultArgumentInitializer", "ExplicitClosure", "ImplicitClosure", "Structure", "Class", "Enum", "Protocol", "Extension", "TypeAlias"]
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
        func owner(_ nodes: [Node]) -> Ownership? {
            guard nodes.first?.value == "kind=Global" else { return nil }
            // Validate the wrapper's direct children. Never descend through the
            // function signature or actor type looking for a declaration module.
            if nodes.count > 1, nodes[1].depth == 1,
               nodes[1].value == "kind=ReabstractionThunkHelperWithGlobalActor" {
                let children = nodes.enumerated().filter { $0.element.depth == 2 }
                guard nodes.filter({ $0.depth == 1 }).count == 1,
                      children.map({ $0.element.value }) == ["kind=ReabstractionThunkHelper", "kind=Type"] else { return nil }
                let helper = children[0].offset, actor = children[1].offset
                let signatures = nodes[(helper + 1)..<actor].filter { $0.depth == 3 }
                guard signatures.count == 2, signatures.allSatisfy({ $0.value == "kind=Type" }),
                      actor + 1 < nodes.count, nodes[actor + 1].depth == 3 else { return nil }
                return .adapter
            }
            if nodes.count > 1, nodes[1].depth == 1,
               ["kind=KeyPathEqualsThunkHelper", "kind=KeyPathHashThunkHelper"].contains(nodes[1].value) {
                let captures = nodes.enumerated().filter { $0.element.depth == 2 }
                guard nodes.filter({ $0.depth == 1 }).count == 1, !captures.isEmpty,
                      captures.allSatisfy({ $0.element.value == "kind=Type" && $0.offset + 1 < nodes.count
                          && nodes[$0.offset + 1].depth == 3 }) else { return nil }
                return .adapter
            }
            var index = 0, depth = 0
            while index < nodes.count {
                let node = nodes[index]
                guard node.depth == depth else { return nil }
                // These attributes precede, but do not own, the declaration.
                if depth == 1 && ["kind=DynamicAttribute", "kind=ObjCAttribute", "kind=NonObjCAttribute"].contains(node.value) { index += 1; continue }
                if let module = node.module { return .declaration(module) }
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
                    return modules.count == 1 ? modules[0].module.map(Ownership.declaration) : nil
                }
                // Follow only the declaration's first-child context. A module
                // found in parameter/result types is not its defining module.
                guard contexts.contains(String(node.value.dropFirst("kind=".count))) else { return nil }
                index += 1; depth += 1
            }
            return nil
        }
        var owners: [String: Ownership] = [:]
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
