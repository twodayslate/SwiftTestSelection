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
    // Version 26 authenticates historical caller bodies and qualified extension owners.
    static let currentProofVersion = 26
    /// Nil in older captures, whose caller/escape proof is not sufficient.
    public var statements: [Statement]? = nil
    /// Writes are limited to newly created, local XCTest attachments.
    public var localAttachmentState: Bool? = nil
    /// Every direct private callee has a supported transitive effect body.
    public var calleeEffectsSupported: Bool? = nil
    /// Exact same-class declarations whose bodies were checked, including self.
    /// Compiler callees must belong to these regions, not merely share a name.
    public var effectCalleeLines: [String: Int]? = nil
    /// SDK member names used by a transitive body that constructs attachments.
    /// Empty means no attachment construction; nil is incomplete saved evidence.
    public var attachmentEffectMembers: Set<String>? = nil
    /// All transitive SDK bindings, even when the helper creates no attachment.
    public var sdkEffectMembers: Set<String>? = nil
    /// Call shapes across the checked transitive body. Ambiguous overload sets
    /// cannot prove a binding when SIL omits labels and source call-site identity.
    public var sdkCallShapes: [String: Set<[String]>]? = nil
    /// Prefix, infix and postfix operators across the checked transitive body.
    /// Nil is incomplete evidence; literal operands do not prove SDK ownership.
    public var effectOperators: Set<String>? = nil

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

    private static let allowedGlobals = assertions.union(["NSPredicate", "XCUIElement", "XCTAttachment", "CGRect", "CGVector", "max"])
    private static let valueTypes: Set<String> = ["String", "Bool", "Int", "Double", "XCUIApplication", "XCUIElement",
        "Swift.String", "Swift.Bool", "Swift.Int", "Swift.Double", "XCTest.XCUIApplication", "XCTest.XCUIElement"]
    // Every accepted bare global must participate in the whole-source binding
    // audit, including deleted/unowned base files. A head SDK binding cannot
    // prove the effects of a project declaration that disappeared at head.
    // Qualification alone does not prove identity: another source can alias
    // Swift/XCTest to a foreign namespace or MainActor to a custom actor.
    // Audit every component of accepted type spellings and every trusted SDK
    // module name, not just the final type name or the helper file's imports.
    // Caller/lifecycle proofs accept more types than helper bodies. Their full
    // vocabulary must also be authenticated in base and unowned base sources.
    static let reservedNames = allowedGlobals
        .union(valueTypes.flatMap { $0.split(separator: ".").map(String.init) })
        .union(SDKReceiverContracts.bindingNames)
        .union(SDKTestHelperSyntax.trustedCallerModules)
        .union(["CoreGraphics", "MainActor", "XCTestCase",
        "IntegerLiteralType", "FloatLiteralType", "BooleanLiteralType", "StringLiteralType",
        "UnicodeScalarLiteralType", "ExtendedGraphemeClusterLiteralType"])

    static func shadowsReservedName(_ token: TokenSyntax) -> Bool {
        guard let parent = token.parent else { return false }
        // Only the internal parameter name is a lexical binding. An external
        // argument label alone cannot replace the XCTest function in a body.
        if let parameter = parent.as(FunctionParameterSyntax.self) {
            return (parameter.secondName ?? parameter.firstName).id == token.id
        }
        if let parameter = parent.as(ClosureParameterSyntax.self) {
            return (parameter.secondName ?? parameter.firstName).id == token.id
        }
        return parent.as(GenericParameterSyntax.self)?.name.id == token.id ||
            parent.as(ClosureShorthandParameterSyntax.self)?.name.id == token.id ||
            parent.as(ClosureCaptureSyntax.self)?.name?.id == token.id ||
            parent.as(AssociatedTypeDeclSyntax.self)?.name.id == token.id ||
            parent.as(FunctionDeclSyntax.self)?.name.id == token.id ||
            parent.as(ClassDeclSyntax.self)?.name.id == token.id || parent.as(StructDeclSyntax.self)?.name.id == token.id ||
            parent.as(ActorDeclSyntax.self)?.name.id == token.id ||
            parent.as(EnumDeclSyntax.self)?.name.id == token.id || parent.as(ProtocolDeclSyntax.self)?.name.id == token.id ||
            parent.as(TypeAliasDeclSyntax.self)?.name.id == token.id || parent.is(IdentifierPatternSyntax.self)
    }

    static func shadowsNestedCallerType(_ token: TokenSyntax) -> Bool {
        guard shadowsReservedName(token) else { return false }
        // Names such as State and Result are qualified by an SDK owner. A
        // project nominal with that owner is already rejected above. Extensions
        // can add nested names without redeclaring the owner, including through
        // aliases, so retain fallback for these names in any extension.
        var ancestor = token.parent
        while let node = ancestor {
            if node.is(ExtensionDeclSyntax.self) { return true }
            ancestor = node.parent
        }
        return false
    }

    static func shadowsAttachmentAdd(_ token: TokenSyntax) -> Bool {
        if token.parent?.as(FunctionDeclSyntax.self)?.name.id == token.id { return true }
        guard let pattern = token.parent?.as(IdentifierPatternSyntax.self),
              let variable = pattern.parent?.parent?.parent?.as(VariableDeclSyntax.self) else { return false }
        return variable.parent?.is(MemberBlockItemSyntax.self) == true ||
            variable.parent?.parent?.parent?.is(SourceFileSyntax.self) == true
    }

    static func isPlainExtension(_ node: ExtensionDeclSyntax) -> Bool {
        node.attributes.isEmpty && node.modifiers.isEmpty && node.inheritanceClause == nil &&
            node.genericWhereClause == nil && node.parent?.is(CodeBlockItemSyntax.self) == true &&
            node.parent?.parent?.parent?.is(SourceFileSyntax.self) == true &&
            node.extendedType.is(IdentifierTypeSyntax.self) &&
            node.extendedType.as(IdentifierTypeSyntax.self)?.genericArgumentClause == nil
    }

    static func bodylessProtocolRequirement(_ node: Syntax) -> String? {
        guard let owner = node.parent?.parent?.parent?.parent?.as(ProtocolDeclSyntax.self) else { return nil }
        func supported(_ attributes: AttributeListSyntax) -> Bool {
            attributes.allSatisfy { item in
                guard let attribute = item.as(AttributeSyntax.self) else { return false }
                return ["objc", "MainActor"].contains(attribute.attributeName.trimmedDescription)
            }
        }
        guard supported(owner.attributes) else { return nil }
        if let function = node.as(FunctionDeclSyntax.self), function.body == nil, supported(function.attributes) {
            return SDKTestHelperSyntax.canonicalName(function.name.text)
        }
        if let initializer = node.as(InitializerDeclSyntax.self), initializer.body == nil, supported(initializer.attributes) {
            return "init"
        }
        return nil
    }

    static func safeSuperclass(_ type: ClassDeclSyntax) -> String? {
        guard type.genericParameterClause == nil, type.genericWhereClause == nil,
              type.attributes.allSatisfy({ $0.as(AttributeSyntax.self)?.attributeName.trimmedDescription == "MainActor" }),
              let parents = type.inheritanceClause?.inheritedTypes, parents.count == 1,
              let parent = parents.first?.type.trimmedDescription,
              SwiftSourceSnapshot.nominalTypeName(parent) == parent else { return nil }
        return parent
    }

    private struct Owner {
        var methods: [FunctionDeclSyntax]
        var containers: Set<SyntaxIdentifier>
    }

    private static func owner(of function: FunctionDeclSyntax) -> Owner? {
        guard let container = function.parent?.parent?.parent?.parent else { return nil }
        var root = Syntax(function)
        while let parent = root.parent { root = parent }
        guard let file = root.as(SourceFileSyntax.self) else { return nil }
        let name: String
        if let type = container.as(ClassDeclSyntax.self) { name = type.name.text }
        else if let ext = container.as(ExtensionDeclSyntax.self), isPlainExtension(ext) { name = ext.extendedType.trimmedDescription }
        else { return nil }
        let classes = file.statements.compactMap { $0.item.as(ClassDeclSyntax.self) }.filter { $0.name.text == name }
        guard classes.count == 1, let type = classes.first,
              type.modifiers.contains(where: { $0.name.text == "final" }), safeSuperclass(type) != nil else { return nil }
        let extensions = file.statements.compactMap { $0.item.as(ExtensionDeclSyntax.self) }
            .filter { $0.extendedType.trimmedDescription == name }
        guard extensions.allSatisfy(isPlainExtension) else { return nil }
        let methods = ([type.memberBlock] + extensions.map(\.memberBlock)).flatMap {
            $0.members.compactMap { $0.decl.as(FunctionDeclSyntax.self) }
        }
        return Owner(methods: methods, containers: Set([type.id] + extensions.map(\.id)))
    }

    private static func primitiveDefault(_ parameter: FunctionParameterSyntax) -> Bool {
        guard let value = parameter.defaultValue?.value else { return true }
        return primitiveValue(value, type: parameter.type.trimmedDescription)
    }

    /// Defaults may have separate SIL entry points from their owning declaration.
    /// Only closed primitive literals are safe without visiting those thunks.
    static func primitiveValue(_ value: ExprSyntax, type: String?) -> Bool {
        switch type {
        case nil:
            return value.is(BooleanLiteralExprSyntax.self) || value.is(IntegerLiteralExprSyntax.self) ||
                value.is(FloatLiteralExprSyntax.self) ||
                value.as(StringLiteralExprSyntax.self)?.segments.allSatisfy { $0.is(StringSegmentSyntax.self) } == true
        case "Bool", "Swift.Bool": return value.is(BooleanLiteralExprSyntax.self)
        case "Int", "Swift.Int": return value.is(IntegerLiteralExprSyntax.self)
        case "Double", "Swift.Double": return value.is(FloatLiteralExprSyntax.self) || value.is(IntegerLiteralExprSyntax.self)
        case "String", "Swift.String":
            return value.as(StringLiteralExprSyntax.self)?.segments.allSatisfy { $0.is(StringSegmentSyntax.self) } == true
        default: return false
        }
    }

    /// Explain the first intentionally unsupported effect without granting a
    /// source-only exemption. Compiler bindings and receiver checks still apply.
    static func unsupportedEffect(_ function: FunctionDeclSyntax, locations: SourceLocationConverter) -> String? {
        guard function.modifiers.map(\.name.text) == ["private"], !function.name.text.hasPrefix("test"),
              owner(of: function) != nil else { return nil }
        if function.signature.parameterClause.parameters.contains(where: { !primitiveDefault($0) }) {
            return "Default argument is not a primitive literal"
        }
        guard let body = function.body else { return "Missing helper body" }
        if let owner = owner(of: function), safeBody(function, methods: owner.methods) != nil { return nil }
        // Report unsupported nested bindings without granting source-only isolation.
        for token in body.tokens(viewMode: .sourceAccurate) {
            if let declaration = token.parent?.as(VariableDeclSyntax.self), declaration.bindingSpecifier.id == token.id,
               declaration.parent?.parent?.id != body.statements.id && declaration.parent?.parent?.parent?.id != body.id {
                return "Nested local declaration at line \(locations.location(for: declaration.positionAfterSkippingLeadingTrivia).line) requires control-flow effect evidence"
            }
        }
        return nil
    }

    static func prove(_ function: FunctionDeclSyntax, importsSupported: Bool, references: [TokenSyntax],
                      locations: SourceLocationConverter) -> Self? {
        guard function.modifiers.map(\.name.text) == ["private"],
              function.attributes.allSatisfy({ $0.as(AttributeSyntax.self)?.attributeName.trimmedDescription == "MainActor" }),
              function.genericParameterClause == nil, function.genericWhereClause == nil,
              function.signature.effectSpecifiers == nil,
              let owner = owner(of: function),
              !function.name.text.hasPrefix("test"),
              !["setUp", "setUpWithError", "tearDown", "tearDownWithError", "setUpClass", "tearDownClass"].contains(function.name.text),
              let attachmentState = safeBody(function, methods: owner.methods) else { return nil }
        let name = function.name.identifier?.name ?? function.name.text
        var callers = Set<Int>()
        // A value reference, selector, key path, overload, recursive
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
            guard let caller, caller.parent?.parent?.parent?.parent.map({ owner.containers.contains($0.id) }) == true,
                  (caller.name.text.hasPrefix("test") && caller.signature.parameterClause.parameters.isEmpty && caller.modifiers.isEmpty) ||
                    (caller.modifiers.map(\.name.text) == ["private"] && !caller.name.text.hasPrefix("test")) else { return nil }
            callers.insert(locations.location(for: caller.positionAfterSkippingLeadingTrivia).line)
        }
        guard !callers.isEmpty else { return nil }
        var effectCallees: [String: Int] = [:]
        var attachmentMembers = Set<String>(), sdkMembers = Set<String>(), operators = Set<String>()
        var callShapes: [String: Set<[String]>] = [:]
        let effects = importsSupported ? safeCalleeEffects(function, methods: owner.methods, locations: locations,
            proven: &effectCallees, attachmentMembers: &attachmentMembers, sdkMembers: &sdkMembers, callShapes: &callShapes, operators: &operators) : nil
        return Self(name: name, callerLines: callers, proofVersion: currentProofVersion, statements: statements(in: function),
                    localAttachmentState: attachmentState || (effects ?? false), calleeEffectsSupported: effects != nil, effectCalleeLines: effects == nil ? nil : effectCallees,
                    attachmentEffectMembers: effects == nil ? nil : attachmentMembers, sdkEffectMembers: effects == nil ? nil : sdkMembers, sdkCallShapes: effects == nil ? nil : callShapes, effectOperators: effects == nil ? nil : operators)
    }

    /// Added entries may be omitted only under an explicit separate-execution
    /// policy. No source reference may acquire a new binding through this name.
    static func independentAddedEntry(_ function: FunctionDeclSyntax, references: [TokenSyntax]) -> String? {
        guard function.name.text.hasPrefix("test"), function.modifiers.isEmpty,
              function.attributes.allSatisfy({ $0.as(AttributeSyntax.self)?.attributeName.trimmedDescription == "MainActor" }),
              function.genericParameterClause == nil, function.genericWhereClause == nil,
              function.signature.parameterClause.parameters.isEmpty,
              function.signature.returnClause.map({ ["Void", "()"].contains($0.type.trimmedDescription) }) ?? true,
              (owner(of: function) != nil || function.parent?.parent?.parent?.parent?.as(ExtensionDeclSyntax.self).map(isPlainExtension) == true),
              references.allSatisfy({ $0.id == function.name.id }) else { return nil }
        return function.name.identifier?.name ?? function.name.text
    }

    /// Outbound effects are separate from the inbound caller proof: walking
    /// both directions in one traversal would falsely reject ordinary chains.
    /// Explicit work items bound stack usage while memoizing shared callees.
    /// A nil result is unsupported; true propagates local attachment effects.
    private static func safeCalleeEffects(_ function: FunctionDeclSyntax, methods allMethods: [FunctionDeclSyntax],
                                          locations: SourceLocationConverter, proven: inout [String: Int],
                                          attachmentMembers: inout Set<String>, sdkMembers: inout Set<String>,
                                          callShapes: inout [String: Set<[String]>], operators: inout Set<String>) -> Bool? {
        let methods = Dictionary(grouping: allMethods.filter { $0.modifiers.map(\.name.text) == ["private"] }, by: { $0.name.text })
        var usesAttachments = false, memberNames = Set<String>()
        var active = Set<SyntaxIdentifier>()
        var completed: [SyntaxIdentifier: Bool] = [:]
        enum Work {
            case enter(FunctionDeclSyntax)
            case finish(FunctionDeclSyntax, Bool, [FunctionDeclSyntax])
        }
        var pending: [Work] = [.enter(function)]
        while let work = pending.popLast() {
            switch work {
            case let .enter(candidate):
                if completed[candidate.id] != nil { continue }
                guard active.insert(candidate.id).inserted else { return nil }
                guard candidate.attributes.allSatisfy({ $0.as(AttributeSyntax.self)?.attributeName.trimmedDescription == "MainActor" }),
                      candidate.genericParameterClause == nil, candidate.genericWhereClause == nil,
                      candidate.signature.effectSpecifiers == nil,
                      !candidate.name.text.hasPrefix("test"), !SDKTestHelperSyntax.lifecycle.contains(candidate.name.text),
                      let attachments = safeBody(candidate, methods: allMethods, validateBindings: true), let body = candidate.body else { return nil }
                var callees: [FunctionDeclSyntax] = [], seen = Set<SyntaxIdentifier>()
                for token in body.tokens(viewMode: .sourceAccurate) {
                    // Interpolation lowers to member calls absent from the
                    // expression's spelling. A concrete project overload can
                    // disappear at head just like an explicit SDK member.
                    if token.parent?.as(ExpressionSegmentSyntax.self)?.backslash.id == token.id {
                        memberNames.formUnion(["init", "appendLiteral", "appendInterpolation"])
                    }
                    if token.parent?.as(BinaryOperatorExprSyntax.self)?.operator.id == token.id ||
                        token.parent?.as(PrefixOperatorExprSyntax.self)?.operator.id == token.id ||
                        token.parent?.as(PostfixOperatorExprSyntax.self)?.operator.id == token.id {
                        operators.insert(token.text)
                    }
                    if let subscriptCall = token.parent?.as(SubscriptCallExprSyntax.self), subscriptCall.leftSquare.id == token.id {
                        memberNames.insert("subscript")
                    }
                    if let reference = token.parent?.as(DeclReferenceExprSyntax.self), reference.baseName.id == token.id {
                        let name = SDKTestHelperSyntax.canonicalName(reference.baseName.text)
                        if reference.parent?.as(MemberAccessExprSyntax.self)?.declName.id == reference.id {
                            memberNames.insert(name)
                            if let member = reference.parent?.as(MemberAccessExprSyntax.self),
                               let call = member.parent?.as(FunctionCallExprSyntax.self), call.calledExpression.id == member.id {
                                callShapes[name, default: []].insert(call.arguments.map { SDKTestHelperSyntax.canonicalName($0.label?.text ?? "_") })
                            }
                        } else if ["XCTAttachment", "NSPredicate", "XCUIElement", "CGRect", "CGVector"].contains(name) {
                            memberNames.insert("init")
                            if name == "XCTAttachment" { usesAttachments = true }
                        } else if name == "add" {
                            memberNames.insert(name)
                        }
                    }
                    guard let reference = token.parent?.as(DeclReferenceExprSyntax.self), reference.baseName.id == token.id,
                          reference.parent?.as(MemberAccessExprSyntax.self)?.declName.id != reference.id,
                          let candidates = methods[reference.baseName.text] else { continue }
                    guard candidates.count == 1, let callee = candidates.first else { return nil }
                    if seen.insert(callee.id).inserted { callees.append(callee) }
                }
                pending.append(.finish(candidate, attachments, callees))
                for callee in callees.reversed() { pending.append(.enter(callee)) }
            case let .finish(candidate, attachments, callees):
                var result = attachments
                for callee in callees {
                    guard let effects = completed[callee.id] else { return nil }
                    result = result || effects
                }
                active.remove(candidate.id)
                completed[candidate.id] = result
                proven[candidate.name.text] = locations.location(for: candidate.positionAfterSkippingLeadingTrivia).line
            }
        }
        // Include construction inside assertions and downstream private helpers,
        // even when no attachment setter/add operation was used.
        sdkMembers = memberNames
        attachmentMembers = usesAttachments ? memberNames.union(["init"]) : []
        return completed[function.id]
    }

    // Keep the caller/escape proof when binding checks fail in the effect pass.
    // A surviving helper must retain an explicit unproven-effect result instead
    // of dropping to ordinary head-only dependency selection.
    private static func safeBody(_ function: FunctionDeclSyntax, methods: [FunctionDeclSyntax], validateBindings: Bool = false) -> Bool? {
        guard let body = function.body else { return nil }
        // Query/assertion helpers receive their context as ordinary values. No
        // self/global captures, inout, function-valued arguments, or effectful defaults.
        if let result = function.signature.returnClause?.type.trimmedDescription,
           !valueTypes.union(["Void", "()"]).contains(result) { return nil }
        var locals = Set<String>()
        for parameter in function.signature.parameterClause.parameters {
            guard valueTypes.contains(parameter.type.trimmedDescription), primitiveDefault(parameter),
                  parameter.attributes.isEmpty, parameter.modifiers.isEmpty, parameter.ellipsis == nil else { return nil }
            let name = (parameter.secondName ?? parameter.firstName).text
            guard !reservedNames.contains(name), name != "add" else { return nil }
            locals.insert(name)
        }
        let helpers = Set(methods.filter { $0.modifiers.map(\.name.text) == ["private"] }.map { $0.name.text })
        var attachments = Set<String>(), writesAttachment = false
        func references(_ node: Syntax) -> Bool {
            // A contextual type can invoke a project literal initializer even
            // when its expression contains only a literal. The head graph
            // cannot authenticate a base alias that later resolves to Int.
            // Also cover casts, which supply context without a local annotation.
            if validateBindings, let type = node.as(TypeSyntax.self) { return valueTypes.contains(type.trimmedDescription) }
            if let block = node.as(CodeBlockSyntax.self) {
                // Each branch/iteration inherits its enclosing values but cannot
                // export local names or attachment provenance into another scope.
                return statements(block.statements)
            }
            if let loop = node.as(ForStmtSyntax.self) {
                // Only a fixed literal range with no bound value or pattern
                // matching is admitted. Both revisions must exclude project
                // operator bindings before the head compiler can authenticate
                // the standard range and iterator implementations.
                guard loop.pattern.is(WildcardPatternSyntax.self), loop.whereClause == nil,
                      loop.tryKeyword == nil, loop.awaitKeyword == nil,
                      let range = loop.sequence.as(SequenceExprSyntax.self), range.elements.count == 3,
                      let lower = range.elements.first?.as(IntegerLiteralExprSyntax.self),
                      let upper = range.elements.last?.as(IntegerLiteralExprSyntax.self),
                      let low = Int(lower.literal.text), let high = Int(upper.literal.text), low <= high,
                      let op = range.elements.dropFirst().first?.as(BinaryOperatorExprSyntax.self),
                      ["..<", "..."].contains(op.operator.text) else { return false }
                return references(Syntax(loop.sequence)) && statements(loop.body.statements)
            }
            if validateBindings, let call = node.as(SubscriptCallExprSyntax.self) {
                // The SDK query subscript takes one unlabeled identifier. SIL
                // erases labels, so a labeled external getter can look identical.
                guard call.arguments.count == 1, call.arguments.first?.label == nil,
                      call.trailingClosure == nil, call.additionalTrailingClosures.isEmpty else { return false }
            }
            if validateBindings, let member = node.as(MemberAccessExprSyntax.self),
               ExternalHelperEffects.sdkCallLabels[SDKTestHelperSyntax.canonicalName(member.declName.baseName.text)] != nil {
                // A method value loses its labels at the eventual call site.
                guard member.declName.argumentNames == nil,
                      let call = member.parent?.as(FunctionCallExprSyntax.self), call.calledExpression.id == member.id else { return false }
            }
            if validateBindings, let call = node.as(FunctionCallExprSyntax.self) {
                if let member = call.calledExpression.as(MemberAccessExprSyntax.self),
                   let shapes = ExternalHelperEffects.sdkCallLabels[SDKTestHelperSyntax.canonicalName(member.declName.baseName.text)] {
                    if ExternalHelperEffects.sdkActions.contains(SDKTestHelperSyntax.canonicalName(member.declName.baseName.text)),
                       call.parent?.is(CodeBlockItemSyntax.self) != true { return false }
                    guard call.trailingClosure == nil, call.additionalTrailingClosures.isEmpty,
                          shapes.contains(call.arguments.map { SDKTestHelperSyntax.canonicalName($0.label?.text ?? "_") }) else { return false }
                }
                if call.calledExpression.as(DeclReferenceExprSyntax.self).map({ SDKTestHelperSyntax.canonicalName($0.baseName.text) }) == "XCTAttachment" {
                    guard call.arguments.map({ SDKTestHelperSyntax.canonicalName($0.label?.text ?? "_") }) == ["screenshot"],
                          call.trailingClosure == nil, call.additionalTrailingClosures.isEmpty else { return false }
                }
            }
            if node.is(ClosureExprSyntax.self) || node.is(DeclSyntax.self) || node.is(PatternSyntax.self) || node.is(SuperExprSyntax.self) ||
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
        func statements(_ items: CodeBlockItemListSyntax) -> Bool {
            let outerLocals = locals, outerAttachments = attachments
            defer { locals = outerLocals; attachments = outerAttachments }
            for statement in items {
                if let variable = statement.item.as(VariableDeclSyntax.self) {
                    guard variable.bindingSpecifier.text == "let", variable.attributes.isEmpty, variable.modifiers.isEmpty else { return false }
                    for binding in variable.bindings {
                        guard let name = binding.pattern.as(IdentifierPatternSyntax.self), binding.accessorBlock == nil,
                              (!validateBindings || (binding.typeAnnotation.map({ valueTypes.contains($0.type.trimmedDescription) }) ?? true)),
                              let initializer = binding.initializer, references(Syntax(initializer.value)) else { return false }
                        if let call = initializer.value.as(FunctionCallExprSyntax.self),
                           call.calledExpression.as(DeclReferenceExprSyntax.self)?.baseName.text == "XCTAttachment",
                           call.arguments.count == 1, call.arguments.first?.label?.text == "screenshot" {
                            attachments.insert(name.identifier.text)
                        }
                        // Shadowing could redirect an attachment mutation to other state.
                        guard !locals.contains(name.identifier.text), !allowedGlobals.contains(name.identifier.text),
                              !helpers.contains(name.identifier.text), name.identifier.text != "add" else { return false }
                        locals.insert(name.identifier.text)
                    }
                } else if let sequence = statement.item.as(SequenceExprSyntax.self), sequence.elements.count == 3,
                          sequence.elements[sequence.elements.index(after: sequence.elements.startIndex)].is(AssignmentExprSyntax.self),
                          let member = sequence.elements.first?.as(MemberAccessExprSyntax.self),
                          let local = member.base?.as(DeclReferenceExprSyntax.self), attachments.contains(local.baseName.text),
                          ["name", "lifetime"].contains(member.declName.baseName.text),
                          let value = sequence.elements.last, references(Syntax(value)) {
                    writesAttachment = true
                } else if !references(Syntax(statement)) { return false }
            }
            return true
        }
        guard statements(body.statements) else { return nil }
        return writesAttachment
    }
}
