// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
import Foundation

/// Swift Testing executes argument producers and traits through generated
/// discovery functions, outside the source test body. Follow exact compiler
/// references from SDK test factories to entry thunks; never infer a binding
/// from a macro's generated display name or a source spelling alone.
enum SwiftTestingDiscoveryRoots {
    static let missingEvidence = "Swift Testing discovery roots are incomplete; compiler evidence for argument generation and traits is required"
    static let runtimeEvidence = "Swift Testing argument/trait factory roots are bound, but runtime trait/scoping callbacks and generic argument-iteration witnesses remain unproven"

    /// Discovery invokes protocol witnesses outside the generated factory.
    /// Keep all compiled candidates for the concrete existential payload,
    /// including same-spelled conformances from different capture modules.
    static func bindTraitWitnesses(graph: inout DependencyGraph, tables: [String: Set<String>]) {
        var witnesses: [String: Set<String>] = [:]
        let protocols: Set<Substring> = ["Trait", "SuiteTrait", "TestTrait", "TestScoping"]
        for (key, targets) in tables {
            guard let separator = key.range(of: "@witness:"),
                  let owner = key[..<separator.lowerBound].split(separator: ".").first,
                  protocols.contains(owner) else { continue }
            witnesses[String(key[separator.upperBound...]), default: []].formUnion(targets)
        }
        guard !witnesses.isEmpty else { return }
        for (symbol, node) in graph.functions {
            for type in node.swiftTestingExistentialTypes ?? [] {
                if let candidates = witnesses[type] { graph.functions[symbol]?.dependencies.formUnion(candidates) }
            }
        }
    }

