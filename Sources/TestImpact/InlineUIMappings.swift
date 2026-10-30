// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation
import SwiftParser
import SwiftSyntax

/// Syntax evidence, never an executable test inventory. Kept separate from Swift
/// semantic fingerprints so ordinary comments remain semantically inert.
public struct InlineMappingSyntax: Codable, Sendable {
    public struct Directive: Codable, Sendable {
        public var line: Int
        public var normalized: String
        public var error: String?
    }
    public struct Declaration: Codable, Sendable {
        public var module: String
        public var scope: String
        public var kind: String
        public var method: String?
        public var superclass: String?
        public var region: SourceRegion
        public var conditional: Bool
        public var directives: [Directive]
    }
    public var declarations: [Declaration]
    public var diagnostics: [String]
    /// Unconditional framework imports that can establish built-in base names.
    /// Older snapshots lack this proof and must not assume a name's identity.
    public var frameworkImports: Set<String>? = nil
    /// Names introduced by scoped type imports, including conditional imports
    /// whose activity cannot be proven from source alone.
    public var scopedTypeImports: Set<String>? = nil
    /// Import-only files also contribute to their module's exported namespace.
    public var module: String? = nil
    public var reexportedTypeImports: Set<String>? = nil
    /// Whole-module imports need export evidence even for binary dependencies.
    /// Scoped imports expose only the names tracked above.
    public var moduleImports: Set<String>? = nil
    public var reexportedModules: Set<String>? = nil

    static let prefix = "swift-test-selection:"

