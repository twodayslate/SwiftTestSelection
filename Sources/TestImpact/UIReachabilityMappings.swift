// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation

/// Declared selection contracts, kept distinct from measured function execution.
public struct UIReachabilityMappings: Codable, Sendable {
    public struct Rule: Codable, Sendable {
        public var origin: String
        public var location: String
        public var binding: String
        public var feature: UIFeatureMappings.Feature
        public var expandedTestSelectors: [String]
        public var matchesTestSelector: Bool
        public var matchingFunctionSourcePatterns: [String]
        /// Nil means that no compiler identity was available to resolve symbols.
        public var matchingFunctionSymbolPatterns: [String]?
    }
    public var rules: [Rule] = []
    public var runtimeDependencyPolicy: UIFeatureMappings.RuntimeDependencyPolicy?
    public var limitations: [String] = []
    public var omittedRuleCount = 0
}

enum UIReachabilityMappingPreparation {
    static let defaultPath = ".swift-test-selection.json"

    /// Never read today's working-tree mapping when evaluating historical source.
    static func load(repository: URL, revision: String, path: String, required: Bool) throws -> UIFeatureMappings? {
        guard !path.isEmpty, !path.hasPrefix("/"),
              !path.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == ".." || $0 == "." || $0.isEmpty }) else {
            throw ImpactError("AI mappings path must be repository-relative without dot components")
        }
        let entry = try CommandRunner.run("git", ["--literal-pathspecs", "ls-tree", "-z", revision, "--", path], at: repository).text
        guard !entry.isEmpty else {
            if required { throw ImpactError("Mapping file absent at \(revision):\(path)") }
            return nil
        }
        guard entry.hasPrefix("100644 blob ") || entry.hasPrefix("100755 blob ") else {
            throw ImpactError("AI mapping must be a regular committed file: \(path)")
        }
        let data = try CommandRunner.run("git", ["show", revision + ":" + path], at: repository).stdout
        let mappings = try JSONDecoder().decode(UIFeatureMappings.self, from: data)
        try mappings.validate()
        return mappings
    }

    static func collect(function: UIReachabilityInput.Fragment, test: UIReachabilityInput.Fragment,
                        testIdentifier: String, syntax: InlineMappingSyntax?,
                        mappings: UIFeatureMappings?, mappingPath: String,
                        graph: XcodeTestGraph?) -> UIReachabilityMappings {
        var result = UIReachabilityMappings(runtimeDependencyPolicy: mappings?.runtimeDependencyPolicy)
        result.limitations = [
            "Mappings declare test selection contracts, not per-function execution coverage. Missing associations are not negative execution evidence.",
            "when predicates describe changes across a base/head comparison; they have not been evaluated for this single source snapshot."
        ]
        let symbols = graph?.dependencies?.functions.values.filter { node in
            node.regions.contains { $0.intersects(function.region) }
        }.map { $0.module + "." + $0.name }
        func rule(_ feature: UIFeatureMappings.Feature, selectors: [String], origin: String,
                  location: String, binding: String) -> UIReachabilityMappings.Rule {
            .init(origin: origin, location: location, binding: binding, feature: feature,
                  expandedTestSelectors: selectors,
                  matchesTestSelector: selectors.contains { UIFeatureMappings.selects(testIdentifier, selector: $0) },
                  matchingFunctionSourcePatterns: ((feature.sources ?? []) + (feature.when?.sourcePatterns ?? [])).filter {
                      UIFeatureMappings.matches(function.region.path, pattern: $0)
                  },
                  matchingFunctionSymbolPatterns: symbols.map { names in
                      ((feature.symbols ?? []) + (feature.when?.symbolPatterns ?? [])).filter { pattern in
                          names.contains { UIFeatureMappings.matches($0, pattern: pattern) }
                      }
                  })
        }
        if let mappings {
            let candidates = mappings.features.map {
                rule($0, selectors: mappings.selectors(for: $0), origin: "historical-json",
                     location: mappingPath, binding: "declared-test-selectors")
            }
            var relevant = Set(candidates.filter {
                $0.matchesTestSelector || !$0.matchingFunctionSourcePatterns.isEmpty || !($0.matchingFunctionSymbolPatterns?.isEmpty ?? true)
            }.map { $0.feature.name })
            // Keep connected dependsOn declarations so a scoped rule is not shown
            // without its runtime dependency contract. Cycles terminate at a fixed point.
            var previous: Set<String>
            repeat {
                previous = relevant
                for feature in mappings.features {
                    let dependencies = Set(feature.dependsOn ?? [])
                    if relevant.contains(feature.name) { relevant.formUnion(dependencies) }
                    if !relevant.isDisjoint(with: dependencies) { relevant.insert(feature.name) }
                }
            } while previous != relevant
            result.rules += candidates.filter { relevant.contains($0.feature.name) }.sorted { $0.feature.name < $1.feature.name }
        } else {
            result.limitations.append("No \(mappingPath) exists at this case's revision; no JSON mapping rules were supplied.")
        }
        if let graph {
            let resolution = InlineUIMappings.resolve(graph)
            for feature in resolution.features.sorted(by: { $0.name < $1.name }) where
                (feature.tests ?? []).contains(testIdentifier) {
                result.rules.append(rule(feature, selectors: feature.tests ?? [], origin: "inline-comment",
                    location: feature.name, binding: "compiler-resolved-test"))
            }
            result.limitations += resolution.diagnostics.filter { $0.tests.contains(testIdentifier) }.map(\.message)
        } else if let syntax {
            result.limitations += syntax.diagnostics
            // Direct enclosing declarations only. Do not guess inherited contracts,
            // extension ownership, or which conditional-compilation branch is active.
            let owners = syntax.declarations.filter {
                $0.scope == test.scope && $0.region.startLine <= test.region.startLine &&
                $0.region.endLine >= test.region.endLine &&
                ($0.kind == "class" || $0.kind == "extension" || $0.method == test.name + "()")
            }
            for owner in owners {
                for directive in owner.directives {
                    let location = "\(owner.region.path):\(directive.line)"
                    if let error = directive.error {
                        result.limitations.append(location + ": " + error); continue
                    }
                    guard let object = (try? JSONSerialization.jsonObject(with: Data(directive.normalized.utf8))) as? [String: Any] else { continue }
                    let condition = object["when"].flatMap { try? JSONDecoder().decode(UIFeatureMappings.Condition.self,
                        from: JSONSerialization.data(withJSONObject: $0)) }
                    let feature = UIFeatureMappings.Feature(name: "inline:" + location,
                        sources: object["sources"] as? [String] ?? [], symbols: object["symbols"] as? [String] ?? [],
                        tests: [testIdentifier], when: condition)
                    result.rules.append(rule(feature, selectors: [testIdentifier], origin: "inline-comment",
                        location: location, binding: "syntax-candidate:\(owner.kind):\(owner.scope):conditional=\(owner.conditional)"))
                }
            }
            result.limitations.append("Inline rules are enclosing syntax candidates, not compiler-bound contracts. Inherited and cross-file rules and active build conditions are unresolved.")
        }
        if symbols == nil {
            result.limitations.append("Symbol patterns are retained for selected tests but cannot be resolved against function identity without a compiler graph.")
        }
        return result
    }
}
