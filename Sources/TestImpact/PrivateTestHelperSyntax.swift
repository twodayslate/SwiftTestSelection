// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import SwiftSyntax

/// Deliberately narrow source evidence, not a declaration that all private
/// functions are isolated. Compiler bindings and both revisions must agree.
public struct PrivateTestHelperSyntax: Codable, Sendable {
    public var name: String
    public var callerLines: Set<Int>
    /// A capture produced by an older escape analysis must not grant isolation.
    public var proofVersion: Int? = nil
    static let currentProofVersion = 3
    /// Nil in older captures, whose caller/escape proof is not sufficient.
    public var statements: [Statement]? = nil
    /// Writes are limited to newly created, local XCTest attachments.
    public var localAttachmentState: Bool? = nil

    public struct Statement: Codable, Sendable {
        public var signature: String
        public var isAssertion: Bool
    }

    private static let assertions: Set<String> = ["XCTAssert", "XCTAssertTrue", "XCTAssertFalse", "XCTAssertEqual", "XCTAssertNotEqual",
        "XCTAssertNil", "XCTAssertNotNil", "XCTAssertGreaterThan", "XCTAssertGreaterThanOrEqual", "XCTAssertLessThan",
        "XCTAssertLessThanOrEqual", "XCTFail"]

    /// A head graph cannot establish effects of removed/rebound base calls.
    /// Preserve every old statement and its binding/control-flow context. Only
    /// standalone assertions may be inserted; their head effects are checked by
    /// the compiler graph. This is deliberately stricter than matching call names.
    func preservesEffects(of previous: Self) -> Bool {
        guard let statements, let old = previous.statements else { return false }
        var next = 0
        for statement in statements {
            if next < old.count, statement.signature == old[next].signature { next += 1 }
            else if !statement.isAssertion { return false }
        }
        return next == old.count
    }

    private static func statements(in function: FunctionDeclSyntax) -> [Statement] {
        (function.body?.statements ?? []).map { statement in
            let call = statement.item.as(FunctionCallExprSyntax.self)
                ?? statement.item.as(ExpressionStmtSyntax.self)?.expression.as(FunctionCallExprSyntax.self)
            let name = call?.calledExpression.as(DeclReferenceExprSyntax.self)?.baseName.text
            let signature = statement.item.tokens(viewMode: .sourceAccurate).map {
                "\($0.tokenKind):\($0.text.utf8.count):\($0.text)"
            }.joined(separator: "|")
            return Statement(signature: signature, isAssertion: name.map(assertions.contains) ?? false)
        }
    }

    static let reservedNames: Set<String> = ["XCTestCase", "String", "Bool", "Int", "Double", "XCUIApplication", "XCUIElement", "NSPredicate", "XCTAttachment",
        "XCTAssert", "XCTAssertTrue", "XCTAssertFalse", "XCTAssertEqual", "XCTAssertNotEqual", "XCTAssertNil", "XCTAssertNotNil",
        "XCTAssertGreaterThan", "XCTAssertGreaterThanOrEqual", "XCTAssertLessThan", "XCTAssertLessThanOrEqual", "XCTFail"]

    static func shadowsReservedName(_ token: TokenSyntax) -> Bool {
        guard let parent = token.parent else { return false }
        return parent.as(FunctionDeclSyntax.self)?.name.id == token.id ||
            parent.as(ClassDeclSyntax.self)?.name.id == token.id || parent.as(StructDeclSyntax.self)?.name.id == token.id ||
            parent.as(EnumDeclSyntax.self)?.name.id == token.id || parent.as(ProtocolDeclSyntax.self)?.name.id == token.id ||
            parent.as(TypeAliasDeclSyntax.self)?.name.id == token.id || parent.is(IdentifierPatternSyntax.self)
    }

    static func shadowsAttachmentAdd(_ token: TokenSyntax) -> Bool {
        if token.parent?.as(FunctionDeclSyntax.self)?.name.id == token.id { return true }
        guard let pattern = token.parent?.as(IdentifierPatternSyntax.self),
              let variable = pattern.parent?.parent?.parent?.as(VariableDeclSyntax.self) else { return false }
        return variable.parent?.is(MemberBlockItemSyntax.self) == true ||
            variable.parent?.parent?.parent?.is(SourceFileSyntax.self) == true
    }

    static func safeSuperclass(_ type: ClassDeclSyntax) -> String? {
        guard type.genericParameterClause == nil, type.genericWhereClause == nil,
              type.attributes.allSatisfy({ $0.as(AttributeSyntax.self)?.attributeName.trimmedDescription == "MainActor" }),
              let parents = type.inheritanceClause?.inheritedTypes, parents.count == 1,
              let parent = parents.first?.type.trimmedDescription,
              SwiftSourceSnapshot.nominalTypeName(parent) == parent else { return nil }
        return parent
    }