    static func parse(_ tree: SourceFileSyntax, path: String, module: String, hasDirectives: Bool = true) -> Self {
        let locations = SourceLocationConverter(fileName: path, tree: tree)
        var result = Self(declarations: [], diagnostics: [], frameworkImports: [], scopedTypeImports: [], module: module, reexportedTypeImports: [], moduleImports: [], reexportedModules: [])
        var attached = Set<Int>()
        func directives(_ trivia: Trivia, at position: AbsolutePosition) -> [(Int, Directive)] {
            guard hasDirectives else { return [] }
            var offset = position.utf8Offset
            var values: [(Int, Directive)] = []
            for piece in trivia {
                defer { offset += piece.sourceLength.utf8Length }
                let comment: String
                switch piece {
                case .lineComment(let text), .docLineComment(let text), .blockComment(let text), .docBlockComment(let text): comment = text
                default: continue
                }
                var lineOffset = offset
                for line in comment.split(separator: "\n", omittingEmptySubsequences: false) {
                    defer { lineOffset += line.utf8.count + 1 }
                    var text = String(line).trimmingCharacters(in: .whitespaces)
                    if text.hasPrefix("//") { text = String(text.drop(while: { $0 == "/" })) }
                    else if text.hasPrefix("/*") { text = String(text.dropFirst(2)) }
                    text = text.trimmingCharacters(in: .whitespaces)
                    if text.hasPrefix("*") { text = String(text.dropFirst()).trimmingCharacters(in: .whitespaces) }
                    if text.hasSuffix("*/") { text = String(text.dropLast(2)).trimmingCharacters(in: .whitespaces) }
                    guard text.hasPrefix(prefix) else { continue }
                    let payload = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
                    var directive = Directive(line: locations.location(for: AbsolutePosition(utf8Offset: lineOffset)).line,
                                              normalized: payload)
                    do {
                        let data = Data(payload.utf8)
                        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                              !object.isEmpty, Set(object.keys).isSubset(of: ["sources", "symbols", "when"]) else {
                            throw ImpactError("expected a JSON object containing sources/symbols or a when condition")
                        }
                        if let condition = object["when"] {
                            guard object.count == 1 else { throw ImpactError("when cannot be mixed with dependency boundaries in one directive; use separate additive directives") }
                            _ = try JSONDecoder().decode(UIFeatureMappings.Condition.self, from: JSONSerialization.data(withJSONObject: condition, options: [.fragmentsAllowed]))
                        }
                        for (key, value) in object where key != "when" {
                            guard let entries = value as? [String], !entries.isEmpty, entries.allSatisfy({ !$0.isEmpty }) else {
                                throw ImpactError("\(key) must be a nonempty array of nonempty strings")
                            }
                            object[key] = Array(Set(entries)).sorted()
                        }
                        directive.normalized = String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
                    } catch { directive.error = "Invalid \(prefix) directive: \(error)" }
                    values.append((lineOffset, directive))
                }
            }
            return values
        }
        func walk(_ node: Syntax, scope: String, conditional: Bool, member: Bool) {
            if let imported = node.as(ImportDeclSyntax.self), imported.importKindSpecifier == nil,
               let name = imported.path.first?.name {
                let module = name.identifier?.name ?? name.text
                result.moduleImports?.insert(module)
                if imported.attributes.contains(where: { $0.as(AttributeSyntax.self)?.attributeName.trimmedDescription == "_exported" }) {
                    result.reexportedModules?.insert(module)
                }
            }
            if let imported = node.as(ImportDeclSyntax.self),
               let kind = imported.importKindSpecifier?.text,
               ["typealias", "class", "struct", "enum", "protocol"].contains(kind) {
                let names = imported.path.dropFirst().map {
                    $0.name.identifier?.name ?? $0.name.text
                }
                result.scopedTypeImports?.formUnion(names)
                if imported.attributes.contains(where: { $0.as(AttributeSyntax.self)?.attributeName.trimmedDescription == "_exported" }) {
                    result.reexportedTypeImports?.formUnion(names)
                }
            }
            if let imported = node.as(ImportDeclSyntax.self), !conditional,
               imported.attributes.isEmpty, imported.importKindSpecifier == nil,
               ["XCTest", "Foundation"].contains(imported.path.trimmedDescription) {
                result.frameworkImports?.insert(imported.path.trimmedDescription)
            }
            var nextScope = scope
            var kind: String?
            var method: String?
            var superclass: String?
            if let value = node.as(ClassDeclSyntax.self) {
                nextScope = [scope, value.name.identifier?.name ?? value.name.text].filter { !$0.isEmpty }.joined(separator: ".")
                kind = "class"
                superclass = value.inheritanceClause?.inheritedTypes.first?.type.trimmedDescription
            } else if let value = node.as(ExtensionDeclSyntax.self) {
                nextScope = Self.canonicalScope(value.extendedType.trimmedDescription)
                if nextScope.hasPrefix(module + ".") { nextScope = String(nextScope.dropFirst(module.count + 1)) }
                kind = "extension"
            } else if let name = node.as(StructDeclSyntax.self)?.name ?? node.as(EnumDeclSyntax.self)?.name ?? node.as(ProtocolDeclSyntax.self)?.name {
                nextScope = [scope, name.identifier?.name ?? name.text].filter { !$0.isEmpty }.joined(separator: ".")
            } else if let value = node.as(FunctionDeclSyntax.self), member {
                kind = "method"
                if value.signature.parameterClause.parameters.isEmpty,
                   !value.modifiers.contains(where: { ["static", "class"].contains($0.name.text) }) {
                    method = (value.name.identifier?.name ?? value.name.text) + "()"
                }
            }
            if let kind {
                let values = directives(node.leadingTrivia, at: node.position)
                attached.formUnion(values.map(\.0))
                var annotations = values.map(\.1)
                if kind == "method", method == nil {
                    for i in annotations.indices { annotations[i].error = "Inline mappings require a parameterless instance XCTest method" }
                }
                result.declarations.append(Declaration(module: module, scope: nextScope, kind: kind, method: method,
                    superclass: superclass, region: .init(path: path, startLine: node.startLocation(converter: locations).line,
                                                          endLine: node.endLocation(converter: locations).line),
                    conditional: conditional, directives: annotations))
                if kind == "method" { return }
            }
            if node.is(FunctionDeclSyntax.self) || node.is(InitializerDeclSyntax.self) { return }
            for child in node.children(viewMode: .sourceAccurate) {
                // Only class/extension members can be annotated methods. Nested
                // structs/enums/protocols must not borrow an enclosing class.
                let isOtherType = node.is(StructDeclSyntax.self) || node.is(EnumDeclSyntax.self) || node.is(ProtocolDeclSyntax.self)
                walk(child, scope: nextScope, conditional: conditional || node.is(IfConfigDeclSyntax.self),
                     member: isOtherType ? false : (kind == "class" || kind == "extension" || member))
            }
        }
        walk(Syntax(tree), scope: "", conditional: false, member: false)
        if hasDirectives {
            for token in tree.tokens(viewMode: .sourceAccurate) {
                let all = directives(token.leadingTrivia, at: token.position) + directives(token.trailingTrivia, at: token.endPositionBeforeTrailingTrivia)
                for (offset, directive) in all where !attached.contains(offset) {
                    result.diagnostics.append("\(path):\(directive.line): mapping directive must be leading trivia on a class, extension, or parameterless instance test method")
                }
            }
        }
        if tree.hasError, result.declarations.contains(where: { !$0.directives.isEmpty }) {
            result.diagnostics.append("\(path): cannot bind inline mappings in a source file with syntax errors")
        }
        return result
    }

    static func canonicalScope(_ spelling: String) -> String {
        SDKTestHelperSyntax.canonicalName(SwiftSourceSnapshot.nominalTypeName(spelling) ?? spelling)
    }
}

/// Resolves inline rules through the enabled executable inventory and physical
/// compiler locations. No method name or comment creates a runnable test.
struct InlineUIMappings {
    struct Resolution {
        var features: [UIFeatureMappings.Feature] = []
        var diagnostics: [SelectionDiagnostic] = []
        var policies: [String: [String]] = [:]
        func applying(to snapshot: XcodeTestGraph) -> XcodeTestGraph {
            var result = snapshot
            // Adding an inline condition must not upgrade and accidentally
            // legitimize an invalid version-1 file condition or other bad policy.
            if let existing = snapshot.mappings, (try? existing.validate()) == nil { return result }
            if !features.isEmpty {
                var mappings = result.mappings ?? UIFeatureMappings(features: [])
                mappings.features += features
                if mappings.version == 1, features.contains(where: { $0.when != nil }) { mappings.version = 2 }
                result.mappings = mappings
            }
            return result
        }
    }

