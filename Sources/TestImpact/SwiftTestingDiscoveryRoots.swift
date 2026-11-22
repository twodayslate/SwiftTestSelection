// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
import Foundation

/// Swift Testing executes argument producers and traits through generated
/// discovery functions, outside the source test body. Follow exact compiler
/// references from SDK test factories to entry thunks; never infer a binding
/// from a macro's generated display name or a source spelling alone.
enum SwiftTestingDiscoveryRoots {
    static let sharedDiscoveryID = "swift-testing:discovery"
    static let missingEvidence = "Swift Testing discovery roots are incomplete; compiler evidence for argument generation and traits is required"
    static let runtimeEvidence = "Swift Testing argument/trait factory roots are bound, but runtime trait/scoping callbacks and generic argument-iteration witnesses remain unproven"

    /// Follow each Mach-O test record's C accessor to the function supplied to
    /// Testing.Test.__store. Unknown lowering or a missing record body leaves
    /// the module on the conservative source-inventory check.
    static func registeredFactories(tables: [String: Set<String>], graph: DependencyGraph) -> [String: Set<String>]? {
        var inventories: [String: Set<String>] = [:], incomplete = Set<String>()
        let store = "$s7Testing4TestV7__store_4into8asTypeAt"
        func registeredFactory(from accessor: String, module: String) -> String? {
            var id = accessor, visited = Set<String>(), reachedStore = false
            while visited.insert(id).inserted, let node = graph.functions[id],
                  node.module == module, node.regions.isEmpty, var references = node.compilerReferences {
                if reachedStore, references.contains(where: SwiftTestingFactoryProof.isFactory) { return id }
                if let sdk = references.first(where: { $0.hasPrefix(store) }) {
                    guard !reachedStore else { return nil }
                    reachedStore = true
                    references.remove(sdk)
                }
                guard references.count == 1, let next = references.first else { return nil }
                id = next
            }
            return nil
        }
        for (key, accessors) in tables where key.hasPrefix(SILModule.testingRecordPrefix) {
            let module = String(key.dropFirst(SILModule.testingRecordPrefix.count).prefix { $0 != ":" })
            guard accessors.count == 1, let accessor = accessors.first,
                  let factory = registeredFactory(from: accessor, module: module),
                  inventories[module, default: []].insert(factory).inserted else { incomplete.insert(module); continue }
        }
        for module in incomplete { inventories.removeValue(forKey: module) }
        return inventories.isEmpty ? nil : inventories
    }

    /// Both ends of the runtime edge must name the same concrete type.
    /// The producer can be defined in a different module from the factory.
    static func bindTraitWitnesses(graph: inout DependencyGraph, tables: [String: Set<String>], compiler: String?) {
        let producers = graph.functions.values.reduce(into: Set<String>()) { symbols, node in
            if let applied = node.swiftTestingTraitProducers { symbols.formUnion(applied) }
        }
        guard !producers.isEmpty else { return }
        let protocols: Set<Substring> = ["Trait", "SuiteTrait", "TestTrait", "TestScoping"]
        var targets = Set<String>()
        for (key, symbols) in tables {
            guard let separator = key.range(of: "@witness:"),
                  let owner = key[..<separator.lowerBound].split(separator: ".").first,
                  protocols.contains(owner) else { continue }
            targets.formUnion(symbols)
        }
        guard !targets.isEmpty else { return }
        let names = demangledNames(producers.union(targets).sorted(), compiler: compiler)
        let prefixes = protocols.map { "protocol witness for Testing." + $0 + "." }
        var witnesses: [String: Set<String>] = [:]
        for symbol in targets {
            guard let name = names[symbol], prefixes.contains(where: name.hasPrefix),
                  let conformance = Pattern.groups(witnessOwner, in: name) else { continue }
            // A trait can itself conform to TestScoping while returning another
            // provider. Only the associated conformance dispatches provideScope.
            if name.hasPrefix("protocol witness for Testing.TestScoping.") { continue }
            witnesses[conformance[0], default: []].insert(symbol)
            if name.hasPrefix("protocol witness for Testing.Trait.scopeProvider("),
               let providers = tables[SILModule.scopeProviderPrefix + symbol], providers.count == 1,
               let provider = providers.first, let callbacks = tables[provider], callbacks.count == 1,
               let callback = callbacks.first,
               names[callback]?.hasPrefix("protocol witness for Testing.TestScoping.provideScope(") == true {
                witnesses[conformance[0], default: []].insert(callback)
            }
        }
        let resultTypes = producers.reduce(into: [String: String]()) { result, symbol in
            guard let name = names[symbol], let type = Pattern.groups(producerResult, in: name) else { return }
            result[symbol] = type[0]
        }
        for (symbol, node) in graph.functions {
            guard let applied = node.swiftTestingTraitProducers, !applied.isEmpty else { continue }
            let candidates = applied.reduce(into: Set<String>()) { symbols, producer in
                if let type = resultTypes[producer], let callbacks = witnesses[type] { symbols.formUnion(callbacks) }
            }
            guard !candidates.isEmpty else { continue }
            if node.compilerReferences?.contains(where: { $0.hasPrefix("$s7Testing4TestV6__type") }) == true {
                if graph.swiftTestingSuiteWitnesses == nil { graph.swiftTestingSuiteWitnesses = [:] }
                graph.swiftTestingSuiteWitnesses?[symbol, default: []].formUnion(candidates)
            } else {
                graph.functions[symbol]?.dependencies.formUnion(candidates)
            }
        }
    }

