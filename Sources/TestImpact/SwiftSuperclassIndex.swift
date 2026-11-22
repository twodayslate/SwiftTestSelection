// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

struct SwiftSuperclassIndex {
    let superclasses: [String: [String]]
    let nominalParents: [String: String]
    private let typeAliases: Set<String>
    private let nominalTypes: Set<String>

    init(sources: [String: SwiftSourceSnapshot]) {
        superclasses = sources.values.reduce(into: [String: [String]]()) { result, file in
            result.merge(file.superclasses ?? file.inheritance) { Array(Set($0 + $1)) }
        }
        nominalParents = Dictionary(uniqueKeysWithValues: Set(superclasses.values.flatMap { $0 }).compactMap { spelling in
            SwiftSourceSnapshot.nominalTypeName(spelling).map { (spelling, $0) }
        })
        typeAliases = Set(sources.values.flatMap { $0.typeAliases ?? [] })
        nominalTypes = Set(sources.values.flatMap { file in
            file.units.filter { $0.kind == "type" }.map {
                String($0.key.prefix { $0 != ":" }) + "." + $0.scope
            }
        })
    }

    /// A positive caller attribution needs one known superclass. Prefer a
    /// compiler identity when aliases or imported names obscure its spelling.
    func verifiedSuperclass(of owner: String, identities: [String: CompilerClassIdentity]?) -> String? {
        if let identities, let parent = identities[owner]?.superclass {
            let matches = identities.filter { $0.value.symbol == parent }
            return matches.count == 1 ? matches.first?.key : nil
        }
        guard let parents = superclasses[owner], parents.count == 1,
              let parent = nominalParents[parents[0]] else { return nil }
        let resolution = resolveSuperclass(parent, of: owner)
        return resolution.complete && resolution.candidates.count == 1 ? resolution.candidates.first : nil
    }

    private func containsAlias(_ name: String) -> Bool {
        typeAliases.contains(name) || name.indices.contains {
            name[$0] == "." && typeAliases.contains(String(name[..<$0]))
        }
    }

    func resolveSuperclass(_ parent: String, of owner: String) -> (candidates: [String], complete: Bool) {
        // Swift resolves an unqualified name from its enclosing scopes
        // outward. A module-level class must not hide a nested superclass.
        var scope = owner.split(separator: ".").dropLast()
        let qualifier = parent.firstIndex(of: ".").map { String(parent[..<$0]) }
        while !scope.isEmpty {
            let enclosingType = scope.joined(separator: ".")
            let prefix = enclosingType + "."
            let candidate = prefix + parent
            if containsAlias(candidate) { return ([], false) }
            if superclasses[candidate] != nil { return ([candidate], true) }
            // A nearer nominal qualifier shadows outer names even if its
            // member is inherited and absent from this declaration index.
            // Keep that ancestry unknown instead of choosing an unrelated
            // outer class with the same qualified spelling.
            if let qualifier, nominalTypes.contains(prefix + qualifier) { return ([], false) }
            // Inherited members of the enclosing class precede outer
            // lexical scopes too. This includes unqualified nested classes,
            // aliases, and the first component of a qualified name. Their
            // absence from the declaration index does not prove absence
            // from the inherited scope, so do not accept an outer match.
            if let parents = superclasses[enclosingType], !parents.isEmpty { return ([], false) }
            scope = scope.dropLast()
        }
        if containsAlias(parent) { return ([], false) }
        if superclasses[parent] != nil { return ([parent], true) }
        let candidates = superclasses.keys.filter { $0.hasSuffix("." + parent) }
        // Imports are not resolved by this index. Retain possible imported
        // classes without treating a same-named class as proof of ancestry.
        return (candidates, candidates.isEmpty)
    }
}
