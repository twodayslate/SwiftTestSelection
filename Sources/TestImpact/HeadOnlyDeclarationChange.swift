// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
import Foundation

/// Source references are possible callers, never reconstructed compiler edges.
/// In particular, a new same-bodied declaration does not prove a safe rename.
public struct HeadOnlyDeclarationChange: Codable, Sendable {
    public struct Reference: Codable, Sendable {
        public var sourceKey: String
        public var signature: String
        public var callerLines: [Int]
        public var unsupportedLines: [Int]
        public var incomplete: Bool
    }
    public var key: String
    public var change: String
    public var baseRegions: [SourceRegion]
    public var headRegions: [SourceRegion]
    public var historicalReferences: [Reference]
    public var missingEvidence: [String]

    static func describe(key: String, before: [SourceUnit], after: [SourceUnit], source: XcodeHeadOnlySources) -> Self {
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
                    references.append(.init(sourceKey: sourceKey, signature: signature, callerLines: uses.callers.sorted(),
                        unsupportedLines: uses.unsupportedLines.sorted(), incomplete: uses.unsupported))
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

    private static func regions(_ units: [SourceUnit]) -> [SourceRegion] {
        units.map(\.region).sorted { ($0.path, $0.startLine, $0.endLine) < ($1.path, $1.startLine, $1.endLine) }
    }
}
