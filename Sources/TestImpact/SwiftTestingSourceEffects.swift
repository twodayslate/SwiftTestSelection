// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

/// Source and compiler evidence that can rule out two otherwise unobservable
/// effects: a removed inline call edge, or a caller-supplied location operand.
struct SwiftTestingSourceEffects {
    struct Declaration: Hashable {
        let path: String
        let key: String

        init(_ unit: SourceUnit) {
            path = unit.region.path
            key = unit.key
        }
    }

    private(set) var unusedInline = Set<Declaration>()
    private(set) var positionIndependent = Set<Declaration>()

    init(_ snapshot: XcodeTestGraph, touching paths: Set<String>, historical: [String: SwiftSourceSnapshot]? = nil,
         unowned: [String: SwiftSourceSnapshot] = [:], hasAuditedCallerInputs: Bool = true) {
        guard snapshot.dependencies != nil else { return }
        unusedInline = Self.unusedBodies(snapshot.sources, in: snapshot, touching: paths, unowned: [:], exactRevision: historical == nil)
        if let historical {
            unusedInline.formIntersection(Self.unusedBodies(historical, in: snapshot, touching: paths, unowned: unowned, exactRevision: false))
        }

        if hasAuditedCallerInputs {
            positionIndependent = Self.positionIndependentCallers(snapshot, touching: paths, historical: historical, unowned: unowned)
        }
    }

    static func positionIndependentCallers(_ snapshot: XcodeTestGraph, touching paths: Set<String>,
                                           historical: [String: SwiftSourceSnapshot]?, unowned: [String: SwiftSourceSnapshot] = [:]) -> Set<Declaration> {
        guard let graph = snapshot.dependencies, graph.functions[SwiftTestingDiscoveryRoots.sharedDiscoveryID] != nil else { return [] }
        let candidates = snapshot.sources.filter {
            guard let path = $0.value.units.first?.region.path, paths.contains(path) else { return false }
            return $0.value.units.contains { $0.hasOnlyDirectSourceCalls == true }
        }
        guard !candidates.isEmpty else { return [] }
        // With no historical SIL, a competing overload in uninspected input
        // could have supplied a caller-location default in the base build.
        if let historical {
            guard snapshot.hasCompleteSwiftSourceInventory(snapshot.sources),
                  historical.keys == snapshot.sources.keys else { return [] }
            // Even an unchanged function header can bind differently after an edit
            // to a typealias, inferred type, import, or conformance in another file.
            // Reuse the head binding only across identical inputs or a trivia edit
            // in the inspected files whose complete declaration syntax is stable.
            for (key, head) in snapshot.sources {
                guard let base = historical[key], base.diagnostics.isEmpty, head.diagnostics.isEmpty else { return [] }
                if let blobs = head.sourceBlobIDs, base.sourceBlobIDs?.isDisjoint(with: blobs) == false { continue }
                guard let path = head.units.first?.region.path, paths.contains(path),
                      head.helperDeclarationsComplete == true, base.helperDeclarationsComplete == true,
                      head.units.elementsEqual(base.units, by: {
                          $0.key == $1.key && $0.conditionalBranch == $1.conditionalBranch &&
                              ($0.syntaxFingerprint ?? $0.fingerprint) == ($1.syntaxFingerprint ?? $1.fingerprint)
                      }) else { return [] }
            }
        }
        // An unowned base file might previously have contributed an overload.
        // Only top-level bindings in a closed file participate in lookup.
        var unownedNames = Set<String>()
        for file in unowned.values {
            guard file.diagnostics.isEmpty, file.helperDeclarationsComplete == true,
                  file.helperImportsLocal == true, file.typeAliases?.isEmpty == true,
                  file.helperOperatorDeclarations?.isEmpty == true,
                  file.units.allSatisfy({ $0.helperInheritedTypes?.isEmpty == true && $0.kind != "extension" }),
                  let declarations = file.helperGlobalDeclarations else { return [] }
            unownedNames.formUnion(declarations.keys)
            for unit in file.units where unit.kind == "type" && !unit.scope.contains(".") {
                unownedNames.insert(SDKTestHelperSyntax.canonicalName(unit.scope))
            }
        }
        // An unowned declaration can change a type used in a callee's signature
        // through an intermediate file, even when the callee's own name is unique.
        if !unownedNames.isEmpty, !snapshot.sources.values.allSatisfy({
            $0.identifierNames?.isDisjoint(with: unownedNames) == true
        }) { return [] }
        var callers = Set<Declaration>()
        let units = snapshot.sources.values.flatMap(\.unitsWithInlineEvidence).filter { $0.kind == "function" }
        let functions = Dictionary(grouping: units, by: { $0.helperCallableName ?? "" })
        let oldFunctions = historical.map { sources in
            Dictionary(grouping: sources.values.flatMap(\.units).filter { $0.kind == "function" }, by: { $0.helperCallableName ?? "" })
        }
        let symbols = Dictionary(grouping: graph.functions.values.filter { !$0.regions.isEmpty }, by: \.name)
        let physicalModules = snapshot.modulesWithPhysicalSourceLocations
        for (fileKey, file) in candidates {
            let old = historical?[fileKey]
            if historical != nil {
                guard let old, old.receiverPhysicalLocations == true, old.units.map(\.key) == file.units.map(\.key) else { continue }
            }
            let oldDirectCallers = Set(old?.units.filter { $0.hasOnlyDirectSourceCalls == true }.map(\.key) ?? [])
            for unit in file.units where unit.hasOnlyDirectSourceCalls == true {
                guard let names = unit.invocationNames, let signature = unit.helperReferenceSignature,
                      let caller = Self.symbol(for: unit, among: symbols[signature], physicalModules: physicalModules),
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
                              let callee = Self.symbol(for: $0, among: symbols[signature], physicalModules: physicalModules) else { return false }
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
                callers.insert(Declaration(unit))
            }
        }
        return callers
    }

