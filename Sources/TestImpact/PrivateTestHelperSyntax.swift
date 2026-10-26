// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import SwiftParser
import SwiftSyntax

/// Deliberately narrow source evidence, not a declaration that all private
/// functions are isolated. Compiler bindings and both revisions must agree.
public struct PrivateTestHelperSyntax: Codable, Sendable {
    public var name: String
    public var callerLines: Set<Int>

    static let reservedNames: Set<String> = ["XCTestCase", "String", "Bool", "Int", "Double", "XCUIApplication", "XCUIElement", "NSPredicate",
        "XCTAssert", "XCTAssertTrue", "XCTAssertFalse", "XCTAssertEqual", "XCTAssertNotEqual", "XCTAssertNil", "XCTAssertNotNil",
        "XCTAssertGreaterThan", "XCTAssertGreaterThanOrEqual", "XCTAssertLessThan", "XCTAssertLessThanOrEqual", "XCTFail"]

    static func shadowsReservedName(_ token: TokenSyntax) -> Bool {
        guard let parent = token.parent else { return false }
        return parent.as(FunctionDeclSyntax.self)?.name.id == token.id ||
            parent.as(ClassDeclSyntax.self)?.name.id == token.id || parent.as(StructDeclSyntax.self)?.name.id == token.id ||
            parent.as(EnumDeclSyntax.self)?.name.id == token.id || parent.as(ProtocolDeclSyntax.self)?.name.id == token.id ||
            parent.as(TypeAliasDeclSyntax.self)?.name.id == token.id || parent.is(IdentifierPatternSyntax.self)
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
              safeBody(function) else { return nil }
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
                if node.is(ClosureExprSyntax.self) || node.is(FunctionCallExprSyntax.self) ||
                    node.is(MacroExpansionExprSyntax.self) || node.is(DeferStmtSyntax.self) { return nil }
                if let variable = node.as(VariableDeclSyntax.self), !variable.modifiers.isEmpty || !variable.attributes.isEmpty { return nil }
                ancestor = node.parent
            }
            guard let caller, caller.parent?.parent?.parent?.parent?.id == type.id,
                  caller.name.text.hasPrefix("test"), caller.signature.parameterClause.parameters.isEmpty,
                  caller.modifiers.isEmpty else { return nil }
            callers.insert(locations.location(for: caller.positionAfterSkippingLeadingTrivia).line)
        }
        guard !callers.isEmpty else { return nil }
        return Self(name: name, callerLines: callers)
    }

    private static func safeBody(_ function: FunctionDeclSyntax) -> Bool {
        guard let body = function.body else { return false }
        // Query/assertion helpers receive their context as ordinary values. No
        // self/global captures, inout, function-valued arguments, or defaults.
        let valueTypes: Set<String> = ["String", "Bool", "Int", "Double", "XCUIApplication", "XCUIElement",
                                        "Swift.String", "Swift.Bool", "Swift.Int", "Swift.Double", "XCTest.XCUIApplication", "XCTest.XCUIElement"]
        if let result = function.signature.returnClause?.type.trimmedDescription,
           !valueTypes.union(["Void", "()"]).contains(result) { return false }
        var locals = Set<String>()
        for parameter in function.signature.parameterClause.parameters {
            guard valueTypes.contains(parameter.type.trimmedDescription), parameter.defaultValue == nil,
                  parameter.attributes.isEmpty, parameter.modifiers.isEmpty, parameter.ellipsis == nil else { return false }
            locals.insert((parameter.secondName ?? parameter.firstName).text)
        }
        let allowedGlobals: Set<String> = ["XCTAssert", "XCTAssertTrue", "XCTAssertFalse", "XCTAssertEqual", "XCTAssertNotEqual",
            "XCTAssertNil", "XCTAssertNotNil", "XCTAssertGreaterThan", "XCTAssertGreaterThanOrEqual", "XCTAssertLessThan",
            "XCTAssertLessThanOrEqual", "XCTFail", "NSPredicate", "XCUIElement"]
        func references(_ node: Syntax) -> Bool {
            if node.is(ClosureExprSyntax.self) || node.is(DeclSyntax.self) || node.is(SuperExprSyntax.self) ||
                node.is(KeyPathExprSyntax.self) || node.is(AssignmentExprSyntax.self) ||
                node.is(InOutExprSyntax.self) || node.is(MacroExpansionExprSyntax.self) || node.is(IfConfigDeclSyntax.self) ||
                node.is(VariableDeclSyntax.self) { return false }
            if let reference = node.as(DeclReferenceExprSyntax.self),
               reference.parent?.as(MemberAccessExprSyntax.self)?.declName.id != reference.id {
                guard locals.contains(reference.baseName.text) || allowedGlobals.contains(reference.baseName.text) else { return false }
            }
            return node.children(viewMode: .sourceAccurate).allSatisfy(references)
        }
        // Add locals only after checking their initializer. Collecting every
        // binding up front could mistake `let value = value` for a local read.
        // Nested bindings are outside this intentionally small proof language.
        for statement in body.statements {
            if let variable = statement.item.as(VariableDeclSyntax.self) {
                guard variable.bindingSpecifier.text == "let", variable.attributes.isEmpty, variable.modifiers.isEmpty else { return false }
                for binding in variable.bindings {
                    guard let name = binding.pattern.as(IdentifierPatternSyntax.self), binding.accessorBlock == nil,
                          let initializer = binding.initializer, references(Syntax(initializer.value)) else { return false }
                    locals.insert(name.identifier.text)
                }
            } else if !references(Syntax(statement)) { return false }
        }
        return true
    }
}
