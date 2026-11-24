// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
import Foundation

/// One comparison of Swift Testing registrations for both Xcode selection modes.
/// An entry-local projection requires matching source declarations and a compiler
/// proof. Everything else contributes its full inputs to shared discovery.
struct SwiftTestingRegistrationComparison {
    private(set) var entryEdits: [String: String] = [:]
    private(set) var supportedBodies = Set<String>()
    private(set) var suiteTests = Set<String>()
    private(set) var uncertainSuiteTests = Set<String>()
    private(set) var suitePaths = Set<String>()
    private(set) var discoveryPaths = Set<String>()
    private(set) var incompletePaths = Set<String>()
    private(set) var suiteArgumentEdits: [String: String] = [:]
    private(set) var registrationEdits: [String: String] = [:]
    private var baseDiscovery = DiscoveryChange()
    private var headDiscovery = DiscoveryChange()
    private var rebound = false
    var changedDiscovery: Bool { rebound || !discoveryPaths.isEmpty || !incompletePaths.isEmpty }

    init(before: [String: [SourceUnit]], after: [String: [SourceUnit]], baseSources: [String: SwiftSourceSnapshot],
         base: XcodeTestGraph? = nil, head: XcodeTestGraph, moves: [String: String] = [:],
         touching paths: Set<String>, policy: UIFeatureMappings.SourceLocationPolicy) {
        func signatures(_ unit: SourceUnit) -> [[String]] {
            ((unit.swiftTestingArguments ?? []) + [unit.swiftTestingMetadata].compactMap { $0 }).map { $0.comparison(policy) }
        }
        func candidates(_ units: [String: [SourceUnit]], other: [String: [SourceUnit]]) -> [[String]: [SourceUnit]] {
            var result: [[String]: [SourceUnit]] = [:]
            for (key, group) in units where group.count == 1 {
                let unit = group[0]
                guard let inputs = unit.swiftTestingEntryInputs else { continue }
                if let matches = other[key], matches.count == 1, signatures(unit) == signatures(matches[0]) { continue }
                // Without a base factory, a changed expression could previously
                // have selected an eager overload. Boolean literals retain their
                // type; require all other predicates to compare unchanged.
                let historical = base == nil ? inputs.nonliteralPredicates ?? [] : []
                let identity = [String(key.prefix { $0 != ":" }), unit.region.path, unit.scope, unit.conditionalBranch ?? "",
                                String(inputs.providers), inputs.declaration] +
                    (inputs.eager + historical).map { SourceUnit.withLocations($0.comparison(policy), syntax: "eager") }
                result[identity, default: []].append(unit)
            }
            return result
        }

        let old = candidates(before, other: after)
        let indexedPaths = paths.union(old.values.flatMap { $0.map { $0.region.path } })
        let headProof = FactoryIndex(head, inspecting: indexedPaths)
        let baseProof = base.map { FactoryIndex($0, inspecting: indexedPaths) }
        incompletePaths = headProof.unmodeledPaths.union(baseProof?.unmodeledPaths.map { moves[$0] ?? $0 } ?? [])
        if !old.isEmpty {
            let current = candidates(after, other: before)
            for (identity, units) in current {
                guard units.count == 1, let previous = old[identity], previous.count == 1,
                      headProof.provesInputs(of: units[0]), baseProof?.provesInputs(of: previous[0]) ?? true else { continue }
                entryEdits[units[0].key] = previous[0].key
            }
        }

        // A changed eager trait can change the source-unit key even though the
        // callable survives intact. Only pair unique, compiler-bound entries.
        func declarations(_ groups: [String: [SourceUnit]]) -> [[String]: [SourceUnit]] {
            var result: [[String]: [SourceUnit]] = [:]
            for (key, group) in groups where group.count == 1 {
                let unit = group[0]
                guard paths.contains(unit.region.path), let declaration = unit.swiftTestingRegistrationDeclaration else { continue }
                let identity = [String(key.prefix { $0 != ":" }), unit.region.path, unit.scope, unit.conditionalBranch ?? "", declaration]
                result[identity, default: []].append(unit)
            }
            return result
        }
        var headSuites: SuiteIndex?, baseSuites: SuiteIndex?
        lazy var historicalSuites = SwiftTestingSuiteDeclarations(baseSources)
        func factory(of unit: SourceUnit, historical: Bool) -> String? {
            if unit.swiftTestingRole == "suite" {
                // Opaque declarations can carry nested entries in the same source
                // unit. Only a separately modeled suite header owns all its inputs.
                guard unit.swiftTestingSuiteMetadata != nil else { return nil }
                if historical, let base {
                    if baseSuites == nil { baseSuites = SuiteIndex(base) }
                    return baseSuites?.factory(of: unit)
                }
                if headSuites == nil { headSuites = SuiteIndex(head) }
                return headSuites?.factory(of: unit)
            }
            return (historical ? baseProof : headProof)?.factory(of: unit)?.id
        }

        var survivingFactories: [String: String] = [:]
        let previousDeclarations = declarations(before)
        for (identity, units) in declarations(after) {
            guard units.count == 1, let unit = units.first,
                  base == nil || unit.swiftTestingRole == "suite",
                  let prior = previousDeclarations[identity], prior.count == 1, let old = prior.first,
                  entryEdits[unit.key] == nil,
                  (old.swiftTestingArguments ?? []).map({ $0.comparison(policy) }) !=
                    (unit.swiftTestingArguments ?? []).map({ $0.comparison(policy) }),
                  (old.swiftTestingRole != "suite" || historicalSuites.canBind(old)),
                  let id = factory(of: unit, historical: false) else { continue }
            if base == nil {
                survivingFactories[old.key] = id
                registrationEdits[unit.key] = old.key
            }
            guard let inputs = unit.swiftTestingSuiteInputs, let historical = old.swiftTestingSuiteInputs,
                  inputs.eager.isEmpty, historical.eager.isEmpty,
                  let proof = head.dependencies?.functions[id]?.swiftTestingDeferredConditions,
                  proof.matches(inputs.conditions ?? .init()) else { continue }
            if let base {
                guard let oldID = factory(of: old, historical: true),
                      base.dependencies?.functions[oldID]?.swiftTestingDeferredConditions?.matches(historical.conditions ?? .init()) == true else { continue }
            } else {
                // A bare suite had no arguments to evaluate. Otherwise require stable source
                // evidence before applying the head factory’s overload binding to the base.
                guard historical.bare == true || inputs.declaration == historical.declaration,
                      (inputs.nonliteralPredicates ?? []).map({ $0.comparison(policy) }) ==
                        (historical.nonliteralPredicates ?? []).map({ $0.comparison(policy) }) else { continue }
            }
            suiteArgumentEdits[unit.key] = old.key
        }

        var scopedSuites = Set<String>()
        for (key, group) in after where group.count == 1 {
            let unit = group[0]
            guard paths.contains(unit.region.path), let previous = before[suiteArgumentEdits[key] ?? registrationEdits[key] ?? key], previous.count == 1,
                  previous[0].region.path == unit.region.path, previous[0].conditionalBranch == unit.conditionalBranch else { continue }
            if base == nil, unit.swiftTestingBodyCandidate == true, previous[0].swiftTestingBodyCandidate == true,
               previous[0].fingerprint != unit.fingerprint, headProof.provesInputs(of: unit, requireEmpty: true) {
                supportedBodies.insert(key)
            }
            guard let a = previous[0].swiftTestingSuiteMetadata, let b = unit.swiftTestingSuiteMetadata,
                  suiteArgumentEdits[key] != nil || a.comparison(policy) != b.comparison(policy) else { continue }
            if headSuites == nil { headSuites = SuiteIndex(head) }
            guard historicalSuites.canBind(previous[0]), let tests = headSuites?.members(of: unit) else { continue }
            if let base {
                if baseSuites == nil { baseSuites = SuiteIndex(base) }
                guard let oldTests = baseSuites?.members(of: previous[0]) else { continue }
                suiteTests.formUnion(oldTests.members)
                uncertainSuiteTests.formUnion(oldTests.uncertain)
            }
            scopedSuites.insert(key)
            scopedSuites.insert(previous[0].key)
            suitePaths.insert(unit.region.path)
            suiteTests.formUnion(tests.members)
            uncertainSuiteTests.formUnion(tests.uncertain)
        }

        typealias Headers = [String: [[String]: [SourceUnit]]]
        func headers(_ groups: [String: [SourceUnit]], sources: [String: SwiftSourceSnapshot],
                     moves: [String: String], excluding: Set<String>) -> Headers {
            var result: Headers = [:]
            for (key, group) in groups where !excluding.contains(key) {
                let module = String(key.prefix { $0 != ":" })
                for unit in group {
                    let path = unit.region.path, destination = moves[path] ?? path
                    let suite = scopedSuites.contains(key) ? nil : unit.swiftTestingSuiteMetadata
                    for record in (unit.swiftTestingArguments ?? []) + [suite].compactMap({ $0 }) {
                        let signature = [module, unit.conditionalBranch ?? ""] + record.comparison(policy)
                        result[destination, default: [:]][signature, default: []].append(unit)
                    }
                    if paths.contains(path), let file = sources[module + ":" + path],
                       !file.hasSwiftTestingRegistrationMetadata,
                       unit.swiftTestingRole != nil || (unit.kind == "function" && head.dependencies?.functions[SwiftTestingDiscoveryRoots.sharedDiscoveryID] != nil) ||
                           (unit.kind == "declaration" &&
                           file.swiftTestingDeclarations?.tests.contains(where: { $0.intersects(unit.region) }) == true) {
                        incompletePaths.insert(destination)
                    }
                }
            }
            return result
        }
        let lhs = headers(before, sources: baseSources, moves: moves, excluding: Set(entryEdits.values).union(suiteArgumentEdits.values))
        let rhs = headers(after, sources: head.sources, moves: [:], excluding: Set(entryEdits.keys).union(suiteArgumentEdits.keys))
        for path in Set(lhs.keys).union(rhs.keys) {
            let left = lhs[path] ?? [:], right = rhs[path] ?? [:]
            for signature in Set(left.keys).union(right.keys) {
                let a = left[signature] ?? [], b = right[signature] ?? []
                guard a.count != b.count else { continue }
                discoveryPaths.insert(path)
                for unit in b { headDiscovery.record(unit, factory: factory(of: unit, historical: false)) }
                for unit in a {
                    if base != nil { baseDiscovery.record(unit, factory: factory(of: unit, historical: true)) }
                    else if let factory = survivingFactories[unit.key] {
                        headDiscovery.factories.insert(factory)
                    } else {
                        // The head image cannot place a historical registration
                        // without a matching source declaration.
                        headDiscovery.unbounded = true
                    }
                }
            }
        }
        if let before = base?.dependencies, let after = head.dependencies {
            for (old, new) in Self.reboundDiscoveryCalls(before: before, after: after) {
                rebound = true
                baseDiscovery.factories.insert(old)
                headDiscovery.factories.insert(new)
            }
        }
    }

