// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
import Foundation

/// A maintainer-reviewed identity boundary, scoped to one helper and one source
/// at one revision. It never grants effects to an imported function or macro.
public struct HelperBindingContract: Codable, Sendable, Equatable {
    public struct Construct: Codable, Sendable, Equatable {
        public var issue: HelperDeclarationIssue
        public var identity: String
        public var evidence: String
    }
    public var version = 1
    public var id: String
    public var helper: String
    public var helperSymbol: String
    public var revision: String
    public var sourceKey: String
    public var baseRevision: String
    public var headRevision: String
    public var baseSources: String
    public var headSources: String
    public var buildContext: String
    public var capturedInputs: String
    public var constructs: [Construct]
    public var imports: [String]
    /// Seals the exact source declarations and compiler binding observations.
    /// This is not a module-wide import allowlist.
    public var bindings: String
    public var guarantees: [String]
    public var evidence: String
    public static let requiredGuarantees = [
        "reviewed-identities-include-transitive-exports-and-host-modules",
        "no-additional-helper-sdk-operator-alias-or-lifecycle-bindings",
        "historical-identities-reviewed-without-assuming-head-bindings"
    ]
}

public struct HelperBindingDecision: Codable, Sendable {
    public var id: String
    public var helper: String
    public var revision: String
    public var sourceKey: String
    public var status: String
    public var failures: [String]
}

/// No mutation of the captured graph or raw completeness/import flags. The
/// evaluation belongs to a single changed helper and comparison only.
final class HelperBindingEvaluation {
    private var inventories: [String: Set<String>] = [:]
    private var importedSources: [String: Set<String>] = [:]
    private var importedUnits: [String: Set<String>] = [:]
    private var inventoryCandidates = Set<String>()
    private var importCandidates = Set<String>()
    private var importedUnitCandidates = Set<String>()
    private(set) var used = Set<String>()
    private let digestCache: HelperBindingDigestCache
    private static func locator(_ snapshot: SwiftSourceSnapshot) -> String {
        snapshot.units.first.map { $0.region.path + ":" + $0.key } ?? "<empty>"
    }
    init(contracts: [HelperBindingContract], current: XcodeTestGraph, source: XcodeHeadOnlySources, digestCache: HelperBindingDigestCache? = nil) {
        self.digestCache = digestCache?.matching(current) ?? HelperBindingDigestCache(current: current)
        guard !contracts.isEmpty else { return }
        var inventoryReviews: [String: HelperBindingContract] = [:], importReviews: [String: HelperBindingContract] = [:]
        for contract in contracts {
            let key = contract.revision + ":" + contract.sourceKey
            if !contract.constructs.isEmpty { inventoryReviews[key] = contract }
            if !contract.imports.isEmpty { importReviews[key] = contract }
        }
        let all = current.sources.map { ("head:" + $0.key, $0.value) } + source.base.map { ("base:" + $0.key, $0.value) } +
            source.unownedBaseSources.map { ("unowned:" + $0.key, $0.value) }
        inventoryCandidates = Set(all.filter { inventoryReviews[$0.0] != nil }.map { Self.locator($0.1) })
        importCandidates = Set(all.filter { importReviews[$0.0] != nil }.map { Self.locator($0.1) })
        let candidates = inventoryCandidates.union(importCandidates)
        // Identical bytes at head do not authorize an unreviewed base binding.
        // Require explicit coverage of every revision represented by a snapshot.
        for (digest, entries) in Dictionary(grouping: all.filter { candidates.contains(Self.locator($0.1)) }, by: { self.digestCache.snapshotDigest($0.1) }) {
            if entries.allSatisfy({ inventoryReviews[$0.0] != nil }), !entries.isEmpty {
                inventories[digest] = Set(entries.compactMap { inventoryReviews[$0.0]?.id })
            }
            if entries.allSatisfy({ importReviews[$0.0] != nil }), !entries.isEmpty {
                importedSources[digest] = Set(entries.compactMap { importReviews[$0.0]?.id })
            }
        }
        importedUnitCandidates = Set(all.filter { importReviews[$0.0] != nil }.flatMap { $0.1.units.map { $0.region.path + ":" + $0.key } })
        let units = all.flatMap { key, snapshot in snapshot.units.filter { importedUnitCandidates.contains($0.region.path + ":" + $0.key) }.map { (key, $0) } }
        for (digest, entries) in Dictionary(grouping: units, by: { HelperBindingContracts.digest($0.1) }) {
            if entries.allSatisfy({ importReviews[$0.0] != nil }), !entries.isEmpty {
                importedUnits[digest] = Set(entries.compactMap { importReviews[$0.0]?.id })
            }
        }
    }
    func inventoryComplete(_ snapshot: SwiftSourceSnapshot) -> Bool {
        if snapshot.helperDeclarationsComplete == true { return true }
        guard inventoryCandidates.contains(Self.locator(snapshot)) else { return false }
        guard let id = inventories[digestCache.snapshotDigest(snapshot)] else { return false }
        used.formUnion(id)
        return true
    }
    func operators(_ snapshot: SwiftSourceSnapshot) -> Set<String>? {
        if let result = snapshot.helperOperatorDeclarations { return result }
        // Missing metadata on an otherwise complete source is not a reviewed
        // synthesis boundary and must retain the legacy conservative fallback.
        return snapshot.helperDeclarationsComplete == false && inventoryComplete(snapshot) ? snapshot.helperWrittenOperators : nil
    }
    func references(_ snapshot: SwiftSourceSnapshot) -> [String: SDKTestHelperSyntax.References]? {
        guard importCandidates.contains(Self.locator(snapshot)) else { return snapshot.helperReferences }
        guard let id = importedSources[digestCache.snapshotDigest(snapshot)] else { return snapshot.helperReferences }
        used.formUnion(id)
        return snapshot.helperReferencesWithReviewedImports
    }
    func importsSupported(_ unit: SourceUnit) -> Bool {
        if unit.receiverImportsSupported == true { return true }
        guard importedUnitCandidates.contains(unit.region.path + ":" + unit.key) else { return false }
        guard let id = importedUnits[HelperBindingContracts.digest(unit)] else { return false }
        used.formUnion(id)
        return true
    }
}

