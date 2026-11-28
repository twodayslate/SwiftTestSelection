// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import SwiftSyntax

/// An unreferenced file-private type can still use its own members through
/// Self or implicit member lookup. Keep their defaults in that lexical scope.
struct LocationDefaultOwner {
    let source: String
    let type: String
}

/// Certify a lexical subtree only when its type cannot be named from outside
/// and runtime dispatch cannot bypass that lexical boundary.
struct PrivateLocationDefaultSyntax {
    private let identifiers: [String: [TokenSyntax]]
    private let hasExtensions: Bool

    init?(_ file: SourceFileSyntax, identifiers: [String: [TokenSyntax]], declarationIssues: [HelperDeclarationIssue]) {
        // These compiler attributes cannot synthesize a use of a private type.
        // Unknown expansions anywhere in the file can name it.
        guard declarationIssues.allSatisfy({ issue in
            issue.kind == "unresolved-attribute" && ["@inline", "@_transparent", "@resultBuilder", "@_functionBuilder"].contains(issue.spelling)
        }) else { return nil }
        self.identifiers = identifiers
        hasExtensions = file.tokens(viewMode: .sourceAccurate).contains { $0.tokenKind == .keyword(.extension) }
    }

    func scope(for node: Syntax, in parents: [String]) -> String? {
        guard let group = node.asProtocol(DeclGroupSyntax.self), group.inheritanceClause == nil,
              group.modifiers.contains(where: { [.keyword(.private), .keyword(.fileprivate)].contains($0.name.tokenKind) }),
              node.is(StructDeclSyntax.self) || node.is(EnumDeclSyntax.self) || node.is(ClassDeclSyntax.self),
              let name = node.asProtocol(NamedDeclSyntax.self)?.name, let spelling = name.identifier?.name,
              let uses = identifiers[spelling],
              uses.allSatisfy({ $0.position >= node.position && $0.endPosition <= node.endPosition })
        else { return nil }

        // A nested type can satisfy an associated-type requirement without its
        // name appearing at the conformance. Check its enclosing declarations.
        if !parents.isEmpty {
            guard !hasExtensions else { return nil }
            var parent = node.parent
            while let ancestor = parent {
                if let enclosing = ancestor.asProtocol(DeclGroupSyntax.self),
                   enclosing.inheritanceClause != nil || !enclosing.attributes.isEmpty { return nil }
                parent = ancestor.parent
            }
        }

        // Inspect the whole subtree, including local declarations, opaque actor
        // units and inactive branches. AnyObject can reach Objective-C members
        // without naming the type. A subclass can inherit that exposure.
        // A nested value type's conformance alone does not expose its owner.
        for token in node.tokens(viewMode: .sourceAccurate) {
            if token.tokenKind == .keyword(.dynamic) { return nil }
            if let inheritance = token.parent?.as(InheritanceClauseSyntax.self),
               inheritance.parent?.is(ClassDeclSyntax.self) == true || inheritance.parent?.is(ActorDeclSyntax.self) == true { return nil }
            if token.tokenKind == .atSign, let attribute = token.parent?.as(AttributeSyntax.self),
               ["objc", "objcMembers"].contains(attribute.attributeName.trimmedDescription) { return nil }
        }
        return (parents + [name.text]).joined(separator: ".")
    }
}

extension SourceUnit {
    var privateDefaultOwner: LocationDefaultOwner? {
        privateLocationDefaultScope.map { LocationDefaultOwner(source: qualifiedSourcePath, type: $0) }
    }
}

struct ScopedLocationKinds {
    var shared = Set<String>()
    private var bySource: [String: [String: Set<String>]] = [:]

    mutating func include(_ kinds: Set<String>, owner: LocationDefaultOwner?) {
        guard !kinds.isEmpty else { return }
        if let owner { bySource[owner.source, default: [:]][owner.type, default: []].formUnion(kinds) }
        else { shared.formUnion(kinds) }
    }

    mutating func formUnion(_ other: Self) {
        shared.formUnion(other.shared)
        for (source, types) in other.bySource {
            bySource[source, default: [:]].merge(types) { $0.union($1) }
        }
    }

    subscript(unit: SourceUnit) -> Set<String> {
        guard !unit.scope.isEmpty, !bySource.isEmpty, let types = bySource[unit.qualifiedSourcePath] else { return shared }
        var kinds = shared
        var scope = unit.scope[...]
        while !scope.isEmpty {
            if let local = types[String(scope)] { kinds.formUnion(local) }
            guard let dot = scope.lastIndex(of: ".") else { break }
            scope = scope[..<dot]
        }
        return kinds
    }
}
