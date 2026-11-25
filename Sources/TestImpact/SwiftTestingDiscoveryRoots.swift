// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
import Foundation

/// Swift Testing executes argument producers and traits through generated
/// discovery functions, outside the source test body. Follow exact compiler
/// references from SDK test factories to entry thunks; never infer a binding
/// from a macro's generated display name or a source spelling alone.
enum SwiftTestingDiscoveryRoots {
    static let sharedDiscoveryID = "swift-testing:discovery"
    static func processRoot(_ target: String) -> String { sharedDiscoveryID + ":" + target }

    static func isDiscoveryRoot(_ id: String) -> Bool {
        id == sharedDiscoveryID || id.hasPrefix(sharedDiscoveryID + ":")
    }

    static let missingEvidence = "Swift Testing discovery roots are incomplete; compiler evidence for argument generation and traits is required"
    static let runtimeEvidence = "Swift Testing argument/trait factory roots are bound, but runtime trait/scoping callbacks and generic argument-iteration witnesses remain unproven"

    /// Follow each Mach-O test record's C accessor to the function supplied to
    /// Testing.Test.__store. Unknown lowering or a missing record body leaves
    /// the module on the conservative source-inventory check.
    static func registrationInventory(tables: [String: Set<String>], graph: DependencyGraph)
        -> (factories: [String: Set<String>]?, byRecord: [String: String]) {
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
        var byRecord: [String: String] = [:], seen = Set<String>(), ambiguous = Set<String>()
        for (key, accessors) in tables where key.hasPrefix(SILModule.testingRecordPrefix) {
            let fields = key.dropFirst(SILModule.testingRecordPrefix.count).split(separator: ":", maxSplits: 1)
            guard fields.count == 2 else { return (nil, [:]) }
            let module = String(fields[0]), record = String(fields[1])
            if !seen.insert(record).inserted { ambiguous.insert(record) }
            guard accessors.count == 1, let accessor = accessors.first,
                  let factory = registeredFactory(from: accessor, module: module),
                  inventories[module, default: []].insert(factory).inserted else { incomplete.insert(module); continue }
            byRecord[record] = factory
        }
        for module in incomplete { inventories.removeValue(forKey: module) }
        for record in ambiguous { byRecord.removeValue(forKey: record) }
        return (inventories.isEmpty ? nil : inventories, byRecord)
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

    /// The constrained standard-library overloads invoke these protocol requirements.
    /// The unconstrained and reflecting overloads can inspect erased values at runtime.
    static func isStringFormatting(_ symbol: String) -> Bool {
        symbol.hasPrefix("$sSS10describingSSx_") || symbol.hasPrefix("$sSS10reflectingSSx_")
    }

    static func formattingRequirement(_ symbol: String) -> String? {
        switch symbol {
        case "$sSS10describingSSx_tcs23CustomStringConvertibleRzlufC",
             "$sSS10describingSSx_tcs23CustomStringConvertibleRzs20TextOutputStreamableRzlufC":
            return "CustomStringConvertible.description"
        case "$sSS10describingSSx_tcs20TextOutputStreamableRzlufC":
            return "TextOutputStreamable.write"
        default: return nil
        }
    }

    static let unresolvedEffects = "Swift Testing discovery may execute unmodeled code before test filtering"

    /// Follow eager construction only. The ordinary graph keeps known witness
    /// and destructor edges even when another part of the same path is opaque.
    static func restoreDiscoveryEffects(_ graph: inout DependencyGraph) {
        guard graph.functions[sharedDiscoveryID] != nil else { return }
        let factories = Set(graph.functions.values.filter {
            $0.compilerReferences?.contains(where: SwiftTestingFactoryProof.isFactory) == true
        }.map(\.id))
        let tests = graph.tests.filter { $0.value.contains(sharedDiscoveryID) }
        let byRoot = Dictionary(grouping: tests.keys) { test in
            let id = processRoot(String(test.prefix { $0 != "/" }))
            return tests[test]?.contains(id) == true ? id : sharedDiscoveryID
        }
        for (id, entries) in byRoot {
            let linked: Set<String>?
            if id == sharedDiscoveryID {
                linked = graph.swiftTestingLinkedRecordsVerified == true ? factories : nil
            } else {
                linked = graph.swiftTestingFactoriesByTarget?[String(id.dropFirst(sharedDiscoveryID.count + 1))]
            }
            let incomplete = id == sharedDiscoveryID
                ? graph.testDiagnostics.values.contains { $0.contains(missingEvidence) }
                : entries.contains { graph.testDiagnostics[$0]?.contains(missingEvidence) == true }
            let verified = linked.flatMap { !$0.isEmpty && $0.isSubset(of: factories) ? $0 : nil }
            restoreEffects(rootID: id, tests: entries, factories: verified ?? factories,
                complete: verified != nil && !incomplete, graph: &graph)
        }
    }

    private static func restoreEffects(rootID: String, tests: [String], factories: Set<String>, complete: Bool,
                                       graph: inout DependencyGraph) {
        guard let root = graph.functions[rootID] else { return }
        // Older roots can contain additional construction edges. Audit those
        // too, preserving the caller context for flattened factory references.
        var extraRoots = root.dependencies.subtracting(factories)
        for id in factories {
            if let eager = graph.functions[id]?.swiftTestingDiscoveryReferences { extraRoots.subtract(eager) }
        }
        var pending = Array(factories.union(extraRoots)), visited = Set<String>()
        var unresolved = !complete
        if rootID == sharedDiscoveryID, let recorded = graph.swiftTestingRegisteredFactories,
           recorded.values.contains(where: { !$0.isSubset(of: factories) }) { unresolved = true }
        while !unresolved, let id = pending.popLast() {
            guard visited.insert(id).inserted else { continue }
            guard let node = graph.functions[id], let references = node.compilerReferences else {
                unresolved = true
                continue
            }
            if node.hasModeledDiscoveryInstructions != true { unresolved = true }
            // Proven release edges are already on the releasing SIL function.
            // Erased values and legacy captures still need runtime fallback.
            if node.mayDestroyValue != false { unresolved = true }
            let factory = factories.contains(id)
            if factory && node.swiftTestingDiscoveryReferences == nil { unresolved = true }
            let eager = factory ? node.swiftTestingDiscoveryReferences ?? references : references
            for callee in eager {
                // At capture a modeled factory validated the SDK call and its
                // deferred operands. All other eager calls need a body or contract.
                if factory && SwiftTestingFactoryProof.isFactory(callee) { continue }
                if SwiftTestingDiscoveryEffects.metadataCallees.contains(callee) { continue }
                pending.append(callee)
            }
            pending.append(contentsOf: node.dependencies.subtracting(references))
        }
        // Drop derived state from pre-effect-summary captures before recomputing.
        graph.functions[rootID]?.uncertainties.remove("Indirect function invocation")
        if unresolved { graph.functions[rootID]?.uncertainties.insert(unresolvedEffects) }
        else { graph.functions[rootID]?.uncertainties.remove(unresolvedEffects) }
        for test in tests {
            if graph.testDiagnostics[test]?.contains(legacyIndirectCallback) == true {
                graph.testDiagnostics[test]?.removeAll { $0 == legacyIndirectCallback }
            }
            if unresolved {
                if graph.testDiagnostics[test]?.contains(unresolvedEffects) != true {
                    graph.testDiagnostics[test, default: []].append(unresolvedEffects)
                }
            } else if graph.testDiagnostics[test]?.contains(unresolvedEffects) == true {
                graph.testDiagnostics[test]?.removeAll { $0 == unresolvedEffects }
            }
        }
    }

    /// The shared discovery root reaches construction code. Deferred callbacks
    /// stay with their entry or suite. Missing evidence keeps the whole factory.
    private struct FactoryConstruction {
        var functions: [String: Set<String>] = [:]
        var suites: [String: Set<String>] = [:]
        var eager: [String: Set<String>] = [:]
        var deferredSuites: [String: Set<String>] = [:]

        init(_ graph: DependencyGraph, declaredSuites: [String: [String]]) {
            for node in graph.functions.values {
                guard let references = node.compilerReferences else { continue }
                if references.contains(where: { $0.hasPrefix("$s7Testing4TestV6__type") }) {
                    suites[node.module, default: []].insert(node.id)
                    if let construction = node.swiftTestingDiscoveryReferences, !references.isSubset(of: construction),
                       node.dynamicDeclarations.isEmpty, let type = node.swiftTestingFactoryType,
                       declaredSuites[node.module]?.contains(type) == true {
                        eager[node.id] = node.dependencies.subtracting(references.subtracting(construction))
                        deferredSuites[node.module + "." + type, default: []].insert(node.id)
                    } else {
                        eager[node.id] = [node.id]
                    }
                }
                if references.contains(where: { $0.hasPrefix("$s7Testing4TestV10__function") }) {
                    functions[node.module, default: []].insert(node.id)
                    eager[node.id] = node.dynamicDeclarations.isEmpty ? node.swiftTestingDiscoveryReferences ?? [node.id] : [node.id]
                }
            }
        }
    }

    private static let legacyIndirectCallback = "Swift Testing discovery invokes an indirect callback before test filtering"
    static let parameterizedArguments = "Parameterized test arguments may execute outside the test body; compiler evidence for argument generation and traits is required"

    private static let derivedDiagnostics: Set<String> = [missingEvidence, runtimeEvidence, unresolvedEffects, legacyIndirectCallback]

    static func nominalOwner(of entries: [FunctionNode]) -> String? {
        guard let owner = entries.first?.nominalTypeContext, !owner.isEmpty,
              entries.allSatisfy({ $0.nominalTypeContext == owner }) else { return nil }
        return owner
    }

    /// A test inherits traits from its nominal type and its lexical enclosing types.
    /// The first component is the module, including for cross-module extensions.
    static func enclosingSuites(of owner: String) -> [String] {
        var path = owner.split(separator: ".")[...]
        var suites: [String] = []
        while path.count > 1 {
            suites.append(path.joined(separator: "."))
            path = path.dropLast()
        }
        return suites
    }

    /// Restore compiler inputs before binding. Older archives mixed entry and
    /// discovery roots in one set and could count an app host's static images as complete.
    static func restore(modules: [String: String], sources: [String: SwiftSourceSnapshot], graph: inout DependencyGraph) {
        guard !modules.values.contains("Testing") else { return }
        if graph.swiftTestingProcessInventoryVersion != LinkedTestingRecords.inventoryVersion {
            graph.swiftTestingFactoriesByTarget = nil
            graph.swiftTestingLinkedRecordsVerified = nil
        }
        // New archives retain the binder inputs directly. For older ones the
        // reserved discovery nodes, compiler factories and bound witnesses are
        // the only additions the discovery binder made to an entry.
        let saved = graph.swiftTestingEntryRoots
        let factories = Set(graph.functions.values.filter {
            $0.compilerReferences?.contains(where: SwiftTestingFactoryProof.isFactory) == true
        }.map(\.id))
        guard saved != nil || graph.functions[sharedDiscoveryID] != nil || !factories.isEmpty || sources.values.contains(where: {
            $0.swiftTestingDeclarations?.tests.isEmpty == false || $0.units.contains { $0.swiftTestingRole == "test" }
        }) else { return }

        let testFactories = factories.filter {
            graph.functions[$0]?.compilerReferences?.contains(where: { $0.hasPrefix("$s7Testing4TestV10__function") }) == true
        }
        let suiteRoots = factories.subtracting(testFactories).union(graph.swiftTestingSuiteWitnesses?.values.flatMap { $0 } ?? [])
        let generated = testFactories.union(suiteRoots)
        var archived: [String: Set<String>] = [:]
        for (test, roots) in graph.tests {
            if let original = saved?[test] {
                graph.tests[test] = original.subtracting(suiteRoots)
                archived[test] = []
            } else {
                let prior = roots.intersection(generated)
                guard roots.contains(sharedDiscoveryID) || !prior.isEmpty else { continue }
                graph.tests[test] = roots.subtracting(prior).filter { !isDiscoveryRoot($0) }
                // Only per-test factories can independently preserve an entry binding.
                // Recompute suite callbacks from ownership and linkage on every read.
                archived[test] = prior.intersection(testFactories)
            }
        }
        bind(modules: modules, sources: sources, graph: &graph, archived: archived)
    }

    static func bind(modules: [String: String], sources: [String: SwiftSourceSnapshot], graph: inout DependencyGraph,
                     archived: [String: Set<String>] = [:]) {
        guard !Set(modules.values).contains("Testing") else { return }
        let entries = graph.tests
        var compilerRoots: [String: Set<String>] = [:]
        for id in graph.functions.keys where isDiscoveryRoot(id) { graph.functions.removeValue(forKey: id) }
        let sourceModules = Dictionary(grouping: sources, by: { String($0.key.prefix { $0 != ":" }) })
        var testRegions: [String: [String: [SourceRegion]]] = [:]
        let written = SwiftTestingSuiteDeclarations(sources)
        let declaredSuites = written.names
        var nonInheritingTypes: [String: Bool] = [:]
        for (module, files) in sourceModules {
            for (_, file) in files {
                for unit in file.units where unit.kind == "type" {
                    let name = module + "." + unit.scope
                    let independent = unit.receiverValueType == true ||
                        (file.classFinality?[unit.scope] == true && file.inheritance[name]?.isEmpty == true)
                    nonInheritingTypes[name] = (nonInheritingTypes[name] ?? true) && independent
                }
                let declarations = file.swiftTestingDeclarations ?? SwiftTestingSourceDeclarations(legacyUnits: file.units)
                for region in declarations.tests { testRegions[module, default: [:]][region.path, default: []].append(region) }
            }
        }
        var entryTests: [String: Set<String>] = [:]
        for (test, roots) in entries {
            let name = test.split(separator: "/").dropFirst().joined(separator: ".")
            for root in roots where graph.functions[root].map({ $0.name == name || $0.name == "static " + name }) == true {
                entryTests[root, default: []].insert(test)
            }
        }
        let registration = FactoryConstruction(graph, declaredSuites: declaredSuites)
        let factories = registration.functions, suites = registration.suites
        let construction = registration.eager, deferredSuites = registration.deferredSuites
        let allConstruction = Set(construction.values.flatMap { $0 })
        if !construction.isEmpty {
            // All entries share the marker for edits to registration source.
            // Fresh captures attach their executable construction edges to a
            // separate node for each bundle and host. Legacy graphs share them.
            graph.functions[sharedDiscoveryID] = FunctionNode(id: sharedDiscoveryID, module: "Testing",
                name: "discovery", dependencies: graph.swiftTestingFactoriesByTarget == nil ? allConstruction : [])
        }
        if let linked = graph.swiftTestingFactoriesByTarget {
            for (target, module) in modules {
                guard let ids = linked[target] else { continue }
                let local = (factories[module] ?? []).union(suites[module] ?? [])
                if !local.isSubset(of: ids) { graph.swiftTestingFactoriesByTarget?.removeValue(forKey: target) }
            }
        }
        // Keep the originating registration with every deferred condition and
        // trait witness until the entry's process inventory has been checked.
        var callbacksBySuite = deferredSuites.mapValues { factories in
            Dictionary(uniqueKeysWithValues: factories.map { ($0, Set([$0])) })
        }
        for (id, witnesses) in graph.swiftTestingSuiteWitnesses ?? [:] {
            guard let suite = graph.functions[id], let type = suite.swiftTestingFactoryType,
                  declaredSuites[suite.module]?.contains(type) == true else { continue }
            callbacksBySuite[suite.module + "." + type, default: [:]][id, default: []].formUnion(witnesses)
        }
        let callbackFactories = Set(callbacksBySuite.values.flatMap(\.keys))
        let traitSuites = suites.values.flatMap { $0 }.compactMap { graph.functions[$0] }.filter { $0.swiftTestingEmptyFactory != "suite" }
        let suiteTypes = Set(traitSuites.compactMap { suite in
            suite.swiftTestingFactoryType.map { suite.module + "." + $0 }
        })
        // A verified non-inheriting local type only receives enclosing suite
        // traits. Missing factories in unrelated modules cannot apply to it.
        var completeSuiteModules = Set<String>()
        for module in written.completeModules {
            let symbols = suites[module] ?? []
            let types = symbols.compactMap { graph.functions[$0]?.swiftTestingFactoryType }
            let declared = declaredSuites[module] ?? []
            guard types.count == symbols.count else { continue }
            if types.sorted() == declared.sorted() { completeSuiteModules.insert(module); continue }
            // Conditional source is parsed on every platform. An omitted suite
            // is benign only when every emitted registration has a bound factory
            // and every unmatched declaration could be inactive.
            guard let conditional = written.conditional[module],
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
            let target = String(test.prefix { $0 != "/" })
            let module = modules[target] ?? ""
            let isWrittenTest = roots.contains { id in
                entryTests[id]?.contains(test) == true && graph.functions[id]?.regions.contains { region in
                    testRegions[module]?[region.path]?.contains { $0.intersects(region) } == true
                } == true
            }
            guard isWrittenTest || discovered[test] != nil || archived[test] != nil else { continue }
            graph.testDiagnostics[test]?.removeAll(where: derivedDiagnostics.contains)
            compilerRoots[test] = roots
            let factoryRoots = discovered[test] ?? []
            graph.tests[test, default: []].formUnion(factoryRoots)
            let linked = graph.swiftTestingFactoriesByTarget?[target]
            if !construction.isEmpty {
                graph.tests[test, default: []].insert(sharedDiscoveryID)
                if graph.swiftTestingFactoriesByTarget != nil {
                    let id = processRoot(target)
                    if graph.functions[id] == nil {
                        let dependencies = linked.map { ids in Set(ids.flatMap { construction[$0] ?? [] }) } ?? allConstruction
                        graph.functions[id] = FunctionNode(id: id, module: "Testing", name: "discovery in " + target, dependencies: dependencies)
                    }
                    graph.tests[test, default: []].insert(id)
                }
            }
            // Extensions register in their emitting module, but inherit traits
            // from the nominal type's declaring module (and its enclosing suites).
            let methods = roots.filter { entryTests[$0]?.contains(test) == true }.compactMap { graph.functions[$0] }
            let owner = nominalOwner(of: methods)
            let enclosing = owner.map(enclosingSuites) ?? []
            let factory = factoryRoots.count == 1 ? factoryRoots.first.flatMap { graph.functions[$0] } : nil
            let hasUnknownCallbacks = owner == nil && !callbackFactories.isEmpty &&
                (linked.map { !$0.isDisjoint(with: callbackFactories) } ?? true)
            if !factoryRoots.isEmpty, factory?.swiftTestingMetadataFactory != "top-level" {
                for suite in enclosing {
                    guard let registrations = callbacksBySuite[suite] else { continue }
                    for (id, callbacks) in registrations where linked?.contains(id) != false {
                        graph.tests[test, default: []].formUnion(callbacks)
                    }
                }
            }
            guard factoryRoots.count == 1, completeSuiteModules.contains(module) || (declaredSuites[module]?.count ?? 0) <= (suites[module]?.count ?? 0),
                  written.completeModules.contains(module),
                  factoryRoots.isDisjoint(with: incompleteFactories),
                  (suites[module] ?? []).isDisjoint(with: incompleteFactories),
                  !roots.isEmpty, graph.diagnostics.isEmpty else {
                // If early archives lack the inputs to reproduce an observed
                // per-entry edge, retain that positive evidence across re-encoding.
                if let prior = archived[test], !prior.isEmpty {
                    graph.tests[test]?.formUnion(prior)
                    compilerRoots[test]?.formUnion(prior)
                }
                if test.split(separator: "/").last?.contains(":") == true,
                   graph.testDiagnostics[test]?.contains(parameterizedArguments) != true {
                    graph.testDiagnostics[test, default: []].append(parameterizedArguments)
                }
                graph.testDiagnostics[test, default: []].append(missingEvidence)
                continue
            }
            // Factory references cover producers, not the runtime invocation of
            // TestTrait/TestScoping witnesses or custom Collection iteration.
            // Keep explicit uncertainty even for nonparameterized trait-bearing
            // tests; finding a constructor is not a lifecycle/effect proof.
            graph.testDiagnostics[test]?.removeAll {
                $0 == parameterizedArguments
            }
            let factoryKind = factory?.swiftTestingMetadataFactory
            let emptySuites = (suites[module] ?? []).allSatisfy { graph.functions[$0]?.swiftTestingEmptyFactory == "suite" }
            let localMember = factoryRoots.allSatisfy { $0.hasPrefix("$s" + String(module.utf8.count) + module) }
            // Excluding suite runtime uncertainty also requires a local, non-inheriting
            // declaration and a matching metatype in a complete suite inventory.
            let unrelatedSuites = factory?.swiftTestingFactoryType.map { type in
                completeSuiteModules.contains(module) && nonInheritingTypes[module + "." + type] == true &&
                    owner == module + "." + type && suiteTypes.isDisjoint(with: enclosing)
            } ?? false
            if factoryKind != "top-level" && (hasUnknownCallbacks ||
                !(factoryKind == "member" && localMember && (emptySuites || unrelatedSuites))) {
                graph.testDiagnostics[test, default: []].append(runtimeEvidence)
            }
        }
        graph.swiftTestingEntryRoots = compilerRoots.isEmpty ? nil : compilerRoots
        restoreDiscoveryEffects(&graph)
    }
}
