// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation
import SwiftParser
import SwiftSyntax
#if canImport(CryptoKit)
import CryptoKit
#endif

public struct SourceUnit: Codable, Sendable {
    public var key: String
    public var fingerprint: String
    public var kind: String
    public var scope: String
    public var region: SourceRegion
    /// Present only when evaluated location literals add meaning beyond syntax.
    /// Older graphs lack this evidence and keep their conservative fingerprint.
    public var syntaxFingerprint: String? = nil
    /// A surviving body can be compared without assuming old compiler edges.
    public var headOnlyBodySupported: Bool? = nil
    /// Evaluated file/fileID/filePath literals, excluding caller defaults. An
    /// empty array proves there are none; nil keeps legacy snapshots conservative.
    public var fileLocationValues: [String]? = nil
    /// Bare source-location defaults declared in this unit. Callers, rather than
    /// the declaration, supply these values.
    public var locationDefaultKinds: Set<String>? = nil
    /// Syntactic callable names supplement compiler edges lost during lowering.
    /// "*" represents constructors or an otherwise ambiguous callable name.
    public var locationDefaultNames: [String: Set<String>]? = nil
    public var invocationNames: Set<String>? = nil
    /// Invocation token locations, compared only for compiler callers of a
    /// source-location default. Separate dimensions avoid line-only changes
    /// affecting callers of a file-only default.
    public var callerLocations: [String: String]? = nil
    /// Syntax proof for a private helper referenced only by direct test/helper calls.
    public var privateTestHelper: PrivateTestHelperSyntax? = nil
    /// Concrete source limitation for an otherwise private test-helper candidate.
    public var privateTestHelperBlocker: String? = nil
    /// Closed name evidence for a separately executed added XCTest entry.
    public var independentAddedTestEntry: String? = nil
    public var sdkTestHelper: SDKTestHelperSyntax? = nil
    /// Authenticated direct, bodyless protocol requirement; never an extension implementation.
    public var bodylessProtocolRequirement: String? = nil
    /// Empty, unconditional extension header with no attributes, modifiers or conformance.
    public var plainExtension: Bool? = nil
    public var helperCallableName: String? = nil
    public var helperReferenceSignature: String? = nil
    public var helperCallerSupported: Bool? = nil
    /// Source overload shapes paired with SIL signatures during receiver audits.
    public var receiverCallShapes: [String: Set<[String]>]? = nil
    public var receiverCallSites: [String: [String]]? = nil
    public var receiverImportsSupported: Bool? = nil
    public var receiverUnsupportedImports: Set<String>? = nil
    /// Captured struct/enum identity; classes cannot use value-type metatype rules.
    public var receiverValueType: Bool? = nil
    /// Whether this subscript can compete with the SDK identifier getter.
    public var subscriptAcceptsSingleUnlabeledArgument: Bool? = nil

    static func withLocations(_ values: [String], syntax: String) -> String {
        values.isEmpty ? syntax : syntax + "@locations[" +
            values.map { "\($0.utf8.count):" + $0 }.joined(separator: "|") + "]"
    }
}

public struct SwiftSourceSnapshot: Codable, Sendable {
    public var inlineMappings: InlineMappingSyntax? = nil
    public var units: [SourceUnit]
    public var inheritance: [String: [String]]
    public var diagnostics: [String]
    /// Member declarations owned by the project, including extensions of SDK
    /// types. Optional so older saved graphs keep their conservative behavior.
    public var dispatchMembers: Set<String>? = nil
    /// Module-qualified overrides and required initializer implementations.
    public var dispatchOverrides: Set<String>? = nil
    /// Alias declarations shadow nominal names even when their targets cannot
    /// be resolved by the source index.
    public var typeAliases: Set<String>? = nil
    /// First inherited type for each class, excluding trailing conformances.
    /// Older snapshots fall back to the broader inheritance inventory.
    public var superclasses: [String: [String]]? = nil
    /// Optional proof inventory; older captures conservatively decline isolation.
    public var identifierNames: Set<String>? = nil
    public var helperSafeClasses: [String: String]? = nil
    public var helperNamesUnshadowed: Bool? = nil
    public var attachmentAddUnshadowed: Bool? = nil
    public var helperReferences: [String: SDKTestHelperSyntax.References]? = nil
    public var sdkHelperNamesUnshadowed: Bool? = nil
    /// Stored properties proven to be immutable, inferred string literals.
    /// All other declarations explicitly carry false, including duplicates.
    public var literalStoredProperties: [String: Bool]? = nil
    /// Inferred Bool instance storage cannot carry a receiver or callback.
    /// Annotations, wrappers, observers, custom literal defaults and duplicates decline the proof.
    public var booleanStoredProperties: [String: Bool]? = nil
    public var booleanLiteralNamesUnshadowed: Bool? = nil
    public var classFinality: [String: Bool]? = nil
    /// Module-wide pairing must reject presumed locations redirected into another file.
    public var receiverPhysicalLocations: Bool? = nil