    static func resolve(_ snapshot: XcodeTestGraph) -> Resolution {
        var result = Resolution()
        var declarations = snapshot.sources.values.flatMap { $0.inlineMappings?.declarations ?? [] }
        // Also normalize older saved syntax before matching compiler names.
        for index in declarations.indices {
            declarations[index].scope = InlineMappingSyntax.canonicalScope(declarations[index].scope)
        }
        let annotated = declarations.contains { !$0.directives.isEmpty }
        let uiTargets = Set(snapshot.targets.filter(\.isUITest).map(\.name))
        let inventory = snapshot.tests.filter { uiTargets.contains(String($0.prefix { $0 != "/" })) }
        let testPaths = Set(snapshot.targets.filter(\.isUITest).flatMap(\.sourceFiles))
        func diagnose(_ message: String, tests: [String]) {
            result.diagnostics.append(.init(code: "invalid_inline_mapping", message: message, tests: tests.sorted()))
        }
        if snapshot.sources.values.contains(where: { $0.inlineMappings == nil && $0.units.contains(where: { testPaths.contains($0.region.path) }) }) {
            diagnose("Saved UI source snapshots lack inline mapping metadata; regenerate this graph before narrowing the enabled UI inventory", tests: inventory)
        }
        for syntax in snapshot.sources.values.compactMap(\.inlineMappings) {
            for message in syntax.diagnostics where testPaths.contains(where: { message.hasPrefix($0 + ":") }) {
                diagnose(message, tests: inventory)
            }
        }
        let hasSyntaxDiagnostics = snapshot.sources.values.contains { !($0.inlineMappings?.diagnostics.isEmpty ?? true) }
        guard annotated || hasSyntaxDiagnostics, !inventory.isEmpty else { return result }
        // Binding only reads identity and locations. Copying the full effect
        // graph into every index retains dozens of sets per node on each query.
        struct BindingNode {
            var id: String; var module: String; var name: String
            var regions: [SourceRegion]; var nominalTypeContext: String?
        }
        let nodes = (snapshot.dependencies?.functions.values ?? [:].values).compactMap { node -> BindingNode? in
            guard !node.regions.isEmpty else { return nil }
            return .init(id: node.id, module: node.module, name: node.name,
                         regions: node.regions, nominalTypeContext: node.nominalTypeContext)
        }
        let nodesByName = Dictionary(grouping: nodes, by: { $0.module + "." + $0.name })
        var nodesByFile: [String: [BindingNode]] = [:]
        var nodesByScope: [String: [BindingNode]] = [:]
        for node in nodes {
            for path in Set(node.regions.map(\.path)) { nodesByFile[node.module + ":" + path, default: []].append(node) }
            for index in node.name.indices where node.name[index] == "." {
                nodesByScope[node.module + "." + node.name[..<index], default: []].append(node)
            }
        }
        let declarationsByFile = Dictionary(grouping: declarations.indices, by: {
            declarations[$0].module + ":" + declarations[$0].region.path
        })
        let physical = Set(snapshot.sources.values.filter { $0.receiverPhysicalLocations != false }.flatMap {
            $0.inlineMappings?.declarations.map { $0.module + ":" + $0.region.path } ?? []
        })
        func enclosed(_ member: InlineMappingSyntax.Declaration, by container: InlineMappingSyntax.Declaration) -> Bool {
            member.module == container.module && member.region.path == container.region.path &&
                member.region.startLine >= container.region.startLine && member.region.endLine <= container.region.endLine &&
                (member.scope == container.scope || member.scope.hasPrefix(container.scope + "."))
        }
        var aliases = Set(snapshot.sources.values.flatMap { $0.typeAliases ?? [] }.map(InlineMappingSyntax.canonicalScope))
        var nominalTypes = Set(snapshot.sources.values.flatMap { source in
            source.units.filter { $0.kind == "type" }.map { InlineMappingSyntax.canonicalScope(String($0.key.prefix { $0 != ":" }) + "." + $0.scope) }
        })
        // An alias spelling cannot establish an extension's owner. Compiler
        // methods, including nested class methods, can prove the owner after
        // removing the lexical suffix beneath the extension. Rebind every
        // enclosed declaration together so class defaults and methods agree.
        var unresolvedExtensions: [InlineMappingSyntax.Declaration] = []
        var unresolvedExtensionMethods = Set<Int>()
        for index in declarations.indices where declarations[index].kind == "extension" {
            let ext = declarations[index]
            let members = (declarationsByFile[ext.module + ":" + ext.region.path] ?? []).filter { $0 != index && enclosed(declarations[$0], by: ext) }
            var owners = Set<String>()
            var conflictingOwner = false
            if physical.contains(ext.module + ":" + ext.region.path) {
                for member in members {
                    guard declarations[member].kind == "method", let method = declarations[member].method else { continue }
                    let suffix = String(declarations[member].scope.dropFirst(ext.scope.count)) + "." + method
                    for node in nodesByFile[ext.module + ":" + ext.region.path] ?? [] where node.name.hasSuffix(suffix) && node.regions.contains(where: {
                        $0.path == ext.region.path && $0.startLine >= declarations[member].region.startLine && $0.startLine <= declarations[member].region.endLine
                    }) {
                        let name = node.name.hasPrefix("@objc ") ? String(node.name.dropFirst(6)) : node.name
                        // Closures (including async ObjC bridges) and local
                        // helpers describe their enclosing method with " in ".
                        // They share its suffix and locations, but are not
                        // competing declarations of that method's owner.
                        guard !name.contains(" in ") else { continue }
                        let owner = String(name.dropLast(suffix.count))
                        let relativeScope = declarations[member].scope.dropFirst(ext.scope.count)
                        guard node.nominalTypeContext == ext.module + "." + owner + relativeScope else {
                            if node.nominalTypeContext?.isEmpty != false {
                                // A private nested helper may lack supported
                                // nominal evidence. Keep its method unresolved
                                // without discarding another method's proof.
                                unresolvedExtensionMethods.insert(member)
                            } else {
                                // A known conflicting owner invalidates the
                                // extension even if another member agrees.
                                conflictingOwner = true
                            }
                            continue
                        }
                        owners.insert(owner)
                    }
                }
            }
            guard !conflictingOwner, owners.count == 1, let owner = owners.first, nominalTypes.contains(ext.module + "." + owner) else {
                unresolvedExtensions.append(ext)
                continue
            }
            declarations[index].scope = owner
            for member in members {
                declarations[member].scope = owner + declarations[member].scope.dropFirst(ext.scope.count)
            }
            // Keep lexical shadowing evidence under the compiler identity too.
            // Retaining the original names is conservative when conditional
            // extensions use the same spelling for different owners.
            let replacement = ext.module + "." + owner + "."
            // Source snapshots retain a module qualifier in extension scopes;
            // inline declarations have already stripped it. Preserve both forms.
            for prefix in [ext.module + "." + ext.scope + ".", ext.module + "." + ext.module + "." + ext.scope + "."] {
                aliases.formUnion(aliases.filter { $0.hasPrefix(prefix) }.map { replacement + $0.dropFirst(prefix.count) })
                nominalTypes.formUnion(nominalTypes.filter { $0.hasPrefix(prefix) }.map { replacement + $0.dropFirst(prefix.count) })
            }
        }
        let classNames = Set(declarations.filter { $0.kind == "class" }.map { $0.module + "." + $0.scope })
        let methodsByOwner = Dictionary(grouping: declarations.filter { $0.kind == "method" }, by: { $0.module + "." + $0.scope })
        let extensionsByOwner = Dictionary(grouping: declarations.filter { $0.kind == "extension" }, by: { $0.module + "." + $0.scope })
        let classes = Dictionary(grouping: declarations.filter { $0.kind == "class" }, by: { $0.module + "." + $0.scope })
        let declarationsByOwner = Dictionary(grouping: declarations, by: { $0.module + "." + $0.scope })
        let methodsByName = Dictionary(grouping: declarations.filter { $0.kind == "method" }, by: { $0.method ?? "" })
        let policyDeclarations = declarations.filter { !$0.directives.isEmpty }
        // Only declarations actually enclosed by unresolved extensions can be
        // suffix candidates. Build this relation once, not per test/ancestor.
        var unresolvedNested: [String: [InlineMappingSyntax.Declaration]] = [:]
        for declaration in declarations where declaration.kind == "class" || declaration.kind == "method" {
            for ext in unresolvedExtensions where enclosed(declaration, by: ext) && declaration.scope.hasPrefix(ext.scope + ".") {
                let suffix = String(declaration.scope.dropFirst(ext.scope.count))
                unresolvedNested[suffix, default: []].append(declaration)
            }
        }
        var frameworkImports = Set<String>()
        var scopedTypeImports: [String: Set<String>] = [:]
        var reexportedNames = Set<String>()
        for syntax in snapshot.sources.values.compactMap(\.inlineMappings) {
            if let module = syntax.module {
                reexportedNames.formUnion((syntax.reexportedTypeImports ?? []).map { module + "." + $0 })
            }
            for declaration in syntax.declarations {
                // Legacy import evidence did not account for scoped re-exports.
                guard let scoped = syntax.scopedTypeImports, syntax.reexportedTypeImports != nil else { continue }
                scopedTypeImports[declaration.module + ":" + declaration.region.path] = scoped
                for framework in syntax.frameworkImports ?? [] {
                    frameworkImports.insert(declaration.module + ":" + declaration.region.path + ":" + framework)
                }
            }
        }
        func containsAlias(_ name: String) -> Bool {
            aliases.contains(name) || name.indices.contains { name[$0] == "." && aliases.contains(String(name[..<$0])) }
        }
        func couldImport(_ owner: String, into module: String) -> Bool {
            if owner == module { return true }
            guard let inventory = snapshot.runtimeInventory, inventory.diagnostics.isEmpty,
                  inventory.unavailableModules?[module] == nil, let imports = inventory.imports[module],
                  inventory.imports[owner] != nil || inventory.unavailableModules?[owner] != nil else { return true }
            return imports.contains(owner)
        }
        let sourcesByModule = Dictionary(grouping: snapshot.sources.keys, by: { String($0.prefix { $0 != ":" }) })
        var completeExportCache: [String: Bool] = [:]
        func hasCompleteExports(_ module: String) -> Bool {
            if let cached = completeExportCache[module] { return cached }
            let result = computeCompleteExports(module)
            completeExportCache[module] = result
            return result
        }
        func computeCompleteExports(_ module: String) -> Bool {
            guard snapshot.unsupportedSourceInputs?[module]?.isEmpty != false,
                  let keys = sourcesByModule[module], !keys.isEmpty,
                  keys.allSatisfy({ snapshot.sources[$0]?.inlineMappings?.reexportedModules != nil &&
                      snapshot.sources[$0]?.inlineMappings?.reexportedTypeImports != nil }) else { return false }
            // A captured file cannot prove that another, missing file does not
            // re-export a scoped name. Check the declared source inventory too.
            return snapshot.targets.filter { (snapshot.modules[$0.name] ?? $0.name) == module }.allSatisfy { target in
                target.sourceFiles.allSatisfy { snapshot.sources[module + ":" + $0] != nil }
            }
        }
        func missingExports(_ declaration: InlineMappingSyntax.Declaration) -> Set<String> {
            let module = declaration.module
            guard let implicitImports = snapshot.dependencies?.compilerImplicitImports,
                  let moduleImports = implicitImports[module],
                  hasCompleteExports(module),
                  let imports = snapshot.sources[module + ":" + declaration.region.path]?.inlineMappings?.moduleImports else { return [module + " (source or compiler import inventory)"] }
            var pending = Array(imports.union(moduleImports))
            // Re-exports in another file are visible throughout this module.
            pending += (sourcesByModule[module] ?? []).flatMap { Array(snapshot.sources[$0]?.inlineMappings?.reexportedModules ?? []) }
            var visited = Set<String>(), missing = Set<String>()
            while let imported = pending.popLast() {
                guard visited.insert(imported).inserted,
                      implicitImports[module]?.contains(imported) == true || couldImport(imported, into: module) else { continue }
                // These SDK modules establish the supported terminal bases.
                if ["XCTest", "Foundation", "Swift"].contains(imported) { continue }
                guard hasCompleteExports(imported) else { missing.insert(imported); continue }
                pending += (sourcesByModule[imported] ?? []).flatMap { Array(snapshot.sources[$0]?.inlineMappings?.reexportedModules ?? []) }
            }
            return missing
        }
        func compilerIdentity(_ declaration: InlineMappingSyntax.Declaration) -> CompilerClassIdentity? {
            guard physical.contains(declaration.module + ":" + declaration.region.path),
                  let identity = snapshot.dependencies?.compilerClassIdentities?[declaration.module + "." + declaration.scope],
                  identity.path == declaration.region.path,
                  identity.line >= declaration.region.startLine, identity.line <= declaration.region.endLine else { return nil }
            return identity
        }
        let globalNames = aliases.union(nominalTypes).filter { $0.split(separator: ".").count == 2 }
        func couldShadow(_ parent: String, in module: String, names: Set<String>, includeOwnModule: Bool = false) -> Bool {
            let name = String(parent.prefix { $0 != "." })
            return names.contains { candidate in
                guard candidate.hasSuffix("." + name) else { return false }
                let owner = String(candidate.prefix { $0 != "." })
                guard includeOwnModule || owner != module else { return false }
                // These maps contain transitive project imports. Only a complete
                // inventory can rule out an unrelated module's exported name.
                return couldImport(owner, into: module)
            }
        }
        // This is an overapproximation for diagnostics, never a binding rule.
        // A disabled sibling's policy cannot make an unrelated enabled suite
        // require inline ancestry evidence. Preserve uncertainty for plausible
        // ancestors, aliases, and imported policies whose reachability is unknown.
        func mayHavePolicy(owner: String, method: String, roots: Set<String>) -> Bool {
            // If an extension owner could not be proven above, do not silently
            // discard a directive on a compiler-bound enabled method. Its source
            // location still establishes that binding must succeed or diagnose.
            let methodDeclarations = methodsByName[method] ?? []
            let located = methodDeclarations.filter { declaration in
                guard declaration.kind == "method", declaration.method == method,
                      (!classNames.contains(declaration.module + "." + declaration.scope) ||
                       unresolvedExtensions.contains { enclosed(declaration, by: $0) }) else { return false }
                if !physical.contains(declaration.module + ":" + declaration.region.path) || roots.isEmpty {
                    return couldImport(declaration.module, into: String(owner.prefix { $0 != "." }))
                }
                return (nodesByFile[declaration.module + ":" + declaration.region.path] ?? []).contains { node in
                    roots.contains(node.id) && node.name.hasSuffix("." + method) && node.regions.contains {
                        $0.path == declaration.region.path && $0.startLine >= declaration.region.startLine && $0.startLine <= declaration.region.endLine
                    }
                }
            }
            if located.contains(where: { !$0.directives.isEmpty }) { return true }
            if policyDeclarations.contains(where: { container in
                ["class", "extension"].contains(container.kind) && !container.directives.isEmpty && located.contains {
                    $0.scope == container.scope && enclosed($0, by: container)
                }
            }) { return true }
            // A nested class with only inherited methods, or a method with
            // missing locations, may not establish its extension owner. Its
            // suffix is diagnostic evidence, never enough to bind the alias.
            func unresolvedNestedCandidates(_ key: String, methodsAllowed: Bool) -> [InlineMappingSyntax.Declaration] {
                // Enumerate lexical suffixes of the queried owner. The index
                // retains the same conservative candidates and import checks.
                key.indices.filter { key[$0] == "." }.flatMap { unresolvedNested[String(key[$0...])] ?? [] }.filter { declaration in
                    (declaration.kind == "class" || methodsAllowed && declaration.method == method) &&
                        couldImport(declaration.module, into: String(owner.prefix { $0 != "." }))
                }
            }

            let implementations = methodDeclarations.filter { active($0, methodOnly: true, roots: roots) }
            func carriesPolicy(_ declaration: InlineMappingSyntax.Declaration, methodsAllowed: Bool) -> Bool {
                guard !declaration.directives.isEmpty else { return false }
                if declaration.kind == "class" { return true }
                guard methodsAllowed else { return false }
                if declaration.kind == "method" {
                    return declaration.method == method && (implementations.isEmpty || active(declaration, methodOnly: true, roots: roots))
                }
                return (methodsByOwner[declaration.module + "." + declaration.scope] ?? []).contains {
                    $0.method == method && $0.region.path == declaration.region.path &&
                    $0.region.startLine >= declaration.region.startLine && $0.region.endLine <= declaration.region.endLine &&
                    (implementations.isEmpty || active($0, methodOnly: true, roots: roots))
                }
            }
            // A physically bound method in an unresolved extension can still
            // inherit defaults through its raw nested declaration. Examine that
            // ancestry for diagnostics, without treating it as a binding.
            let rawOwners = located.map { $0.module + "." + $0.scope }
            let displayOwner = String(owner.dropFirst(owner.prefix { $0 != "." }.count + 1))
            let possibleOwners = located.isEmpty ? [] : classes.keys.filter { $0.hasSuffix("." + displayOwner) }
            var pending = ([owner] + rawOwners + possibleOwners).map { ($0, true) }, visited = Set<String>()
            while let (key, methodsAllowed) = pending.popLast() {
                guard visited.insert(key + ":" + String(methodsAllowed)).inserted else { continue }
                let nested = unresolvedNestedCandidates(key, methodsAllowed: methodsAllowed)
                if nested.contains(where: { !$0.directives.isEmpty }) { return true }
                // The nested declaration may have no directive of its own.
                // Follow its raw ancestry too: a method in another extension
                // (or subclass) can inherit the base class's policy. These
                // suffix candidates only require diagnostics, never binding.
                pending.append(contentsOf: nested.filter { $0.kind == "class" }.map { ($0.module + "." + $0.scope, methodsAllowed) })
                if (declarationsByOwner[key] ?? []).contains(where: { carriesPolicy($0, methodsAllowed: methodsAllowed) }) { return true }
                let inheritedMethods = methodsAllowed && !implementations.contains { $0.module + "." + $0.scope == key }
                for declaration in classes[key] ?? [] {
                    guard let spelling = declaration.superclass else { continue }
                    guard let parent = SwiftSourceSnapshot.nominalTypeName(spelling) else { return annotated }
                    pending.append((declaration.module + "." + parent, inheritedMethods))
                    let qualifier = String(parent.prefix { $0 != "." })
                    var matches = classes.keys.filter { $0 == parent || $0.hasSuffix("." + parent) }
                    let localAlias = aliases.contains { $0 == parent || $0.hasSuffix("." + parent) || $0.hasSuffix("." + qualifier) }
                    if localAlias { matches += classes.keys.filter { $0.hasPrefix(declaration.module + ".") } }
                    pending.append(contentsOf: matches.map { ($0, inheritedMethods) })
                    // A suffix candidate is not a lookup result and cannot rule
                    // out an uncaptured imported ancestor carrying these rules.
                    if policyDeclarations.contains(where: {
                        $0.module != declaration.module && couldImport($0.module, into: declaration.module) &&
                        carriesPolicy($0, methodsAllowed: inheritedMethods)
                    }) { return true }
                }
            }
            return false
        }
        func active(_ declaration: InlineMappingSyntax.Declaration, methodOnly: Bool = false, roots: Set<String>? = nil) -> Bool {
            // #sourceLocation can make a physical-region match misleading.
            guard physical.contains(declaration.module + ":" + declaration.region.path) else { return false }
            let candidates = methodOnly ? nodesByName[declaration.module + "." + declaration.scope + "." + (declaration.method ?? "")] ?? [] : nodesByScope[declaration.module + "." + declaration.scope] ?? []
            return candidates.contains { node in
                node.module == declaration.module && (roots == nil || roots!.contains(node.id)) &&
                (methodOnly ? node.name == declaration.scope + "." + (declaration.method ?? "") : node.name.hasPrefix(declaration.scope + ".")) &&
                node.regions.contains { $0.path == declaration.region.path && $0.startLine >= declaration.region.startLine && $0.startLine <= declaration.region.endLine }
            }
        }
        var featureIndexes: [String: Int] = [:]
        for test in inventory.sorted() {
            let parts = test.split(separator: "/").map(String.init)
            guard parts.count == 3, let module = snapshot.modules[parts[0]] else { continue }
            let method = parts[2].contains("(") ? parts[2] : parts[2] + "()"
            let needsBinding = mayHavePolicy(owner: module + "." + parts[1], method: method, roots: snapshot.dependencies?.tests[test] ?? [])
            var hierarchy: [InlineMappingSyntax.Declaration] = []
            var pending: String? = module + "." + parts[1]
            var visited = Set<String>()
            var failed = false
            var unknownExports = Set<String>()
            var compilerAncestry = true
            var diagnosedPaths = testPaths
            func diagnoseSources(_ applicable: [InlineMappingSyntax.Declaration]) {
                let paths = Set(applicable.map { $0.region.path }).subtracting(diagnosedPaths)
                diagnosedPaths.formUnion(paths)
                for syntax in snapshot.sources.values.compactMap(\.inlineMappings) {
                    for message in syntax.diagnostics where paths.contains(where: { message.hasPrefix($0 + ":") }) {
                        diagnose(message, tests: [test])
                    }
                }
            }
            while let key = pending {
                pending = nil
                guard visited.insert(key).inserted else { failed = true; break }
                let candidates = (classes[key] ?? []).filter { !$0.conditional || active($0) }
                guard candidates.count == 1, let declaration = candidates.first else {
                    if needsBinding {
                        diagnose("Cannot uniquely bind inline suite declarations for \(test): \(key) [" + (classes[key] ?? []).map { "\($0.region.path):\($0.region.startLine)" }.joined(separator: ", ") + "]; need an active class and compiler locations", tests: [test])
                    }
                    failed = true; break
                }
                hierarchy.append(declaration)
                guard let spelling = declaration.superclass else { break }
                guard let parent = SwiftSourceSnapshot.nominalTypeName(spelling) else { failed = true; break }
                let importedName = String(parent.prefix { $0 != "." })
                guard let importedTypes = scopedTypeImports[declaration.module + ":" + declaration.region.path] else {
                    failed = true; break
                }
                // Continue through lexical candidates to report their malformed
                // directives, but never materialize rules from uncertain ancestry.
                unknownExports.formUnion(missingExports(declaration))
                compilerAncestry = compilerAncestry && hasCompleteExports(declaration.module) &&
                    snapshot.dependencies?.compilerImplicitImports?[declaration.module] != nil
                if importedTypes.contains(importedName) || couldShadow(parent, in: declaration.module, names: reexportedNames, includeOwnModule: true) {
                    failed = true; break
                }
                var scope = (declaration.module + "." + declaration.scope).split(separator: ".").dropLast()
                let qualifier = parent.firstIndex(of: ".").map { String(parent[..<$0]) }
                while !scope.isEmpty {
                    let enclosing = scope.joined(separator: ".")
                    let candidate = enclosing + "." + parent
                    if containsAlias(candidate) { failed = true; break }
                    if classes[candidate] != nil { pending = candidate; break }
                    // A nearer qualifier or inherited enclosing scope can hide
                    // an outer class. Syntax alone cannot prove that its nested
                    // members are absent; never borrow an unrelated annotation.
                    if let qualifier, nominalTypes.contains(enclosing + "." + qualifier) { failed = true; break }
                    if classes[enclosing]?.contains(where: { $0.superclass != nil }) == true { failed = true; break }
                    scope = scope.dropLast()
                }
                if failed || containsAlias(parent) { failed = true; break }
                if pending == nil, classes[parent] != nil { pending = parent }
                if pending == nil, ["XCTestCase", "XCTest.XCTestCase", "NSObject", "Foundation.NSObject"].contains(parent) {
                    // The spelling alone cannot distinguish a framework class
                    // from a project alias or type exported under the same name.
                    let source = declaration.module + ":" + declaration.region.path + ":"
                    let imported = frameworkImports.contains(source + "XCTest") ||
                        (parent.hasSuffix("NSObject") && frameworkImports.contains(source + "Foundation"))
                    if !imported || couldShadow(parent, in: declaration.module, names: globalNames) { failed = true }
                    let expected = parent.hasSuffix("XCTestCase") ? "c:objc(cs)XCTestCase" : "c:objc(cs)NSObject"
                    compilerAncestry = compilerAncestry && compilerIdentity(declaration)?.superclass == expected
                    break
                }
                if let parentKey = pending {
                    let parentDeclarations = classes[parentKey] ?? []
                    let parentIdentities = Set(parentDeclarations.compactMap { compilerIdentity($0)?.symbol })
                    compilerAncestry = compilerAncestry && parentIdentities.count == 1 &&
                        compilerIdentity(declaration).map { parentIdentities.contains($0.superclass) } == true
                }
                if pending == nil {
                    // A unique suffix is not proof of Swift name lookup: an
                    // unrelated nested type or unimported module may match while
                    // the actual imported superclass has no captured source.
                    failed = true; break
                }
            }
            diagnoseSources(hierarchy)
            if failed {
                if needsBinding {
                    diagnose("Inline ancestry is unresolved for \(test) [" + hierarchy.map { "\($0.region.path):\($0.region.startLine)" }.joined(separator: ", ") + "]; regenerate complete source/compiler evidence and use module-qualified names for imported superclasses", tests: [test])
                }
                continue
            }
            var applicable = hierarchy
            let roots = snapshot.dependencies?.tests[test] ?? []
            for owner in hierarchy {
                let methods = (methodsByOwner[owner.module + "." + owner.scope] ?? []).filter { $0.method == method }
                let bound = methods.filter { active($0, methodOnly: true, roots: roots) }
                if bound.isEmpty { continue }
                guard bound.count == 1, let implementation = bound.first else {
                    if needsBinding { diagnose("Ambiguous inline method binding for \(test); compiler locations match multiple declarations", tests: [test]) }
                    failed = true; break
                }
                applicable.append(implementation)
                applicable += (extensionsByOwner[owner.module + "." + owner.scope] ?? []).filter {
                    $0.region.path == implementation.region.path && $0.region.startLine <= implementation.region.startLine && $0.region.endLine >= implementation.region.endLine }
                break
            }
            if !applicable.contains(where: { $0.kind == "method" }) {
                if needsBinding { diagnose("No unique compiler-backed method declaration for inline mappings on \(test)", tests: [test]) }
                failed = true
            }
            diagnoseSources(applicable)
            if applicable.contains(where: { declaration in
                unresolvedExtensions.contains { enclosed(declaration, by: $0) } ||
                    (declaration.kind == "method" && unresolvedExtensionMethods.contains { index in
                        let candidate = declarations[index]
                        return candidate.module == declaration.module && candidate.scope == declaration.scope &&
                            candidate.method == declaration.method && candidate.region == declaration.region
                    })
            }) {
                if needsBinding {
                    diagnose("Cannot establish the compiler-qualified extension owner for \(test); regenerate complete nominal type evidence", tests: [test])
                }
                continue
            }
            if !unknownExports.isEmpty && !compilerAncestry {
                if needsBinding {
                    diagnose("Inline ancestry is unresolved for \(test): imported module exports are not fully captured (\(unknownExports.sorted().joined(separator: ", "))); missing compiler superclass identity; regenerate from the built Swift modules or retain this rule in JSON", tests: [test])
                }
                continue
            }
            guard !failed else { continue }
            for declaration in applicable {
                guard physical.contains(declaration.module + ":" + declaration.region.path) else {
                    diagnose("\(declaration.region.path):\(declaration.region.startLine): redirected source locations cannot bind inline mappings", tests: [test]); continue
                }
                for (ordinal, directive) in declaration.directives.enumerated() {
                    let location = "\(declaration.region.path):\(directive.line)"
                    if let error = directive.error { diagnose(location + ": " + error, tests: [test]); continue }
                    let object = (try? JSONSerialization.jsonObject(with: Data(directive.normalized.utf8))) as? [String: Any] ?? [:]
                    // Resolve a declaration once even when its class default
                    // applies to hundreds of executable methods.
                    let identity = "inline:\(location):\(declaration.module).\(declaration.scope):\(declaration.kind):\(declaration.method ?? ""):\(ordinal)"
                    if let index = featureIndexes[identity] {
                        result.features[index].tests?.append(test)
                    } else {
                        let condition = object["when"].flatMap { try? JSONDecoder().decode(UIFeatureMappings.Condition.self, from: JSONSerialization.data(withJSONObject: $0)) }
                        featureIndexes[identity] = result.features.count
                        result.features.append(.init(name: identity, sources: object["sources"] as? [String] ?? [],
                                                     symbols: object["symbols"] as? [String] ?? [], tests: [test], when: condition))
                    }
                    result.policies[test, default: []].append(declaration.module + ":" + declaration.scope + ":" + declaration.kind + ":" + (declaration.method ?? "") + ":" + directive.normalized)
                }
            }
        }
        result.policies = result.policies.mapValues { $0.sorted() }
        return result
    }

    static func policyPaths(_ sources: [String: SwiftSourceSnapshot]) -> [String: [String]] {
        var result: [String: [String]] = [:]
        for declaration in sources.values.flatMap({ $0.inlineMappings?.declarations ?? [] }) where !declaration.directives.isEmpty {
            result[declaration.region.path, default: []] += declaration.directives.map {
                declaration.module + ":" + declaration.scope + ":" + declaration.kind + ":" + (declaration.method ?? "") + ":" + $0.normalized
            }
        }
        return result.mapValues { $0.sorted() }
    }
}
