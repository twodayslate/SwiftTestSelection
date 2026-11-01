// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
import SwiftSyntax

enum HelperIdentityVisibility {
    /// Names whose *every* written type/alias/macro declaration is bounded by
    /// private/fileprivate access, including an enclosing declaration. This is
    /// only an exclusion for uses in another file; same-file lexical/extension
    /// lookup and inherited accessible names remain conservative.
    static func fileRestrictedNames(_ tree: SourceFileSyntax) -> Set<String> {
        var restricted: [String: Bool] = [:]
        for token in tree.tokens(viewMode: .sourceAccurate) {
            guard let node = token.parent else { continue }
            let name: TokenSyntax?
            if let value = node.as(ClassDeclSyntax.self) { name = value.name }
            else if let value = node.as(StructDeclSyntax.self) { name = value.name }
            else if let value = node.as(EnumDeclSyntax.self) { name = value.name }
            else if let value = node.as(ProtocolDeclSyntax.self) { name = value.name }
            else if let value = node.as(TypeAliasDeclSyntax.self) { name = value.name }
            else if let value = node.as(MacroDeclSyntax.self) { name = value.name }
            else { name = nil }
            guard name?.id == token.id else { continue }
            var current: Syntax? = node, fileOnly = false
            while let ancestor = current {
                // Extension access is a default that an explicitly public member
                // can override; it is not an enclosing visibility boundary.
                if !ancestor.is(ExtensionDeclSyntax.self), let declaration = ancestor.asProtocol(DeclGroupSyntax.self),
                   declaration.modifiers.contains(where: { ["private", "fileprivate"].contains($0.name.text) }) { fileOnly = true }
                if let alias = ancestor.as(TypeAliasDeclSyntax.self),
                   alias.modifiers.contains(where: { ["private", "fileprivate"].contains($0.name.text) }) { fileOnly = true }
                if let macro = ancestor.as(MacroDeclSyntax.self),
                   macro.modifiers.contains(where: { ["private", "fileprivate"].contains($0.name.text) }) { fileOnly = true }
                current = ancestor.parent
            }
            let spelling = SDKTestHelperSyntax.canonicalName(token.text)
            restricted[spelling] = (restricted[spelling] ?? true) && fileOnly
        }
        return Set(restricted.compactMap { $0.value ? $0.key : nil })
    }
}