    private struct DiscoveryChange {
        var factories = Set<String>()
        var modules = Set<String>()
        var unbounded = false

        mutating func record(_ unit: SourceUnit, factory: String?) {
            if let factory { factories.insert(factory) }
            else { modules.insert(String(unit.key.prefix { $0 != ":" })) }
        }
    }

    func discoveryRoots(in graph: DependencyGraph, base: Bool = false) -> Set<String> {
        guard changedDiscovery else { return [] }
        let change = base ? baseDiscovery : headDiscovery
        let shared = SwiftTestingDiscoveryRoots.sharedDiscoveryID
        guard !change.unbounded, incompletePaths.isEmpty, let inventories = graph.swiftTestingFactoriesByTarget else { return [shared] }
        guard !change.factories.isEmpty || !change.modules.isEmpty else { return [] }
        var targets = Set<String>()
        for (test, roots) in graph.tests where roots.contains(shared) {
            let target = String(test.prefix { $0 != "/" })
            guard roots.contains(SwiftTestingDiscoveryRoots.processRoot(target)) else { return [shared] }
            targets.insert(target)
        }
        var result = Set<String>()
        for target in targets {
            let process = SwiftTestingDiscoveryRoots.processRoot(target)
            guard let linked = inventories[target] else { result.insert(process); continue }
            if !linked.isDisjoint(with: change.factories) || (!change.modules.isEmpty && linked.contains {
                graph.functions[$0].map { change.modules.contains($0.module) } ?? true
            }) { result.insert(process) }
        }
        return result
    }