    // Accept concrete qualified nominal types from direct results and getters.
    // More complex or unknown demanglings keep runtime uncertainty.
    // Private nominal components include the compiler's file discriminator.
    private static let nominal = #"\w+(?:\.(?:\w+|\(\w+ in _[A-Fa-f0-9]+\)))+"#
    private static let producerResult = try! NSRegularExpression(pattern: #"(?: -> |\.getter : )("# + nominal + #")$"#)
    private static let witnessOwner = try! NSRegularExpression(pattern: #" in conformance ("# + nominal + #") : Testing\.(?:Trait|TestTrait|SuiteTrait|TestScoping) in [\w]+$"#)

    private static func demangledNames(_ symbols: [String], compiler: String?) -> [String: String] {
        let command: [String]
        let sibling = compiler.map { URL(fileURLWithPath: $0).deletingLastPathComponent().appendingPathComponent("swift-demangle").path }
        if compiler?.hasPrefix("/") == true, let sibling, FileManager.default.isExecutableFile(atPath: sibling) {
            command = [sibling]
        } else {
            #if os(macOS)
            command = ["xcrun", "swift-demangle"]
            #else
            command = ["swift-demangle"]
            #endif
        }
        guard let output = try? CommandRunner.run(command[0], Array(command.dropFirst()) + ["--compact"],
            at: FileManager.default.temporaryDirectory, input: Data((symbols.joined(separator: "\n") + "\n").utf8)).text else { return [:] }
        let names = output.split(separator: "\n")
        guard names.count == symbols.count else { return [:] }
        return Dictionary(uniqueKeysWithValues: zip(symbols, names.map(String.init)))
    }

    /// Moving a registration can change its generated symbol while keeping the
    /// enumerated entry stable. Compare its eager callees by compiler identity.
    /// Surviving symbols distinguish rebinding from a whole-file private rename.
    static func reboundDiscoveryCall(before: DependencyGraph?, after: DependencyGraph?) -> Bool {
        guard let before, let after, before.functions[sharedDiscoveryID] != nil, after.functions[sharedDiscoveryID] != nil else { return false }
        func references(_ roots: Set<String>, in graph: DependencyGraph) -> Set<String>? {
            let factories = roots.compactMap { graph.functions[$0]?.swiftTestingDiscoveryReferences }
            return factories.count == 1 ? factories[0] : nil
        }
        return before.tests.contains { test, roots in
            guard let current = after.tests[test], let old = references(roots, in: before),
                  let new = references(current, in: after), old != new else { return false }
            return old.symmetricDifference(new).contains { symbol in
                before.functions[symbol]?.regions.isEmpty == false && after.functions[symbol]?.regions.isEmpty == false
            }
        }
    }

    /// Pair a literal label edit only when the declaration (including its body),
    /// lexical context and file still agree, and its SDK factory has empty traits.
    static func displayNameEdits(before: [String: [SourceUnit]], after: [String: [SourceUnit]],
                                 head: XcodeTestGraph, base: XcodeTestGraph? = nil) -> [String: String] {
        func candidates(_ units: [String: [SourceUnit]], excluding other: [String: [SourceUnit]]) -> [[String]: [SourceUnit]] {
            var result: [[String]: [SourceUnit]] = [:]
            for (key, group) in units where other[key] == nil && group.count == 1 {
                let unit = group[0]
                guard let comparison = unit.swiftTestingDisplayComparison else { continue }
                let identity = [String(key.prefix { $0 != ":" }), unit.region.path, unit.scope, unit.conditionalBranch ?? "", comparison]
                result[identity, default: []].append(unit)
            }
            return result
        }
        func hasEmptyFactory(_ unit: SourceUnit, in snapshot: XcodeTestGraph) -> Bool {
            guard let graph = snapshot.dependencies else { return false }
            let module = String(unit.key.prefix { $0 != ":" })
            let owners = snapshot.targets.filter { $0.sourceFiles.contains(unit.region.path) }
            guard !owners.isEmpty, owners.allSatisfy(\.isTest),
                  let file = snapshot.sources[module + ":" + unit.region.path],
                  file.units.filter({ $0.kind == "function" && $0.region.intersects(unit.region) }).count == 1 else { return false }
            let matches = snapshot.tests.filter { test in
                let parts = test.split(separator: "/")
                guard let target = parts.first, snapshot.modules[String(target)] == module else { return false }
                let method = parts.dropFirst().joined(separator: ".")
                return (graph.tests[test] ?? []).contains { id in
                    guard let node = graph.functions[id], node.module == module,
                          node.name == method || node.name == "static " + method else { return false }
                    return node.regions.contains { $0.intersects(unit.region) }
                }
            }
            guard matches.count == 1, let test = matches.first,
                  graph.testDiagnostics[test]?.contains(missingEvidence) != true else { return false }
            let factories = (graph.tests[test] ?? []).compactMap { graph.functions[$0] }.filter {
                $0.compilerReferences?.contains { $0.hasPrefix("$s7Testing4TestV10__function") } == true
            }
            return factories.count == 1 && ["member", "top-level"].contains(factories[0].swiftTestingEmptyFactory)
        }
        let old = candidates(before, excluding: after)
        guard !old.isEmpty else { return [:] }
        var pairs: [String: String] = [:]
        for (identity, current) in candidates(after, excluding: before) {
            guard current.count == 1, let previous = old[identity], previous.count == 1,
                  hasEmptyFactory(current[0], in: head),
                  base.map({ hasEmptyFactory(previous[0], in: $0) }) ?? true else { continue }
            pairs[current[0].key] = previous[0].key
        }
        return pairs
    }

    static func bind(modules: [String: String], sources: [String: SwiftSourceSnapshot], graph: inout DependencyGraph) {
        guard !Set(modules.values).contains("Testing") else { return }
        let entries = graph.tests
        let sourceModules = Dictionary(grouping: sources, by: { String($0.key.prefix { $0 != ":" }) })
        var testRegions: [String: [String: [SourceRegion]]] = [:]
        var conditionalSuites: [String: [String]] = [:]
        var valueTypes: [String: Set<String>] = [:], declaredSuites: [String: [String]] = [:]
        var currentMetadata = Set<String>()
        for (module, files) in sourceModules {
            if files.allSatisfy({ $0.value.parserVersion == SwiftSourceSnapshot.currentParserVersion && $0.value.swiftTestingDeclarations != nil }) { currentMetadata.insert(module) }
            for (_, file) in files {
                for unit in file.units where unit.kind == "type" && unit.receiverValueType == true && !unit.scope.contains(".") {
                    valueTypes[module, default: []].insert(unit.scope)
                }
                let declarations = file.swiftTestingDeclarations ?? SwiftTestingSourceDeclarations(legacyUnits: file.units)
                for region in declarations.tests { testRegions[module, default: [:]][region.path, default: []].append(region) }
                for suite in declarations.suites {
                    declaredSuites[module, default: []].append(suite.name)
                    if suite.conditional { conditionalSuites[module, default: []].append(suite.name) }
                }
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
        // Swift Testing constructs registrations across linked modules before it
        // applies a filter. Without linkage information, share construction
        // across the capture. A single node keeps the graph linear in its entries.
        var construction = Set(suites.values.flatMap { $0 })
        for id in factories.values.flatMap({ $0 }) {
            guard let node = graph.functions[id] else { continue }
            if let references = node.swiftTestingDiscoveryReferences, node.dynamicDeclarations.isEmpty {
                construction.formUnion(references)
            } else {
                // Unsupported lowering and older fragments retain the entire factory.
                construction.insert(id)
            }
        }
        if !construction.isEmpty {
            graph.functions[sharedDiscoveryID] = FunctionNode(id: sharedDiscoveryID, module: "Testing",
                name: "discovery", dependencies: construction)
        }
        var suiteWitnesses: [String: Set<String>] = [:]
        for (id, witnesses) in graph.swiftTestingSuiteWitnesses ?? [:] {
            guard let suite = graph.functions[id], let type = suite.swiftTestingFactoryType,
                  declaredSuites[suite.module]?.contains(type) == true else { continue }
            suiteWitnesses[suite.module + "." + type, default: []].formUnion(witnesses)
        }
        let witnessModules = Set(suiteWitnesses.keys.map { String($0.prefix { $0 != "." }) })
        let traitSuites = suites.values.flatMap { $0 }.compactMap { graph.functions[$0] }.filter { $0.swiftTestingEmptyFactory != "suite" }
        let suiteTypes = Set(traitSuites.compactMap { suite in
            suite.swiftTestingFactoryType.map { suite.module + "." + $0 }
        })
        // A verified locally declared value type only inherits its own suite
        // traits. Missing factories in unrelated modules cannot apply to it.
        var completeSuiteModules = Set<String>()
        for module in currentMetadata {
            let symbols = suites[module] ?? []
            let types = symbols.compactMap { graph.functions[$0]?.swiftTestingFactoryType }
            let declared = declaredSuites[module] ?? []
            guard types.count == symbols.count else { continue }
            if types.sorted() == declared.sorted() { completeSuiteModules.insert(module); continue }
            // Conditional source is parsed on every platform. An omitted suite
            // is benign only when every emitted registration has a bound factory
            // and every unmatched declaration could be inactive.
            guard let conditional = conditionalSuites[module],
                  graph.swiftTestingRegisteredFactories?[module] == symbols.union(factories[module] ?? []) else { continue }
            func counts(_ names: [String]) -> [String: Int] { Dictionary(grouping: names, by: { $0 }).mapValues(\.count) }
            let captured = counts(types)
            let conditionalCounts = counts(conditional)
            let written = counts(declared)
            if captured.allSatisfy({ $0.value <= written[$0.key, default: 0] }) &&
                written.allSatisfy({ $0.value - conditionalCounts[$0.key, default: 0] <= captured[$0.key, default: 0] }) {
                completeSuiteModules.insert(module)
            }
        }
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
            graph.tests[test, default: []].formUnion(factoryRoots)
            if !construction.isEmpty {
                graph.tests[test, default: []].insert(sharedDiscoveryID)
            }
            // Extensions register in their emitting module, but inherit traits
            // from the nominal type's declaring module (and its enclosing suites).
            let owners = Set(roots.compactMap { id -> String? in
                guard entryTests[id]?.contains(test) == true, let owner = graph.functions[id]?.nominalTypeContext,
                      !owner.isEmpty else { return nil }
                return owner
            })
            if !factoryRoots.isEmpty {
                let scope = test.split(separator: "/").dropFirst().dropLast().joined(separator: ".")
                let candidates = owners.isEmpty && !scope.isEmpty
                    ? Set(witnessModules.map { $0 + "." + scope }) : owners
                for owner in candidates {
                    var path = owner.split(separator: ".")
                    while path.count > 1 {
                        if let callbacks = suiteWitnesses[path.joined(separator: ".")] {
                            graph.tests[test, default: []].formUnion(callbacks)
                        }
                        path = path.dropLast()
                    }
                }
            }
            guard factoryRoots.count == 1, completeSuiteModules.contains(module) || (declaredSuites[module]?.count ?? 0) <= (suites[module]?.count ?? 0),
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
                completeSuiteModules.contains(module) && !suiteTypes.contains(module + "." + type) && valueTypes[module]?.contains(type) == true &&
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
