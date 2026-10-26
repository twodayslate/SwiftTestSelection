// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation

/// Combines syntax accessibility/escape evidence with actual head consumers.
/// This proof is independent of app feature mappings and opaque SDK dispatch.
enum PrivateTestHelperIsolation {
    static func proves(_ unit: SourceUnit, previous: SourceUnit?, current: XcodeTestGraph,
                       base: [String: SwiftSourceSnapshot], graph: DependencyGraph, index: DependencyIndex) -> Bool {
        guard let syntax = unit.privateTestHelper, syntax.statements != nil, unit.headOnlyBodySupported == true,
              previous == nil || (previous?.headOnlyBodySupported == true &&
                  previous?.privateTestHelper.map { syntax.preservesEffects(of: $0) } == true),
              current.tests.allSatisfy({ test in
                  guard let roots = graph.tests[test], !roots.isEmpty, graph.testDiagnostics[test]?.isEmpty ?? true else { return false }
                  return roots.allSatisfy { graph.functions[$0] != nil }
              }) else { return false }
        let module = String(unit.key.prefix { $0 != ":" })
        let owners = current.targets.filter { $0.sourceFiles.contains(unit.region.path) }
        guard !owners.isEmpty, owners.allSatisfy({ $0.isTest && !$0.hasProductionRole && current.modules[$0.name] == module }),
              current.unsupportedSourceInputs?[module]?.isEmpty ?? true,
              current.unresolvedProductRoles?[module] == nil else { return false }
        let headSources = Array(current.sources.values), baseSources = Array(base.values)
        guard (headSources + baseSources).allSatisfy({ $0.helperNamesUnshadowed == true }) else { return false }
        let headUnits = headSources.flatMap(\.units), baseUnits = baseSources.flatMap(\.units)
        func snapshotsInModule(_ snapshots: [String: SwiftSourceSnapshot]) -> [SwiftSourceSnapshot] {
            snapshots.filter { key, snapshot in
                key.hasPrefix(module + ":") || snapshot.units.contains { $0.key.hasPrefix(module + ":") }
            }.map(\.value)
        }
        let moduleSources = snapshotsInModule(current.sources)
        let oldModuleSources = snapshotsInModule(base)
        // No missing module source, legacy evidence, overload in another file, or
        // inaccessible extension/alias may be mistaken for a closed caller set.
        let capturedPaths = Set(moduleSources.flatMap(\.units).map { $0.region.path }).union(
            current.sources.keys.filter { $0.hasPrefix(module + ":") }.map { String($0.dropFirst(module.count + 1)) })
        guard current.targets.filter({ current.modules[$0.name] == module }).allSatisfy({ Set($0.sourceFiles).isSubset(of: capturedPaths) }),
              (moduleSources + oldModuleSources).allSatisfy({ $0.identifierNames != nil && $0.helperSafeClasses != nil }),
              moduleSources.filter({ !$0.units.contains { $0.region.path == unit.region.path } }).allSatisfy({ !$0.identifierNames!.contains(syntax.name) }),
              oldModuleSources.filter({ previous == nil || !$0.units.contains { $0.region.path == unit.region.path } }).allSatisfy({ !$0.identifierNames!.contains(syntax.name) }),
              safeHierarchy(unit.scope, module: module, sources: moduleSources),
              safeHierarchy(unit.scope, module: module, sources: oldModuleSources),
              !(headUnits + baseUnits).contains(where: { $0.kind == "extension" && [$0.scope, module + "." + $0.scope].contains(module + "." + unit.scope) }),
              Set(headUnits.filter { $0.kind == "function" && $0.region.intersects(unit.region) }.map(\.key)) == [unit.key] else { return false }
        let ids = symbols(unit, graph: graph, index: index)
        guard !ids.isEmpty else { return false }
        let paths = index.paths(to: ids)
        var callers = headUnits.filter { $0.region.path == unit.region.path && $0.key.hasPrefix(module + ":") &&
            $0.kind == "function" && syntax.callerLines.contains($0.region.startLine) }
        guard callers.count == syntax.callerLines.count else { return false }
        if let previous, let oldSyntax = previous.privateTestHelper {
            let oldCallers = baseUnits.filter { $0.region.path == previous.region.path && $0.key.hasPrefix(module + ":") &&
                $0.kind == "function" && oldSyntax.callerLines.contains($0.region.startLine) }
            guard oldCallers.count == oldSyntax.callerLines.count else { return false }
            // Changed/deleted headers have no historical graph proof. Even old
            // callers which stopped calling the helper must survive as entries.
            for old in oldCallers {
                let surviving = headUnits.filter { $0.key == old.key && $0.region.path == old.region.path }
                guard surviving.count == 1 else { return false }
                callers += surviving
            }
        }
        guard callers.allSatisfy({ $0.headOnlyBodySupported == true && XcodeFineSelector.isTestEntry($0, in: current) }) else { return false }
        let callerSymbols = callers.reduce(into: Set<String>()) { $0.formUnion(symbols($1, graph: graph, index: index)) }
        let expectedTests = Set(current.tests.filter { !(graph.tests[$0] ?? []).isDisjoint(with: callerSymbols) })
        let consumers = Set(current.tests.filter { paths.path(from: graph.tests[$0] ?? []) != nil })
        // At least one compiled consumer and a path for every current syntactic
        // caller. Removed old calls need not have a surviving edge.
        guard !consumers.isEmpty, consumers.isSubset(of: expectedTests),
              callers.filter({ syntax.callerLines.contains($0.region.startLine) }).allSatisfy({
                  paths.path(from: symbols($0, graph: graph, index: index)) != nil
              }) else { return false }
        // Reject compiler-observed state/pointer effects in project callees too,
        // including extension helpers reached from the changed body. SDK runtime
        // uncertainty alone is not a route into this private, nonescaping method.
        let projectModules = Set(current.modules.values)
        var pending = Array(ids), visited = Set<String>()
        while let id = pending.popLast() {
            guard visited.insert(id).inserted, let node = graph.functions[id] else { continue }
            if projectModules.contains(node.module) && node.hasProjectRuntimeContext &&
                (!node.uncertainties.isDisjoint(with: ["Global state access", "Shared state access", "Raw pointer operation"])) { return false }
            pending += node.dependencies.filter { graph.functions[$0].map { projectModules.contains($0.module) } ?? false }
        }
        return true
    }