    func uncertainty(in snapshot: XcodeTestGraph) -> (message: String, tests: Set<String>)? {
        guard changedDiscovery, let graph = snapshot.dependencies else { return nil }
        let root = SwiftTestingDiscoveryRoots.sharedDiscoveryID
        if graph.functions[root] == nil {
            return ("Swift Testing registration changed without compiled discovery roots", Set(snapshot.tests))
        }
        let incomplete = Set(snapshot.tests.filter { test in
            let roots = graph.tests[test] ?? []
            return roots.isEmpty || graph.testDiagnostics[test]?.contains(SwiftTestingDiscoveryRoots.missingEvidence) == true ||
                (!incompletePaths.isEmpty && roots.contains(root))
        })
        guard !incomplete.isEmpty else { return nil }
        return ("Swift Testing registration evidence is incomplete for the changed sources or test entries", incomplete)
    }

    /// Index nominal owners once. A single insertion can move many suite bounds.
    private struct SuiteIndex {
        let written: SwiftTestingSuiteDeclarations
        var factories: [String: [String]] = [:]
        let linkedByTarget: [String: Set<String>]
        var testsBySuite: [String: Set<String>] = [:]
        var unresolved = Set<String>()

        init(_ snapshot: XcodeTestGraph) {
            written = SwiftTestingSuiteDeclarations(snapshot.sources)
            linkedByTarget = snapshot.dependencies?.swiftTestingFactoriesByTarget ?? [:]
            guard let graph = snapshot.dependencies else { return }
            for node in graph.functions.values {
                guard let type = node.swiftTestingFactoryType,
                      node.compilerReferences?.contains(where: { $0.hasPrefix("$s7Testing4TestV6__type") }) == true else { continue }
                factories[node.module + "." + type, default: []].append(node.id)
            }
            for test in snapshot.tests {
                let roots = graph.tests[test] ?? []
                if roots.isEmpty || graph.testDiagnostics[test]?.contains(SwiftTestingDiscoveryRoots.missingEvidence) == true {
                    unresolved.insert(test)
                    continue
                }
                guard roots.contains(SwiftTestingDiscoveryRoots.sharedDiscoveryID) else { continue }
                let method = test.split(separator: "/").dropFirst().joined(separator: ".")
                let nodes = roots.compactMap { graph.functions[$0] }
                let entries = nodes.filter { $0.name == method || $0.name == "static " + method }
                if let owner = SwiftTestingDiscoveryRoots.nominalOwner(of: entries) {
                    for suite in SwiftTestingDiscoveryRoots.enclosingSuites(of: owner) {
                        testsBySuite[suite, default: []].insert(test)
                    }
                } else if !nodes.contains(where: { $0.swiftTestingEmptyFactory == "top-level" }) {
                    unresolved.insert(test)
                }
            }
        }

