// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import SwiftSyntax

/// Narrow source evidence for completion inputs consumed only by XCTest's
/// nil assertions or failure messages. Compiler bindings must independently verify those assertions.
enum SDKCallbackInputs {
    static func evidence(_ function: FunctionDeclSyntax, importsSupported: Bool,
                         locations: SourceLocationConverter) -> [String: [SourceRegion]] {
        guard importsSupported, let body = function.body else { return [:] }
        var candidates: [String: [SourceRegion]] = [:], rejected = Set<String>(), seen = Set<SyntaxIdentifier>()
        // One iterative pass per saved declaration, including its local
        // functions (which share that source unit). No recursive suffix scans.
        var pending = [Syntax(body)]
        while let node = pending.popLast() {
            pending.append(contentsOf: node.children(viewMode: .sourceAccurate))
            guard let reference = node.as(DeclReferenceExprSyntax.self) else { continue }
            if let member = reference.parent?.as(MemberAccessExprSyntax.self), member.declName.id != reference.id { continue }
            let expression = reference.parent?.as(MemberAccessExprSyntax.self).map(Syntax.init) ?? Syntax(reference)
            guard let call = expression.parent?.as(FunctionCallExprSyntax.self), call.calledExpression.id == expression.id,
                  seen.insert(call.id).inserted else { continue }
            let name = SDKTestHelperSyntax.canonicalName(reference.baseName.text)
            let closures = call.arguments.compactMap { $0.expression.as(ClosureExprSyntax.self) } +
                (call.trailingClosure.map { [$0] } ?? []) + call.additionalTrailingClosures.map(\.closure)
            guard closures.count == 1, let closure = closures.first, checked(closure) else {
                rejected.insert(name); continue
            }
            candidates[name, default: []].append(.init(path: locations.location(for: closure.positionAfterSkippingLeadingTrivia).file,
                startLine: locations.location(for: closure.positionAfterSkippingLeadingTrivia).line,
                endLine: locations.location(for: closure.endPositionBeforeTrailingTrivia).line))
        }
        return candidates.filter { !rejected.contains($0.key) }
    }

    private static func checked(_ closure: ClosureExprSyntax) -> Bool {
        guard let signature = closure.signature, signature.capture == nil,
              signature.attributes.isEmpty, let parameters = signature.parameterClause else { return false }
        let names: Set<String>
        switch parameters {
        case let .simpleInput(values): names = Set(values.map { SDKTestHelperSyntax.canonicalName($0.name.text) })
        case let .parameterClause(values): names = Set(values.parameters.map { SDKTestHelperSyntax.canonicalName(($0.secondName ?? $0.firstName).text) })
        }
        guard names.count == 1, !names.contains("_") else { return false }
        var used = false
        for token in closure.statements.tokens(viewMode: .sourceAccurate) where names.contains(SDKTestHelperSyntax.canonicalName(token.text)) {
            // Optional error completions commonly use shorthand unwrapping
            // before reporting a failure. No new name or initializer may hide
            // a store, cast, or forwarded value.
            if let pattern = token.parent?.as(IdentifierPatternSyntax.self),
               let binding = pattern.parent?.as(OptionalBindingConditionSyntax.self),
               binding.initializer == nil, binding.bindingSpecifier.text == "let" { continue }
            guard let reference = token.parent?.as(DeclReferenceExprSyntax.self), reference.baseName.id == token.id,
                  let argument = reference.parent?.as(LabeledExprSyntax.self), argument.expression.id == reference.id else { return false }
            if let segment = argument.parent?.parent?.as(ExpressionSegmentSyntax.self),
               let literal = segment.parent?.parent?.as(StringLiteralExprSyntax.self),
               let message = literal.parent?.as(LabeledExprSyntax.self),
               let call = message.parent?.parent?.as(FunctionCallExprSyntax.self),
               call.calledExpression.as(DeclReferenceExprSyntax.self)?.baseName.text == "XCTFail",
               call.arguments.first?.id == message.id {
                // Only interpolate the value itself, not a computed expression.
            } else {
                guard let call = argument.parent?.parent?.as(FunctionCallExprSyntax.self),
                      ["XCTAssertNil", "XCTAssertNotNil"].contains(call.calledExpression.as(DeclReferenceExprSyntax.self)?.baseName.text ?? ""),
                      call.arguments.first?.id == argument.id else { return false }
            }
            used = true
        }
        return used
    }
}
