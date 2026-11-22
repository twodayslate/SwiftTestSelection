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

    /// The source projection retains the signature, body and sibling attributes.
    /// Its erased inputs are entry-local only with a matching SDK factory proof.
    struct EntryInputs: Codable, Sendable {
        let declaration: String
        let providers: Int
        let eager: [Arguments]
        var bare: Bool?
        var conditions: SwiftTestingFactoryProof.Conditions?
        var nonliteralPredicates: [Arguments]?
    }

    private static func name(_ attribute: AttributeSyntax) -> [String] {
        attribute.attributeName.tokens(viewMode: .sourceAccurate).map { $0.identifier?.name ?? $0.text }
    }

    private static func matches(_ attribute: AttributeSyntax, _ expected: String) -> Bool {
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

    static func entryInputs(_ function: FunctionDeclSyntax, fingerprint: (Syntax) -> String,
                            capture: (Syntax) -> Arguments) -> EntryInputs? {
        var attributes = function.attributes
        var providers: Int?
        var eager: [Arguments] = []
        var bare = false
        var conditions = SwiftTestingFactoryProof.Conditions()
        var nonliteralPredicates: [Arguments] = []
        for index in attributes.indices {
            guard let attribute = attributes[index].as(AttributeSyntax.self) else { return nil }
            if !matches(attribute, "Test") {
                guard isMainActor(attribute) else { return nil }
                continue
            }
            guard providers == nil else { return nil }
            if attribute.arguments == nil || attribute.arguments?.as(LabeledExprListSyntax.self)?.isEmpty == true {
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
                } else if argument.label?.text == "arguments" && providerCount == 0 {
                    providerCount = 1
                } else if argument.label == nil && providerCount > 0 {
                    providerCount += 1
                } else if argument.label == nil,
                          let call = argument.expression.as(FunctionCallExprSyntax.self),
                          let member = call.calledExpression.as(MemberAccessExprSyntax.self), member.base == nil,
                          ["enabled", "disabled"].contains(member.declName.baseName.text),
                          call.trailingClosure == nil, call.additionalTrailingClosures.isEmpty,
                          call.arguments.count == 1, let predicate = call.arguments.first, predicate.label?.text == "if" {
                    conditions.predicates[conditions.traitCount] = member.declName.baseName.text
                    conditions.traitCount += 1
                    if !predicate.expression.is(BooleanLiteralExprSyntax.self) {
                        nonliteralPredicates.append(capture(Syntax(predicate.expression)))
                    }
                    let placeholder = predicate.with(\.expression, ExprSyntax(NilLiteralExprSyntax()))
                    projected[index] = argument.with(\.expression, ExprSyntax(call.with(\.arguments, [placeholder])))
                    continue
                } else if argument.label == nil {
                    conditions.traitCount += 1
                    eager.append(capture(Syntax(argument.expression)))
                    continue
                } else { return nil }
                projected[index] = argument.with(\.expression, ExprSyntax(NilLiteralExprSyntax()))
            }
            guard hasDisplayName || providerCount > 0 || !conditions.predicates.isEmpty else { return nil }
            if hasDisplayName && !eager.isEmpty {
                // A nonempty traits array alone cannot prove how a string
                // literal was interpreted. Retain its value and caller location.
                projected[args.startIndex] = args[args.startIndex]
                eager.append(capture(Syntax(args[args.startIndex].expression)))
            }
            providers = providerCount
            attributes[index] = .attribute(attribute.with(\.arguments, .argumentList(projected)))
        }
        return providers.map { EntryInputs(declaration: fingerprint(Syntax(function.with(\.attributes, attributes))),
                                          providers: $0, eager: eager, bare: bare, conditions: conditions.predicates.isEmpty ? nil : conditions,
                                          nonliteralPredicates: nonliteralPredicates.isEmpty ? nil : nonliteralPredicates) }
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
