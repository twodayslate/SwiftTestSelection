// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation

struct MappingIndex {
    var roots: [String: Set<String>] = [:]
    var tests: [String: Set<String>] = [:]
    var unmatched: [String: [String]] = [:]
    init(_ mappings: UIFeatureMappings, snapshot: XcodeTestGraph, graph: DependencyGraph, index: DependencyIndex) {
        for feature in mappings.features {
            var symbols = Set<String>()
            let sourcePatterns = (feature.sources ?? []).map(Glob.init)
            for (path, ids) in index.byFile where sourcePatterns.contains(where: { $0.matches(path) }) { symbols.formUnion(ids) }
            for match in Self.symbolMatches(feature, graph: graph) { symbols.formUnion(match.roots) }
            roots[feature.name] = symbols
            var selected = Set<String>()
            for selector in mappings.selectors(for: feature) {
                let pattern = Glob(selector)
                let matches = snapshot.tests.filter { $0 == selector || $0.hasPrefix(selector + "/") || pattern.matches($0) }
                selected.formUnion(matches)
                if matches.isEmpty { unmatched[feature.name, default: []].append(selector) }
            }
            tests[feature.name] = selected
        }
    }

    /// Preserve each entry's resolution independently of sibling/source roots.
    static func symbolMatches(_ feature: UIFeatureMappings.Feature, graph: DependencyGraph) -> [(pattern: String, roots: Set<String>)] {
        (feature.symbols ?? []).map { pattern in
            let glob = Glob(pattern)
            return (pattern, Set(graph.functions.values.lazy.filter { glob.matches($0.module + "." + $0.name) }.map(\.id)))
        }
    }
}

private struct Glob {
    let literal: String
    let regex: NSRegularExpression?
    init(_ pattern: String) {
        literal = pattern
        guard pattern.contains("*") else { regex = nil; return }
        var expression = "^", cursor = pattern.startIndex
        while cursor < pattern.endIndex {
            let c = pattern[cursor]; cursor = pattern.index(after: cursor)
            if c == "*" {
                if cursor < pattern.endIndex, pattern[cursor] == "*" { expression += ".*"; cursor = pattern.index(after: cursor) }
                else { expression += "[^/]*" }
            } else { expression += NSRegularExpression.escapedPattern(for: String(c)) }
        }
        regex = try! NSRegularExpression(pattern: expression + "$")
    }
    func matches(_ value: String) -> Bool {
        guard let regex else { return value == literal }
        return regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
    }
}
