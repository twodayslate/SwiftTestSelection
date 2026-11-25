// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
import SwiftSyntax

/// Written discovery declarations are candidates until matched to compiler registrations.
struct SwiftTestingSourceDeclarations: Codable, Sendable {
    struct Suite: Codable, Sendable {
        let name: String
        let conditional: Bool
    }

    struct Arguments: Codable, Sendable {
        let identity: String
        let locations: [String]
        let calls: [String: String]

        func comparison(_ policy: UIFeatureMappings.SourceLocationPolicy) -> [String] {
            guard policy != .diagnostic else { return [identity] }
            let ignorePosition = policy == .diagnosticLineColumn
            let literals = locations.filter { !ignorePosition || !($0.hasPrefix("line:") || $0.hasPrefix("column:")) }
            // Imported defaults and macro expansions can observe the caller even
            // when no definition or explicit location literal appears in source.
            let defaults = calls.keys.sorted().compactMap { kind in
                ignorePosition && ["line", "column"].contains(kind) ? nil : calls[kind].map { kind + ":" + $0 }
            }
            return [identity] + literals + defaults
        }
    }

    /// Preserves the rest of the declaration while projecting out registration arguments.
    /// Scoping the projected arguments to a test or suite requires matching SDK factory evidence.
    struct RegistrationInputs: Codable, Sendable {
        let declaration: String
        let providers: Int
        let eager: [Arguments]
        var bare: Bool?
        var conditions: SwiftTestingFactoryProof.Conditions?
        var nonliteralPredicates: [Arguments]?

        var hasNoRuntimeInputs: Bool {
            providers == 0 && eager.isEmpty && conditions == nil && nonliteralPredicates == nil
        }
    }

    private static func name(_ attribute: AttributeSyntax) -> [String] {
        attribute.attributeName.tokens(viewMode: .sourceAccurate).map { $0.identifier?.name ?? $0.text }
    }

    static func matches(_ attribute: AttributeSyntax, _ expected: String) -> Bool {
        let tokens = name(attribute)
        return tokens == [expected] || tokens == ["Testing", ".", expected]
    }

    private static func isMainActor(_ attribute: AttributeSyntax) -> Bool {
        [["MainActor"], ["Swift", ".", "MainActor"]].contains(name(attribute)) && attribute.arguments == nil
    }

    /// Sibling macros can participate in registration even on an argumentless test.
    private static func hasOpaqueSibling(of expected: String, in attributes: AttributeListSyntax) -> Bool {
        attributes.contains { element in
            guard let attribute = element.as(AttributeSyntax.self) else { return true }
            return !matches(attribute, expected) && !isMainActor(attribute)
        }
    }

    static func supportsEnclosingDeclaration(_ attributes: AttributeListSyntax) -> Bool {
        !hasOpaqueSibling(of: "Suite", in: attributes)
    }

    static func hasSuiteOwner(_ attributes: AttributeListSyntax) -> Bool {
        attributes.contains { $0.as(AttributeSyntax.self).map { matches($0, "Suite") } == true } &&
            supportsEnclosingDeclaration(attributes)
    }

    private static func withoutArguments(_ attribute: AttributeSyntax) -> AttributeSyntax {
        attribute.with(\.arguments, nil).with(\.leftParen, nil).with(\.rightParen, nil)
    }

    /// Match a surviving declaration across edits to its registration. A match
    /// preserves the test body and signature. Eager arguments are still compared
    /// separately, with their locations, for every process that loads the factory.
    static func registrationDeclaration(_ node: Syntax, attribute expected: String, fingerprint: (Syntax) -> String) -> String? {
        guard var declaration = node.asProtocol(WithAttributesSyntax.self) else { return nil }
        var attributes = declaration.attributes
        let matches = attributes.indices.filter { index in
            attributes[index].as(AttributeSyntax.self).map { Self.matches($0, expected) } == true
        }
        guard matches.count == 1, let index = matches.first, let attribute = attributes[index].as(AttributeSyntax.self),
              !hasOpaqueSibling(of: expected, in: attributes) else { return nil }
        attributes[index] = .attribute(withoutArguments(attribute))
        declaration.attributes = attributes
        return fingerprint(Syntax(declaration))
    }

