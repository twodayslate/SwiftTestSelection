// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
import Foundation

/// Source references are possible callers, never reconstructed compiler edges.
/// In particular, a new same-bodied declaration does not prove a safe rename.
public struct HeadOnlyDeclarationChange: Codable, Sendable {
    public struct Caller: Codable, Sendable {
        public var declaration: String
        public var baseRegion: SourceRegion
        /// A matching head entry identifies the enclosing historical method.
        /// It does not establish which overload or callback the base invoked.
        public var survivingTestEntries: [String]
    }
    public struct Reference: Codable, Sendable {
        public var sourceKey: String
        public var signature: String
        public var callerLines: [Int]
        public var unsupportedLines: [Int]
        public var incomplete: Bool
        public var possibleCallers: [Caller]? = nil
    }
    public var key: String
    public var change: String
    public var baseRegions: [SourceRegion]
    public var headRegions: [SourceRegion]
    public var historicalReferences: [Reference]
    public var missingEvidence: [String]

    static func describe(key: String, before: [SourceUnit], after: [SourceUnit], source: XcodeHeadOnlySources, current: XcodeTestGraph, hierarchy: SwiftSuperclassIndex) -> Self {
        let names = Set(before.compactMap(\.helperCallableName))
        let sources = source.base.map { ($0.key, $0.value) } + source.unownedBaseSources.map { ("unowned:" + $0.key, $0.value) }
        var references: [Reference] = []
        for (sourceKey, snapshot) in sources.sorted(by: { $0.0 < $1.0 }) {
            guard let inventory = snapshot.helperReferences else {
                references.append(.init(sourceKey: sourceKey, signature: "<missing inventory>", callerLines: [], unsupportedLines: [], incomplete: true))
                continue
            }
            for (signature, uses) in inventory.sorted(by: { $0.key < $1.key }) where names.contains(String(signature.prefix { $0 != "(" })) {
                if !uses.callers.isEmpty || uses.unsupported || !uses.unsupportedLines.isEmpty {
                    let lines = uses.callers.union(uses.unsupportedLines)
                    let functions = snapshot.units.filter { $0.kind == "function" }
                    let callers = functions.filter { unit in
                        lines.contains { $0 >= unit.region.startLine && $0 <= unit.region.endLine }
                    }.map { unit in
                        let unique = functions.filter {
                            ($0.key == unit.key && $0.conditionalBranch == unit.conditionalBranch) || $0.region.intersects(unit.region)
                        }.count == 1
                        return Caller(declaration: unit.key, baseRegion: unit.region,
                               survivingTestEntries: unique ? survivingEntries(for: unit, baseBlobIDs: snapshot.sourceBlobIDs,
                                   sourceKey: sourceKey, current: current, hierarchy: hierarchy) : [])
                    }.sorted { ($0.baseRegion.startLine, $0.declaration) < ($1.baseRegion.startLine, $1.declaration) }
                    references.append(.init(sourceKey: sourceKey, signature: signature, callerLines: uses.callers.sorted(),
                        unsupportedLines: uses.unsupportedLines.sorted(), incomplete: uses.unsupported, possibleCallers: callers))
                }
            }
        }
        return .init(key: key, change: before.isEmpty ? "added" : after.isEmpty ? "removed" : "ambiguous",
            baseRegions: regions(before), headRegions: regions(after), historicalReferences: references,
            missingEvidence: [
                "Exact historical declaration/module ownership and overload bindings, including callers outside changed files",
                "Historical escaped/stored references, dynamic selectors/macros and lifecycle/shared effects",
                "A verified mapping of every historical consumer to surviving or independently executed head entries; absence of head callers is insufficient"
            ])
    }

    private static func survivingEntries(for historical: SourceUnit, baseBlobIDs: Set<String>?, sourceKey: String,
                                         current: XcodeTestGraph, hierarchy: SwiftSuperclassIndex) -> [String] {
        guard let snapshot = current.sources[sourceKey], let graph = current.dependencies else { return [] }
        // A caller audit has already parsed the base file. Identical captured bytes
        // let its physical region distinguish branches even in a pre-v5 head.
        let incompleteBranches = snapshot.lacksConditionalMembership
        let identicalBytes = snapshot.sourceBlobIDs?.isDisjoint(with: baseBlobIDs ?? []) == false
        let matches = snapshot.units.filter { unit in
            guard unit.key == historical.key, unit.region.path == historical.region.path else { return false }
            if incompleteBranches && unit.conditionalBranch == nil {
                return identicalBytes && unit.region == historical.region
            }
            return unit.conditionalBranch == historical.conditionalBranch
        }
        guard matches.count == 1, let unit = matches.first, let name = unit.helperCallableName else { return [] }
        let module = String(sourceKey.prefix { $0 != ":" })
        let owners = current.targets.filter { current.modules[$0.name] == module && $0.sourceFiles.contains(unit.region.path) }
        guard !owners.isEmpty, owners.allSatisfy(\.isTest),
              snapshot.units.filter({ $0.kind == "function" && $0.region.intersects(unit.region) }).count == 1 else { return [] }
        // Restrict this projection to zero-argument test methods. Match the
        // enumerated ID, compiler root, module, and physical declaration.
        let method = name + "()"
        let qualified = unit.scope.isEmpty ? method : unit.scope + "." + method
        return current.tests.filter { entry in
            // XCTest can enumerate this declaration under a subclass, including
            // one in another test module. Verify the bound implementation below.
            let parts = entry.split(separator: "/")
            guard let target = parts.first, let entryModule = current.modules[String(target)],
                  parts.last == Substring(method) || parts.last == Substring(name) else { return false }
            let roots = (graph.tests[entry] ?? []).compactMap { graph.functions[$0] }
            let matches = roots.filter { node in
                node.module == module && (node.name == qualified || node.name == "static " + qualified) &&
                    node.regions.contains { region in
                        region.path == unit.region.path && region.startLine >= unit.region.startLine && region.startLine <= unit.region.endLine
                    }
            }
            guard !matches.isEmpty else { return false }

            // Selection retains superclass methods alongside overrides. Report
            // only the first bound implementation on the entry's class chain.
            let scope = parts.dropFirst().dropLast().joined(separator: ".")
            if scope == unit.scope && entryModule == module { return true }
            guard !scope.isEmpty, !unit.scope.isEmpty else { return false }
            var owner = entryModule + "." + scope
            if let slots = graph.testVTableEntries?[owner + "." + name] {
                // Overloads share a SIL slot basename. Only the enumerated
                // zero-argument signature can identify this implementation.
                guard slots.allSatisfy({ graph.functions[$0] != nil }) else { return false }
                let implementations = slots.filter { graph.functions[$0]?.name.hasSuffix("." + method) == true }
                if !implementations.isEmpty { return implementations.isSubset(of: Set(matches.map(\.id))) }
            }
            var visited = Set<String>()
            while visited.insert(owner).inserted {
                if owner == module + "." + unit.scope { return true }
                if roots.contains(where: { node in
                    let name = node.name.hasPrefix("static ") ? String(node.name.dropFirst(7)) : node.name
                    return !node.regions.isEmpty && node.module + "." + name == owner + "." + method
                }) { return false }
                guard let candidate = hierarchy.verifiedSuperclass(of: owner, identities: graph.compilerClassIdentities) else { return false }
                owner = candidate
            }
            return false
        }.sorted()
    }

    private static func regions(_ units: [SourceUnit]) -> [SourceRegion] {
        units.map(\.region).sorted { ($0.path, $0.startLine, $0.endLine) < ($1.path, $1.startLine, $1.endLine) }
    }
}
