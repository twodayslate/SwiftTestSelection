// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
import Foundation

/// Ephemeral evidence reuse for one synchronous selection invocation. No
/// decisions, helper grants, revisions or scope policy are cached here.
final class HelperBindingDigestCache {
    private struct UnitInput: Equatable {
        let key: String
        let region: SourceRegion
        let syntax: String
        let imports: Set<String>?
        let importSupport: Bool?
        let uses: HelperBindingUses?

        init(_ unit: SourceUnit) {
            key = unit.key; region = unit.region
            syntax = unit.syntaxFingerprint ?? unit.fingerprint
            imports = unit.receiverUnsupportedImports; importSupport = unit.receiverImportsSupported
            uses = unit.helperBindingUses
        }
    }
    /// Every input consumed by snapshotDigest, compared structurally before a
    /// hit. Source keys or syntax alone cannot authenticate supplemental proofs.
    private struct SnapshotInput: Equatable {
        let units: [UnitInput]
        let issues: [HelperDeclarationIssue]?
        let complete: Bool?
        let names: Bool?
        let localImports: Bool?
        let operators: Set<String>?
        let references: [String: SDKTestHelperSyntax.References]?
        let conditionalReferences: [String: SDKTestHelperSyntax.References]?
        let diagnostics: [String]
        init(_ snapshot: SwiftSourceSnapshot) {
            units = snapshot.units.map(UnitInput.init)
            issues = snapshot.helperDeclarationIssues; complete = snapshot.helperDeclarationsComplete
            names = snapshot.helperNamesUnshadowed; localImports = snapshot.helperImportsLocal
            operators = snapshot.helperWrittenOperators; references = snapshot.helperReferences
            conditionalReferences = snapshot.helperReferencesWithReviewedImports; diagnostics = snapshot.diagnostics
        }
    }
    private let functions: [String: FunctionNode]
    private var bySource: [String: Set<String>]?
    private var nodeDigests: [String: String] = [:]
    private var snapshots: [String: [(SnapshotInput, String)]] = [:]
    private var bindings: [String: [String: String]] = [:]
    private(set) var snapshotComputations = 0
    private(set) var snapshotHits = 0
    private(set) var nodeComputations = 0
    private(set) var bindingComputations = 0

    init(current: XcodeTestGraph) {
        functions = current.dependencies?.functions ?? [:]
    }

    /// A caller may reuse a cache for independent scopes, but never substitute
    /// a changed compiler graph. Equality covers all FunctionNode evidence.
    func matching(_ current: XcodeTestGraph) -> HelperBindingDigestCache {
        functions == (current.dependencies?.functions ?? [:]) ? self : .init(current: current)
    }

    func snapshotDigest(_ snapshot: SwiftSourceSnapshot) -> String {
        let input = SnapshotInput(snapshot)
        let locator = snapshot.units.first.map { $0.region.path + ":" + $0.key } ?? "<empty>"
        if let match = snapshots[locator]?.first(where: { $0.0 == input }) {
            snapshotHits += 1
            return match.1
        }
        let digest = HelperBindingContracts.snapshotDigest(snapshot)
        snapshots[locator, default: []].append((input, digest)); snapshotComputations += 1
        return digest
    }

    func bindingDigest(key: String, snapshot: SwiftSourceSnapshot) -> String {
        let source = snapshotDigest(snapshot)
        let module = String(key.prefix { $0 != ":" })
        // Source digest includes every unit path, so this cache cannot reuse
        // compiler observations for a different file or module.
        if let result = bindings[module]?[source] { return result }
        if bySource == nil {
            var index: [String: Set<String>] = [:]
            for node in functions.values {
                for path in Set(node.regions.map(\.path)) { index[node.module + ":" + path, default: []].insert(node.id) }
            }
            bySource = index
        }
        var fingerprints = ["source": source]
        let ids = snapshot.units.reduce(into: Set<String>()) {
            $0.formUnion(bySource![module + ":" + $1.region.path] ?? [])
        }
        for id in ids {
            if nodeDigests[id] == nil {
                nodeDigests[id] = HelperBindingContracts.digest(functions[id]!); nodeComputations += 1
            }
            fingerprints["compiler:" + id] = nodeDigests[id]!
        }
        let result = try! XcodeGraphCache.key(fingerprints)
        bindings[module, default: [:]][source] = result; bindingComputations += 1
        return result
    }
}