    private static func hasSDKTypeQualifier(_ member: MemberAccessExprSyntax, type: String) -> Bool {
        guard let base = member.base else { return true }
        let tokens = base.tokens(viewMode: .sourceAccurate).map { $0.identifier?.name ?? $0.text }
        return tokens == [type] || tokens == ["Testing", ".", type]
    }

    static func registrationInputs(_ node: Syntax, attribute expected: String, fingerprint: (Syntax) -> String,
                                   capture: (Syntax) -> Arguments) -> RegistrationInputs? {
        guard var declaration = node.asProtocol(WithAttributesSyntax.self) else { return nil }
        var attributes = declaration.attributes
        var providers: Int?
        var eager: [Arguments] = []
        var bare = false
        var conditions = SwiftTestingFactoryProof.Conditions()
        var hasScopedTraits: Bool { !conditions.predicates.isEmpty || conditions.serializedSlots != nil }
        var nonliteralPredicates: [Arguments] = []
        for index in attributes.indices {
            guard let attribute = attributes[index].as(AttributeSyntax.self) else { return nil }
            if !matches(attribute, expected) {
                guard isMainActor(attribute) else { return nil }
                continue
            }
            guard providers == nil else { return nil }
            if attribute.arguments == nil || attribute.arguments?.as(LabeledExprListSyntax.self)?.isEmpty == true {
                attributes[index] = .attribute(withoutArguments(attribute))
                bare = true
                providers = 0
                continue
            }
            guard let args = attribute.arguments?.as(LabeledExprListSyntax.self) else { return nil }
            var projected = args
            var providerCount = 0, hasDisplayName = false
            for index in args.indices {
                let argument = args[index]
                if index == args.startIndex, argument.label == nil,
                   let literal = argument.expression.as(StringLiteralExprSyntax.self),
                   literal.segments.allSatisfy({ $0.is(StringSegmentSyntax.self) }) {
                    hasDisplayName = true
                } else if expected == "Suite", argument.label == nil,
                          let member = argument.expression.as(MemberAccessExprSyntax.self),
                          member.declName.baseName.text == "serialized", member.declName.argumentNames == nil,
                          hasSDKTypeQualifier(member, type: "ParallelizationTrait") {
                    // Keep the getter spelling in the projection and authenticate its trait slot in SIL.
                    conditions.serializedSlots = (conditions.serializedSlots ?? []).union([conditions.traitCount])
                    conditions.traitCount += 1
                    continue
                } else if expected == "Test", argument.label?.text == "arguments" && providerCount == 0 {
                    providerCount = 1
                } else if argument.label == nil && providerCount > 0 {
                    providerCount += 1
                } else if argument.label == nil,
                          let call = argument.expression.as(FunctionCallExprSyntax.self),
                          let member = call.calledExpression.as(MemberAccessExprSyntax.self),
                          hasSDKTypeQualifier(member, type: "ConditionTrait"),
                          ["enabled", "disabled"].contains(member.declName.baseName.text),
                          call.trailingClosure == nil, call.additionalTrailingClosures.isEmpty,
                          let predicate = call.arguments.first, predicate.label?.text == "if" {
                    conditions.predicates[conditions.traitCount] = member.declName.baseName.text
                    conditions.traitCount += 1
                    if !predicate.expression.is(BooleanLiteralExprSyntax.self) {
                        nonliteralPredicates.append(capture(Syntax(predicate.expression)))
                    }
                    // The SDK evaluates the comment and explicit source location during
                    // registration. A plain Comment string has no caller expressions.
                    for operand in call.arguments.dropFirst() {
                        if let literal = operand.expression.as(StringLiteralExprSyntax.self),
                           literal.segments.allSatisfy({ $0.is(StringSegmentSyntax.self) }) { continue }
                        eager.append(capture(Syntax(operand.expression)))
                    }
                    let placeholder = predicate.with(\.expression, ExprSyntax(NilLiteralExprSyntax()))
                    var operands = call.arguments
                    operands[operands.startIndex] = placeholder
                    projected[index] = argument.with(\.expression, ExprSyntax(call.with(\.arguments, operands)))
                    continue
                } else if argument.label == nil {
                    conditions.traitCount += 1
                    eager.append(capture(Syntax(argument.expression)))
                    continue
                } else { return nil }
                projected[index] = argument.with(\.expression, ExprSyntax(NilLiteralExprSyntax()))
            }
            guard hasDisplayName || providerCount > 0 || hasScopedTraits else { return nil }
            if hasDisplayName && !eager.isEmpty {
                // A nonempty traits array alone cannot prove how a string
                // literal was interpreted. Retain its value and caller location.
                projected[args.startIndex] = args[args.startIndex]
                eager.append(capture(Syntax(args[args.startIndex].expression)))
            } else if hasDisplayName {
                // A verified literal display name is optional. Compare the surviving
                // trait expressions identically when the name is added or removed.
                projected.remove(at: projected.startIndex)
            }
            providers = providerCount
            attributes[index] = .attribute(projected.isEmpty ? withoutArguments(attribute) : attribute.with(\.arguments, .argumentList(projected)))
        }
        declaration.attributes = attributes
        guard let providers else { return nil }
        return RegistrationInputs(declaration: fingerprint(Syntax(declaration)), providers: providers, eager: eager, bare: bare,
                                  conditions: hasScopedTraits ? conditions : nil,
                                  nonliteralPredicates: nonliteralPredicates.isEmpty ? nil : nonliteralPredicates)
    }

