// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation
import SwiftSyntax

/// A reviewed assertion about one runtime formatting boundary, not a list of
/// consumers or a replacement for the compiler/source helper isolation proof.
public struct HelperFormattingContract: Codable, Sendable, Equatable {
    public var version: Int = 1
    public var id: String
    public var helper: String
    public var helperSymbol: String
    public var producer: String
    public var producerSymbol: String
    public var assertionSymbol: String
    public var substitutions: String
    public var baseRevision: String
    public var baseSources: String
    public var headSources: String
    public var toolchain: String
    public var buildContext: String
    public var guarantees: [String]
    public var rationale: String

    public static let requiredGuarantees = [
        "formatting-has-no-shared-state-or-resource-effects",
        "formatting-does-not-register-or-escape-callbacks",
        "formatting-does-not-inject-test-or-sdk-receivers"
    ]

    func validate() throws {
        guard version == 1, !id.isEmpty, !helper.isEmpty, !helperSymbol.isEmpty,
              !producer.isEmpty, !producerSymbol.isEmpty, !baseRevision.isEmpty,
              !baseSources.isEmpty, !headSources.isEmpty, !toolchain.isEmpty, !buildContext.isEmpty,
              Set(guarantees) == Set(Self.requiredGuarantees),
              guarantees.count == Self.requiredGuarantees.count,
              !rationale.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              SDKReceiverContracts.missingWitnessProof(substitutions, for: assertionSymbol) != nil else {
            throw ImpactError("Formatting contract requires exact helper/producer/overload identities, review fingerprints, toolchain, all formatting guarantees, and a review rationale; only XCTest equality failure formatting with a proven equality witness is supported")
        }
    }
}

/// Kept outside source fingerprints: ordinary comments stay inert, while
/// policy edits are compared separately and treated as selection inputs.
public struct HelperContractSyntax: Codable, Sendable {
    public var contracts: [HelperFormattingContract] = []
    public var diagnostics: [String] = []
    static let prefix = "swift-test-helper-formatting:"

    static func parse(_ tree: SourceFileSyntax) -> Self {
        var result = Self()
        for token in tree.tokens(viewMode: .sourceAccurate) {
            for piece in Array(token.leadingTrivia) + Array(token.trailingTrivia) {
                let comment: String
                switch piece {
                case .lineComment(let text), .docLineComment(let text), .blockComment(let text), .docBlockComment(let text): comment = text
                default: continue
                }
                for line in comment.split(separator: "\n") {
                    var text = String(line).trimmingCharacters(in: .whitespaces)
                    if text.hasPrefix("//") { text = String(text.drop(while: { $0 == "/" })) }
                    else if text.hasPrefix("/*") { text = String(text.dropFirst(2)) }
                    text = text.trimmingCharacters(in: .whitespaces)
                    if text.hasPrefix("*") { text = String(text.dropFirst()).trimmingCharacters(in: .whitespaces) }
                    if text.hasSuffix("*/") { text = String(text.dropLast(2)).trimmingCharacters(in: .whitespaces) }
                    guard text.hasPrefix(prefix) else { continue }
                    do {
                        let contract = try JSONDecoder().decode(HelperFormattingContract.self, from: Data(text.dropFirst(prefix.count).utf8))
                        try contract.validate()
                        result.contracts.append(contract)
                    } catch { result.diagnostics.append("Invalid \(prefix) directive: \(error)") }
                }
            }
        }
        return result
    }
}

public struct HelperContractDecision: Codable, Sendable {
    public var contractID: String
    public var helper: String
    /// invalid, valid-unused, or discharged. Discharge is local to one boundary;
    /// it does not imply that the enclosing helper proof succeeded.
    public var status: String
    public var failures: [String]
    public var dischargedBoundaries: [FormattingBoundary] = []
}

public struct FormattingBoundary: Codable, Sendable, Equatable {
    public var diagnosticCode: String? = nil
    public var helper: String
    public var producer: String
    public var producerSymbol: String
    public var assertionSymbol: String
    public var substitutions: String
    public var region: SourceRegion?
    public var explanation: String
}


public struct HelperContractReviewContext: Codable, Sendable {
    public var baseRevision: String
    public var baseSources: String
    public var headSources: String
    public var toolchain: String
    public var buildContext: String
    public var helperSymbols: [String: [String]]
    public var requiredGuarantees = HelperFormattingContract.requiredGuarantees
    public var instruction = "Binding evidence only. Do not enable a declaration until a maintainer reviews the formatting behavior at both revisions, including binary/runtime conformances. Historical caller, callback, state and lifecycle checks still apply."
}

