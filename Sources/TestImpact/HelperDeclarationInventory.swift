// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation
import SwiftSyntax

/// A missing source proof, not a claim that the construct actually expands or
/// collides. Locations are physical source coordinates, including inactive code.
public struct HelperDeclarationIssue: Codable, Sendable, Equatable {
    public var kind: String
    public var spelling: String
    public var line: Int
    public var column: Int
    public var possibleEffects: [String]
    public var requiredEvidence: String
}

/// Complete diagnostic inventory for one source/revision. Kept outside the
/// ordinary diagnostic message so a large project does not truncate blockers or
/// duplicate thousands of source locations for every selected test.
public struct HelperDeclarationInventoryBoundary: Codable, Sendable, Equatable {
    public var revision: String
    public var sourceKey: String
    public var issues: [HelperDeclarationIssue]
}

/// Names under audit are candidates, not proven generated declarations. Source
/// imports alone cannot eliminate modules, historical files or host effects.
public struct HelperDeclarationAudit: Codable, Sendable, Equatable {
    public var helper: String
    public var sdkMembers: [String]
    public var operators: [String]
    public var protectedBindings = ["SDK/global/type names", "XCTest lifecycle and callbacks", "project members and conformances"]
}

enum HelperDeclarationInventory {
    static func issues(_ tree: SourceFileSyntax, locations: SourceLocationConverter,
                       unsupportedImports: Set<String>) -> [HelperDeclarationIssue] {
        let knownAttributes: Set<String> = ["available", "objc", "objcMembers", "nonobjc",
            "preconcurrency", "inlinable", "usableFromInline", "discardableResult", "testable", "_exported",
            "Sendable", "escaping", "autoclosure", "convention"]
        let compilerLiterals: Set<String> = ["file", "fileID", "filePath", "line", "column", "function", "dsohandle"]
        let expansionEffects = ["globals or operators", "SDK members or aliases", "conformances", "XCTest lifecycle or callbacks"]
        var result: [HelperDeclarationIssue] = []
        func add(_ token: TokenSyntax, kind: String, spelling: String, effects: [String], evidence: String) {
            let location = locations.location(for: token.positionAfterSkippingLeadingTrivia)
            result.append(.init(kind: kind, spelling: spelling, line: location.line, column: location.column,
                                possibleEffects: effects, requiredEvidence: evidence))
        }
        if tree.hasError {
            result.append(.init(kind: "syntax", spelling: "unparsed source", line: 1, column: 1,
                possibleEffects: expansionEffects, requiredEvidence: "A complete parse with the captured toolchain's syntax is required; source declarations may be missing."))
        }
        for token in tree.tokens(viewMode: .sourceAccurate) {
            if let macro = token.parent?.as(MacroDeclSyntax.self), token.id == macro.macroKeyword.id {
                add(token, kind: "macro-declaration", spelling: macro.name.text, effects: expansionEffects,
                    evidence: "Authenticate the macro implementation, declared roles/names, and expansions at both revisions; its source declaration does not prove expansion effects.")
            } else if let macro = token.parent?.as(MacroExpansionDeclSyntax.self), token.id == macro.pound.id {
                add(token, kind: "declaration-macro", spelling: "#" + macro.macroName.text, effects: expansionEffects,
                    evidence: "Captured declaration expansion and ownership evidence is required at both revisions, including generated globals, operators and lifecycle declarations.")
            } else if let macro = token.parent?.as(MacroExpansionExprSyntax.self), token.id == macro.pound.id,
                      !compilerLiterals.contains(macro.macroName.text) || macro.leftParen != nil || macro.genericArgumentClause != nil ||
                        macro.trailingClosure != nil || !macro.additionalTrailingClosures.isEmpty {
                add(token, kind: "expression-macro", spelling: "#" + macro.macroName.text, effects: expansionEffects + ["hidden expression effects"],
                    evidence: "Authenticate the macro identity and expanded expression/declarations at both revisions; a head compiler location alone does not cover historical expansion effects.")
            } else if let attribute = token.parent?.as(AttributeSyntax.self), token.id == attribute.atSign.id {
                let name = attribute.attributeName.trimmedDescription
                if name == "MainActor" || name == "Swift.MainActor" {
                    guard !unsupportedImports.isEmpty else { continue }
                    add(token, kind: "unresolved-global-actor", spelling: "@" + name, effects: expansionEffects + ["actor isolation"],
                        evidence: "Authenticate the actor/attribute identity and module exports at both revisions. Unsupported import context: " + unsupportedImports.sorted().joined(separator: ", ") + ". A namesake macro cannot be excluded from source imports alone.")
                } else if !knownAttributes.contains(name) {
                    add(token, kind: "unresolved-attribute", spelling: "@" + name,
                        effects: expansionEffects + ["wrapper storage/accessors or result-builder calls"],
                        evidence: "Authenticate whether this is a compiler attribute, SDK wrapper/builder/actor or attached macro, its module/exports, and synthesized declarations/effects at both revisions. Attribute spelling alone is insufficient.")
                }
            }
        }
        return result
    }

    static func boundaries(current: [String: SwiftSourceSnapshot], base: [String: SwiftSourceSnapshot],
                           unownedBase: [String: SwiftSourceSnapshot]) -> [HelperDeclarationInventoryBoundary] {
        [("head", current), ("base", base), ("unowned base", unownedBase)].flatMap { revision, sources in
            sources.keys.sorted().compactMap { key in
                guard let source = sources[key], source.helperDeclarationsComplete != true else { return nil }
                let issues = source.helperDeclarationIssues
                return .init(revision: revision, sourceKey: key, issues: issues?.isEmpty == false ? issues! : [
                    .init(kind: "missing-metadata", spelling: "unknown declaration inventory", line: 1, column: 1,
                        possibleEffects: ["unaccounted declarations or expansions"],
                        requiredEvidence: "Refresh source proofs to identify each unsupported construct. Legacy or incomplete metadata cannot authenticate declaration completeness.")
                ])
            }
        }
    }

    static func summary(_ boundaries: [HelperDeclarationInventoryBoundary]) -> String? {
        guard let first = boundaries.first, let issue = first.issues.first else { return nil }
        return "Incomplete helper declaration inventories: \(first.revision):\(first.sourceKey):\(issue.line):\(issue.column) \(issue.spelling) (\(issue.kind)); \(boundaries.count) source inventories are incomplete. " +
            "See helperDeclarationInventories for every source, attribute/macro, possible effect and required evidence, and helperDeclarationAudits for the affected helper bindings. A formatting declaration cannot supply this evidence."
    }
}