    var suites: [Suite] = []
    var tests: [SourceRegion] = []

    init() {}

    init(legacyUnits: [SourceUnit]) {
        for unit in legacyUnits {
            if unit.swiftTestingRole == "test" { tests.append(unit.region) }
            if unit.swiftTestingRole == "suite", let name = unit.swiftTestingSuiteName ?? (unit.kind == "type" ? unit.scope : nil) {
                suites.append(Suite(name: name, conditional: unit.conditionalBranch != nil))
            }
        }
    }

    private enum AttributePresence { case absent, conditional, unconditional }

    private func presence(of name: String, in attributes: AttributeListSyntax) -> AttributePresence {
        var result = AttributePresence.absent
        for element in attributes {
            if let attribute = element.as(AttributeSyntax.self),
               Self.matches(attribute, name) { return .unconditional }
            if let directive = element.as(IfConfigDeclSyntax.self) {
                let branches = directive.clauses.map { clause in
                    clause.elements?.as(AttributeListSyntax.self).map { presence(of: name, in: $0) } ?? .absent
                }
                if directive.clauses.last?.poundKeyword.text == "#else", branches.allSatisfy({ $0 == .unconditional }) {
                    return .unconditional
                }
                if branches.contains(where: { $0 != .absent }) { result = .conditional }
            }
        }
        return result
    }

    /// Even a literal argument can be passed to a custom trait initializer.
    /// Conditional attribute lists keep their enclosing declaration conservative.
    private func hasArguments(_ name: String, in attributes: AttributeListSyntax) -> Bool {
        attributes.contains { element in
            if let attribute = element.as(AttributeSyntax.self) {
                return Self.matches(attribute, name) &&
                    attribute.arguments?.firstToken(viewMode: .sourceAccurate) != nil
            }
            return element.as(IfConfigDeclSyntax.self)?.clauses.contains { clause in
                clause.elements?.as(AttributeListSyntax.self).map { hasArguments(name, in: $0) } == true
            } == true
        }
    }