        func factory(of unit: SourceUnit) -> String? {
            guard written.canBind(unit), let name = unit.swiftTestingSuiteName,
                  let matches = factories[String(unit.key.prefix { $0 != ":" }) + "." + name], matches.count == 1 else { return nil }
            return matches.first
        }

        func members(of unit: SourceUnit) -> (members: Set<String>, uncertain: Set<String>)? {
            guard let name = unit.swiftTestingSuiteName, let id = factory(of: unit) else { return nil }
            let suite = String(unit.key.prefix { $0 != ":" }) + "." + name
            func mayLoadFactory(_ test: String) -> Bool {
                linkedByTarget[String(test.prefix { $0 != "/" })]?.contains(id) != false
            }
            return ((testsBySuite[suite] ?? []).filter(mayLoadFactory), unresolved.filter(mayLoadFactory))
        }
    }

    /// Bind an unambiguous source entry to its single compiler-emitted factory.
    /// Index by source file once, including tests with overlapping entry regions.
    struct FactoryIndex {
        let snapshot: XcodeTestGraph
        var entries: [String: [(SourceRegion, String)]] = [:]
        var unmodeledPaths = Set<String>()

        init(_ snapshot: XcodeTestGraph, inspecting paths: Set<String>) {
            self.snapshot = snapshot
            guard let graph = snapshot.dependencies, !graph.tests.isEmpty else { return }
            let targets = Set(snapshot.targets.filter { !$0.sourceFiles.isDisjoint(with: paths) }.map(\.name))
            guard !targets.isEmpty else { return }
            for test in snapshot.tests {
                let roots = graph.tests[test] ?? []
                let parts = test.split(separator: "/")
                guard let target = parts.first.map(String.init), targets.contains(target), let module = snapshot.modules[target] else { continue }
                let method = parts.dropFirst().joined(separator: ".")
                let isRegistration = roots.contains(SwiftTestingDiscoveryRoots.sharedDiscoveryID) ||
                    roots.contains { graph.functions[$0]?.swiftTestingDiscoveryReferences != nil }
                for id in roots {
                    guard let node = graph.functions[id], node.module == module,
                          node.name == method || node.name == "static " + method else { continue }
                    for region in node.regions where paths.contains(region.path) {
                        let fileKey = module + ":" + region.path
                        entries[fileKey, default: []].append((region, test))
                        if isRegistration,
                           snapshot.sources[fileKey]?.swiftTestingDeclarations?.tests.contains(where: { $0.intersects(region) }) != true {
                            unmodeledPaths.insert(region.path)
                        }
                    }
                }
            }
        }

