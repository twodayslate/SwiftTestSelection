// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import SwiftSyntax

/// Source evidence for a deliberately small, read-only XCTest waiting language.
/// No method names or source paths are prescribed by this contract.
public struct SDKTestHelperSyntax: Codable, Sendable {
    public var version: Int
    public var name: String
    public var blocker: String?
    public var queriedMembers: Set<String> = []
    // Version 5 also proves the import boundary of enclosing assertion/operator
    // calls. Version 4's lexical shadow checks could miss external overloads.
    static let currentVersion = 5
    static let trustedModules: Set<String> = ["XCTest", "Foundation", "Swift"]
    // UIKit is allowed in callers for UI types, not in the helper query body.
    // These SDKs do not replace XCTest assertions or Swift's Bool negation.
    static let trustedCallerModules = trustedModules.union(["UIKit"])

    public struct References: Codable, Sendable {
        public var declarations: Set<Int> = []
        public var callers: Set<Int> = []
        public var unsupported = false
        public var unsupportedLines: Set<Int> = []
        public var untrustedWrapperImports: Bool? = nil
    }

    static let assertions: Set<String> = ["XCTAssert", "XCTAssertTrue", "XCTAssertFalse", "XCTAssertEqual", "XCTAssertNotEqual",
        "XCTAssertNil", "XCTAssertNotNil", "XCTAssertGreaterThan", "XCTAssertGreaterThanOrEqual", "XCTAssertLessThan", "XCTAssertLessThanOrEqual", "XCTFail"]
    static let names = assertions.union(["XCUIElement", "NSPredicate", "XCTNSPredicateExpectation", "XCTWaiter", "String", "Bool", "TimeInterval", "Double"])
    static let lifecycle: Set<String> = ["setUp", "setUpWithError", "tearDown", "tearDownWithError", "setUpClass", "tearDownClass", "defaultTestSuite", "testInvocations"]

    /// Swift backticks quote an identifier without changing its identity. Apply
    /// this to saved evidence too; source fingerprints keep their original text.
    static func canonicalName(_ spelling: String) -> String {
        spelling.contains("`") ? spelling.replacingOccurrences(of: "`", with: "") : spelling
    }

    /// Older captures can contain multiple raw keys for one Swift signature.
    /// Merge all evidence; choosing one key could lose callers or escape flags.
    static func canonicalReferences(_ references: [String: References]) -> [String: References] {
        // Leave the common, already-canonical map shared through copy-on-write.
        var result = references
        for (key, evidence) in references where key.contains("`") {
            result.removeValue(forKey: key)
            let key = canonicalName(key)
            result[key, default: References()].declarations.formUnion(evidence.declarations)
            result[key, default: References()].callers.formUnion(evidence.callers)
            result[key, default: References()].unsupportedLines.formUnion(evidence.unsupportedLines)
            result[key, default: References()].unsupported = result[key]!.unsupported || evidence.unsupported
            if evidence.untrustedWrapperImports == true { result[key]!.untrustedWrapperImports = true }
        }
        return result
    }

    static func signature(_ function: FunctionDeclSyntax) -> String {
        canonicalName(function.name.text + "(" + function.signature.parameterClause.parameters.map { $0.firstName.text + ":" }.joined() + ")")
    }

    static func referenceKey(_ token: TokenSyntax) -> String? {
        if let function = token.parent?.as(FunctionDeclSyntax.self), function.name.id == token.id { return signature(function) }
        guard let reference = token.parent?.as(DeclReferenceExprSyntax.self), reference.argumentNames == nil else { return nil }
        var expression = Syntax(reference)
        if let member = reference.parent?.as(MemberAccessExprSyntax.self), member.declName.id == reference.id { expression = Syntax(member) }
        guard let call = expression.parent?.as(FunctionCallExprSyntax.self), call.calledExpression.id == expression.id else { return nil }
        return canonicalName(token.text + "(" + call.arguments.map { ($0.label?.text ?? "_") + ":" }.joined() + ")")
    }

    /// Check imports once per source file. Declaration-scoped, attributed and
    /// unknown imports may introduce or re-export a same-spelled callable.
    static func callerImportsSupported(_ tree: SourceFileSyntax) -> Bool {
        tree.tokens(viewMode: .sourceAccurate).allSatisfy { token in
            guard token.tokenKind == .keyword(.import), let declaration = token.parent?.as(ImportDeclSyntax.self) else { return true }
            return declaration.attributes.isEmpty && declaration.importKindSpecifier == nil &&
                trustedCallerModules.contains(declaration.path.trimmedDescription)
        }
    }