    /// Match specialized superclass references to their nominal declarations.
    /// Parse the type so nested arguments, function types and qualification do
    /// not get confused with the enclosing type's name.
    static func nominalTypeName(_ spelling: String) -> String? {
        let tree = Parser.parse(source: "typealias ImpactSuperclass = " + spelling)
        guard !tree.hasError, tree.statements.count == 1,
              let declaration = tree.statements.first?.item.as(TypeAliasDeclSyntax.self) else { return nil }
        func name(_ type: TypeSyntax) -> String? {
            if let identifier = type.as(IdentifierTypeSyntax.self) { return identifier.name.text }
            if let member = type.as(MemberTypeSyntax.self), let base = name(member.baseType) {
                return base + "." + member.name.text
            }
            return nil
        }
        return name(declaration.initializer.value)
    }

    public static func parse(_ text: String, path: String, module: String) -> Self {
        let tree = Parser.parse(source: text)
        let locations = SourceLocationConverter(fileName: path, tree: tree)
        var result = Self(units: [], inheritance: [:], diagnostics: [])
        result.inlineMappings = InlineMappingSyntax.parse(tree, path: path, module: module, hasDirectives: text.contains(InlineMappingSyntax.prefix))
        result.dispatchMembers = []
        result.dispatchOverrides = []
        result.typeAliases = []
        result.superclasses = [:]
        let identifiers = Dictionary(grouping: tree.tokens(viewMode: .sourceAccurate).filter { $0.identifier != nil }, by: { $0.identifier!.name })
        result.identifierNames = Set(identifiers.keys)
        result.helperNamesUnshadowed = PrivateTestHelperSyntax.reservedNames.allSatisfy { name in
            !(identifiers[name] ?? []).contains(where: PrivateTestHelperSyntax.shadowsReservedName)
        }
        result.attachmentAddUnshadowed = !(identifiers["add"] ?? []).contains(where: PrivateTestHelperSyntax.shadowsAttachmentAdd)
        let unsupportedCallerImports = SDKTestHelperSyntax.unsupportedCallerImports(tree)
        let callerImportsSupported = unsupportedCallerImports.isEmpty
        let physicalLocations = !tree.tokens(viewMode: .sourceAccurate).contains { $0.tokenKind == .poundSourceLocation }
        result.receiverPhysicalLocations = physicalLocations
        let referenceAnalysis = SDKHelperReferenceAnalysis(identifiers: identifiers, locations: locations, callerImportsSupported: callerImportsSupported)
        result.helperReferences = identifiers.mapValues { referenceAnalysis.references($0) }
        for tokens in identifiers.values {
            for signature in Set(tokens.compactMap(SDKTestHelperSyntax.referenceKey)) {
                result.helperReferences![signature] = referenceAnalysis.references(tokens, matching: signature)
            }
        }
        result.sdkHelperNamesUnshadowed = SDKTestHelperSyntax.names.allSatisfy { name in
            !(identifiers[name] ?? []).contains(where: PrivateTestHelperSyntax.shadowsReservedName)
        }
        result.helperSafeClasses = [:]
        result.literalStoredProperties = [:]
        result.booleanStoredProperties = [:]
        result.booleanLiteralNamesUnshadowed = ["Bool", "BooleanLiteralType"].allSatisfy { name in
            !(identifiers[name] ?? []).contains(where: PrivateTestHelperSyntax.shadowsReservedName)
        }
        result.classFinality = [:]
        if tree.hasError { result.diagnostics.append("Swift syntax could not be parsed completely: \(path)") }
        // Preserve syntax structure, token kinds and literal contents, but not
        // trivia. Location values belong to their expression, not the whole file.
        func fingerprint(_ node: Syntax) -> String {
            if let token = node.as(TokenSyntax.self) { return "\(token.tokenKind):\(token.text.utf8.count):\(token.text)" }
            return "\(node.kind)[" + node.children(viewMode: .sourceAccurate).map(fingerprint).joined(separator: "|") + "]"
        }
        let locationNames: Set<String> = ["line", "column", "file", "fileID", "filePath"]
        func bareDefault(_ macro: MacroExpansionExprSyntax) -> Bool {
            macro.parent?.is(InitializerClauseSyntax.self) == true &&
                (macro.parent?.parent?.is(FunctionParameterSyntax.self) == true ||
                 macro.parent?.parent?.is(EnumCaseParameterSyntax.self) == true)
        }
        func locationValue(_ name: String, at position: AbsolutePosition) -> String {
            let location = locations.location(for: position)
            switch name {
            case "line": return String(location.presumedLine)
            case "column": return String(location.column)
            case "fileID": return module + "/" + (location.presumedFile.split(separator: "/").last.map(String.init) ?? "")
            default: return location.presumedFile
            }
        }
        func defaultName(_ macro: MacroExpansionExprSyntax) -> String {
            var ancestor = macro.parent
            while let node = ancestor {
                if let function = node.as(FunctionDeclSyntax.self) { return function.name.identifier?.name ?? function.name.text }
                if let element = node.as(EnumCaseElementSyntax.self) { return element.name.identifier?.name ?? element.name.text }
                if node.is(InitializerDeclSyntax.self) { return "*" } // Type aliases can rename constructors.
                if node.is(SubscriptDeclSyntax.self) { return "subscript" }
                ancestor = node.parent
            }
            return "*"
        }
        func callerInfo(_ node: Syntax) -> (locations: [String: String], names: Set<String>) {
            var offsets = Set<Int>()
            var names = Set<String>()
            func calledName(_ expression: ExprSyntax) -> String {
                if let reference = expression.as(DeclReferenceExprSyntax.self) { return reference.baseName.identifier?.name ?? reference.baseName.text }
                if let member = expression.as(MemberAccessExprSyntax.self) { return member.declName.baseName.identifier?.name ?? member.declName.baseName.text }
                if let generic = expression.as(GenericSpecializationExprSyntax.self) { return calledName(generic.expression) }
                return "*"
            }
            func record(_ tokens: TokenSequence) {
                offsets.formUnion(tokens.map { $0.positionAfterSkippingLeadingTrivia.utf8Offset })
            }
            func visit(_ node: Syntax) {
                if let call = node.as(FunctionCallExprSyntax.self) {
                    names.insert(calledName(call.calledExpression))
                    record(call.calledExpression.tokens(viewMode: .sourceAccurate))
                    for token in [call.leftParen, call.rightParen].compactMap({ $0 }) {
                        offsets.insert(token.positionAfterSkippingLeadingTrivia.utf8Offset)
                    }
                } else if let call = node.as(SubscriptCallExprSyntax.self) {
                    names.insert("subscript")
                    record(call.calledExpression.tokens(viewMode: .sourceAccurate))
                    offsets.insert(call.leftSquare.positionAfterSkippingLeadingTrivia.utf8Offset)
                    offsets.insert(call.rightSquare.positionAfterSkippingLeadingTrivia.utf8Offset)
                } else if let attribute = node.as(AttributeSyntax.self) {
                    names.insert(attribute.attributeName.trimmedDescription)
                    record(attribute.tokens(viewMode: .sourceAccurate))
                } else if let macro = node.as(MacroExpansionExprSyntax.self),
                          !locationNames.contains(macro.macroName.text) && macro.macroName.text != "function" {
                    // A source macro can synthesize a call that subsequently inlines.
                    names.insert("*")
                    record(macro.tokens(viewMode: .sourceAccurate))
                }
                for child in node.children(viewMode: .sourceAccurate) { visit(child) }
            }
            visit(node)
            guard !offsets.isEmpty else { return ([:], names) }
            let positions = offsets.sorted().map { AbsolutePosition(utf8Offset: $0) }
            let valuesByKind = Dictionary(uniqueKeysWithValues: locationNames.map { name in
                let values = positions.map {
                    let value = locationValue(name, at: $0)
                    return "\(value.utf8.count):" + value
                }.joined(separator: "|")
                #if canImport(CryptoKit)
                // Keep archive size bounded even for large generated functions.
                return (name, Data(SHA256.hash(data: Data(values.utf8))).base64EncodedString())
                #else
                return (name, values)
                #endif
            })
            return (valuesByKind, names)
        }
        func locationValues(_ node: Syntax) -> [String] {
            var values: [String] = []
            for token in node.tokens(viewMode: .sourceAccurate) where token.tokenKind == .pound {
                guard let macro = token.parent?.as(MacroExpansionExprSyntax.self) else { continue }
                // Bare parameter defaults use the caller's location. Parenthesized
                // or arithmetic defaults use the declaration's location instead.
                if bareDefault(macro) { continue }
                let name = macro.macroName.text
                if locationNames.contains(name) {
                    values.append(name + ":" + locationValue(name, at: macro.positionAfterSkippingLeadingTrivia))
                }
            }
            return values
        }
        func containsOpaqueResult(_ node: Syntax) -> Bool {
            node.is(SomeOrAnyTypeSyntax.self) ||
                node.children(viewMode: .sourceAccurate).contains(where: containsOpaqueResult)
        }
        func add(_ node: Syntax, header: Syntax, kind: String, scope: [String], plainExtension: Bool? = nil) {
            if let function = node.as(FunctionDeclSyntax.self), ["!", "==", "!=", "&&", "||"].contains(function.name.text) {
                result.sdkHelperNamesUnshadowed = false
            }
            if let alias = node.as(TypeAliasDeclSyntax.self) {
                result.typeAliases!.insert(([module] + scope + [alias.name.text]).joined(separator: "."))
            }
            if !scope.isEmpty {
                let names: [String]
                if let function = node.as(FunctionDeclSyntax.self) { names = [function.name.text] }
                else if node.is(InitializerDeclSyntax.self) { names = ["init"] }
                else if node.is(DeinitializerDeclSyntax.self) { names = ["deinit"] }
                else if node.is(SubscriptDeclSyntax.self) { names = ["subscript"] }
                else if let variable = node.as(VariableDeclSyntax.self) {
                    names = variable.bindings.compactMap { $0.pattern.as(IdentifierPatternSyntax.self)?.identifier.text }
                } else { names = [] }
                result.dispatchMembers!.formUnion(names.map { scope.joined(separator: ".") + "." + $0 })
                let modifiers = node.as(FunctionDeclSyntax.self)?.modifiers
                    ?? node.as(InitializerDeclSyntax.self)?.modifiers
                    ?? node.as(VariableDeclSyntax.self)?.modifiers
                    ?? node.as(SubscriptDeclSyntax.self)?.modifiers
                if modifiers?.contains(where: {
                    $0.name.tokenKind == .keyword(.override) ||
                        node.is(InitializerDeclSyntax.self) && $0.name.tokenKind == .keyword(.required)
                }) == true {
                    result.dispatchOverrides!.formUnion(names.map { module + "." + scope.joined(separator: ".") + "." + $0 })
                }
            }
            let start = locations.location(for: node.positionAfterSkippingLeadingTrivia).line
            let end = locations.location(for: node.endPositionBeforeTrailingTrivia).line
            var defaultNames: [String: Set<String>] = [:]
            for token in node.tokens(viewMode: .sourceAccurate) where token.tokenKind == .pound {
                guard let macro = token.parent?.as(MacroExpansionExprSyntax.self),
                      bareDefault(macro), locationNames.contains(macro.macroName.text) else { continue }
                defaultNames[defaultName(macro), default: []].insert(macro.macroName.text)
            }
            let defaults = Set(defaultNames.values.flatMap { $0 })
            let calls = callerInfo(node)
            let syntax = fingerprint(node)
            let values = locationValues(node)
            let semantic = SourceUnit.withLocations(values, syntax: syntax)
            var bodySupported = false
            if let function = node.as(FunctionDeclSyntax.self) {
                // Optional, tuple and generic wrappers can hide an opaque result
                // whose inferred type changes callers without a surviving call edge.
                let hasOpaqueResult = function.signature.returnClause.map { containsOpaqueResult(Syntax($0.type)) } ?? false
                let attributes = function.attributes.compactMap { $0.as(AttributeSyntax.self)?.attributeName.trimmedDescription }
                let hasMacro = function.body?.tokens(viewMode: .sourceAccurate).contains { token in
                    guard token.tokenKind == .pound, let macro = token.parent?.as(MacroExpansionExprSyntax.self) else { return false }
                    return !locationNames.contains(macro.macroName.text) && macro.macroName.text != "function"
                } ?? false
                // Enclosing attached macros may synthesize other declarations
                // from this body, outside the body's direct dependency paths.
                var enclosing = node.parent
                var enclosingSupported = true
                while let ancestor = enclosing {
                    let list = ancestor.as(ClassDeclSyntax.self)?.attributes
                        ?? ancestor.as(StructDeclSyntax.self)?.attributes
                        ?? ancestor.as(EnumDeclSyntax.self)?.attributes
                        ?? ancestor.as(ExtensionDeclSyntax.self)?.attributes
                        ?? ancestor.as(ProtocolDeclSyntax.self)?.attributes
                    if let list {
                        enclosingSupported = enclosingSupported && list.allSatisfy {
                            $0.as(AttributeSyntax.self)?.attributeName.trimmedDescription == "MainActor"
                        }
                    }
                    enclosing = ancestor.parent
                }
                bodySupported = enclosingSupported && attributes.count == function.attributes.count && attributes.allSatisfy { $0 == "MainActor" } &&
                    !hasOpaqueResult && !hasMacro
            }
            if let variable = node.as(VariableDeclSyntax.self) {
                var container = node.parent
                var knownContainer = true
                while let ancestor = container {
                    let attributes = ancestor.as(ClassDeclSyntax.self)?.attributes
                        ?? ancestor.as(StructDeclSyntax.self)?.attributes
                        ?? ancestor.as(EnumDeclSyntax.self)?.attributes
                        ?? ancestor.as(ExtensionDeclSyntax.self)?.attributes
                    if let attributes {
                        knownContainer = knownContainer && attributes.allSatisfy {
                            $0.as(AttributeSyntax.self)?.attributeName.trimmedDescription == "MainActor"
                        }
                    }
                    container = ancestor.parent
                }
                for binding in variable.bindings {
                    guard let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text else { continue }
                    let member = (scope + [SDKTestHelperSyntax.canonicalName(name)]).joined(separator: ".")
                    let literal = binding.initializer?.value.as(StringLiteralExprSyntax.self)
                    let safe = callerImportsSupported && !scope.isEmpty && variable.bindingSpecifier.text == "let" &&
                        variable.attributes.isEmpty && variable.modifiers.allSatisfy { ["private", "fileprivate", "internal"].contains($0.name.text) } &&
                        binding.typeAnnotation == nil && binding.accessorBlock == nil &&
                        literal?.segments.allSatisfy { $0.is(StringSegmentSyntax.self) } == true
                    result.literalStoredProperties![member] = (result.literalStoredProperties![member] ?? true) && safe
                    let boolean = callerImportsSupported && knownContainer && !scope.isEmpty &&
                        variable.attributes.isEmpty && variable.modifiers.allSatisfy { ["private", "fileprivate", "internal"].contains($0.name.text) } &&
                        binding.typeAnnotation == nil && binding.accessorBlock == nil &&
                        binding.initializer?.value.is(BooleanLiteralExprSyntax.self) == true
                    result.booleanStoredProperties![member] = (result.booleanStoredProperties![member] ?? true) && boolean
                }
            }
            let receiverCalls = SDKReceiverCallSyntax.evidence(in: node, locations: physicalLocations ? locations : nil, path: path)
            result.units.append(SourceUnit(
                key: module + ":" + scope.joined(separator: ".") + ":" + fingerprint(header),
                fingerprint: semantic,
                kind: kind, scope: scope.joined(separator: "."),
                region: SourceRegion(path: path, startLine: start, endLine: end),
                syntaxFingerprint: semantic == syntax ? nil : syntax,
                headOnlyBodySupported: bodySupported,
                fileLocationValues: values.filter { !$0.hasPrefix("line:") && !$0.hasPrefix("column:") },
                locationDefaultKinds: defaults,
                locationDefaultNames: defaultNames, invocationNames: calls.names,
                callerLocations: calls.locations,
                privateTestHelper: node.as(FunctionDeclSyntax.self).flatMap {
                    PrivateTestHelperSyntax.prove($0, importsSupported: callerImportsSupported, references: identifiers[$0.name.identifier?.name ?? $0.name.text] ?? [], locations: locations)
                }, privateTestHelperBlocker: node.as(FunctionDeclSyntax.self).flatMap { PrivateTestHelperSyntax.unsupportedEffect($0, locations: locations) },
                independentAddedTestEntry: node.as(FunctionDeclSyntax.self).flatMap {
                    PrivateTestHelperSyntax.independentAddedEntry($0, references: identifiers[$0.name.identifier?.name ?? $0.name.text] ?? [])
                }, sdkTestHelper: node.as(FunctionDeclSyntax.self).flatMap(SDKTestHelperSyntax.prove),
                bodylessProtocolRequirement: PrivateTestHelperSyntax.bodylessProtocolRequirement(node),
                plainExtension: plainExtension,
                helperCallableName: node.as(FunctionDeclSyntax.self).map { $0.name.identifier?.name ?? $0.name.text },
                helperReferenceSignature: node.as(FunctionDeclSyntax.self).flatMap { function in
                    function.signature.parameterClause.parameters.allSatisfy { $0.defaultValue == nil && $0.ellipsis == nil } ? SDKTestHelperSyntax.signature(function) : nil
                },
                helperCallerSupported: node.as(FunctionDeclSyntax.self).map(SDKTestHelperSyntax.callerSupported),
                receiverCallShapes: receiverCalls.shapes,
                receiverCallSites: physicalLocations ? receiverCalls.sites : nil,
                receiverImportsSupported: callerImportsSupported,
                receiverUnsupportedImports: unsupportedCallerImports,
                receiverValueType: node.is(StructDeclSyntax.self) || node.is(EnumDeclSyntax.self),
                subscriptAcceptsSingleUnlabeledArgument: node.as(SubscriptDeclSyntax.self).map { declaration in
                    let parameters = Array(declaration.parameterClause.parameters)
                    return parameters.indices.contains { i in
                        let parameter = parameters[i]
                        let label = parameter.secondName == nil ? "_" : SDKTestHelperSyntax.canonicalName(parameter.firstName.text)
                        return label == "_" && parameters.indices.allSatisfy { j in
                            i == j || parameters[j].defaultValue != nil || parameters[j].ellipsis != nil
                        }
                    }
                }))
        }
        func walk(_ node: Syntax, scope: [String]) {
            if let item = node.as(CodeBlockItemSyntax.self), !item.item.is(DeclSyntax.self) {
                add(node, header: node, kind: "topLevel", scope: scope)
            } else if let value = node.as(IfConfigDeclSyntax.self) {
                let header = Syntax(value.with(\.clauses, IfConfigClauseListSyntax(value.clauses.map { $0.with(\.elements, nil) })))
                add(header, header: header, kind: "configuration", scope: scope)
                for child in node.children(viewMode: .sourceAccurate) { walk(child, scope: scope) }
            } else if let value = node.as(ClassDeclSyntax.self) {
                let names = scope + [value.name.text]
                let className = (scope + [value.name.identifier?.name ?? value.name.text]).joined(separator: ".")
                result.classFinality![className] = (result.classFinality![className] ?? true) && value.modifiers.contains { $0.name.text == "final" }
                if scope.isEmpty, let parent = PrivateTestHelperSyntax.safeSuperclass(value) {
                    result.helperSafeClasses![module + "." + value.name.text] = parent
                }
                let header = Syntax(value.with(\.memberBlock.members, MemberBlockItemListSyntax([])))
                add(header, header: header, kind: "type", scope: names)
                result.inheritance[module + "." + names.joined(separator: "."), default: []] += value.inheritanceClause?.inheritedTypes.map { $0.type.trimmedDescription } ?? []
                result.superclasses![module + "." + names.joined(separator: "."), default: []] += value.inheritanceClause?.inheritedTypes.first.map { [$0.type.trimmedDescription] } ?? []
                for member in value.memberBlock.members { walk(Syntax(member.decl), scope: names) }
            } else if let value = node.as(ProtocolDeclSyntax.self) {
                let names = scope + [value.name.text]
                let header = Syntax(value.with(\.memberBlock.members, MemberBlockItemListSyntax([])))
                add(header, header: header, kind: "type", scope: names)
                for member in value.memberBlock.members { walk(Syntax(member.decl), scope: names) }
            } else if let value = node.as(StructDeclSyntax.self) {
                let names = scope + [value.name.text]
                let header = Syntax(value.with(\.memberBlock.members, MemberBlockItemListSyntax([])))
                add(header, header: header, kind: "type", scope: names)
                for member in value.memberBlock.members { walk(Syntax(member.decl), scope: names) }
            } else if let value = node.as(EnumDeclSyntax.self) {
                let names = scope + [value.name.text]
                let header = Syntax(value.with(\.memberBlock.members, MemberBlockItemListSyntax([])))
                add(header, header: header, kind: "type", scope: names)
                for member in value.memberBlock.members { walk(Syntax(member.decl), scope: names) }
            } else if let value = node.as(ExtensionDeclSyntax.self) {
                let names = [value.extendedType.trimmedDescription]
                let header = Syntax(value.with(\.memberBlock.members, MemberBlockItemListSyntax([])))
                add(header, header: header, kind: "extension", scope: names, plainExtension: PrivateTestHelperSyntax.isPlainExtension(value))
                for member in value.memberBlock.members { walk(Syntax(member.decl), scope: names) }
            } else if let value = node.as(FunctionDeclSyntax.self) {
                add(node, header: Syntax(value.with(\.body, nil)), kind: "function", scope: scope)
            } else if node.is(InitializerDeclSyntax.self) || node.is(DeinitializerDeclSyntax.self) || node.is(VariableDeclSyntax.self) || node.is(SubscriptDeclSyntax.self) {
                add(node, header: node, kind: "state", scope: scope)
            } else if let imported = node.as(ImportDeclSyntax.self) {
                if imported.attributes.contains(where: { $0.as(AttributeSyntax.self)?.attributeName.trimmedDescription == "_exported" }),
                   !SDKTestHelperSyntax.trustedModules.contains(imported.path.trimmedDescription) {
                    result.sdkHelperNamesUnshadowed = false
                    result.helperNamesUnshadowed = false
                }
                add(node, header: node, kind: "import", scope: scope)
            } else if node.is(DeclSyntax.self) && !node.is(IfConfigDeclSyntax.self) {
                add(node, header: node, kind: "declaration", scope: scope)
            } else {
                for child in node.children(viewMode: .sourceAccurate) { walk(child, scope: scope) }
            }
        }
        walk(Syntax(tree), scope: [])
        return result
    }
}
