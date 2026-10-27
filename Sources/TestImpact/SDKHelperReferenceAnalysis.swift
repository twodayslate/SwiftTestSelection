// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import SwiftSyntax

/// One analysis per source snapshot. Classify each reference once, and resolve
/// local-function caller relationships once with a heap-based DFS. The file's
/// existing identifier index avoids rescanning an enclosing function's tokens.
final class SDKHelperReferenceAnalysis {
    typealias References = SDKTestHelperSyntax.References
    private enum Use {
        case declaration(Int)
        case call(FunctionDeclSyntax)
        case unsupported(untrustedImports: Bool)
    }
    private struct Resolution {
        var root: FunctionDeclSyntax?
        var untrustedImports = false
    }
    private struct Local {
        var function: FunctionDeclSyntax
        var enclosing: FunctionDeclSyntax
        var dependencies: [FunctionDeclSyntax]
        var valid: Bool
        var untrustedImports: Bool
    }
    private let identifiers: [String: [TokenSyntax]]
    private let locations: SourceLocationConverter
    private let callerImportsSupported: Bool
    private var uses: [SyntaxIdentifier: Use] = [:]
    private var resolved: [SyntaxIdentifier: Resolution] = [:]
    private(set) var classifiedTokenCount = 0
    private(set) var localFunctionEvaluationCount = 0

    init(identifiers: [String: [TokenSyntax]], locations: SourceLocationConverter, callerImportsSupported: Bool) {
        self.identifiers = identifiers
        self.locations = locations
        self.callerImportsSupported = callerImportsSupported
    }

    func references(_ tokens: [TokenSyntax], matching signature: String? = nil) -> References {
        var result = References()
        for token in tokens {
            if let signature, let key = SDKTestHelperSyntax.referenceKey(token), key != SDKTestHelperSyntax.canonicalName(signature) { continue }
            switch classify(token) {
            case let .declaration(line): result.declarations.insert(line)
            case let .call(caller):
                let resolution = resolve(caller)
                if resolution.untrustedImports { result.untrustedWrapperImports = true }
                if let root = resolution.root {
                    result.callers.insert(locations.location(for: root.positionAfterSkippingLeadingTrivia).line)
                } else { reject(token, result: &result) }
            case let .unsupported(untrustedImports):
                if untrustedImports { result.untrustedWrapperImports = true }
                reject(token, result: &result)
            }
        }
        return result
    }

    private func reject(_ token: TokenSyntax, result: inout References) {
        result.unsupported = true
        result.unsupportedLines.insert(locations.location(for: token.positionAfterSkippingLeadingTrivia).line)
    }

    private func classify(_ token: TokenSyntax) -> Use {
        if let cached = uses[token.id] { return cached }
        classifiedTokenCount += 1
        let use = classifyUncached(token)
        uses[token.id] = use
        return use
    }

    private func classifyUncached(_ token: TokenSyntax) -> Use {
        if let function = token.parent?.as(FunctionDeclSyntax.self), function.name.id == token.id {
            return .declaration(locations.location(for: function.positionAfterSkippingLeadingTrivia).line)
        }
        guard let reference = token.parent?.as(DeclReferenceExprSyntax.self), reference.argumentNames == nil else { return .unsupported(untrustedImports: false) }
        var expression = Syntax(reference)
        if let member = reference.parent?.as(MemberAccessExprSyntax.self), member.declName.id == reference.id { expression = Syntax(member) }
        guard let call = expression.parent?.as(FunctionCallExprSyntax.self), call.calledExpression.id == expression.id else { return .unsupported(untrustedImports: false) }
        var ancestor = call.parent
        while let node = ancestor {
            if let function = node.as(FunctionDeclSyntax.self) { return .call(function) }
            if let outer = node.as(FunctionCallExprSyntax.self) {
                guard callerImportsSupported else { return .unsupported(untrustedImports: true) }
                guard SDKTestHelperSyntax.assertions.contains(outer.calledExpression.as(DeclReferenceExprSyntax.self)?.baseName.text ?? "") else { return .unsupported(untrustedImports: false) }
            } else if let prefix = node.as(PrefixOperatorExprSyntax.self) {
                guard callerImportsSupported else { return .unsupported(untrustedImports: true) }
                guard prefix.operator.text == "!" else { return .unsupported(untrustedImports: false) }
            } else if node.is(IfExprSyntax.self) || node.is(SwitchExprSyntax.self) || node.is(TryExprSyntax.self) {
                // Structured control flow does not retain or escape the call.
            } else if node.is(ExprSyntax.self) || node.is(PatternSyntax.self) || node.is(AccessorDeclSyntax.self) ||
                        node.is(DeferStmtSyntax.self) || node.is(FunctionParameterSyntax.self) {
                return .unsupported(untrustedImports: false)
            }
            if let variable = node.as(VariableDeclSyntax.self), !variable.attributes.isEmpty || !variable.modifiers.isEmpty { return .unsupported(untrustedImports: false) }
            ancestor = node.parent
        }
        return .unsupported(untrustedImports: false)
    }