enum HelperBindingContracts {
    // These declarations have language/SDK-defined synthesis. Arbitrary macros,
    // property wrappers and namesakes remain unsupported, even with a contract.
    static let identities: [String: Set<String>] = [
        "@MainActor": ["Swift.MainActor", "_Concurrency.MainActor"],
        "@Swift.MainActor": ["Swift.MainActor", "_Concurrency.MainActor"],
        "@State": ["SwiftUI.State"], "@Environment": ["SwiftUI.Environment"],
        "@AppStorage": ["SwiftUI.AppStorage"], "@Binding": ["SwiftUI.Binding"],
        "@FocusState": ["SwiftUI.FocusState"], "@Bindable": ["SwiftUI.Bindable"],
        "@StateObject": ["SwiftUI.StateObject"], "@ObservedObject": ["SwiftUI.ObservedObject"],
        "@EnvironmentObject": ["SwiftUI.EnvironmentObject"], "@GestureState": ["SwiftUI.GestureState"],
        "@ScaledMetric": ["SwiftUI.ScaledMetric"], "@Namespace": ["SwiftUI.Namespace"],
        "@ViewBuilder": ["SwiftUI.ViewBuilder"], "@ToolbarContentBuilder": ["SwiftUI.ToolbarContentBuilder"],
        "@Published": ["Combine.Published"]
    ]
    static func digest<T: Encodable>(_ value: T) -> String {
        // Snapshot token fingerprints preserve source order. All supplemental
        // inventories and compiler observations are collections: canonicalize
        // their arrays so Set encoding is stable across processes/archives.
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        func bytes(_ object: Any) -> Data { try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .fragmentsAllowed]) }
        func canonical(_ object: Any) -> Any {
            if let dictionary = object as? [String: Any] { return dictionary.mapValues(canonical) }
            if let array = object as? [Any] { return array.map(canonical).map { (bytes($0), $0) }.sorted { $0.0.lexicographicallyPrecedes($1.0) }.map { $0.1 } }
            return object
        }
        return withSILAutoreleasePool {
            XcodeGraphCache.digest(bytes(canonical(try! JSONSerialization.jsonObject(with: encoder.encode(value), options: .fragmentsAllowed))))
        }
    }
    static func digest(_ unit: SourceUnit) -> String {
        // Hash each declaration separately. Encoding a complete real-app
        // snapshot into an object tree can multiply its memory footprint.
        try! XcodeGraphCache.key([
            "key": unit.key, "path": unit.region.path,
            "start": String(unit.region.startLine), "end": String(unit.region.endLine),
            "syntax": unit.syntaxFingerprint ?? unit.fingerprint,
            "imports": (unit.receiverUnsupportedImports?.sorted().joined(separator: "\n")) ?? "<missing>",
            "importSupport": String(describing: unit.receiverImportsSupported),
            "uses": unit.helperBindingUses.map { digest($0) } ?? "<missing>"
        ])
    }
    static func snapshotDigest(_ snapshot: SwiftSourceSnapshot) -> String {
        func references(_ values: [String: SDKTestHelperSyntax.References]?) -> String {
            guard let values else { return "<missing>" }
            return try! XcodeGraphCache.key(values.mapValues { digest($0) })
        }
        return try! XcodeGraphCache.key([
            "units": snapshot.units.map { digest($0) }.sorted().joined(separator: "\n"),
            "issues": snapshot.helperDeclarationIssues.map { digest($0) } ?? "<missing>",
            "complete": String(describing: snapshot.helperDeclarationsComplete),
            "names": String(describing: snapshot.helperNamesUnshadowed),
            "localImports": String(describing: snapshot.helperImportsLocal),
            "writtenOperators": snapshot.helperWrittenOperators?.sorted().joined(separator: "\n") ?? "<missing>",
            "references": references(snapshot.helperReferences),
            "conditionalReferences": references(snapshot.helperReferencesWithReviewedImports),
            "diagnostics": snapshot.diagnostics.joined(separator: "\n")
        ])
    }
    static func bindingDigest(key: String, snapshot: SwiftSourceSnapshot, current: XcodeTestGraph) -> String {
        let module = String(key.prefix { $0 != ":" })
        let paths = Set(snapshot.units.map { $0.region.path })
        var fingerprints = ["source": snapshotDigest(snapshot)]
        for node in current.dependencies?.functions.values ?? Dictionary<String, FunctionNode>().values where
            node.module == module && node.regions.contains(where: { paths.contains($0.path) }) {
            fingerprints["compiler:" + node.id] = digest(node)
        }
        return try! XcodeGraphCache.key(fingerprints)
    }
    static func validate(current: XcodeTestGraph, source: XcodeHeadOnlySources, baseRevision: String, digestCache: HelperBindingDigestCache? = nil)
        -> (contracts: [HelperBindingContract], decisions: [HelperBindingDecision]) {
        let contracts = current.mappings?.helperBindingContracts ?? []
        let digestCache = digestCache?.matching(current) ?? HelperBindingDigestCache(current: current)
        guard !contracts.isEmpty else { return ([], []) }
        let baseDigest = HelperFormattingContracts.fingerprint(source.base, unowned: source.unownedBaseSources)
        let headDigest = HelperFormattingContracts.fingerprint(current.sources)
        let buildContext = HelperFormattingContracts.buildContext(current)
        let capturedFingerprint = current.buildArtifact?.helperBindingBuild?.fingerprint
        let headUnits = current.sources.values.flatMap(\.units)
        var bindingDigests: [String: String] = [:], identityShadows: [String: Bool] = [:]
        var accepted: [HelperBindingContract] = [], decisions: [HelperBindingDecision] = []
        let groups = Dictionary(grouping: contracts, by: \.id)
        let scopes = Dictionary(grouping: contracts, by: { [$0.helper, $0.revision, $0.sourceKey] })
        for contract in contracts {
            var failures: [String] = []
            let snapshot = (contract.revision == "head" ? current.sources : source.base)[contract.sourceKey]
            if contract.version != 1 || contract.id.isEmpty || groups[contract.id]?.count != 1 || scopes[[contract.helper, contract.revision, contract.sourceKey]]?.count != 1 { failures.append("Unsupported version or ambiguous review ID") }
            if !["head", "base"].contains(contract.revision) || snapshot == nil || contract.sourceKey.hasPrefix(":") {
                failures.append("Missing owned source at the exact revision; unowned historical sources cannot be reviewed")
            }
            if contract.baseRevision != baseRevision || contract.headRevision != current.buildArtifact?.revision { failures.append("Review revision changed") }
            if contract.baseSources != baseDigest || contract.headSources != headDigest { failures.append("Source/ownership bindings changed") }
            if contract.buildContext != buildContext ||
                current.buildArtifact.map({ $0.helperFormattingBuild?.matches($0) == true }) != true { failures.append("Missing or stale effective compiler/build evidence") }
            if contract.capturedInputs.isEmpty || contract.capturedInputs != current.buildArtifact?.helperBindingInputs ||
                capturedFingerprint != contract.capturedInputs ||
                current.buildArtifact.map({ $0.helperBindingBuild?.matches($0) == true }) != true {
                failures.append("Missing or changed captured dependency/compiler input bytes; recapture before review")
            }
            if Set(contract.guarantees) != Set(HelperBindingContract.requiredGuarantees) || contract.guarantees.count != HelperBindingContract.requiredGuarantees.count ||
                contract.evidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { failures.append("Missing scoped identity/export/host and historical review") }
            let helper = headUnits.filter { $0.key == contract.helper && $0.kind == "function" }
            if helper.count != 1 || current.dependencies?.functions[contract.helperSymbol].map({ node in
                node.module == String(contract.helper.prefix { $0 != ":" }) && node.regions.contains { region in
                    helper.contains { $0.region.path == region.path && region.startLine >= $0.region.startLine && region.endLine <= $0.region.endLine }
                }
            }) != true { failures.append("Missing exact helper source/compiler binding") }
            if !current.diagnostics.isEmpty || !source.diagnostics.isEmpty || current.dependencies?.diagnostics.isEmpty != true { failures.append("Incomplete compiler/source evidence") }
            if let snapshot {
                let sourceID = contract.revision + ":" + contract.sourceKey
                let binding = bindingDigests[sourceID] ?? digestCache.bindingDigest(key: contract.sourceKey, snapshot: snapshot)
                bindingDigests[sourceID] = binding
                if contract.bindings != binding { failures.append("Exact source/compiler binding inventory changed") }
                if !snapshot.diagnostics.isEmpty || snapshot.helperNamesUnshadowed != true || snapshot.helperImportsLocal != true {
                    failures.append("Source shadows protected names, reexports imports or has incomplete syntax")
                }
                if !contract.constructs.isEmpty {
                    if snapshot.helperDeclarationIssues == nil || contract.constructs.map(\.issue) != snapshot.helperDeclarationIssues || snapshot.helperWrittenOperators == nil {
                        failures.append("Review must enumerate every exact construct and retain written declarations")
                    }
                    for construct in contract.constructs {
                        let module = String(contract.sourceKey.prefix { $0 != ":" })
                        let components = Set(construct.identity.split(separator: ".").map(String.init))
                        let reviewedPath = String(contract.sourceKey.dropFirst(module.count + 1))
                        let identityKey = contract.sourceKey + ":" + construct.identity
                        let shadowed: Bool
                        if let cached = identityShadows[identityKey] { shadowed = cached }
                        else {
                            let bindings = current.sources.filter { $0.key.hasPrefix(module + ":") }.map { (String($0.key.dropFirst(module.count + 1)), $0.value) } +
                                source.base.filter { $0.key.hasPrefix(module + ":") }.map { (String($0.key.dropFirst(module.count + 1)), $0.value) } +
                                source.unownedBaseSources.map { ($0.key, $0.value) }
                            shadowed = bindings.contains { path, candidate in
                                // This exclusion proves only cross-file inaccessibility.
                                // It never authorizes same-file lexical/extension lookup.
                                func canShadow(_ spelling: String) -> Bool {
                                    let name = SDKTestHelperSyntax.canonicalName(spelling)
                                    return components.contains(name) && !(path != reviewedPath && candidate.helperFileRestrictedIdentityNames?.contains(name) == true)
                                }
                                return candidate.typeAliases == nil || (candidate.typeAliases ?? []).contains {
                                    $0.split(separator: ".").last.map(String.init).map(canShadow) == true
                                } || candidate.units.contains {
                                    $0.kind == "type" && $0.scope.split(separator: ".").last.map(String.init).map(canShadow) == true
                                } || (candidate.helperDeclarationIssues ?? []).contains { $0.kind == "macro-declaration" && canShadow($0.spelling) }
                            }
                            identityShadows[identityKey] = shadowed
                        }
                        if shadowed || !Set(current.modules.values).isDisjoint(with: components) {
                            failures.append("Project alias, namesake or macro shadows reviewed identity: " + construct.identity)
                        }
                        if !["unresolved-attribute", "unresolved-global-actor"].contains(construct.issue.kind) ||
                            identities[construct.issue.spelling]?.contains(construct.identity) != true || construct.evidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            failures.append("Unsupported synthesis or missing resolved SDK identity: " + construct.issue.spelling)
                        }
                    }
                }
                if !contract.imports.isEmpty {
                    if snapshot.helperDeclarationsComplete != true && contract.constructs.isEmpty {
                        failures.append("Import review cannot cover unreviewed declaration synthesis")
                    }
                    let module = String(contract.sourceKey.prefix { $0 != ":" })
                    let capturedImports = Set(current.buildArtifact?.helperBindingBuild?.importedModules[module] ?? [])
                    if !Set(contract.imports.map { String($0.dropFirst(7)) }).isSubset(of: capturedImports) {
                        failures.append("Reviewed dependency is absent from the captured compiler import map")
                    }
                    let imports = Set(snapshot.units.flatMap { $0.receiverUnsupportedImports ?? [] })
                    if imports != Set(contract.imports) || imports.count != contract.imports.count || snapshot.helperReferencesWithReviewedImports == nil || snapshot.units.contains(where: { $0.receiverUnsupportedImports == nil || $0.receiverImportsSupported == nil }) {
                        failures.append("Review must bind the exact unsupported imports and source reference inventory")
                    }
                    if contract.imports.contains(where: { !$0.hasPrefix("import ") || $0.dropFirst(7).contains(where: { !$0.isLetter && !$0.isNumber && $0 != "_" }) }) {
                        failures.append("Attributed, scoped or reexported imports remain unsupported")
                    }
                }
                if contract.constructs.isEmpty && contract.imports.isEmpty { failures.append("Empty binding review") }
            }
            decisions.append(.init(id: contract.id, helper: contract.helper, revision: contract.revision, sourceKey: contract.sourceKey,
                status: failures.isEmpty ? "valid-unused" : "invalid", failures: failures))
            if failures.isEmpty { accepted.append(contract) }
        }
        return (accepted, decisions)
    }
}