    /// The source-unit walker passes nominal headers without their members, except
    /// for opaque declarations such as actors. Inspect those members for discovery
    /// without creating additional source units or changing their semantic boundaries.
    @discardableResult
    mutating func record(_ node: Syntax, scope: [String], conditional: Bool, path: String,
                         locations: SourceLocationConverter, originalAttributes: AttributeListSyntax? = nil,
                         onArguments: ([String], AttributeListSyntax, Bool) -> Void) -> (role: String?, suiteName: String?, hasArguments: Bool?) {
        if let function = node.as(FunctionDeclSyntax.self), presence(of: "Test", in: function.attributes) != .absent {
            tests.append(.init(path: path, startLine: locations.location(for: function.positionAfterSkippingLeadingTrivia).line,
                               endLine: locations.location(for: function.endPositionBeforeTrailingTrivia).line))
            let arguments = hasArguments("Test", in: function.attributes)
            onArguments(scope + [function.name.text] + function.signature.tokens(viewMode: .sourceAccurate).map(\.text),
                        function.attributes, arguments || Self.hasOpaqueSibling(of: "Test", in: function.attributes))
            return ("test", nil, arguments)
        }
        guard let group = node.asProtocol(DeclGroupSyntax.self) else { return (nil, nil, nil) }
        for member in group.memberBlock.members {
            recordMember(member.decl, enclosing: scope, conditional: conditional, path: path, locations: locations, onArguments: onArguments)
        }
        let attributes = originalAttributes ?? group.attributes
        let suite = presence(of: "Suite", in: attributes)
        guard suite != .absent else { return (nil, nil, nil) }
        let name = scope.map(SDKTestHelperSyntax.canonicalName).joined(separator: ".")
        suites.append(Suite(name: name, conditional: conditional || suite == .conditional))
        let arguments = hasArguments("Suite", in: attributes)
        onArguments(scope, attributes, arguments || Self.hasOpaqueSibling(of: "Suite", in: attributes))
        return ("suite", name, arguments)
    }

    private mutating func recordMember(_ member: DeclSyntax, enclosing: [String], conditional: Bool,
                                       path: String, locations: SourceLocationConverter, onArguments: ([String], AttributeListSyntax, Bool) -> Void) {
        if let directive = member.as(IfConfigDeclSyntax.self) {
            for clause in directive.clauses {
                guard let members = clause.elements?.as(MemberBlockItemListSyntax.self) else { continue }
                for child in members { recordMember(child.decl, enclosing: enclosing, conditional: true, path: path, locations: locations, onArguments: onArguments) }
            }
        } else {
            let name = member.is(FunctionDeclSyntax.self) ? nil : member.asProtocol(NamedDeclSyntax.self)?.name.text
            record(Syntax(member), scope: enclosing + (name.map { [$0] } ?? []), conditional: conditional, path: path, locations: locations, onArguments: onArguments)
        }
    }
}

/// Written suites include every compilation branch. SIL names only emitted
/// nominal types, so a conditional declaration needs a unique written owner.
struct SwiftTestingSuiteDeclarations {
    var names: [String: [String]] = [:]
    var conditional: [String: [String]] = [:]
    var completeModules = Set<String>()
    private var counts: [String: Int] = [:]

    init(_ sources: [String: SwiftSourceSnapshot]) {
        var incomplete = Set<String>()
        for (key, file) in sources {
            let module = String(key.prefix { $0 != ":" })
            completeModules.insert(module)
            if !file.hasSwiftTestingRegistrationMetadata { incomplete.insert(module) }
            let declarations = file.swiftTestingDeclarations ?? SwiftTestingSourceDeclarations(legacyUnits: file.units)
            for suite in declarations.suites {
                names[module, default: []].append(suite.name)
                counts[module + "." + suite.name, default: 0] += 1
                if suite.conditional { conditional[module, default: []].append(suite.name) }
            }
        }
        completeModules.subtract(incomplete)
    }

    func canBind(_ unit: SourceUnit) -> Bool {
        guard unit.conditionalBranch != nil else { return true }
        let module = String(unit.key.prefix { $0 != ":" })
        guard let name = unit.swiftTestingSuiteName, completeModules.contains(module) else { return false }
        return counts[module + "." + name] == 1
    }
}
