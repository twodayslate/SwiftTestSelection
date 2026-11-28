// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation
import SwiftParser
import SwiftSyntax

enum SwiftPackageManifest {
    /// Package manifests are build inputs wherever the package lives, including
    /// the toolchain-specific Package@swift-<version>.swift variants.
    static func matches(_ path: String) -> Bool {
        guard path.hasSuffix(".swift"), let name = path.split(separator: "/").last else { return false }
        return name == "Package.swift" || name.hasPrefix("Package@swift-")
    }

    // SwiftPM scans raw lines for the tools version, even inside a multiline
    // string. A template in a compiled source is harmless when the directive
    // only occurs in literal text and the file cannot register a package.
    static func isCompiledSourceOnly(_ path: String, text: String, tree: SourceFileSyntax? = nil) -> Bool {
        guard matches(path) else { return false }
        let header = #"(?im)^[\h\uFEFF]*//\h*swift-tools-version\b"#
        guard text.range(of: header, options: .regularExpression) != nil else { return true }
        let syntax = tree ?? Parser.parse(source: text)
        guard !syntax.hasError else { return false }
        var outsideStrings = ""
        var hasUnknownImport = false
        for token in syntax.tokens(viewMode: .sourceAccurate) {
            if let declaration = token.parent?.as(ImportDeclSyntax.self),
               token.tokenKind == .keyword(.import),
               !["Swift", "Foundation"].contains(declaration.path.first?.name.text ?? "") { hasUnknownImport = true }
            if case .stringSegment = token.tokenKind {
                outsideStrings += token.leadingTrivia.description + " " + token.trailingTrivia.description
            } else {
                outsideStrings += token.description
            }
        }
        guard outsideStrings.range(of: header, options: .regularExpression) == nil else { return false }
        guard hasUnknownImport else { return true }

        // An imported module can re-export PackageDescription. Even then, a
        // manifest must execute code to register a Package. Ordinary declarations
        // and a template literal alone cannot register one.
        return syntax.statements.allSatisfy { item in
            if item.item.is(ImportDeclSyntax.self) { return true }
            if let variable = item.item.as(VariableDeclSyntax.self) {
                return variable.attributes.isEmpty && variable.bindings.allSatisfy { binding in
                    binding.typeAnnotation == nil && binding.accessorBlock == nil &&
                        binding.initializer.map { PrivateTestHelperSyntax.primitiveValue($0.value, type: nil) } == true
                }
            }
            guard let decl = item.item.as(DeclSyntax.self),
                  decl.asProtocol(WithAttributesSyntax.self)?.attributes.isEmpty == true else { return false }
            return decl.is(FunctionDeclSyntax.self) || decl.is(StructDeclSyntax.self) || decl.is(ClassDeclSyntax.self) ||
                decl.is(ActorDeclSyntax.self) || decl.is(EnumDeclSyntax.self) || decl.is(ProtocolDeclSyntax.self) || decl.is(ExtensionDeclSyntax.self)
        }
    }
}