    private static func symbols(_ unit: SourceUnit, graph: DependencyGraph, index: DependencyIndex) -> Set<String> {
        let module = String(unit.key.prefix { $0 != ":" })
        return Set((index.byFile[unit.region.path] ?? []).filter { id in
            let node = graph.functions[id]!
            return node.module == module && node.regions.contains { $0.path == unit.region.path &&
                $0.startLine >= unit.region.startLine && $0.startLine <= unit.region.endLine }
        })
    }

    private static func safeHierarchy(_ name: String, module: String, sources: [SwiftSourceSnapshot]) -> Bool {
        let classes = sources.flatMap { ($0.helperSafeClasses ?? [:]).map { ($0.key, $0.value) } }
        let aliases = Set(sources.flatMap { $0.typeAliases ?? [] })
        var name = name, visited = Set<String>()
        while visited.insert(name).inserted {
            let qualified = name.hasPrefix(module + ".") ? name : module + "." + name
            guard !aliases.contains(qualified) else { return false }
            let matches = classes.filter { $0.0 == qualified }
            if ["XCTestCase", "XCTest.XCTestCase"].contains(name) {
                return matches.isEmpty && !sources.flatMap(\.units).contains { $0.kind == "type" && $0.scope == name }
            }
            let declarations = sources.flatMap(\.units).filter { $0.key.hasPrefix(module + ":") &&
                $0.kind == "type" && module + "." + $0.scope == qualified }
            guard matches.count == 1, declarations.count == 1 else { return false }
            name = matches[0].1
        }
        return false
    }
}