    private func enclosingFunction(_ function: FunctionDeclSyntax) -> FunctionDeclSyntax? {
        var parent = function.parent
        while let node = parent {
            if let function = node.as(FunctionDeclSyntax.self) { return function }
            parent = node.parent
        }
        return nil
    }

    private func local(_ function: FunctionDeclSyntax, enclosing: FunctionDeclSyntax) -> Local {
        localFunctionEvaluationCount += 1
        let name = function.name.identifier?.name ?? function.name.text
        let start = enclosing.position.utf8Offset, end = enclosing.endPosition.utf8Offset
        var declarations = Set<SyntaxIdentifier>(), callers: [SyntaxIdentifier: FunctionDeclSyntax] = [:]
        var valid = function.attributes.isEmpty && function.modifiers.isEmpty, untrusted = false
        for token in identifiers[name] ?? [] where token.position.utf8Offset >= start && token.position.utf8Offset < end {
            switch classify(token) {
            case .declaration: declarations.insert(token.id)
            case let .call(caller): callers[caller.id] = caller
            case let .unsupported(imports): valid = false; untrusted = untrusted || imports
            }
        }
        valid = valid && declarations.count == 1 && !callers.isEmpty
        // The enclosing function must itself be nonescaping if it is local.
        // Include it even when every use is inside a different nested function.
        callers[enclosing.id] = enclosing
        return Local(function: function, enclosing: enclosing,
                     dependencies: callers.values.sorted { $0.position < $1.position }, valid: valid, untrustedImports: untrusted)
    }

    private func resolve(_ function: FunctionDeclSyntax) -> Resolution {
        if let cached = resolved[function.id] { return cached }
        enum Work { case enter(FunctionDeclSyntax); case finish(Local) }
        var pending: [Work] = [.enter(function)], active = Set<SyntaxIdentifier>()
        while let item = pending.popLast() {
            switch item {
            case let .enter(candidate):
                if resolved[candidate.id] != nil { continue }
                guard active.insert(candidate.id).inserted else {
                    resolved[candidate.id] = Resolution(root: nil)
                    continue
                }
                guard let enclosing = enclosingFunction(candidate) else {
                    resolved[candidate.id] = Resolution(root: candidate)
                    active.remove(candidate.id)
                    continue
                }
                let proof = local(candidate, enclosing: enclosing)
                guard proof.valid else {
                    resolved[candidate.id] = Resolution(root: nil, untrustedImports: proof.untrustedImports)
                    active.remove(candidate.id)
                    continue
                }
                pending.append(.finish(proof))
                for dependency in proof.dependencies.reversed() { pending.append(.enter(dependency)) }
            case let .finish(proof):
                let valid = resolved[proof.function.id] == nil && proof.dependencies.allSatisfy { resolved[$0.id]?.root != nil }
                let untrusted = proof.untrustedImports || proof.dependencies.contains { resolved[$0.id]?.untrustedImports == true }
                resolved[proof.function.id] = Resolution(root: valid ? resolved[proof.enclosing.id]?.root : nil, untrustedImports: untrusted)
                active.remove(proof.function.id)
            }
        }
        return resolved[function.id]!
    }
}