    static func bind(modules: [String: String], sources: [String: SwiftSourceSnapshot], graph: inout DependencyGraph) {
        guard !Set(modules.values).contains("Testing") else { return }
        let entries = graph.tests
        let sourceModules = Dictionary(grouping: sources, by: { String($0.key.prefix { $0 != ":" }) })
        var testRegions: [String: [String: [SourceRegion]]] = [:], suiteCounts: [String: Int] = [:]
        var valueTypes: [String: Set<String>] = [:]
        var currentMetadata = Set<String>()
        for (module, files) in sourceModules {
            if files.allSatisfy({ $0.value.parserVersion == SwiftSourceSnapshot.currentParserVersion }) { currentMetadata.insert(module) }
            for unit in files.flatMap({ $0.value.units }) {
                if unit.kind == "type", unit.receiverValueType == true, !unit.scope.contains(".") {
                    valueTypes[module, default: []].insert(unit.scope)
                }
                if unit.swiftTestingRole == "test" { testRegions[module, default: [:]][unit.region.path, default: []].append(unit.region) }
                if unit.swiftTestingRole == "suite" { suiteCounts[module, default: 0] += 1 }
            }
        }
        var entryTests: [String: Set<String>] = [:]
        for (test, roots) in entries {
            let name = test.split(separator: "/").dropFirst().joined(separator: ".")
            for root in roots where graph.functions[root].map({ $0.name == name || $0.name == "static " + name }) == true {
                entryTests[root, default: []].insert(test)
            }
        }
        var factories: [String: Set<String>] = [:], suites: [String: Set<String>] = [:]
        for node in graph.functions.values {
            guard let references = node.compilerReferences else { continue }
            if references.contains(where: { $0.hasPrefix("$s7Testing4TestV10__function") }) {
                factories[node.module, default: []].insert(node.id)
            }
            if references.contains(where: { $0.hasPrefix("$s7Testing4TestV6__type") }) {
                suites[node.module, default: []].insert(node.id)
            }
        }
        // Even an unrelated suite factory remains a discovery root. Only the
        // separate runtime trait diagnostic can be scoped by nominal identity.
        let traitSuites = suites.values.flatMap { $0 }.compactMap { graph.functions[$0] }.filter { $0.swiftTestingEmptyFactory != "suite" }
        let suiteTypes = Set(traitSuites.compactMap(\.swiftTestingFactoryType))
        let suiteTypesComplete = traitSuites.allSatisfy { $0.swiftTestingFactoryType != nil } &&
            suiteCounts.allSatisfy { suites[$0.key]?.count == $0.value }
        var discovered: [String: Set<String>] = [:], incompleteFactories = Set<String>()
        let ownedPrefixes = Set(modules.values).map { "$s" + String($0.utf8.count) + $0 }
        for (module, roots) in factories.merging(suites, uniquingKeysWith: { $0.union($1) }) {
            for root in roots {
                var pending = [root], visited = Set<String>()
                while let id = pending.popLast() {
                    guard visited.insert(id).inserted else { continue }
                    if let tests = entryTests[id], factories[module]?.contains(root) == true {
                        for test in tests where modules[String(test.prefix { $0 != "/" })] == module {
                            discovered[test, default: []].insert(root)
                        }
                        continue
                    }
                    guard let node = graph.functions[id] else {
                        if ownedPrefixes.contains(where: id.hasPrefix) { incompleteFactories.insert(root) }
                        continue
                    }
                    guard node.module == module, node.regions.isEmpty else { continue }
                    guard let references = node.compilerReferences else { incompleteFactories.insert(root); continue }
                    pending.append(contentsOf: references)
                }
            }
        }
        for (test, roots) in entries {
            guard let module = modules[String(test.prefix { $0 != "/" })] else { continue }
            let isWrittenTest = roots.contains { id in
                entryTests[id]?.contains(test) == true && graph.functions[id]?.regions.contains { region in
                    testRegions[module]?[region.path]?.contains { $0.intersects(region) } == true
                } == true
            }
            guard isWrittenTest || discovered[test] != nil else { continue }
            let factoryRoots = discovered[test] ?? []
            // All suite factories in this module are retained. This deliberately
            // overapproximates inherited/custom suite traits rather than guessing
            // a precise hierarchy from generated symbol names.
            graph.tests[test, default: []].formUnion(factoryRoots.union(suites[module] ?? []))
            guard factoryRoots.count == 1, (suiteCounts[module] ?? 0) <= (suites[module]?.count ?? 0),
                  currentMetadata.contains(module),
                  factoryRoots.isDisjoint(with: incompleteFactories),
                  (suites[module] ?? []).isDisjoint(with: incompleteFactories),
                  !roots.isEmpty, graph.diagnostics.isEmpty else {
                graph.testDiagnostics[test, default: []].append(missingEvidence)
                continue
            }
            // Factory references cover producers, not the runtime invocation of
            // TestTrait/TestScoping witnesses or custom Collection iteration.
            // Keep explicit uncertainty even for nonparameterized trait-bearing
            // tests; finding a constructor is not a lifecycle/effect proof.
            graph.testDiagnostics[test]?.removeAll {
                $0 == "Parameterized test arguments may execute outside the test body; compiler evidence for argument generation and traits is required"
            }
            let factoryKind = factoryRoots.first.flatMap { graph.functions[$0]?.swiftTestingEmptyFactory }
            let emptySuites = (suites[module] ?? []).allSatisfy { graph.functions[$0]?.swiftTestingEmptyFactory == "suite" }
            let localMember = factoryRoots.allSatisfy { $0.hasPrefix("$s" + String(module.utf8.count) + module) }
            // Top-level functions cannot inherit suite traits. Member tests
            // require empty traits in every captured suite until exact suite
            // ownership is available. Extensions of imported types have a
            // different mangled declaration owner and may inherit unseen traits.
            // Legacy/unknown SIL stays conservative.
            // A local, top-level value type cannot inherit another nominal
            // suite's traits. Require the source declaration, demangled test
            // method owner, and literal SDK factory metatype to agree. Nested,
            // imported, class, and generic contexts keep their uncertainty.
            let factoryType = factoryRoots.first.flatMap { graph.functions[$0]?.swiftTestingFactoryType }
            let unrelatedSuites = factoryType.map { type in
                suiteTypesComplete && !suiteTypes.contains(type) && valueTypes[module]?.contains(type) == true &&
                    roots.contains { id in
                        entryTests[id]?.contains(test) == true && graph.functions[id]?.nominalTypeContext == module + "." + type
                    }
            } ?? false
            if factoryKind != "top-level" && !(factoryKind == "member" && localMember && (emptySuites || unrelatedSuites)) {
                graph.testDiagnostics[test, default: []].append(runtimeEvidence)
            }
        }
    }
}
