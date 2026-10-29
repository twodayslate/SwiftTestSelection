// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import SwiftSyntax

/// Uses, not declarations: a current SDK call does not authenticate the same
/// expression when a competing project overload existed in the base revision.
public struct HelperBindingUses: Codable, Sendable {
    public var operators: Set<String> = []
    public var members: Set<String> = []
    public var globals: Set<String> = []

    init(in node: Syntax) {
        for token in node.tokens(viewMode: .sourceAccurate) {
            if token.parent?.as(BinaryOperatorExprSyntax.self)?.operator.id == token.id ||
                token.parent?.as(PrefixOperatorExprSyntax.self)?.operator.id == token.id ||
                token.parent?.as(PostfixOperatorExprSyntax.self)?.operator.id == token.id {
                operators.insert(token.text)
            }
            if token.parent?.as(ExpressionSegmentSyntax.self)?.backslash.id == token.id {
                members.formUnion(["init", "appendLiteral", "appendInterpolation"])
            }
            if let call = token.parent?.as(SubscriptCallExprSyntax.self), call.leftSquare.id == token.id {
                members.insert("subscript")
            }
            if let reference = token.parent?.as(DeclReferenceExprSyntax.self), reference.baseName.id == token.id,
               reference.parent?.as(MemberAccessExprSyntax.self)?.declName.id == reference.id {
                members.insert(SDKTestHelperSyntax.canonicalName(reference.baseName.text))
            }
            if let reference = token.parent?.as(DeclReferenceExprSyntax.self), reference.baseName.id == token.id,
               reference.parent?.as(MemberAccessExprSyntax.self)?.declName.id != reference.id {
                globals.insert(SDKTestHelperSyntax.canonicalName(reference.baseName.text))
            }
            if let type = token.parent?.as(IdentifierTypeSyntax.self), type.name.id == token.id {
                globals.insert(SDKTestHelperSyntax.canonicalName(type.name.text))
            }
            // The source syntax cannot distinguish a bare constructor from a
            // function or metatype value call. Audit initializer overloads too.
            if let call = token.parent?.as(FunctionCallExprSyntax.self), call.leftParen?.id == token.id {
                members.insert("init")
            }
            if let closure = token.parent?.as(ClosureExprSyntax.self), closure.leftBrace.id == token.id,
               closure.parent?.as(FunctionCallExprSyntax.self)?.trailingClosure?.id == closure.id {
                members.insert("init")
            }
        }
    }
}
