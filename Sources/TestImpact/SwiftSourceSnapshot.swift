// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import SwiftParser
import SwiftSyntax

public struct SourceUnit: Codable, Sendable {
    public var key: String
    public var fingerprint: String
    public var kind: String
    public var scope: String
    public var region: SourceRegion
    /// Present only when evaluated location literals add meaning beyond syntax.
    /// Older graphs lack this evidence and keep their conservative fingerprint.
    public var syntaxFingerprint: String? = nil
}

public struct SwiftSourceSnapshot: Codable, Sendable {
    public var units: [SourceUnit]
    public var inheritance: [String: [String]]
    public var diagnostics: [String]
    /// Member declarations owned by the project, including extensions of SDK
    /// types. Optional so older saved graphs keep their conservative behavior.
    public var dispatchMembers: Set<String>? = nil
    /// Module-qualified overrides and required initializer implementations.
    public var dispatchOverrides: Set<String>? = nil
    /// Alias declarations shadow nominal names even when their targets cannot
    /// be resolved by the source index.
    public var typeAliases: Set<String>? = nil
    /// First inherited type for each class, excluding trailing conformances.
    /// Older snapshots fall back to the broader inheritance inventory.
    public var superclasses: [String: [String]]? = nil

    /// Match specialized superclass references to their nominal declarations.
    /// Parse the type so nested arguments, function types and qualification do
    /// not get confused with the enclosing type's name.
    static func nominalTypeName(_ spelling: String) -> String? {
        let tree = Parser.parse(source: "typealias ImpactSuperclass = " + spelling)
        guard !tree.hasError, tree.statements.count == 1,
              let declaration = tree.statements.first?.item.as(TypeAliasDeclSyntax.self) else { return nil }
        func name(_ type: TypeSyntax) -> String? {
            if let identifier = type.as(IdentifierTypeSyntax.self) { return identifier.name.text }
            if let member = type.as(MemberTypeSyntax.self), let base = name(member.baseType) {
                return base + "." + member.name.text
            }
            return nil
        }
        return name(declaration.initializer.value)
    }