    static func references(_ tokens: [TokenSyntax], locations: SourceLocationConverter, callerImportsSupported: Bool,
                           activeLocals: Set<Int> = [], matching signature: String? = nil) -> References {
        var result = References()
        for token in tokens {
            if let signature, let key = referenceKey(token), key != canonicalName(signature) { continue }
            func reject() {
                result.unsupported = true
                result.unsupportedLines.insert(locations.location(for: token.positionAfterSkippingLeadingTrivia).line)
            }
            if let function = token.parent?.as(FunctionDeclSyntax.self), function.name.id == token.id {
                result.declarations.insert(locations.location(for: function.positionAfterSkippingLeadingTrivia).line)
                continue
            }
            guard let reference = token.parent?.as(DeclReferenceExprSyntax.self), reference.argumentNames == nil else {
                reject(); continue
            }
            var expression = Syntax(reference)
            if let member = reference.parent?.as(MemberAccessExprSyntax.self), member.declName.id == reference.id { expression = Syntax(member) }
            guard let call = expression.parent?.as(FunctionCallExprSyntax.self), call.calledExpression.id == expression.id else {
                reject(); continue
            }
            var ancestor = call.parent
            var caller: FunctionDeclSyntax?
            var supported = true
            while let node = ancestor {
                if let function = node.as(FunctionDeclSyntax.self) { caller = function; break }
                if let outer = node.as(FunctionCallExprSyntax.self) {
                    // A bare assertion spelling is not proof of its binding:
                    // imported overloads can store an escaping autoclosure.
                    if !callerImportsSupported { result.untrustedWrapperImports = true; supported = false; break }
                    if !assertions.contains(outer.calledExpression.as(DeclReferenceExprSyntax.self)?.baseName.text ?? "") { supported = false; break }
                } else if let prefix = node.as(PrefixOperatorExprSyntax.self) {
                    if !callerImportsSupported { result.untrustedWrapperImports = true; supported = false; break }
                    if prefix.operator.text != "!" { supported = false; break }
                } else if node.is(IfExprSyntax.self) || node.is(SwitchExprSyntax.self) || node.is(TryExprSyntax.self) {
                    // Structured control flow does not retain or escape the call.
                } else if node.is(ExprSyntax.self) || node.is(PatternSyntax.self) || node.is(AccessorDeclSyntax.self) ||
                    node.is(DeferStmtSyntax.self) || node.is(FunctionParameterSyntax.self) {
                    supported = false; break
                }
                if let variable = node.as(VariableDeclSyntax.self), !variable.attributes.isEmpty || !variable.modifiers.isEmpty { supported = false; break }
                ancestor = node.parent
            }
            // A local named function is part of its enclosing source unit.
            // Collapse it only after proving its own references do not escape.
            while supported, let local = caller {
                var parent = local.parent
                var enclosing: FunctionDeclSyntax?
                while let node = parent {
                    if let function = node.as(FunctionDeclSyntax.self) { enclosing = function; break }
                    parent = node.parent
                }
                guard let enclosing else { break }
                let position = local.positionAfterSkippingLeadingTrivia.utf8Offset
                guard !activeLocals.contains(position), local.attributes.isEmpty, local.modifiers.isEmpty else { supported = false; break }
                let name = local.name.identifier?.name ?? local.name.text
                let uses = references(enclosing.tokens(viewMode: .sourceAccurate).filter { $0.identifier?.name == name },
                                      locations: locations, callerImportsSupported: callerImportsSupported, activeLocals: activeLocals.union([position]))
                if uses.untrustedWrapperImports == true { result.untrustedWrapperImports = true }
                guard !uses.unsupported, uses.declarations.count == 1, !uses.callers.isEmpty else { supported = false; break }
                caller = enclosing
            }
            if supported, let caller { result.callers.insert(locations.location(for: caller.positionAfterSkippingLeadingTrivia).line) }
            else { reject() }
        }
        return result
    }

    static func callerSupported(_ function: FunctionDeclSyntax) -> Bool {
        guard !lifecycle.contains(function.name.text),
              function.modifiers.allSatisfy({ ["private", "fileprivate", "internal", "final", "static"].contains($0.name.text) }),
              function.attributes.allSatisfy({ $0.as(AttributeSyntax.self)?.attributeName.trimmedDescription == "MainActor" }) else { return false }
        if function.parent?.is(CodeBlockItemSyntax.self) == true { return true }
        if let type = function.parent?.parent?.parent?.parent?.as(ClassDeclSyntax.self) {
            return PrivateTestHelperSyntax.safeSuperclass(type) != nil
        }
        if let ext = function.parent?.parent?.parent?.parent?.as(ExtensionDeclSyntax.self) {
            return ["XCUIElement", "XCTest.XCUIElement"].contains(ext.extendedType.trimmedDescription) &&
                ext.attributes.allSatisfy { $0.as(AttributeSyntax.self)?.attributeName.trimmedDescription == "MainActor" }
        }
        return false
    }