    private static func symbol(for unit: SourceUnit, among candidates: [FunctionNode]?, physicalModules: Set<String>) -> FunctionNode? {
        let module = String(unit.key.prefix { $0 != ":" })
        guard physicalModules.contains(module) else { return nil }
        let matches = candidates?.filter { node in
            node.module == module && node.regions.contains {
                $0.path == unit.region.path && $0.startLine >= unit.region.startLine && $0.endLine <= unit.region.endLine
            }
        }
        return matches?.count == 1 ? matches?.first : nil
    }

    private static func unusedBodies(_ sources: [String: SwiftSourceSnapshot], in snapshot: XcodeTestGraph, touching paths: Set<String>,
                                     unowned: [String: SwiftSourceSnapshot], exactRevision: Bool) -> Set<Declaration> {
        // An expansion in the declaring file could call the function without a
        // written identifier. Internal functions can also be called by other files.
        let hasDiscovery = snapshot.dependencies?.functions[SwiftTestingDiscoveryRoots.sharedDiscoveryID] != nil
        var testingSyntax: Set<String> = ["@inline", "@_transparent"]
        if hasDiscovery { testingSyntax.formUnion(["@Test", "@Testing.Test", "@Suite", "@Testing.Suite", "#expect", "#require"]) }
        func hasCompleteNames(_ file: SwiftSourceSnapshot) -> Bool {
            file.identifierNames != nil && file.diagnostics.isEmpty &&
                file.helperDeclarationIssues?.allSatisfy { testingSyntax.contains($0.spelling) && $0.kind != "macro-declaration" } == true &&
                file.units.allSatisfy { $0.receiverUnsupportedImports?.subtracting(["import Testing"]).isEmpty == true }
        }
        var unused = Set<Declaration>()
        var candidates: [SourceUnit] = []
        // Other files can change unqualified macro lookup through declarations
        // or re-exports. Their ordinary imports are local to those files.
        lazy var completeSources = snapshot.hasCompleteSwiftSourceInventory(sources)
        func preservesMacroLookup(_ file: SwiftSourceSnapshot) -> Bool {
            file.helperImportsLocal == true && file.diagnostics.isEmpty && file.helperDeclarationIssues?.allSatisfy {
                $0.kind != "macro-declaration" && testingSyntax.contains($0.spelling)
            } == true
        }
        lazy var closedModules = Set(snapshot.modules.values).subtracting(sources.compactMap { key, file in
            preservesMacroLookup(file) ? nil : String(key.prefix { $0 != ":" })
        })
        lazy var closedUnowned = unowned.values.allSatisfy(preservesMacroLookup)
        lazy var factories = SwiftTestingRegistrationComparison.FactoryIndex(snapshot, inspecting: paths)
        for (key, file) in sources {
            guard let path = file.units.first?.region.path, paths.contains(path) else { continue }
            let named = file.units.filter { $0.fileUnreferencedInlineName != nil }
            guard !named.isEmpty, hasCompleteNames(file) else { continue }
            lazy var authenticatedTests: Bool = {
                guard completeSources, closedModules.contains(String(key.prefix { $0 != ":" })), closedUnowned else { return false }
                return factories.provesTestsWithoutRuntimeInputs(in: file, fileKey: key)
            }()
            for unit in named {
                if unit.fileProvesUnusedInline == true {
                    unused.insert(Declaration(unit))
                } else if unit.filePrivateInlineWithTests == true {
                    if hasDiscovery && authenticatedTests { unused.insert(Declaration(unit)) }
                } else if exactRevision || hasDiscovery {
                    // A dual graph owns its revision's inputs. With only head SIL,
                    // cross-file lookup still requires the discovery caller audit.
                    candidates.append(unit)
                }
            }
        }
        guard !candidates.isEmpty, unowned.isEmpty, completeSources, sources.values.allSatisfy(hasCompleteNames) else { return unused }
        let names = Set(candidates.compactMap(\.fileUnreferencedInlineName))
        var fileCounts: [String: Int] = [:]
        for file in sources.values {
            for name in names.intersection(file.identifierNames ?? []) { fileCounts[name, default: 0] += 1 }
        }
        unused.formUnion(candidates.compactMap { unit in
            guard let name = unit.fileUnreferencedInlineName, fileCounts[name] == 1 else { return nil }
            return Declaration(unit)
        })
        return unused
    }
}