public struct HelperContractPreview: Codable, Sendable {
    public var withoutDeclarations: [String]
    public var withDeclarations: [String]
    public var added: [String]
    public var removed: [String]
    public var trust = "reviewed-declaration; not compiler-proven isolation or observed coverage"
}

/// Per selection and per changed helper. Never cached on the shared head graph.
final class HelperContractEvaluation {
    let helper: String
    let contracts: [HelperFormattingContract]
    let diagnosticCode: String
    var encountered: [FormattingBoundary] = []
    var discharged: [String: [FormattingBoundary]] = [:]

    init(helper: String, contracts: [HelperFormattingContract], diagnosticCode: String = "head_only_helper_callee_effects") {
        self.helper = helper; self.contracts = contracts.filter { $0.helper == helper }
        self.diagnosticCode = diagnosticCode
    }

    func allows(node: FunctionNode, owners: [SourceUnit], symbol: String, arguments: String) -> Bool {
        guard let explanation = SDKReceiverContracts.missingWitnessProof(arguments, for: symbol) else { return false }
        let owners = Dictionary(grouping: owners.filter { $0.kind == "function" }, by: {
            $0.key + "@" + $0.region.path + ":" + String($0.region.startLine) + ":" + String($0.region.endLine)
        }).values.compactMap(\.first)
        guard owners.count == 1, let owner = owners.first else { return false }
        let boundary = FormattingBoundary(diagnosticCode: diagnosticCode, helper: helper, producer: owner.key, producerSymbol: node.id,
            assertionSymbol: symbol, substitutions: arguments, region: owner.region, explanation: explanation)
        if !encountered.contains(boundary) { encountered.append(boundary) }
        guard let contract = contracts.first(where: {
            $0.producer == owner.key && $0.producerSymbol == node.id &&
                $0.assertionSymbol == symbol && $0.substitutions == arguments
        }) else { return false }
        if !(discharged[contract.id] ?? []).contains(boundary) { discharged[contract.id, default: []].append(boundary) }
        return true
    }
}

enum HelperFormattingContracts {
    static func declarations(_ sources: [String: SwiftSourceSnapshot], _ mappings: UIFeatureMappings?) -> [HelperFormattingContract] {
        (mappings?.helperFormattingContracts ?? []) + sources.keys.sorted().flatMap { sources[$0]?.helperContracts?.contracts ?? [] }
    }

    static func changedPolicyPaths(base: [String: SwiftSourceSnapshot], head: [String: SwiftSourceSnapshot]) -> Set<String> {
        Set(Set(base.keys).union(head.keys).compactMap { key in
            guard (base[key]?.helperContracts?.contracts ?? []) != (head[key]?.helperContracts?.contracts ?? []) ||
                (base[key]?.helperContracts?.diagnostics ?? []) != (head[key]?.helperContracts?.diagnostics ?? []),
                  let colon = key.firstIndex(of: ":") else { return nil }
            return String(key[key.index(after: colon)...])
        })
    }

    /// Review-wide semantic digest. No compiler graph is invented for base.
    /// Source declarations/bodies/conformances/imports and ownership keys are
    /// bound together; prose and directive payloads do not hash themselves.
    static func fingerprint(_ sources: [String: SwiftSourceSnapshot], unowned: [String: SwiftSourceSnapshot] = [:]) -> String {
        var identity: [String: String] = [:]
        for (prefix, snapshots) in [("owned:", sources), ("unowned:", unowned)] {
            for (key, snapshot) in snapshots {
                let units = snapshot.units.map { [$0.key, $0.region.path, $0.syntaxFingerprint ?? $0.fingerprint] }
                    .sorted { $0.lexicographicallyPrecedes($1) }
                identity[prefix + key] = String(decoding: try! JSONEncoder().encode(units), as: UTF8.self)
            }
        }
        return try! XcodeGraphCache.key(identity)
    }

    static func buildContext(_ current: XcodeTestGraph) -> String {
        var context = current.buildArtifact?.context ?? [:]
        context["simulatorRuntimes"] = current.buildArtifact?.simulatorRuntimes ?? ""
        context["toolchain"] = current.buildArtifact?.toolchain ?? current.dependencies?.toolchain ?? ""
        return try! XcodeGraphCache.key(context)
    }