    static func prove(_ function: FunctionDeclSyntax, references: [TokenSyntax],
                      locations: SourceLocationConverter) -> Self? {
        guard function.modifiers.map(\.name.text) == ["private"],
              function.attributes.allSatisfy({ $0.as(AttributeSyntax.self)?.attributeName.trimmedDescription == "MainActor" }),
              function.genericParameterClause == nil, function.genericWhereClause == nil,
              function.signature.effectSpecifiers == nil,
              let member = function.parent?.as(MemberBlockItemSyntax.self),
              let type = member.parent?.parent?.parent?.as(ClassDeclSyntax.self),
              type.modifiers.contains(where: { $0.name.text == "final" }),
              type.parent?.is(CodeBlockItemSyntax.self) == true,
              safeSuperclass(type) != nil,
              !function.name.text.hasPrefix("test"),
              !["setUp", "setUpWithError", "tearDown", "tearDownWithError", "setUpClass", "tearDownClass"].contains(function.name.text),
              let attachmentState = safeBody(function, in: type) else { return nil }
        let name = function.name.identifier?.name ?? function.name.text
        var callers = Set<Int>()
        // A value reference, selector, key path, overload, extension, recursive
        // use or nested/escaping call invalidates the entire proof. Inspect the
        // whole file because Swift private members are visible to its extensions.
        for token in references {
            if token.id == function.name.id { continue }
            guard let reference = token.parent?.as(DeclReferenceExprSyntax.self), reference.argumentNames == nil else { return nil }
            var expression = Syntax(reference)
            if let access = reference.parent?.as(MemberAccessExprSyntax.self) {
                guard access.base?.as(DeclReferenceExprSyntax.self)?.baseName.text == "self" else { return nil }
                expression = Syntax(access)
            }
            guard let call = expression.parent?.as(FunctionCallExprSyntax.self),
                  call.calledExpression.id == expression.id else { return nil }
            var ancestor = call.parent
            var caller: FunctionDeclSyntax?
            while let node = ancestor {
                if let method = node.as(FunctionDeclSyntax.self) { caller = method; break }
                // Enclosing expressions can synthesize escaping autoclosures
                // (operators, subscripts, string interpolation). Patterns can
                // also call a custom ~= with an escaping autoclosure, without
                // any enclosing expression (guard/while/for/catch patterns).
                if node.is(ExprSyntax.self) || node.is(PatternSyntax.self) ||
                    node.is(AccessorDeclSyntax.self) || node.is(DeferStmtSyntax.self) { return nil }
                if let variable = node.as(VariableDeclSyntax.self), !variable.modifiers.isEmpty || !variable.attributes.isEmpty { return nil }
                ancestor = node.parent
            }
            guard let caller, caller.parent?.parent?.parent?.parent?.id == type.id,
                  (caller.name.text.hasPrefix("test") && caller.signature.parameterClause.parameters.isEmpty && caller.modifiers.isEmpty) ||
                    (caller.modifiers.map(\.name.text) == ["private"] && !caller.name.text.hasPrefix("test")) else { return nil }
            callers.insert(locations.location(for: caller.positionAfterSkippingLeadingTrivia).line)
        }
        guard !callers.isEmpty else { return nil }
        return Self(name: name, callerLines: callers, proofVersion: currentProofVersion, statements: statements(in: function), localAttachmentState: attachmentState)
    }

    /// Added entries may be omitted only under an explicit separate-execution
    /// policy. No source reference may acquire a new binding through this name.
    static func independentAddedEntry(_ function: FunctionDeclSyntax, references: [TokenSyntax]) -> String? {
        guard function.name.text.hasPrefix("test"), function.modifiers.isEmpty,
              function.attributes.allSatisfy({ $0.as(AttributeSyntax.self)?.attributeName.trimmedDescription == "MainActor" }),
              function.genericParameterClause == nil, function.genericWhereClause == nil,
              function.signature.parameterClause.parameters.isEmpty,
              function.signature.returnClause.map({ ["Void", "()"].contains($0.type.trimmedDescription) }) ?? true,
              let type = function.parent?.parent?.parent?.parent?.as(ClassDeclSyntax.self),
              type.modifiers.contains(where: { $0.name.text == "final" }),
              type.parent?.is(CodeBlockItemSyntax.self) == true, safeSuperclass(type) != nil,
              references.allSatisfy({ $0.id == function.name.id }) else { return nil }
        return function.name.identifier?.name ?? function.name.text
    }

