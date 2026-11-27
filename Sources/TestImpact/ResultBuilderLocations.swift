// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import SwiftSyntax

/// Result-builder calls may have no source spelling or compiler edge. Compare
/// the body positions that can supply their defaults in either revision.
struct ResultBuilderLocations {
    let kinds: Set<String>
    let incompletePaths: Set<String>

    static func dimensions(_ policy: UIFeatureMappings.SourceLocationPolicy) -> Set<String> {
        switch policy {
        case .semantic: ["line", "column", "file", "fileID", "filePath"]
        case .diagnosticLineColumn: ["file", "fileID", "filePath"]
        case .diagnostic: []
        }
    }

    init(policy: UIFeatureMappings.SourceLocationPolicy, sources: [[String: SwiftSourceSnapshot]],
         modules: Set<String>, incompleteInputs: Bool, touching paths: Set<String>) {
        let dimensions = Self.dimensions(policy)
        guard !dimensions.isEmpty else { kinds = []; incompletePaths = []; return }
        let stepNames: Set<String> = ["buildExpression", "buildBlock", "buildPartialBlock", "buildOptional", "buildIf",
            "buildEither", "buildArray", "buildLimitedAvailability", "buildFinalResult"]
        var knownImports: Set<String> = ["import Testing"]
        for module in modules {
            knownImports.insert("import " + module)
            knownImports.insert("@testable import " + module)
        }
        var observed = Set<String>(), missing = Set<String>()
        var indirect = Set<String>()
        var mayHaveIndirectStep = false
        var opaque = incompleteInputs
        for revision in sources {
            for file in revision.values {
                if let path = file.units.first?.region.path, paths.contains(path),
                   file.units.contains(where: { $0.builderLocations == nil }) {
                    missing.insert(path)
                }
                // A binary module, macro expansion or generated input can supply a builder
                // through a parameter or protocol witness in another file.
                guard !opaque else { continue }
                guard file.diagnostics.isEmpty,
                      file.helperDeclarationIssues?.contains(where: { $0.kind == "macro-declaration" }) == false,
                      file.units.first?.receiverUnsupportedImports?.isSubset(of: knownImports) ?? file.units.isEmpty else {
                    opaque = true
                    continue
                }
                // A local initializer alone cannot supply a builder step. Source
                // must name a step, or an import or expansion can supply one.
                if !mayHaveIndirectStep {
                    mayHaveIndirectStep = file.identifierNames?.isDisjoint(with: stepNames) != true ||
                        file.units.contains { $0.kind == "import" } || file.helperDeclarationIssues?.isEmpty != true
                }
                for unit in file.units {
                    guard let defaults = unit.locationDefaultNames else {
                        opaque = true
                        break
                    }
                    for (name, values) in defaults {
                        if stepNames.contains(name) { observed.formUnion(values) }
                        if SourceUnit.indirectLocationDefaultNames.contains(name),
                           file.unreferencedPrivateTypes?.contains(unit.scope) != true {
                            indirect.formUnion(values)
                        }
                    }
                }
            }
        }
        if mayHaveIndirectStep { observed.formUnion(indirect) }
        kinds = opaque ? dimensions : observed.intersection(dimensions)
        incompletePaths = kinds.isEmpty ? [] : missing
    }
}

/// Swift attaches a builder to an executable body. Nested declarations and closures
/// have their own context even when their surrounding expression is transformed.
struct ResultBuilderBodySyntax {
    private let nonWitnessMembers: Set<SyntaxIdentifier>
    private(set) var unreferencedPrivateTypes: Set<String> = []

    init(_ file: SourceFileSyntax, identifiers: [String: [TokenSyntax]], hasUnresolvedDeclarations: Bool) {
        // An extension (including one emitted by a macro) can add a conformance.
        // Without either, an unadorned file-private nominal with no inheritance
        // cannot acquire a builder through a protocol requirement.
        guard !hasUnresolvedDeclarations else { nonWitnessMembers = []; return }
        let mayExtend = file.tokens(viewMode: .sourceAccurate).contains(where: {
            $0.tokenKind == .keyword(.extension) || $0.tokenKind == .atSign
        })
        var members = Set<SyntaxIdentifier>()
        for item in file.statements {
            guard let group = item.item.asProtocol(DeclGroupSyntax.self), group.inheritanceClause == nil,
                  !item.item.is(ProtocolDeclSyntax.self),
                  group.modifiers.contains(where: { [.keyword(.private), .keyword(.fileprivate)].contains($0.name.tokenKind) })
            else { continue }
            if !mayExtend { members.insert(group.memberBlock.members.id) }
            // A private nominal with no uses in its defining file cannot supply
            // a builder's callable value or type alias in another file.
            if group.attributes.isEmpty, let name = item.item.asProtocol(NamedDeclSyntax.self)?.name,
               let spelling = name.identifier?.name, identifiers[spelling]?.count == 1 {
                unreferencedPrivateTypes.insert(name.text)
            }
        }
        nonWitnessMembers = members
    }

