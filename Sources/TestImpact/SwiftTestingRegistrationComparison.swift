// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
import Foundation

/// One comparison of Swift Testing registrations for both Xcode selection modes.
/// An entry-local projection requires matching source declarations and a compiler
/// proof. Everything else contributes its full inputs to shared discovery.
struct SwiftTestingRegistrationComparison {
    private(set) var entryEdits: [String: String] = [:]
    private(set) var discoveryPaths = Set<String>()
    private(set) var incompletePaths = Set<String>()
    private let rebound: Bool
    var changedDiscovery: Bool { rebound || !discoveryPaths.isEmpty || !incompletePaths.isEmpty }

    init(before: [String: [SourceUnit]], after: [String: [SourceUnit]], baseSources: [String: SwiftSourceSnapshot],
         base: XcodeTestGraph? = nil, head: XcodeTestGraph, moves: [String: String] = [:],
         touching paths: Set<String>, policy: UIFeatureMappings.SourceLocationPolicy) {
        rebound = Self.reboundDiscoveryCall(before: base?.dependencies, after: head.dependencies)
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

        typealias Headers = [String: [[String]: Int]]
        func headers(_ groups: [String: [SourceUnit]], sources: [String: SwiftSourceSnapshot],
                     moves: [String: String], excluding: Set<String>) -> Headers {
            var result: Headers = [:]
            for (key, group) in groups where !excluding.contains(key) {
                let module = String(key.prefix { $0 != ":" })
                for unit in group {
                    let path = unit.region.path, destination = moves[path] ?? path
                    if let records = unit.swiftTestingArguments {
                        for record in records {
                            let signature = [module, unit.conditionalBranch ?? ""] + record.comparison(policy)
                            result[destination, default: [:]][signature, default: 0] += 1
                        }
                    }
                    if paths.contains(path), let file = sources[module + ":" + path],
                       file.parserVersion != SwiftSourceSnapshot.currentParserVersion,
                       unit.swiftTestingRole != nil || (unit.kind == "declaration" &&
                           file.swiftTestingDeclarations?.tests.contains(where: { $0.intersects(unit.region) }) == true) {
                        incompletePaths.insert(destination)
                    }
                }
            }
            return result
        }
        let lhs = headers(before, sources: baseSources, moves: moves, excluding: Set(entryEdits.values))
        let rhs = headers(after, sources: head.sources, moves: [:], excluding: Set(entryEdits.keys))
        discoveryPaths = Set(lhs.keys).union(rhs.keys).filter { lhs[$0] != rhs[$0] }
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

    /// Bind an unambiguous source entry to its single compiler-emitted factory.
    /// Index by source file once, including tests with overlapping entry regions.
    private struct FactoryIndex {
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

        func provesInputs(of unit: SourceUnit) -> Bool {
            guard let graph = snapshot.dependencies, let inputs = unit.swiftTestingEntryInputs else { return false }
            let module = String(unit.key.prefix { $0 != ":" }), fileKey = module + ":" + unit.region.path
            let owners = snapshot.targets.filter { $0.sourceFiles.contains(unit.region.path) }
            guard !owners.isEmpty, owners.allSatisfy(\.isTest),
                  let file = snapshot.sources[fileKey], file.parserVersion == SwiftSourceSnapshot.currentParserVersion,
                  file.units.filter({ $0.kind == "function" && $0.region.intersects(unit.region) }).count == 1 else { return false }
            let matches = Set((entries[fileKey] ?? []).compactMap { $0.0.intersects(unit.region) ? $0.1 : nil })
            guard matches.count == 1, let test = matches.first,
                  graph.testDiagnostics[test]?.contains(SwiftTestingDiscoveryRoots.missingEvidence) != true else { return false }
            let factories = (graph.tests[test] ?? []).compactMap { graph.functions[$0] }.filter {
                $0.compilerReferences?.contains { $0.hasPrefix("$s7Testing4TestV10__function") } == true
            }
            guard factories.count == 1, let factory = factories.first else { return false }
            if let conditions = inputs.conditions {
                return factory.swiftTestingDeferredConditions == conditions &&
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
    private static func reboundDiscoveryCall(before: DependencyGraph?, after: DependencyGraph?) -> Bool {
        guard let before, let after, before.functions[SwiftTestingDiscoveryRoots.sharedDiscoveryID] != nil, after.functions[SwiftTestingDiscoveryRoots.sharedDiscoveryID] != nil else { return false }
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
}
