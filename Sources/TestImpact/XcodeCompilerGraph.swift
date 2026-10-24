// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

enum XcodeCompilerGraph {
    static func extract(log: String, sourceRoot: URL, directory: URL, derived: URL,
                        progress: (String) -> Void, ownership: [String: Set<String>] = [:]) -> DependencyGraph {
        var graph = DependencyGraph()
        var seen: [String: [String]] = [:]
        var definingSymbols = Set<String>()
        var dispatch: [String: Set<String>] = [:]
        for line in log.components(separatedBy: .newlines) {
            guard let marker = line.range(of: "builtin-SwiftDriver -- ") else { continue }
            do {
                let invocation = try XcodeSourceFileList.parse(String(line[marker.upperBound...]))
                guard let compiler = invocation.first,
                      let index = invocation.firstIndex(of: "-module-name"), index + 1 < invocation.count else {
                    throw ImpactError("Unrecognized SwiftDriver invocation")
                }
                let module = invocation[index + 1]
                if let earlier = seen[module] {
                    if earlier != invocation {
                        graph.diagnostics.append("Multiple distinct compiler invocations for module \(module); architecture/target ambiguity requires a full selection.")
                    }
                    continue
                }
                seen[module] = invocation
                progress("Extracting Xcode SIL dependencies: \(module)…")
                let output = derived.appendingPathComponent("impact-\(UUID().uuidString).sil")
                let args = arguments(Array(invocation.dropFirst())) + ["-emit-sil", "-whole-module-optimization", "-Onone", "-g", "-o", output.path]
                _ = try CommandRunner.run(compiler, args, at: directory)
                let parsed = SILParser.parse(try String(contentsOf: output, encoding: .utf8), module: module, sourceRoot: sourceRoot)
                if parsed.functions.isEmpty { throw ImpactError("No SIL functions for \(module)") }
                for (symbol, node) in parsed.functions {
                    let isDefinition = node.regions.contains { ownership[module]?.contains($0.path) == true }
                    if isDefinition || !definingSymbols.contains(symbol) && (graph.functions[symbol] == nil || !node.regions.isEmpty && graph.functions[symbol]!.regions.isEmpty) {
                        graph.functions[symbol] = node
                    }
                    if isDefinition { definingSymbols.insert(symbol) }
                }
                for (declaration, symbols) in parsed.dispatchTargets { dispatch[declaration, default: []].formUnion(symbols) }
            } catch {
                graph.diagnostics.append("Compiler dependency extraction failed: \(error)")
            }
        }
        if seen.isEmpty { graph.diagnostics.append("No supported SwiftDriver invocations found in Xcode build output.") }
        for symbol in graph.functions.keys {
            for declaration in graph.functions[symbol]!.dynamicDeclarations {
                graph.functions[symbol]!.dependencies.formUnion(dispatch[declaration] ?? [])
                if dispatch[declaration]?.isEmpty == false { graph.functions[symbol]!.resolvedDynamicDeclarations.insert(declaration) }
            }
        }
        return graph
    }

    static func arguments(_ arguments: [String]) -> [String] {
        let remove: Set<String> = ["-use-frontend-parseable-output", "-save-temps", "-emit-dependencies", "-emit-const-values", "-experimental-emit-module-separately", "-explicit-module-build", "-O", "-Osize", "-Ounchecked", "-Onone", "-whole-module-optimization"]
        return PackageAnalyzer.silArguments(arguments).filter { !remove.contains($0) }
    }

    static func bind(tests: [String], modules: [String: String], sources: [String: SwiftSourceSnapshot], graph: inout DependencyGraph) {
        let inheritance = sources.values.reduce(into: [String: [String]]()) { result, file in
            result.merge(file.inheritance) { Array(Set($0 + $1)) }
        }
        let projectTypes = Set(sources.values.flatMap { $0.units.filter { $0.kind == "type" }.map(\.scope) })
        for symbol in graph.functions.keys {
            for declaration in graph.functions[symbol]!.dynamicDeclarations {
                let type = declaration.components(separatedBy: ".").first ?? declaration
                if projectTypes.contains(type), !graph.functions[symbol]!.resolvedDynamicDeclarations.contains(declaration) {
                    // Objective-C entry points (including XCTest initializers)
                    // may have no Swift vtable slot. Include all matching
                    // compiled implementations rather than dropping the edge.
                    let candidates = graph.functions.values.filter { node in
                        !node.regions.isEmpty && (node.name.hasPrefix(declaration + "(") || node.name.hasPrefix(declaration + "."))
                    }.map(\.id)
                    if !candidates.isEmpty {
                        graph.functions[symbol]!.dependencies.formUnion(candidates)
                        graph.functions[symbol]!.resolvedDynamicDeclarations.insert(declaration)
                        continue
                    }
                    graph.functions[symbol]!.uncertainties.insert("Unresolved project dispatch: " + declaration)
                }
            }
        }
        for test in tests {
            let parts = test.split(separator: "/").map(String.init)
            if parts.count == 2, let module = modules[parts[0]], parts[1].hasSuffix(")") {
                graph.tests[test] = Set(graph.functions.values.filter { $0.module == module && $0.name == parts[1] && !$0.regions.isEmpty }.map(\.id))
                continue
            }
            guard parts.count == 3, let module = modules[parts[0]] else {
                graph.tests[test] = []
                continue
            }
            var classes: [String: Set<String>] = [module: [parts[1]]]
            var visited = Set<String>()
            var queue = [module + "." + parts[1]]
            while let key = queue.popLast() {
                guard visited.insert(key).inserted else { continue }
                let definingModule = String(key.prefix { $0 != "." })
                for parent in inheritance[key] ?? [] {
                    if ["XCTestCase", "XCTest.XCTestCase", "NSObject", "Foundation.NSObject"].contains(parent) { continue }
                    let local = definingModule + "." + parent
                    let candidates = inheritance[local] != nil ? [local] : inheritance.keys.filter { $0 == parent || $0.hasSuffix("." + parent) }
                    if candidates.isEmpty {
                        graph.testDiagnostics[test, default: []].append("Cannot resolve inherited lifecycle/fixture type: " + parent)
                    }
                    for candidate in candidates {
                        let parentModule = String(candidate.prefix { $0 != "." })
                        let parentClass = String(candidate.dropFirst(parentModule.count + 1))
                        classes[parentModule, default: []].insert(parentClass)
                        queue.append(candidate)
                    }
                }
            }
            let method = parts[2].contains("(") ? parts[2] : parts[2] + "()"
            let entries = graph.functions.values.filter { node in
                !node.regions.isEmpty && (classes[node.module] ?? []).contains { node.name == $0 + "." + method }
            }
            graph.tests[test] = Set(entries.map(\.id))
            // Hooks and initializers are roots of this class and its ancestors,
            // not of every test in the module. Ordinary inherited helpers are
            // reached through SIL references and dispatch tables.
            if !entries.isEmpty {
                let hooks = graph.functions.values.filter { node in
                    guard !node.regions.isEmpty else { return false }
                    return (classes[node.module] ?? []).contains { cls in
                        ["setUp(", "setUpWithError(", "tearDown(", "tearDownWithError(", "init(", "__allocating_init(", "deinit", "__deallocating_deinit"].contains {
                            node.name == cls + "." + $0 || node.name.hasPrefix(cls + "." + $0) || node.name.hasPrefix("static " + cls + "." + $0)
                        } || node.name.hasPrefix("variable initialization expression of " + cls + ".")
                    }
                }
                graph.tests[test]!.formUnion(hooks.map(\.id))
            }
        }
    }
}
