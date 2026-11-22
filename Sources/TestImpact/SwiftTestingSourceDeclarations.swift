// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
import SwiftSyntax

/// Written discovery declarations are candidates until matched to compiler registrations.
struct SwiftTestingSourceDeclarations: Codable, Sendable {
    struct Suite: Codable, Sendable {
        let name: String
        let conditional: Bool
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
               [name, "Testing." + name].contains(attribute.attributeName.trimmedDescription) { return .unconditional }
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
                return [name, "Testing." + name].contains(attribute.attributeName.trimmedDescription) &&
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
                         locations: SourceLocationConverter) -> (role: String?, suiteName: String?, hasArguments: Bool?) {
        if let function = node.as(FunctionDeclSyntax.self), presence(of: "Test", in: function.attributes) != .absent {
            tests.append(.init(path: path, startLine: locations.location(for: function.positionAfterSkippingLeadingTrivia).line,
                               endLine: locations.location(for: function.endPositionBeforeTrailingTrivia).line))
            return ("test", nil, hasArguments("Test", in: function.attributes))
        }
        guard let group = node.asProtocol(DeclGroupSyntax.self) else { return (nil, nil, nil) }
        for member in group.memberBlock.members {
            recordMember(member.decl, enclosing: scope, conditional: conditional, path: path, locations: locations)
        }
        let suite = presence(of: "Suite", in: group.attributes)
        guard suite != .absent else { return (nil, nil, nil) }
        let name = scope.map(SDKTestHelperSyntax.canonicalName).joined(separator: ".")
        suites.append(Suite(name: name, conditional: conditional || suite == .conditional))
        return ("suite", name, hasArguments("Suite", in: group.attributes))
    }

    private mutating func recordMember(_ member: DeclSyntax, enclosing: [String], conditional: Bool,
                                       path: String, locations: SourceLocationConverter) {
        if let directive = member.as(IfConfigDeclSyntax.self) {
            for clause in directive.clauses {
                guard let members = clause.elements?.as(MemberBlockItemListSyntax.self) else { continue }
                for child in members { recordMember(child.decl, enclosing: enclosing, conditional: true, path: path, locations: locations) }
            }
        } else {
            let name = member.asProtocol(NamedDeclSyntax.self)?.name.text
            record(Syntax(member), scope: enclosing + (name.map { [$0] } ?? []), conditional: conditional, path: path, locations: locations)
        }
    }
}