    static func validate(current: XcodeTestGraph, source: XcodeHeadOnlySources, baseRevision: String) -> (contracts: [HelperFormattingContract], decisions: [HelperContractDecision]) {
        let contracts = declarations(current.sources, current.mappings)
        guard !contracts.isEmpty else { return ([], []) }
        let groups = Dictionary(grouping: contracts, by: \.id)
        let head = current.sources.values.flatMap(\.units), base = source.base.values.flatMap(\.units)
        let oldDigest = fingerprint(source.base, unowned: source.unownedBaseSources), newDigest = fingerprint(current.sources)
        var accepted: [HelperFormattingContract] = [], decisions: [HelperContractDecision] = []
        // A protocol alias or inherited protocol can hide a formatting witness.
        // Version 1 therefore declines every project conformance on a formatted
        // type, rather than trying to infer purity from protocol spellings.
        let conformances = (head + base + source.unownedBaseSources.values.flatMap(\.units)).filter {
            $0.helperInheritedTypes?.isEmpty == false
        }
        for contract in contracts.sorted(by: { $0.id < $1.id }) {
            var failures: [String] = []
            do { try contract.validate() } catch { failures.append(String(describing: error)) }
            if groups[contract.id]?.count != 1 { failures.append("Duplicate or ambiguous contract ID") }
            if contract.baseRevision != baseRevision { failures.append("Base revision differs from the actual review comparison") }
            if contract.baseSources != oldDigest { failures.append("Base source binding is stale or incomplete") }
            if contract.headSources != newDigest { failures.append("Head source binding is stale (body, signature, ownership, conformance or callback changes require review)") }
            if contract.toolchain != (current.buildArtifact?.toolchain ?? current.dependencies?.toolchain ?? "") { failures.append("Toolchain differs from the reviewed contract") }
            if contract.buildContext != buildContext(current) { failures.append("Captured build context, SDK, architecture or simulator runtime differs from the reviewed contract") }
            if !source.diagnostics.isEmpty || !current.diagnostics.isEmpty || !(current.dependencies?.diagnostics.isEmpty ?? false) {
                failures.append("Incomplete source/compiler evidence")
            }
            for (label, key, symbol) in [("helper", contract.helper, contract.helperSymbol), ("producer", contract.producer, contract.producerSymbol)] {
                let units = head.filter { $0.key == key && $0.kind == "function" }
                guard units.count == 1, let unit = units.first,
                      let node = current.dependencies?.functions[symbol], node.module == String(key.prefix { $0 != ":" }),
                      node.regions.contains(where: { $0.path == unit.region.path && $0.startLine >= unit.region.startLine && $0.endLine <= unit.region.endLine }) else {
                    failures.append("Missing, renamed, deleted or ambiguous \(label) source/compiler binding"); continue
                }
                let prior = base.filter { $0.key == key }
                if prior.count > 1 || prior.first.map({ $0.region.path != unit.region.path }) == true {
                    failures.append("Ambiguous or moved base \(label) binding")
                }
            }
            if let producer = current.dependencies?.functions[contract.producerSymbol],
               producer.compilerReferences?.contains(contract.assertionSymbol) != true ||
                producer.receiverGenericCalls?.contains(contract.assertionSymbol + "\t" + contract.substitutions) != true {
                failures.append("Missing exact compiled assertion overload/substitutions")
            }
            let typeNames = SDKReceiverContracts.requiredTypeIdentities(contract.substitutions, for: contract.assertionSymbol) ?? []
            let relevantConformances = conformances.filter { unit in
                typeNames.contains(unit.scope) || typeNames.contains { $0.hasSuffix("." + unit.scope) || unit.scope.hasSuffix("." + $0) }
            }
            if !relevantConformances.isEmpty {
                failures.append("Project formatting conformance (or other conformance on a formatted type) requires unsupported effect analysis: " + Set(relevantConformances.map { $0.region.path + ":" + String($0.region.startLine) }).sorted().joined(separator: ", "))
            }
            decisions.append(.init(contractID: contract.id, helper: contract.helper,
                status: failures.isEmpty ? "valid-unused" : "invalid", failures: failures))
            if failures.isEmpty { accepted.append(contract) }
        }
        return (accepted, decisions)
    }
}
