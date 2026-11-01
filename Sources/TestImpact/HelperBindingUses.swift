// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import SwiftSyntax

/// Uses, not declarations: a current SDK call does not authenticate the same
/// expression when a competing project overload existed in the base revision.
public struct HelperBindingUses: Codable, Sendable, Equatable {
    public var operators: Set<String> = []
    /// Operators invoked by syntax without an operator token. Nil means the
    /// capture predates this inventory and cannot authenticate historical uses.
    public var implicitOperators: Set<String>? = []
    public var members: Set<String> = []
    public var globals: Set<String> = []
    /// Syntactic qualifiers may name the caller's module rather than a value.
    /// Nil is legacy evidence; an empty map proves no qualified references.
    public var qualifiedMembers: [String: Set<String>]? = [:]

    init(in node: Syntax) {
        let patterns = PatternOperatorUses(viewMode: .sourceAccurate)
        patterns.walk(node)
        implicitOperators = patterns.operators
        for token in node.tokens(viewMode: .sourceAccurate) {
            if token.parent?.as(BinaryOperatorExprSyntax.self)?.operator.id == token.id ||
                token.parent?.as(PrefixOperatorExprSyntax.self)?.operator.id == token.id ||
                token.parent?.as(PostfixOperatorExprSyntax.self)?.operator.id == token.id {
                operators.insert(token.text)
            }
            if let loop = token.parent?.as(ForStmtSyntax.self), loop.forKeyword.id == token.id {
                // Iteration invokes protocol members absent from the spelling
                // of a for-in loop, including in historical caller bodies.
                members.formUnion([loop.awaitKeyword == nil ? "makeIterator" : "makeAsyncIterator", "next"])
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
                if let base = reference.parent?.as(MemberAccessExprSyntax.self)?.base?.as(DeclReferenceExprSyntax.self) {
                    qualifiedMembers![SDKTestHelperSyntax.canonicalName(base.baseName.text), default: []]
                        .insert(SDKTestHelperSyntax.canonicalName(reference.baseName.text))
                }
            }
            if let reference = token.parent?.as(DeclReferenceExprSyntax.self), reference.baseName.id == token.id,
               reference.parent?.as(MemberAccessExprSyntax.self)?.declName.id != reference.id {
                globals.insert(SDKTestHelperSyntax.canonicalName(reference.baseName.text))
            }
            if let type = token.parent?.as(IdentifierTypeSyntax.self), type.name.id == token.id {
                globals.insert(SDKTestHelperSyntax.canonicalName(type.name.text))
            }
            if let type = token.parent?.as(MemberTypeSyntax.self), type.name.id == token.id {
                members.insert(SDKTestHelperSyntax.canonicalName(type.name.text))
                if let base = type.baseType.as(IdentifierTypeSyntax.self) {
                    qualifiedMembers![SDKTestHelperSyntax.canonicalName(base.name.text), default: []]
                        .insert(SDKTestHelperSyntax.canonicalName(type.name.text))
                }
            }
            // Without the base compiler, a call may be a constructor, ordinary
            // function, or callable value. Audit both implicit member names.
            if let call = token.parent?.as(FunctionCallExprSyntax.self), call.leftParen?.id == token.id {
                members.formUnion(["init", "callAsFunction"])
            }
            if let closure = token.parent?.as(ClosureExprSyntax.self), closure.leftBrace.id == token.id,
               closure.parent?.as(FunctionCallExprSyntax.self)?.trailingClosure?.id == closure.id {
                members.formUnion(["init", "callAsFunction"])
            }
        }
    }
}

private final class PatternOperatorUses: SyntaxVisitor {
    var operators = Set<String>()

    override func visit(_ node: ExpressionPatternSyntax) -> SyntaxVisitorContinueKind {
        // Covers switch/catch cases and matching conditions in if, guard,
        // while and for, including expression patterns inside tuple/optional
        // patterns. The head's SDK matcher does not prove the base overload.
        // SwiftParser also represents wildcard/tuple patterns as expressions.
        // They perform structural matching; inspect their elements instead of
        // inventing an operator call for `_` or a tuple of binding patterns.
        var pending = [node.expression]
        while let expression = pending.popLast() {
            if let tuple = expression.as(TupleExprSyntax.self) {
                pending += tuple.elements.map(\.expression)
            } else if !expression.is(DiscardAssignmentExprSyntax.self) && !expression.is(PatternExprSyntax.self) {
                operators.insert("~=")
                break
            }
        }
        return .visitChildren
    }
}