    private func mayInheritBuilder(_ declaration: Syntax) -> Bool {
        guard let member = declaration.parent?.as(MemberBlockItemSyntax.self) else { return false }
        var parent = member.parent
        while let ancestor = parent {
            if let block = ancestor.as(MemberBlockSyntax.self) { return !nonWitnessMembers.contains(block.members.id) }
            parent = ancestor.parent
        }
        return true
    }

    private func getterCanUseBuilder(_ block: AccessorBlockSyntax) -> Bool {
        let owner = block.parent?.as(PatternBindingSyntax.self)?.parent?.parent ?? block.parent
        guard let owner, let declaration = owner.asProtocol(WithAttributesSyntax.self) else { return true }
        return !declaration.attributes.isEmpty || mayInheritBuilder(owner)
    }

    private func closureCanUseBuilder(_ closure: ClosureExprSyntax, ordinaryStatements: SyntaxIdentifier?) -> Bool {
        // A plain variable initializer has no builder-annotated parameter.
        // Wrappers and member-attribute macros can supply a different initializer.
        guard closure.signature?.attributes.isEmpty != false else { return true }
        var expression = Syntax(closure)
        while let element = expression.parent?.as(LabeledExprSyntax.self),
              let tuple = element.parent?.parent?.as(TupleExprSyntax.self),
              tuple.elements.count == 1, element.label == nil, element.trailingComma == nil {
            expression = Syntax(tuple)
        }
        // A builder can pass this expression to a builder-annotated
        // buildExpression parameter. An ordinary body returns or discards it.
        if let ordinaryStatements, expression.parent?.as(CodeBlockItemSyntax.self)?.parent?.id == ordinaryStatements {
            return false
        }
        if expression.parent?.is(ReturnStmtSyntax.self) == true ||
            expression.parent?.as(FunctionCallExprSyntax.self)?.calledExpression.id == expression.id { return false }
        guard let binding = expression.parent?.as(InitializerClauseSyntax.self)?.parent?.as(PatternBindingSyntax.self),
              let variable = binding.parent?.parent?.as(VariableDeclSyntax.self), variable.attributes.isEmpty
        else { return true }
        if variable.parent?.is(MemberBlockItemSyntax.self) == true {
            var parent = variable.parent
            while let ancestor = parent {
                if let group = ancestor.asProtocol(DeclGroupSyntax.self), !group.attributes.isEmpty { return true }
                parent = ancestor.parent
            }
        }
        return false
    }

    private func body(_ syntax: Syntax, ordinaryStatements: SyntaxIdentifier?) -> (statements: CodeBlockItemListSyntax, eligible: Bool)? {
        if let closure = syntax.as(ClosureExprSyntax.self) {
            return (closure.statements, closureCanUseBuilder(closure, ordinaryStatements: ordinaryStatements))
        }
        if let accessors = syntax.as(AccessorBlockSyntax.self),
           let getter = accessors.accessors.as(CodeBlockItemListSyntax.self) {
            return (getter, getterCanUseBuilder(accessors))
        }
        guard let block = syntax.as(CodeBlockSyntax.self), let owner = syntax.parent else { return nil }
        if let function = owner.as(FunctionDeclSyntax.self) {
            return (block.statements, !function.attributes.isEmpty || mayInheritBuilder(owner))
        }
        if let accessor = owner.as(AccessorDeclSyntax.self) {
            if !accessor.attributes.isEmpty { return (block.statements, true) }
            switch accessor.accessorSpecifier.tokenKind {
            case .keyword(.get):
                let property = owner.parent?.parent?.as(AccessorBlockSyntax.self)
                return (block.statements, property.map(getterCanUseBuilder) ?? true)
            case .keyword(.set), .keyword(.willSet), .keyword(.didSet):
                return (block.statements, false)
            default: return (block.statements, true)
            }
        }
        return nil
    }

    private func containsReturn(_ syntax: Syntax) -> Bool {
        if syntax.is(ReturnStmtSyntax.self) { return true }
        // Nested declarations (including #if) and closures cannot establish a
        // return from this body in every build configuration.
        if syntax.is(ClosureExprSyntax.self) || syntax.is(DeclSyntax.self) { return false }
        return syntax.children(viewMode: .sourceAccurate).contains(where: containsReturn)
    }

    func locations(in node: Syntax) -> Set<Int> {
        var offsets = Set<Int>()
        func visit(_ syntax: Syntax, recording: Bool, ordinaryStatements: SyntaxIdentifier?) {
            if let token = syntax.as(TokenSyntax.self) {
                if recording { offsets.insert(token.positionAfterSkippingLeadingTrivia.utf8Offset) }
                return
            }
            if let body = body(syntax, ordinaryStatements: ordinaryStatements) {
                let transformed = body.eligible && !containsReturn(Syntax(body.statements))
                for child in syntax.children(viewMode: .sourceAccurate) {
                    // The enclosing builder can use the boundaries of a nested
                    // expression. Only the nested builder owns its statements.
                    visit(child, recording: transformed || (recording && child.id != body.statements.id),
                          ordinaryStatements: transformed ? nil : body.statements.id)
                }
            } else {
                for child in syntax.children(viewMode: .sourceAccurate) {
                    visit(child, recording: recording, ordinaryStatements: ordinaryStatements)
                }
            }
        }
        visit(node, recording: false, ordinaryStatements: nil)
        return offsets
    }
}