    private static func safeBody(_ function: FunctionDeclSyntax, in type: ClassDeclSyntax) -> Bool? {
        guard let body = function.body else { return nil }
        // Query/assertion helpers receive their context as ordinary values. No
        // self/global captures, inout, function-valued arguments, or defaults.
        let valueTypes: Set<String> = ["String", "Bool", "Int", "Double", "XCUIApplication", "XCUIElement",
                                        "Swift.String", "Swift.Bool", "Swift.Int", "Swift.Double", "XCTest.XCUIApplication", "XCTest.XCUIElement"]
        if let result = function.signature.returnClause?.type.trimmedDescription,
           !valueTypes.union(["Void", "()"]).contains(result) { return nil }
        var locals = Set<String>()
        for parameter in function.signature.parameterClause.parameters {
            guard valueTypes.contains(parameter.type.trimmedDescription), parameter.defaultValue == nil,
                  parameter.attributes.isEmpty, parameter.modifiers.isEmpty, parameter.ellipsis == nil else { return nil }
            let name = (parameter.secondName ?? parameter.firstName).text
            guard !reservedNames.contains(name), name != "add" else { return nil }
            locals.insert(name)
        }
        let helpers = Set(type.memberBlock.members.compactMap { $0.decl.as(FunctionDeclSyntax.self) }
            .filter { $0.modifiers.map(\.name.text) == ["private"] }.map { $0.name.text })
        let allowedGlobals = assertions.union(["NSPredicate", "XCUIElement", "XCTAttachment"])
        var attachments = Set<String>(), writesAttachment = false
        func references(_ node: Syntax) -> Bool {
            if node.is(ClosureExprSyntax.self) || node.is(DeclSyntax.self) || node.is(SuperExprSyntax.self) ||
                node.is(KeyPathExprSyntax.self) || node.is(AssignmentExprSyntax.self) ||
                node.is(InOutExprSyntax.self) || node.is(MacroExpansionExprSyntax.self) || node.is(IfConfigDeclSyntax.self) ||
                node.is(VariableDeclSyntax.self) { return false }
            if let reference = node.as(DeclReferenceExprSyntax.self),
               reference.parent?.as(MemberAccessExprSyntax.self)?.declName.id != reference.id {
                let name = reference.baseName.text
                if helpers.contains(name) {
                    guard let call = reference.parent?.as(FunctionCallExprSyntax.self), call.calledExpression.id == reference.id else { return false }
                } else if name == "add" {
                    guard let call = reference.parent?.as(FunctionCallExprSyntax.self), call.calledExpression.id == reference.id,
                          call.arguments.count == 1, let argument = call.arguments.first,
                          argument.label == nil, let local = argument.expression.as(DeclReferenceExprSyntax.self),
                          attachments.contains(local.baseName.text) else { return false }
                    writesAttachment = true
                } else if !locals.contains(name) && !allowedGlobals.contains(name) { return false }
            }
            return node.children(viewMode: .sourceAccurate).allSatisfy(references)
        }
        // Add locals only after checking their initializer. Collecting every
        // binding up front could mistake `let value = value` for a local read.
        // Nested bindings are outside this intentionally small proof language.
        for statement in body.statements {
            if let variable = statement.item.as(VariableDeclSyntax.self) {
                guard variable.bindingSpecifier.text == "let", variable.attributes.isEmpty, variable.modifiers.isEmpty else { return nil }
                for binding in variable.bindings {
                    guard let name = binding.pattern.as(IdentifierPatternSyntax.self), binding.accessorBlock == nil,
                          let initializer = binding.initializer, references(Syntax(initializer.value)) else { return nil }
                    if let call = initializer.value.as(FunctionCallExprSyntax.self),
                       call.calledExpression.as(DeclReferenceExprSyntax.self)?.baseName.text == "XCTAttachment",
                       call.arguments.count == 1, call.arguments.first?.label?.text == "screenshot" {
                        attachments.insert(name.identifier.text)
                    }
                    // Shadowing could redirect an attachment mutation to other state.
                    guard !locals.contains(name.identifier.text), !allowedGlobals.contains(name.identifier.text),
                          !helpers.contains(name.identifier.text), name.identifier.text != "add" else { return nil }
                    locals.insert(name.identifier.text)
                }
            } else if let sequence = statement.item.as(SequenceExprSyntax.self), sequence.elements.count == 3,
                      sequence.elements[sequence.elements.index(after: sequence.elements.startIndex)].is(AssignmentExprSyntax.self),
                      let member = sequence.elements.first?.as(MemberAccessExprSyntax.self),
                      let local = member.base?.as(DeclReferenceExprSyntax.self), attachments.contains(local.baseName.text),
                      ["name", "lifetime"].contains(member.declName.baseName.text),
                      let value = sequence.elements.last, references(Syntax(value)) {
                writesAttachment = true
            } else if !references(Syntax(statement)) { return nil }
        }
        return writesAttachment
    }
}