    public static func parse(_ text: String, path: String, module: String) -> Self {
        let tree = Parser.parse(source: text)
        let locations = SourceLocationConverter(fileName: path, tree: tree)
        var result = Self(units: [], inheritance: [:], diagnostics: [])
        result.dispatchMembers = []
        result.dispatchOverrides = []
        result.typeAliases = []
        result.superclasses = [:]
        if tree.hasError { result.diagnostics.append("Swift syntax could not be parsed completely: \(path)") }
        // Preserve syntax structure, token kinds and literal contents, but not
        // trivia. Location values belong to their expression, not the whole file.
        func fingerprint(_ node: Syntax) -> String {
            if let token = node.as(TokenSyntax.self) { return "\(token.tokenKind):\(token.text.utf8.count):\(token.text)" }
            return "\(node.kind)[" + node.children(viewMode: .sourceAccurate).map(fingerprint).joined(separator: "|") + "]"
        }
        func locationValues(_ node: Syntax) -> [String] {
            var values: [String] = []
            for token in node.tokens(viewMode: .sourceAccurate) where token.tokenKind == .pound {
                guard let macro = token.parent?.as(MacroExpansionExprSyntax.self) else { continue }
                // Bare parameter defaults use the caller's location. Parenthesized
                // or arithmetic defaults use the declaration's location instead.
                if macro.parent?.is(InitializerClauseSyntax.self) == true &&
                    macro.parent?.parent?.is(FunctionParameterSyntax.self) == true { continue }
                let location = locations.location(for: macro.positionAfterSkippingLeadingTrivia)
                switch macro.macroName.text {
                case "line": values.append("line:\(location.presumedLine)")
                case "column": values.append("column:\(location.column)")
                case "file", "filePath": values.append("file:\(location.presumedFile)")
                case "fileID": values.append("fileID:\(module)/\(location.presumedFile.split(separator: "/").last ?? "")")
                default: break
                }
            }
            return values
        }
        func add(_ node: Syntax, header: Syntax, kind: String, scope: [String]) {
            if let alias = node.as(TypeAliasDeclSyntax.self) {
                result.typeAliases!.insert(([module] + scope + [alias.name.text]).joined(separator: "."))
            }
            if !scope.isEmpty {
                let names: [String]
                if let function = node.as(FunctionDeclSyntax.self) { names = [function.name.text] }
                else if node.is(InitializerDeclSyntax.self) { names = ["init"] }
                else if node.is(DeinitializerDeclSyntax.self) { names = ["deinit"] }
                else if node.is(SubscriptDeclSyntax.self) { names = ["subscript"] }
                else if let variable = node.as(VariableDeclSyntax.self) {
                    names = variable.bindings.compactMap { $0.pattern.as(IdentifierPatternSyntax.self)?.identifier.text }
                } else { names = [] }
                result.dispatchMembers!.formUnion(names.map { scope.joined(separator: ".") + "." + $0 })
                let modifiers = node.as(FunctionDeclSyntax.self)?.modifiers
                    ?? node.as(InitializerDeclSyntax.self)?.modifiers
                    ?? node.as(VariableDeclSyntax.self)?.modifiers
                    ?? node.as(SubscriptDeclSyntax.self)?.modifiers
                if modifiers?.contains(where: {
                    $0.name.tokenKind == .keyword(.override) ||
                        node.is(InitializerDeclSyntax.self) && $0.name.tokenKind == .keyword(.required)
                }) == true {
                    result.dispatchOverrides!.formUnion(names.map { module + "." + scope.joined(separator: ".") + "." + $0 })
                }
            }
            let start = locations.location(for: node.positionAfterSkippingLeadingTrivia).line
            let end = locations.location(for: node.endPositionBeforeTrailingTrivia).line
            let syntax = fingerprint(node)
            let values = locationValues(node)
            let semantic = values.isEmpty ? syntax : syntax + "@locations[" +
                values.map { "\($0.utf8.count):" + $0 }.joined(separator: "|") + "]"
            result.units.append(SourceUnit(
                key: module + ":" + scope.joined(separator: ".") + ":" + fingerprint(header),
                fingerprint: semantic,
                kind: kind, scope: scope.joined(separator: "."),
                region: SourceRegion(path: path, startLine: start, endLine: end),
                syntaxFingerprint: semantic == syntax ? nil : syntax))
        }
        func walk(_ node: Syntax, scope: [String]) {
            if let item = node.as(CodeBlockItemSyntax.self), !item.item.is(DeclSyntax.self) {
                add(node, header: node, kind: "topLevel", scope: scope)
            } else if let value = node.as(IfConfigDeclSyntax.self) {
                let header = Syntax(value.with(\.clauses, IfConfigClauseListSyntax(value.clauses.map { $0.with(\.elements, nil) })))
                add(header, header: header, kind: "configuration", scope: scope)
                for child in node.children(viewMode: .sourceAccurate) { walk(child, scope: scope) }
            } else if let value = node.as(ClassDeclSyntax.self) {
                let names = scope + [value.name.text]
                let header = Syntax(value.with(\.memberBlock.members, MemberBlockItemListSyntax([])))
                add(header, header: header, kind: "type", scope: names)
                result.inheritance[module + "." + names.joined(separator: "."), default: []] += value.inheritanceClause?.inheritedTypes.map { $0.type.trimmedDescription } ?? []
                result.superclasses![module + "." + names.joined(separator: "."), default: []] += value.inheritanceClause?.inheritedTypes.first.map { [$0.type.trimmedDescription] } ?? []
                for member in value.memberBlock.members { walk(Syntax(member.decl), scope: names) }
            } else if let value = node.as(ProtocolDeclSyntax.self) {
                let names = scope + [value.name.text]
                let header = Syntax(value.with(\.memberBlock.members, MemberBlockItemListSyntax([])))
                add(header, header: header, kind: "type", scope: names)
                for member in value.memberBlock.members { walk(Syntax(member.decl), scope: names) }
            } else if let value = node.as(StructDeclSyntax.self) {
                let names = scope + [value.name.text]
                let header = Syntax(value.with(\.memberBlock.members, MemberBlockItemListSyntax([])))
                add(header, header: header, kind: "type", scope: names)
                for member in value.memberBlock.members { walk(Syntax(member.decl), scope: names) }
            } else if let value = node.as(EnumDeclSyntax.self) {
                let names = scope + [value.name.text]
                let header = Syntax(value.with(\.memberBlock.members, MemberBlockItemListSyntax([])))
                add(header, header: header, kind: "type", scope: names)
                for member in value.memberBlock.members { walk(Syntax(member.decl), scope: names) }
            } else if let value = node.as(ExtensionDeclSyntax.self) {
                let names = [value.extendedType.trimmedDescription]
                let header = Syntax(value.with(\.memberBlock.members, MemberBlockItemListSyntax([])))
                add(header, header: header, kind: "extension", scope: names)
                for member in value.memberBlock.members { walk(Syntax(member.decl), scope: names) }
            } else if let value = node.as(FunctionDeclSyntax.self) {
                add(node, header: Syntax(value.with(\.body, nil)), kind: "function", scope: scope)
            } else if node.is(InitializerDeclSyntax.self) || node.is(DeinitializerDeclSyntax.self) || node.is(VariableDeclSyntax.self) || node.is(SubscriptDeclSyntax.self) {
                add(node, header: node, kind: "state", scope: scope)
            } else if node.is(ImportDeclSyntax.self) {
                add(node, header: node, kind: "import", scope: scope)
            } else if node.is(DeclSyntax.self) && !node.is(IfConfigDeclSyntax.self) {
                add(node, header: node, kind: "declaration", scope: scope)
            } else {
                for child in node.children(viewMode: .sourceAccurate) { walk(child, scope: scope) }
            }
        }
        walk(Syntax(tree), scope: [])
        return result
    }
}
