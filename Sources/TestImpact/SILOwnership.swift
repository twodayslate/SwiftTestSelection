// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation

/// Client-emitted bodies use `shared` in both the defining and importing module.
/// Resolve their declaration context, including extensions, with the compiler's
/// demangler rather than guessing an owner from a mangled prefix or source path.
enum SILOwnership {
    static func resolve(_ input: SILModule, module: String, compiler: String, directory: URL) throws -> SILModule {
        let shared = Set((input.sharedSymbols ?? []).filter { input.functions[$0]?.regions.isEmpty == false })
        // Parameterless source methods are the supported inline XCTest boundary.
        // Display names omit the nominal owner's module, even for extensions.
        let methods = Set(input.functions.values.filter {
            $0.nominalTypeContext == nil && !$0.regions.isEmpty && $0.name.contains(".") && $0.name.hasSuffix("()")
        }.map(\.id))
        let swiftMethods = methods.filter { $0.hasPrefix("$s") || $0.hasPrefix("$S") || $0.hasPrefix("_T") }
        let symbols = shared.union(swiftMethods).sorted()
        var result = input
        result.sharedSymbols = nil
        // Non-Swift symbols cannot prove a Swift nominal context and do not
        // require a demangler process. Record unsupported evidence explicitly.
        for symbol in methods.subtracting(swiftMethods) { result.functions[symbol]?.nominalTypeContext = "" }
        guard !symbols.isEmpty else { return result }
        let demangler = compiler.hasPrefix("/")
            ? URL(fileURLWithPath: compiler).deletingLastPathComponent().appendingPathComponent("swift-demangle").path
            : "swift-demangle"
        let output = try CommandRunner.run(demangler, ["--expand", "--tree-only"], at: directory,
            input: Data((symbols.joined(separator: "\n") + "\n").utf8)).text
        let owners = ownerships(output)
        let contexts = nominalTypeContexts(output)
        for symbol in methods { result.functions[symbol]?.nominalTypeContext = contexts[symbol] ?? "" }
        let unresolved = shared.filter { owners[$0] == nil }.sorted()
        guard unresolved.isEmpty else {
            let examples = unresolved.prefix(16).joined(separator: ", ")
            let remaining = unresolved.count > 16 ? " (and \(unresolved.count - 16) more)" : ""
            throw ImpactError("Cannot resolve defining module for client-emitted SIL symbol \(examples)\(remaining)")
        }
        var adapters: [String: String] = [:]
        for symbol in shared {
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

    /// Follow the declaration context, not modules mentioned in signatures.
    /// An Extension's first child is its declaring module; its second child
    /// retains the nominal type's original module and must supply this identity.
    static func nominalTypeContexts(_ output: String) -> [String: String] {
        struct Node { var depth: Int; var value: String }
        var result: [String: String] = [:]
        var symbol: String?, nodes: [Node] = []
        func children(_ index: Int) -> [Int] {
            var result: [Int] = []
            for child in (index + 1)..<nodes.count {
                if nodes[child].depth <= nodes[index].depth { break }
                if nodes[child].depth == nodes[index].depth + 1 { result.append(child) }
            }
            return result
        }
        func text(_ index: Int, kind: String) -> String? {
            let prefix = "kind=" + kind + ", text="
            guard nodes[index].value.hasPrefix(prefix), children(index).isEmpty,
                  let name = try? JSONDecoder().decode(String.self, from: Data(nodes[index].value.dropFirst(prefix.count).utf8)),
                  !name.isEmpty, !name.contains(".") else { return nil }
            return name
        }
        func context(_ index: Int) -> String? {
            if let module = text(index, kind: "Module") { return module }
            let parts = children(index)
            if nodes[index].value == "kind=Extension" {
                guard parts.count == 2, text(parts[0], kind: "Module") != nil else { return nil }
                return context(parts[1])
            }
            guard ["kind=Class", "kind=Structure", "kind=Enum", "kind=Protocol"].contains(nodes[index].value),
                  parts.count == 2, let parent = context(parts[0]), let name = text(parts[1], kind: "Identifier") else { return nil }
            return parent + "." + name
        }
        func finish() {
            guard let symbol, nodes.first?.value == "kind=Global", nodes.first?.depth == 0 else { return }
            let declarations = children(0).filter { !["kind=ObjCAttribute", "kind=NonObjCAttribute", "kind=DynamicAttribute"].contains(nodes[$0].value) }
            guard declarations.count == 1, let function = declarations.first, nodes[function].value == "kind=Function",
                  let owner = children(function).first, let name = context(owner), name.contains(".") else { return }
            result[symbol] = name
        }
        for line in output.components(separatedBy: .newlines) {
            if line.hasPrefix("Demangling for ") {
                finish()
                symbol = String(line.dropFirst("Demangling for ".count))
                nodes.removeAll(keepingCapacity: true)
            } else if symbol != nil, !line.isEmpty {
                let indent = line.prefix { $0 == " " }.count
                let value = String(line.dropFirst(indent))
                guard indent.isMultiple(of: 2), value.hasPrefix("kind=") else { symbol = nil; continue }
                nodes.append(Node(depth: indent / 2, value: value))
            }
        }
        finish()
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