    static func prove(_ function: FunctionDeclSyntax) -> Self? {
        guard let ext = function.parent?.parent?.parent?.parent?.as(ExtensionDeclSyntax.self),
              ["XCUIElement", "XCTest.XCUIElement"].contains(ext.extendedType.trimmedDescription) else { return nil }
        var evidence = Self(version: currentVersion, name: function.name.identifier?.name ?? function.name.text)
        var root = Syntax(function)
        while let parent = root.parent { root = parent }
        let imports = root.tokens(viewMode: .sourceAccurate).compactMap { token -> ImportDeclSyntax? in
            guard token.tokenKind == .keyword(.import) else { return nil }
            return token.parent?.as(ImportDeclSyntax.self)
        }
        guard imports.allSatisfy({ $0.attributes.isEmpty && $0.importKindSpecifier == nil && trustedModules.contains($0.path.trimmedDescription) }) else {
            evidence.blocker = "Helper file imports modules outside the trusted XCTest/Foundation/Swift boundary"; return evidence
        }
        evidence.queriedMembers = Set(function.tokens(viewMode: .sourceAccurate).map(\.text)).intersection(
            ["exists", "value", "isEnabled", "isHittable", "isSelected", "evaluate", "wait", "waitForExistence", "waitForNonExistence"])
        guard callerSupported(function), ext.inheritanceClause == nil, ext.genericWhereClause == nil,
              function.genericParameterClause == nil, function.genericWhereClause == nil,
              function.signature.effectSpecifiers == nil, function.signature.returnClause?.type.trimmedDescription == "Bool" else {
            evidence.blocker = "Unsupported exposure, signature or extension constraints"; return evidence
        }
        guard Body(function).proves() else { evidence.blocker = "Body is outside the read-only query/predicate/expectation contract"; return evidence }
        return evidence
    }

