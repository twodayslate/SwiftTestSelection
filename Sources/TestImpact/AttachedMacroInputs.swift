// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation
import SwiftParser
import SwiftSyntax
import SwiftSyntaxMacros
#if canImport(CryptoKit)
import CryptoKit
#endif

/// A macro can emit a declaration whose callers have no edge to the source
/// that supplied the expansion. Preserve the syntax and coordinates it can see.
enum AttachedMacroInputs {
    static let version = 3

    static func capture(_ tree: SourceFileSyntax, locations: SourceLocationConverter, indexedMainActor: Bool = false) -> [String: [String]] {
        var inputs: [String: [String]] = [:]
        var digests: [SyntaxIdentifier: String] = [:]
        func location(_ position: AbsolutePosition) -> String {
            let point = locations.location(for: position)
            return "\(point.offset):\(point.line):\(point.column):\(point.presumedLine):\(point.presumedFile.utf8.count):\(point.presumedFile)"
        }
        func record(_ name: String, input: Syntax, invocation: Syntax) {
            // Swift strips members and bodies from the lexical context it sends
            // alongside a macro's own syntax. Later siblings cannot move this site.
            let digest: String
            if let cached = digests[input.id] {
                digest = cached
            } else {
                var parts = [input.description, location(input.position), location(input.positionAfterSkippingLeadingTrivia)]
                var ancestor = input.parent
                while let node = ancestor {
                    if let context = node.asMacroLexicalContext() {
                        parts += [context.description, location(node.position), location(node.positionAfterSkippingLeadingTrivia)]
                    }
                    if let clause = node.as(IfConfigClauseSyntax.self),
                       let siblings = clause.parent?.as(IfConfigClauseListSyntax.self) {
                        for sibling in siblings {
                            parts.append(sibling.with(\.elements, nil).trimmedDescription)
                            if sibling.id == clause.id { break }
                        }
                    }
                    ancestor = node.parent
                }
                let raw = parts.map { "\($0.utf8.count):" + $0 }.joined()
                #if canImport(CryptoKit)
                digest = Data(SHA256.hash(data: Data(raw.utf8))).base64EncodedString()
                #else
                digest = raw
                #endif
                digests[input.id] = digest
            }
            inputs[name, default: []].append(location(invocation.positionAfterSkippingLeadingTrivia) + ":" + digest)
        }
        for token in tree.tokens(viewMode: .sourceAccurate) {
            if token.tokenKind == .pound, let node = token.parent,
               let macro = node.asProtocol(FreestandingMacroExpansionSyntax.self),
               let name = macro.macroName.identifier?.name {
                // A freestanding expansion receives its source and position in
                // both declaration and expression contexts. An expression macro
                // can embed that position in a value consumed by another file.
                record("#" + name, input: node, invocation: node)
                continue
            }
            guard token.tokenKind == .atSign, let attribute = token.parent?.as(AttributeSyntax.self),
                  !attribute.isNonBuilderCompilerAttribute, !(indexedMainActor && attribute.isBareMainActor) else { continue }
            let type = attribute.attributeName
            let identifier = type.as(IdentifierTypeSyntax.self)?.name ?? type.as(MemberTypeSyntax.self)?.name
            guard let name = identifier?.identifier?.name else { continue }
            var list = attribute.parent
            // Conditional attributes can nest their attribute list inside #if.
            while let node = list, !node.is(DeclSyntax.self) || node.is(IfConfigDeclSyntax.self) {
                if !node.is(AttributeListSyntax.self) && !node.is(IfConfigClauseSyntax.self) &&
                    !node.is(IfConfigClauseListSyntax.self) && !node.is(IfConfigDeclSyntax.self) { break }
                list = node.parent
            }
            guard let declaration = list, declaration.is(DeclSyntax.self) else { continue }
            if declaration.is(MacroDeclSyntax.self), ["attached", "freestanding"].contains(attribute.attributeName.trimmedDescription) { continue }
            record(name, input: declaration, invocation: Syntax(attribute))
        }
        return inputs
    }

    /// Re-exports can expose macro names supplied only by a binary module.
    static func historicalDeclarations(_ source: String) -> Set<String>? {
        let tree = Parser.parse(source: source)
        guard !tree.hasError else { return nil }
        var names = Set<String>()
        for token in tree.tokens(viewMode: .sourceAccurate) {
            if token.identifier?.name == "_exported",
               token.parent?.parent?.is(AttributeSyntax.self) == true { return nil }
            if let macro = token.parent?.as(MacroDeclSyntax.self), token.id == macro.macroKeyword.id {
                guard let name = macro.name.identifier?.name else { return nil }
                names.insert(name)
            }
        }
        return names
    }

    static func changedPaths(base: [String: SwiftSourceSnapshot], head: [String: SwiftSourceSnapshot],
                             unowned: [String: SwiftSourceSnapshot] = [:], historicalNames: Set<String> = [],
                             uncertainImports: Set<String> = [], verifiedImports: [String: Set<String>] = [:], touching paths: Set<String>) -> Set<String> {
        let names = Set([base, head, unowned].flatMap { sources in
            sources.values.flatMap { file in
                (file.helperDeclarationIssues ?? []).filter { $0.kind == "macro-declaration" }.map {
                    $0.spelling.trimmingCharacters(in: CharacterSet(charactersIn: "`"))
                }
            }
        }).union(historicalNames)
        var changed = Set<String>()
        for key in Set(base.keys).union(head.keys) {
            let before = base[key], after = head[key]
            guard let file = before ?? after, let id = file.sourceIdentity(storedAs: key), paths.contains(id.path) else { continue }
            if let old = before?.sourceBlobIDs, let new = after?.sourceBlobIDs, !old.isDisjoint(with: new) { continue }
            // A compiler plugin can implement macros from an imported binary module.
            // Its Swift declaration need not occur in either revision's sources.
            let files = [before, after].compactMap { $0 }
            guard files.allSatisfy({ $0.macroInputVersion == AttachedMacroInputs.version && $0.attachedAttributeInputs != nil }) else {
                changed.insert(id.path)
                continue
            }
            let usesPlugin = before?.usesUnmodeledMacroPlugin == true || after?.usesUnmodeledMacroPlugin == true
            let candidates: Set<String>?
            if uncertainImports.contains(id.path) { candidates = nil }
            else if let verified = verifiedImports[key] { candidates = names.union(verified) }
            else { candidates = usesPlugin ? nil : names }
            if candidates?.isEmpty == true { continue }
            func inputs(_ file: SwiftSourceSnapshot?) -> [String: [String]] {
                let sites = file?.attachedAttributeInputs ?? [:]
                guard let candidates else { return sites }
                return sites.filter { candidates.contains($0.key.hasPrefix("#") ? String($0.key.dropFirst()) : $0.key) }
            }
            if inputs(before) == inputs(after) { continue }
            changed.insert(id.path)
        }
        return changed
    }

    static func reason(_ paths: Set<String>) -> String {
        "Macro expansion inputs changed or could not be compared in " + paths.sorted().joined(separator: ", ") +
            ". Generated declarations and expression values can have consumers outside the source declaration."
    }
}
