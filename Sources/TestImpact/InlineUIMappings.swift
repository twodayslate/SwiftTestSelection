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

    static let prefix = "swift-test-selection:"

    static func parse(_ tree: SourceFileSyntax, path: String, module: String, hasDirectives: Bool = true) -> Self {
        let locations = SourceLocationConverter(fileName: path, tree: tree)
        var result = Self(declarations: [], diagnostics: [], frameworkImports: [])
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
                nextScope = value.extendedType.trimmedDescription
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
        let declarations = snapshot.sources.values.flatMap { $0.inlineMappings?.declarations ?? [] }
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
        guard annotated, !inventory.isEmpty else { return result }
        let nodes = Array(snapshot.dependencies?.functions.values ?? [:].values)
        let nodesByModule = Dictionary(grouping: nodes, by: \.module)
        let nodesByName = Dictionary(grouping: nodes, by: { $0.module + "." + $0.name })
        let physical = Set(snapshot.sources.values.filter { $0.receiverPhysicalLocations != false }.flatMap {
            $0.inlineMappings?.declarations.map { $0.module + ":" + $0.region.path } ?? []
        })
        let methodsByOwner = Dictionary(grouping: declarations.filter { $0.kind == "method" }, by: { $0.module + "." + $0.scope })
        let extensionsByOwner = Dictionary(grouping: declarations.filter { $0.kind == "extension" }, by: { $0.module + "." + $0.scope })
        let aliases = Set(snapshot.sources.values.flatMap { $0.typeAliases ?? [] }.map(SDKTestHelperSyntax.canonicalName))
        let classes = Dictionary(grouping: declarations.filter { $0.kind == "class" }, by: { $0.module + "." + $0.scope })
        let nominalTypes = Set(snapshot.sources.values.flatMap { source in
            source.units.filter { $0.kind == "type" }.map { SDKTestHelperSyntax.canonicalName(String($0.key.prefix { $0 != ":" }) + "." + $0.scope) }
        })
        var frameworkImports = Set<String>()
        for syntax in snapshot.sources.values.compactMap(\.inlineMappings) {
            for declaration in syntax.declarations {
                for framework in syntax.frameworkImports ?? [] {
                    frameworkImports.insert(declaration.module + ":" + declaration.region.path + ":" + framework)
                }
            }
        }
        func containsAlias(_ name: String) -> Bool {
            aliases.contains(name) || name.indices.contains { name[$0] == "." && aliases.contains(String(name[..<$0])) }
        }
        let globalNames = aliases.union(nominalTypes).filter { $0.split(separator: ".").count == 2 }
        func couldShadowFrameworkBase(_ parent: String, in module: String) -> Bool {
            let name = String(parent.prefix { $0 != "." })
            return globalNames.contains { candidate in
                guard candidate.hasSuffix("." + name) else { return false }
                let owner = String(candidate.prefix { $0 != "." })
                guard owner != module else { return false } // Checked lexically above.
                // These maps contain transitive project imports. Only a complete
                // inventory can rule out an unrelated module's exported name.
                guard let inventory = snapshot.runtimeInventory, inventory.diagnostics.isEmpty,
                      inventory.unavailableModules?[module] == nil, let imports = inventory.imports[module],
                      inventory.imports[owner] != nil || inventory.unavailableModules?[owner] != nil else { return true }
                return imports.contains(owner)
            }
        }
        func active(_ declaration: InlineMappingSyntax.Declaration, methodOnly: Bool = false, roots: Set<String>? = nil) -> Bool {
            // #sourceLocation can make a physical-region match misleading.
            guard physical.contains(declaration.module + ":" + declaration.region.path) else { return false }
            let candidates = methodOnly ? nodesByName[declaration.module + "." + declaration.scope + "." + (declaration.method ?? "")] ?? [] : nodesByModule[declaration.module] ?? []
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
            var hierarchy: [InlineMappingSyntax.Declaration] = []
            var pending: String? = module + "." + parts[1]
            var visited = Set<String>()
            var failed = false
            while let key = pending {
                pending = nil
                guard visited.insert(key).inserted else { failed = true; break }
                let candidates = (classes[key] ?? []).filter { !$0.conditional || active($0) }
                guard candidates.count == 1, let declaration = candidates.first else {
                    diagnose("Cannot uniquely bind inline suite declarations for \(test): \(key) [" + (classes[key] ?? []).map { "\($0.region.path):\($0.region.startLine)" }.joined(separator: ", ") + "]; need an active class and compiler locations", tests: [test])
                    failed = true; break
                }
                hierarchy.append(declaration)
                guard let spelling = declaration.superclass else { break }
                guard let parent = SwiftSourceSnapshot.nominalTypeName(spelling) else { failed = true; break }
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
                    if !imported || couldShadowFrameworkBase(parent, in: declaration.module) { failed = true }
                    break
                }
                if pending == nil {
                    // A unique suffix is not proof of Swift name lookup: an
                    // unrelated nested type or unimported module may match while
                    // the actual imported superclass has no captured source.
                    failed = true; break
                }
            }
            if failed {
                diagnose("Inline ancestry is unresolved for \(test) [" + hierarchy.map { "\($0.region.path):\($0.region.startLine)" }.joined(separator: ", ") + "]; regenerate complete source/compiler evidence and use module-qualified names for imported superclasses", tests: [test])
                continue
            }
            var applicable = hierarchy
            let roots = snapshot.dependencies?.tests[test] ?? []
            for owner in hierarchy {
                let methods = (methodsByOwner[owner.module + "." + owner.scope] ?? []).filter { $0.method == method }
                let bound = methods.filter { active($0, methodOnly: true, roots: roots) }
                if bound.isEmpty { continue }
                guard bound.count == 1, let implementation = bound.first else {
                    diagnose("Ambiguous inline method binding for \(test); compiler locations match multiple declarations", tests: [test])
                    failed = true; break
                }
                applicable.append(implementation)
                applicable += (extensionsByOwner[owner.module + "." + owner.scope] ?? []).filter {
                    $0.region.path == implementation.region.path && $0.region.startLine <= implementation.region.startLine && $0.region.endLine >= implementation.region.endLine }
                break
            }
            if !applicable.contains(where: { $0.kind == "method" }) {
                diagnose("No unique compiler-backed method declaration for inline mappings on \(test)", tests: [test]); failed = true
            }
            guard !failed else { continue }
            let applicablePaths = Set(applicable.map { $0.region.path }).subtracting(testPaths)
            for syntax in snapshot.sources.values.compactMap(\.inlineMappings) {
                for message in syntax.diagnostics where applicablePaths.contains(where: { message.hasPrefix($0 + ":") }) {
                    diagnose(message, tests: [test])
                }
            }
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