    private struct Body {
        let function: FunctionDeclSyntax
        init(_ function: FunctionDeclSyntax) { self.function = function }
        enum Value { case string, number, boolean, predicate, expectation }
        func proves() -> Bool {
            var locals: [String: Value] = [:]
            for parameter in function.signature.parameterClause.parameters {
                let type: Value
                switch parameter.type.trimmedDescription {
                case "String": type = .string
                case "TimeInterval", "Double": type = .number
                case "Bool": type = .boolean
                default: return false
                }
                let name = (parameter.secondName ?? parameter.firstName).text
                guard parameter.attributes.isEmpty, parameter.modifiers.isEmpty, parameter.ellipsis == nil,
                      !names.contains(name), !["self", "exists", "value", "isEnabled", "isHittable", "isSelected"].contains(name) else { return false }
                if let value = parameter.defaultValue?.value {
                    guard value.is(IntegerLiteralExprSyntax.self) || value.is(FloatLiteralExprSyntax.self) else { return false }
                }
                locals[name] = type
            }
            var waited = false
            func isSelf(_ expression: ExprSyntax) -> Bool { expression.as(DeclReferenceExprSyntax.self)?.baseName.text == "self" }
            func arguments(_ call: FunctionCallExprSyntax, _ labels: [String?]) -> Bool {
                call.arguments.map { $0.label?.text } == labels && call.trailingClosure == nil && call.additionalTrailingClosures.isEmpty
            }
            func predicate(_ expression: ExprSyntax) -> Bool {
                guard let call = expression.as(FunctionCallExprSyntax.self), call.calledExpression.trimmedDescription == "NSPredicate" else { return false }
                if let closure = call.trailingClosure {
                    guard call.arguments.isEmpty, call.additionalTrailingClosures.isEmpty,
                          closure.signature?.capture == nil, closure.signature?.attributes.isEmpty ?? true,
                          closure.signature?.parameterClause?.tokens(viewMode: .sourceAccurate).map(\.text) == ["_", ",", "_"],
                          closure.statements.count == 1, let statement = closure.statements.first else { return false }
                    let value = statement.item.as(ExprSyntax.self) ?? statement.item.as(ReturnStmtSyntax.self)?.expression
                    return value.map(query) ?? false
                }
                guard arguments(call, ["format", nil]), let format = call.arguments.first?.expression.trimmedDescription,
                      ["\"value == %@\"", "\"value != %@\""].contains(format), let value = call.arguments.last?.expression else { return false }
                return query(value)
            }
            func query(_ expression: ExprSyntax) -> Bool {
                if let name = expression.as(DeclReferenceExprSyntax.self)?.baseName.text {
                    return ["self", "exists", "value", "isEnabled", "isHittable", "isSelected"].contains(name) ||
                        locals[name].map { [.string, .number, .boolean].contains($0) } == true
                }
                if expression.is(BooleanLiteralExprSyntax.self) || expression.is(IntegerLiteralExprSyntax.self) || expression.is(FloatLiteralExprSyntax.self) { return true }
                if let text = expression.as(StringLiteralExprSyntax.self) { return text.segments.allSatisfy { $0.is(StringSegmentSyntax.self) } }
                if let member = expression.as(MemberAccessExprSyntax.self) {
                    if member.base == nil { return member.declName.baseName.text == "completed" }
                    return member.base.map(isSelf) == true && ["exists", "value", "isEnabled", "isHittable", "isSelected"].contains(member.declName.baseName.text)
                }
                if let prefix = expression.as(PrefixOperatorExprSyntax.self) { return prefix.operator.text == "!" && query(prefix.expression) }
                if let sequence = expression.as(SequenceExprSyntax.self) { return sequence.elements.allSatisfy(query) }
                if let op = expression.as(BinaryOperatorExprSyntax.self) { return ["==", "!=", "&&", "||"].contains(op.operator.text) }
                if let cast = expression.as(UnresolvedAsExprSyntax.self) { return cast.questionOrExclamationMark?.text == "?" }
                if let type = expression.as(TypeExprSyntax.self) { return type.type.trimmedDescription == "String" }
                if let call = expression.as(FunctionCallExprSyntax.self) {
                    let bare = call.calledExpression.as(DeclReferenceExprSyntax.self)?.baseName.text
                    let member = call.calledExpression.as(MemberAccessExprSyntax.self)
                    let name = bare ?? (member?.base.map(isSelf) == true ? member?.declName.baseName.text : nil)
                    if let name, ["waitForExistence", "waitForNonExistence"].contains(name), arguments(call, ["timeout"]),
                       let timeout = call.arguments.first?.expression,
                       locals[timeout.trimmedDescription] == .number || timeout.is(IntegerLiteralExprSyntax.self) || timeout.is(FloatLiteralExprSyntax.self) {
                        waited = true; return true
                    }
                }
                guard let call = expression.as(FunctionCallExprSyntax.self), let member = call.calledExpression.as(MemberAccessExprSyntax.self),
                      let receiver = member.base?.as(DeclReferenceExprSyntax.self)?.baseName.text else { return false }
                if locals[receiver] == .predicate && member.declName.baseName.text == "evaluate" {
                    return arguments(call, ["with"]) && call.arguments.first.map { isSelf($0.expression) } == true
                }
                if receiver == "XCTWaiter", member.declName.baseName.text == "wait", arguments(call, ["for", "timeout"]),
                   let array = call.arguments.first?.expression.as(ArrayExprSyntax.self), !array.elements.isEmpty,
                   array.elements.allSatisfy({ locals[$0.expression.trimmedDescription] == .expectation }),
                   let timeout = call.arguments.last?.expression, query(timeout) {
                    waited = true; return true
                }
                return false
            }
            func statements(_ list: CodeBlockItemListSyntax) -> Bool {
                for statement in list {
                    if let variable = statement.item.as(VariableDeclSyntax.self) {
                        guard variable.bindingSpecifier.text == "let", variable.attributes.isEmpty, variable.modifiers.isEmpty,
                              variable.bindings.count == 1, let binding = variable.bindings.first,
                              let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text,
                              locals[name] == nil, !names.contains(name), binding.typeAnnotation == nil, binding.accessorBlock == nil,
                              let expression = binding.initializer?.value else { return false }
                        if predicate(expression) { locals[name] = .predicate }
                        else if let call = expression.as(FunctionCallExprSyntax.self), call.calledExpression.trimmedDescription == "XCTNSPredicateExpectation",
                                arguments(call, ["predicate", "object"]), let first = call.arguments.first?.expression,
                                (locals[first.trimmedDescription] == .predicate || predicate(first)),
                                call.arguments.last.map({ isSelf($0.expression) }) == true { locals[name] = .expectation }
                        else { return false }
                    } else if let result = statement.item.as(ReturnStmtSyntax.self), let expression = result.expression {
                        guard query(expression) else { return false }
                    } else if let condition = statement.item.as(IfExprSyntax.self) ?? statement.item.as(ExpressionStmtSyntax.self)?.expression.as(IfExprSyntax.self) {
                        guard condition.conditions.count == 1, let expression = condition.conditions.first?.condition.as(ExprSyntax.self),
                              query(expression), condition.elseBody == nil, statements(condition.body.statements) else { return false }
                    } else { return false }
                }
                return true
            }
            guard let body = function.body else { return false }
            if body.statements.count == 1, let expression = body.statements.first?.item.as(ExprSyntax.self) {
                return query(expression) && waited
            }
            return statements(body.statements) && waited
        }
    }
}
