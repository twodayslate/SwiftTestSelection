// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import SwiftSyntax

/// SIL method display names omit labels. Record every source use, including
/// method values, so a valid call cannot hide an unproven overload in one body.
enum SDKReceiverCallSyntax {
    static func shapes(in node: Syntax) -> [String: Set<[String]>] {
        evidence(in: node).shapes
    }

    /// Collect both proofs in one token walk. Physical token positions pair
    /// labels with exact compiler uses, including same-line calls and closures.
    static func evidence(in node: Syntax, locations: SourceLocationConverter? = nil, path: String = "")
        -> (shapes: [String: Set<[String]>], sites: [String: [String]]) {
        var shapes: [String: Set<[String]>] = [:], sites: [String: [String]] = [:]
        for token in node.tokens(viewMode: .sourceAccurate) {
            if let subscriptCall = token.parent?.as(SubscriptCallExprSyntax.self), subscriptCall.leftSquare.id == token.id {
                shapes["subscript", default: []].insert(subscriptCall.arguments.map { SDKTestHelperSyntax.canonicalName($0.label?.text ?? "_") })
            }
            guard let reference = token.parent?.as(DeclReferenceExprSyntax.self), reference.baseName.id == token.id else { continue }
            let name = SDKTestHelperSyntax.canonicalName(reference.baseName.text)
            guard ExternalHelperEffects.receiverCallLabels[name] != nil else { continue }
            let expression = reference.parent?.as(MemberAccessExprSyntax.self).map(Syntax.init) ?? Syntax(reference)
            var labels = ["<value>"]
            if let call = expression.parent?.as(FunctionCallExprSyntax.self), call.calledExpression.id == expression.id,
               reference.argumentNames == nil {
                labels = call.arguments.map { SDKTestHelperSyntax.canonicalName($0.label?.text ?? "_") }
                if call.trailingClosure != nil { labels.append("<trailing>") }
                labels += call.additionalTrailingClosures.map { SDKTestHelperSyntax.canonicalName($0.label.text) }
            }
            shapes[name, default: []].insert(labels)
            if let locations, name == "matching" || name == "containing" {
                let point = locations.location(for: token.positionAfterSkippingLeadingTrivia)
                sites[path + "\t" + String(point.line) + "\t" + String(point.column)] = [name] + labels
            }
        }
        return (shapes, sites)
    }
}