        /// Each written test attribute must have a surviving declaration and a
        /// single empty SDK factory. Historical locations can move between builds.
        func provesTestsWithoutRuntimeInputs(in file: SwiftSourceSnapshot, fileKey: String) -> Bool {
            guard let head = snapshot.sources[fileKey], file.hasSwiftTestingRegistrationMetadata,
                  let issues = file.helperDeclarationIssues,
                  issues.allSatisfy({ ["@inline", "@_transparent", "@Test", "@Testing.Test", "#expect", "#require"].contains($0.spelling) }) else { return false }
            let attributes = issues.filter { ["@Test", "@Testing.Test"].contains($0.spelling) }
            let tests = file.units.filter { $0.swiftTestingRole == "test" }
            let current = head.units.filter { $0.swiftTestingRole == "test" }
            guard !tests.isEmpty, attributes.count == tests.count, tests.map(\.key) == current.map(\.key),
                  tests.allSatisfy({ $0.swiftTestingEntryInputs?.hasNoRuntimeInputs == true }) else { return false }
            return current.allSatisfy { provesInputs(of: $0, requireEmpty: true) }
        }

        func factory(of unit: SourceUnit) -> FunctionNode? {
            guard unit.swiftTestingRole == "test", let graph = snapshot.dependencies else { return nil }
            let module = String(unit.key.prefix { $0 != ":" }), fileKey = module + ":" + unit.region.path
            let owners = snapshot.targets.filter { $0.sourceFiles.contains(unit.region.path) }
            guard !owners.isEmpty, owners.allSatisfy(\.isTest),
                  let file = snapshot.sources[fileKey], file.hasSwiftTestingRegistrationMetadata,
                  file.units.filter({ $0.kind == "function" && $0.region.intersects(unit.region) }).count == 1 else { return nil }
            let matches = Set((entries[fileKey] ?? []).compactMap { $0.0.intersects(unit.region) ? $0.1 : nil })
            guard matches.count == 1, let test = matches.first,
                  graph.testDiagnostics[test]?.contains(SwiftTestingDiscoveryRoots.missingEvidence) != true else { return nil }
            let factories = (graph.tests[test] ?? []).compactMap { graph.functions[$0] }.filter {
                $0.compilerReferences?.contains { $0.hasPrefix("$s7Testing4TestV10__function") } == true
            }
            return factories.count == 1 ? factories.first : nil
        }

        func provesInputs(of unit: SourceUnit, requireEmpty: Bool = false) -> Bool {
            guard let inputs = unit.swiftTestingEntryInputs, let factory = factory(of: unit) else { return false }
            if requireEmpty { return inputs.hasNoRuntimeInputs && ["member", "top-level"].contains(factory.swiftTestingEmptyFactory) }
            if let conditions = inputs.conditions {
                return factory.swiftTestingDeferredConditions?.matches(conditions) == true &&
                    (inputs.providers == 0 || factory.swiftTestingDeferredProviderCount == inputs.providers)
            }
            if inputs.bare == true { return true }
            if inputs.providers == 0 {
                return inputs.eager.isEmpty && ["member", "top-level"].contains(factory.swiftTestingEmptyFactory)
            }
            return factory.swiftTestingDeferredProviderCount == inputs.providers &&
                factory.swiftTestingExistentialTypes?.isEmpty == inputs.eager.isEmpty
        }
    }

    /// Moving a registration can change its generated symbol while keeping the
    /// enumerated entry stable. Compare its eager callees by compiler identity.
    /// Surviving symbols distinguish rebinding from a whole-file private rename.
    private static func reboundDiscoveryCalls(before: DependencyGraph, after: DependencyGraph) -> [(String, String)] {
        let shared = SwiftTestingDiscoveryRoots.sharedDiscoveryID
        guard before.functions[shared] != nil, after.functions[shared] != nil else { return [] }
        func factory(_ roots: Set<String>, in graph: DependencyGraph) -> FunctionNode? {
            let factories = roots.compactMap { graph.functions[$0] }.filter { $0.swiftTestingDiscoveryReferences != nil }
            return factories.count == 1 ? factories.first : nil
        }
        return before.tests.compactMap { test, roots in
            guard let current = after.tests[test], let old = factory(roots, in: before), let new = factory(current, in: after),
                  let lhs = old.swiftTestingDiscoveryReferences, let rhs = new.swiftTestingDiscoveryReferences,
                  lhs.symmetricDifference(rhs).contains(where: {
                      before.functions[$0]?.regions.isEmpty == false && after.functions[$0]?.regions.isEmpty == false
                  }) else { return nil }
            return (old.id, new.id)
        }
    }
}