public struct HelperBindingReviewContext: Codable, Sendable {
    public struct Source: Codable, Sendable {
        public var revision: String
        public var sourceKey: String
        public var bindings: String
        public var imports: [String]
        public var issues: [HelperDeclarationIssue]
    }
    public var baseRevision: String
    public var headRevision: String
    public var baseSources: String
    public var headSources: String
    public var buildContext: String
    public var capturedInputs: String?
    public var captureFailure: String?
    public var sources: [Source]
    public var helperSymbols: [String: [String]]
    public var supportedConstructIdentities = HelperBindingContracts.identities.mapValues { $0.sorted() }
    public var requiredGuarantees = HelperBindingContract.requiredGuarantees
    public var instruction = "Binding inventory only, not an approved review. Authenticate each construct and each source's exact imported bindings, including transitive exports, host and historical dependencies. Arbitrary macros, unowned sources and effect uncertainty remain unsupported. Recapturing input bytes invalidates the review."
}

extension HelperBindingContracts {
    static func context(current: XcodeTestGraph, source: XcodeHeadOnlySources, baseRevision: String, helpers: Set<String> = [], digestCache: HelperBindingDigestCache? = nil) -> HelperBindingReviewContext {
        let digestCache = digestCache?.matching(current) ?? HelperBindingDigestCache(current: current)
        let sources = [("head", current.sources), ("base", source.base)].flatMap { revision, snapshots in
            snapshots.keys.sorted().compactMap { key -> HelperBindingReviewContext.Source? in
                let snapshot = snapshots[key]!
                let imports = Set(snapshot.units.flatMap { $0.receiverUnsupportedImports ?? [] }).sorted()
                guard snapshot.helperDeclarationsComplete != true || !imports.isEmpty else { return nil }
                // Unreviewable macros remain in the complete raw inventory.
                // Do not hash their potentially huge bodies into an unusable
                // review candidate or imply this contract can discharge them.
                guard snapshot.helperDeclarationsComplete == true || snapshot.helperDeclarationIssues.map({ issues in
                    !issues.isEmpty && issues.allSatisfy { identities[$0.spelling] != nil && ["unresolved-attribute", "unresolved-global-actor"].contains($0.kind) }
                }) == true else { return nil }
                return .init(revision: revision, sourceKey: key, bindings: digestCache.bindingDigest(key: key, snapshot: snapshot),
                    imports: imports, issues: snapshot.helperDeclarationIssues ?? [])
            }
        }
        let helperUnits = current.sources.values.flatMap(\.units).filter { helpers.contains($0.key) }
        var helperSymbols: [String: [String]] = [:]
        for helper in helperUnits {
            helperSymbols[helper.key] = current.dependencies?.functions.values.filter { node in
                node.module == String(helper.key.prefix { $0 != ":" }) && node.regions.contains {
                    $0.path == helper.region.path && $0.startLine >= helper.region.startLine && $0.endLine <= helper.region.endLine
                }
            }.map(\.id).sorted() ?? []
        }
        return .init(baseRevision: baseRevision, headRevision: current.buildArtifact?.revision ?? "",
            baseSources: HelperFormattingContracts.fingerprint(source.base, unowned: source.unownedBaseSources),
            headSources: HelperFormattingContracts.fingerprint(current.sources), buildContext: HelperFormattingContracts.buildContext(current),
            capturedInputs: current.buildArtifact?.helperBindingInputs, captureFailure: current.buildArtifact?.helperBindingBuildFailure, sources: sources, helperSymbols: helperSymbols)
    }
}
