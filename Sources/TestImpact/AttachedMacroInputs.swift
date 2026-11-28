// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation
import SwiftSyntax
#if canImport(CryptoKit)
import CryptoKit
#endif

/// An attached macro receives the declaration's source text and position. Its
/// generated peers can have consumers with no edge to the annotated declaration.
enum AttachedMacroInputs {
    static func capture(_ tree: SourceFileSyntax, locations: SourceLocationConverter) -> [String: [String]] {
        var inputs: [String: [String]] = [:]
        var declarationDigests: [SyntaxIdentifier: String] = [:]
        for token in tree.tokens(viewMode: .sourceAccurate) where token.tokenKind == .atSign {
            guard let attribute = token.parent?.as(AttributeSyntax.self), !attribute.isNonBuilderCompilerAttribute else { continue }
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
            // Nested expansions also receive a lexical context. The outer declaration
            // covers changes to enclosing names and attributes at the same coordinates.
            var context = declaration
            var ancestor = declaration.parent
            while let node = ancestor {
                if node.is(DeclSyntax.self) { context = node }
                ancestor = node.parent
            }
            let digest: String
            if let cached = declarationDigests[context.id] {
                digest = cached
            } else {
                let location = locations.location(for: context.position)
                let first = locations.location(for: context.positionAfterSkippingLeadingTrivia)
                let raw = context.description
                #if canImport(CryptoKit)
                let content = Data(SHA256.hash(data: Data(raw.utf8))).base64EncodedString()
                #else
                let content = raw
                #endif
                digest = "\(location.offset):\(location.line):\(location.column):\(first.presumedLine):\(first.presumedFile):\(content)"
                declarationDigests[context.id] = digest
            }
            inputs[name, default: []].append(digest)
        }
        return inputs
    }

    static func changedPaths(base: [String: SwiftSourceSnapshot], head: [String: SwiftSourceSnapshot],
                             unowned: [String: SwiftSourceSnapshot] = [:], touching paths: Set<String>) -> Set<String> {
        let names = Set([base, head, unowned].flatMap { sources in
            sources.values.flatMap { file in
                (file.helperDeclarationIssues ?? []).filter { $0.kind == "macro-declaration" }.map {
                    $0.spelling.trimmingCharacters(in: CharacterSet(charactersIn: "`"))
                }
            }
        })
        var changed = Set<String>()
        for key in Set(base.keys).union(head.keys) {
            let before = base[key], after = head[key]
            guard let file = before ?? after, let id = file.sourceIdentity(storedAs: key), paths.contains(id.path) else { continue }
            if let old = before?.sourceBlobIDs, let new = after?.sourceBlobIDs, !old.isDisjoint(with: new) { continue }
            // A compiler plugin can implement macros from an imported binary module.
            // Its Swift declaration need not occur in either revision's sources.
            let opaque = before?.usesUnmodeledMacroPlugin == true || after?.usesUnmodeledMacroPlugin == true ||
                [before, after].compactMap { $0 }.contains { $0.attachedAttributeInputs == nil }
            if !opaque && names.isEmpty { continue }
            func inputs(_ file: SwiftSourceSnapshot?) -> [String: [String]]? {
                guard let file else { return [:] }
                if let inputs = file.attachedAttributeInputs { return opaque ? inputs : inputs.filter { names.contains($0.key) } }
                // Older archives can rule out an application when none of the
                // macro identifiers occurs anywhere in this source.
                if opaque { return nil }
                return file.identifierNames?.isDisjoint(with: names) == true ? [:] : nil
            }
            if let old = inputs(before), let new = inputs(after), old == new { continue }
            changed.insert(id.path)
        }
        return changed
    }

    static func reason(_ paths: Set<String>) -> String {
        "Attached macro inputs changed or could not be compared in " + paths.sorted().joined(separator: ", ") +
            ". Generated declarations can have consumers outside the annotated declaration."
    }
}
