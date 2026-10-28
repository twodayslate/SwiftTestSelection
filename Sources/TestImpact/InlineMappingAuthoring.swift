// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
import Foundation
import SwiftParser
import SwiftSyntax

/// Reviewable insertion, suitable for coverage proposals and mapping-maintenance
/// clients. Does not write files or claim that observed dependencies are complete.
public enum InlineMappingAuthoring {
    public struct Proposal: Codable, Sendable {
        public var path: String
        public var line: Int
        public var sourceDigest: String
        public var directive: String
        public var proposedSource: String
        public var limitations: [String]
        /// Original coverage proposal remains review evidence, never selection input.
        public var coverageProposal: String? = nil
        public var coverageFeatures: [String]? = nil
    }

    /// Optional inline output for the version-1 proposal emitted by coverage
    /// import. It preserves shared boundaries and the complete original evidence.
    public static func proposeCoverage(source: String, path: String, module: String,
                                       target: String, suite: String, proposalData: Data) throws -> Proposal {
        struct Coverage: Decodable {
            struct Diagnostic: Decodable { var severity: String }
            var schemaVersion: Int
            var additions: [UIFeatureMappings.Feature]
            var validationPassed: Bool
            var diagnostics: [Diagnostic]
        }
        let coverage = try JSONDecoder().decode(Coverage.self, from: proposalData)
        guard coverage.schemaVersion == 1, coverage.validationPassed,
              !coverage.diagnostics.contains(where: { $0.severity == "error" }) else {
            throw ImpactError("Inline coverage output requires a validated version-1 proposal without error diagnostics")
        }
        let selector = target + "/" + suite
        let features = coverage.additions.filter { $0.tests?.contains(selector) == true }
        guard !features.isEmpty else { throw ImpactError("Coverage proposal has no additions for exact suite \(selector)") }
        guard features.allSatisfy({ ($0.fixtures ?? []).isEmpty && ($0.dependsOn ?? []).isEmpty && $0.when == nil }) else {
            throw ImpactError("Coverage inline output cannot discard fixtures, shared feature dependencies or conditions; review those rules manually")
        }
        let sources = Set(features.flatMap { $0.sources ?? [] }).sorted()
        let symbols = Set(features.flatMap { $0.symbols ?? [] }).sorted()
        var object: [String: [String]] = [:]
        if !sources.isEmpty { object["sources"] = sources }
        if !symbols.isEmpty { object["symbols"] = symbols }
        let payload = String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
        var result = try propose(source: source, path: path, module: module, suite: suite, payload: payload)
        result.coverageProposal = String(decoding: proposalData, as: UTF8.self)
        result.coverageFeatures = features.map(\.name).sorted()
        result.limitations.append("Only \(selector) received an insertion proposal. Other suites and all original mappings/provenance remain in coverageProposal; do not remove their associations.")
        return result
    }

