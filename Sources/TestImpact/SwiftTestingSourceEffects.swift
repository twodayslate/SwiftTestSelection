// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

/// Source and compiler evidence that can rule out two otherwise unobservable
/// effects: a removed inline call edge, or a caller-supplied location operand.
struct SwiftTestingSourceEffects {
    private(set) var unusedInline = Set<String>()
    private(set) var positionIndependent = Set<String>()

    init(_ snapshot: XcodeTestGraph, touching paths: Set<String>, historical: [String: SwiftSourceSnapshot]? = nil) {
        guard let graph = snapshot.dependencies, graph.functions[SwiftTestingDiscoveryRoots.sharedDiscoveryID] != nil else { return }
        unusedInline = Self.unusedBodies(snapshot.sources, in: snapshot, touching: paths)
        if let historical { unusedInline.formIntersection(Self.unusedBodies(historical, in: snapshot, touching: paths)) }

        let candidates = snapshot.sources.filter {
            guard let path = $0.value.units.first?.region.path, paths.contains(path) else { return false }
            return $0.value.units.contains { $0.hasOnlyDirectSourceCalls == true }
        }
        guard !candidates.isEmpty else { return }
        let units = snapshot.sources.values.flatMap(\.units).filter { $0.kind == "function" }
        let functions = Dictionary(grouping: units, by: { $0.helperCallableName ?? "" })
        let oldFunctions = historical.map { sources in
            Dictionary(grouping: sources.values.flatMap(\.units).filter { $0.kind == "function" }, by: { $0.helperCallableName ?? "" })
        }
        let symbols = Dictionary(grouping: graph.functions.values.filter { !$0.regions.isEmpty }, by: \.name)
        for (fileKey, file) in candidates where file.receiverPhysicalLocations == true {
            let old = historical?[fileKey]
            if historical != nil {
                guard let old, old.receiverPhysicalLocations == true, old.units.map(\.key) == file.units.map(\.key) else { continue }
            }
            let oldDirectCallers = Set(old?.units.filter { $0.hasOnlyDirectSourceCalls == true }.map(\.key) ?? [])
            for unit in file.units where unit.hasOnlyDirectSourceCalls == true {
                guard let names = unit.invocationNames, let signature = unit.helperReferenceSignature,
                      let caller = Self.symbol(for: unit, among: symbols[signature]),
                      let refs = caller.compilerReferences, refs.count == names.count,
                      caller.dynamicDeclarations.isEmpty, !caller.hasOpaqueRuntimeDependency else { continue }
                // Bind each distinct written call to an actual local implementation
                // with a complete, default-free source signature. Extra references,
                // erased calls, macros and overload ambiguity retain all dimensions.
                var targets: [SourceUnit] = []
                for name in names {
                    let matches = (functions[name] ?? []).filter {
                        guard $0.scope.isEmpty, $0.conditionalBranch == nil, $0.hasInlineBody != true,
                              let signature = $0.helperReferenceSignature,
                              let callee = Self.symbol(for: $0, among: symbols[signature]) else { return false }
                        return refs.contains(callee.id)
                    }
                    if matches.count == 1 { targets.append(matches[0]) }
                }
                guard targets.count == names.count else { continue }
                if historical != nil {
                    // With only head SIL, limit the proof to a stable file-local
                    // lookup. Additional overloads or changed source inputs could
                    // have selected a different default in the historical build.
                    guard oldDirectCallers.contains(unit.key), targets.allSatisfy({ $0.region.path == unit.region.path &&
                              $0.key.prefix(while: { $0 != ":" }) == unit.key.prefix(while: { $0 != ":" }) &&
                              functions[$0.helperCallableName ?? ""]?.count == 1 &&
                              oldFunctions?[$0.helperCallableName ?? ""]?.map(\.key) == [$0.key]
                          }) else { continue }
                }
                positionIndependent.insert(unit.key)
            }
        }
    }

    private static func symbol(for unit: SourceUnit, among candidates: [FunctionNode]?) -> FunctionNode? {
        let module = String(unit.key.prefix { $0 != ":" })
        let matches = candidates?.filter { node in
            node.module == module && node.regions.contains {
                $0.path == unit.region.path && $0.startLine >= unit.region.startLine && $0.endLine <= unit.region.endLine
            }
        }
        return matches?.count == 1 ? matches?.first : nil
    }

    private static func unusedBodies(_ sources: [String: SwiftSourceSnapshot], in snapshot: XcodeTestGraph, touching paths: Set<String>) -> Set<String> {
        let candidates = sources.values.flatMap { $0.units.filter { $0.fileUnreferencedInlineName != nil && paths.contains($0.region.path) } }
        guard !candidates.isEmpty, snapshot.diagnostics.isEmpty,
              snapshot.unsupportedSourceInputs?.values.allSatisfy(\.isEmpty) != false,
              snapshot.targets.allSatisfy({ target in
                  guard let module = snapshot.modules[target.name] else { return target.sourceFiles.isEmpty }
                  return target.sourceFiles.filter { $0.hasSuffix(".swift") }.allSatisfy { sources[module + ":" + $0] != nil }
              }) else { return [] }
        // Unknown expansions or external entry points can introduce calls with
        // no written identifier. Retain the inline fallback in that case.
        let testingSyntax: Set<String> = ["@Test", "@Testing.Test", "@Suite", "@Testing.Suite", "#expect", "#require", "@inline", "@_transparent"]
        guard sources.values.allSatisfy({ file in
            file.identifierNames != nil && file.diagnostics.isEmpty &&
                file.helperDeclarationIssues?.allSatisfy { testingSyntax.contains($0.spelling) && $0.kind != "macro-declaration" } == true &&
                file.units.allSatisfy { $0.receiverUnsupportedImports?.subtracting(["import Testing"]).isEmpty == true }
        }) else { return [] }
        let names = Set(candidates.compactMap(\.fileUnreferencedInlineName))
        var fileCounts: [String: Int] = [:]
        for file in sources.values {
            for name in names.intersection(file.identifierNames ?? []) { fileCounts[name, default: 0] += 1 }
        }
        return Set(candidates.compactMap { unit in
            guard let name = unit.fileUnreferencedInlineName, fileCounts[name] == 1 else { return nil }
            return unit.key
        })
    }
}
