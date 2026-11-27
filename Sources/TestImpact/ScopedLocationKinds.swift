// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

/// An unreferenced file-private type can still use its own members through
/// Self or implicit member lookup. Keep their defaults in that lexical scope.
struct LocationDefaultOwner {
    let source: String
    let type: String
}

extension SwiftSourceSnapshot {
    func privateDefaultOwner(of unit: SourceUnit) -> LocationDefaultOwner? {
        // An opaque declaration, such as an entire nested actor, also stores
        // defaults from its children. Its enclosing scope does not own them.
        guard privateLocationDefaultOwners?.contains(unit.scope) == true,
              unit.kind == "function" || unit.kind == "state" || unit.helperEnumCaseWithoutDefaults != nil
        else { return nil }
        return LocationDefaultOwner(source: unit.qualifiedSourcePath, type: unit.scope)
    }
}

struct ScopedLocationKinds {
    var shared = Set<String>()
    private var bySource: [String: [String: Set<String>]] = [:]

    mutating func include(_ kinds: Set<String>, owner: LocationDefaultOwner?) {
        guard !kinds.isEmpty else { return }
        if let owner { bySource[owner.source, default: [:]][owner.type, default: []].formUnion(kinds) }
        else { shared.formUnion(kinds) }
    }

    mutating func formUnion(_ other: Self) {
        shared.formUnion(other.shared)
        for (source, types) in other.bySource {
            bySource[source, default: [:]].merge(types) { $0.union($1) }
        }
    }

    subscript(unit: SourceUnit) -> Set<String> {
        guard !unit.scope.isEmpty, !bySource.isEmpty, let types = bySource[unit.qualifiedSourcePath] else { return shared }
        var kinds = shared
        var scope = unit.scope[...]
        while !scope.isEmpty {
            if let local = types[String(scope)] { kinds.formUnion(local) }
            guard let dot = scope.lastIndex(of: ".") else { break }
            scope = scope[..<dot]
        }
        return kinds
    }
}