    public static func propose(source: String, path: String, module: String, suite: String,
                               method: String? = nil, payload: String) throws -> Proposal {
        let tree = Parser.parse(source: source)
        guard !tree.hasError else { throw ImpactError("\(path): repair Swift syntax before proposing an inline mapping") }
        let syntax = InlineMappingSyntax.parse(tree, path: path, module: module)
        let candidates = syntax.declarations.filter {
            $0.scope == suite && (method == nil ? $0.kind == "class" : $0.kind == "method" && $0.method == method)
        }
        guard candidates.count == 1, let declaration = candidates.first, !declaration.conditional else {
            throw ImpactError("\(path): expected one unconditional \(suite)\(method.map { "." + $0 } ?? "") declaration; conditional/inherited/ambiguous destinations require manual review")
        }
        let object = try JSONSerialization.jsonObject(with: Data(payload.utf8))
        let normalized = String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
        let probe = InlineMappingSyntax.parse(Parser.parse(source: "// swift-test-selection: " + normalized + "\nclass Proposal {}"), path: path, module: module)
        guard let directive = probe.declarations.first?.directives.first, directive.error == nil, probe.diagnostics.isEmpty else {
            throw ImpactError("\(path): invalid inline mapping payload: \(probe.declarations.first?.directives.first?.error ?? "expected one JSON object")")
        }
        // Inserting at the first token's line preserves every existing byte,
        // including documentation, unrelated comments, attributes and CRLFs.
        var lines = source.components(separatedBy: "\n")
        let index = declaration.region.startLine - 1
        guard lines.indices.contains(index) else { throw ImpactError("\(path): invalid declaration location") }
        let line = lines[index]
        let indent = String(line.prefix { $0 == " " || $0 == "\t" })
        // A declaration sharing a line with its enclosing type cannot receive a
        // line-comment insertion without changing unrelated source structure.
        if method != nil, !line.dropFirst(indent.count).hasPrefix("func "),
           !line.dropFirst(indent.count).hasPrefix("@"),
           !["public ", "internal ", "private ", "fileprivate ", "open ", "override ", "final ", "nonisolated "].contains(where: { line.dropFirst(indent.count).hasPrefix($0) }) {
            throw ImpactError("\(path):\(declaration.region.startLine): put the method on its own line before proposing a directive")
        }
        let comment = "// swift-test-selection: " + directive.normalized
        lines.insert(indent + comment + (source.contains("\r\n") ? "\r" : ""), at: index)
        let proposed = lines.joined(separator: "\n")
        let verified = InlineMappingSyntax.parse(Parser.parse(source: proposed), path: path, module: module)
        guard verified.declarations.contains(where: {
            $0.scope == suite && $0.kind == declaration.kind && $0.method == declaration.method &&
            $0.directives.contains(where: { $0.line == declaration.region.startLine && $0.normalized == directive.normalized })
        }) else { throw ImpactError("\(path): proposed directive did not attach to the requested declaration") }
        return Proposal(path: path, line: declaration.region.startLine, sourceDigest: XcodeGraphCache.digest(Data(source.utf8)),
                        directive: comment, proposedSource: proposed, limitations: [
                            "Proposal only: review the diff and validate against the selected plan's compiler graph before applying.",
                            "Existing directives and file mappings remain additive. No dependency, shared rule, or global policy was removed.",
                            "Coverage and source observations are positive evidence, not proof of complete runtime dependencies."
                        ])
    }
}

/// Active-inventory audit for authoring clients. It does not inspect disabled
/// declarations or claim behavioral completeness of user-declared mappings.
public struct InlineMappingAudit: Codable, Sendable {
    public struct Rule: Codable, Sendable {
        public var feature: UIFeatureMappings.Feature
        public var resolvedSymbols: [String]
        public var unresolvedEntries: [String]
    }
    public var rules: [Rule]
    public var diagnostics: [SelectionDiagnostic]
    public var unmappedUITests: [String]

    public static func inspect(_ snapshot: XcodeTestGraph) -> Self {
        let inline = InlineUIMappings.resolve(snapshot)
        let combined = inline.applying(to: snapshot)
        let graph = snapshot.dependencies ?? DependencyGraph()
        let mappings = combined.mappings ?? UIFeatureMappings(features: [])
        let index = MappingIndex(mappings, snapshot: snapshot, graph: graph, index: DependencyIndex(graph))
        let mapped = Set(index.tests.values.flatMap { $0 })
        let targets = Set(snapshot.targets.filter(\.isUITest).map(\.name))
        return Self(rules: inline.features.map { feature in
            Rule(feature: feature, resolvedSymbols: (index.roots[feature.name] ?? []).compactMap { graph.functions[$0].map { $0.module + "." + $0.name } }.sorted(),
                 unresolvedEntries: index.unresolvedEntries[feature.name] ?? [])
        }.sorted { $0.feature.name < $1.feature.name }, diagnostics: inline.diagnostics,
                    unmappedUITests: snapshot.tests.filter { targets.contains(String($0.prefix { $0 != "/" })) && !mapped.contains($0) }.sorted())
    }
}
