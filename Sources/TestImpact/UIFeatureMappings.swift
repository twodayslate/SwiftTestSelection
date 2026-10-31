// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation

public struct UIFeatureMappings: Codable, Sendable {
    public enum RuntimeDependencyPolicy: String, Codable, Sendable {
        case conservative, declared
    }
    public enum SourceLocationPolicy: String, Codable, Sendable {
        case semantic, diagnosticLineColumn, diagnostic
    }
    /// Opt in only when the ignored location kinds are diagnostic, never behavior.
    public var sourceLocationPolicy: SourceLocationPolicy? = nil

    public struct Feature: Codable, Sendable {
        public var name: String
        public var sources: [String]?
        public var symbols: [String]?
        public var tests: [String]?
        public var fixtures: [String]?
        public var dependsOn: [String]?
        public var when: Condition?

        private enum CodingKeys: String, CodingKey { case name, sources, symbols, tests, fixtures, dependsOn, when }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decode(String.self, forKey: .name)
            sources = try container.decodeIfPresent([String].self, forKey: .sources)
            symbols = try container.decodeIfPresent([String].self, forKey: .symbols)
            tests = try container.decodeIfPresent([String].self, forKey: .tests)
            fixtures = try container.decodeIfPresent([String].self, forKey: .fixtures)
            dependsOn = try container.decodeIfPresent([String].self, forKey: .dependsOn)
            // An explicitly null condition must not silently become a legacy rule.
            when = container.contains(.when) ? try container.decode(Condition.self, forKey: .when) : nil
        }

        public init(name: String, sources: [String] = [], symbols: [String] = [], tests: [String] = [], fixtures: [String] = [], dependsOn: [String] = [], when: Condition? = nil) {
            self.name = name; self.sources = sources; self.symbols = symbols
            self.tests = tests; self.fixtures = fixtures; self.dependsOn = dependsOn; self.when = when
        }
    }
    public var version: Int
    /// Opt in only when feature boundaries and dependsOn declare runtime dependencies.
    public var runtimeDependencyPolicy: RuntimeDependencyPolicy?
    /// Explicit Markdown-only exclusions, agreed by both review revisions.
    public var ignoredDocumentation: [String]?
    /// Non-UI closed-module contracts, checked against compiler imports and hosts.
    public var helperFormattingContracts: [HelperFormattingContract]? = nil
    public var testRuntimeBoundaries: [TestRuntimeBoundary]? = nil
    public var fixtures: [String: [String]]?
    public var features: [Feature]

    public init(version: Int = 1, fixtures: [String: [String]] = [:], features: [Feature],
                runtimeDependencyPolicy: RuntimeDependencyPolicy? = nil, ignoredDocumentation: [String] = []) {
        self.version = version; self.fixtures = fixtures; self.features = features
        self.runtimeDependencyPolicy = runtimeDependencyPolicy
        self.ignoredDocumentation = ignoredDocumentation
    }

    public func validate() throws {
        guard version == 1 || version == 2 else { throw ImpactError("Unsupported UI mapping version: \(version)") }
        for pattern in ignoredDocumentation ?? [] {
            guard !pattern.hasPrefix("/"), pattern.hasSuffix(".md"),
                  !pattern.split(separator: "/").contains("..") else {
                throw ImpactError("Ignored documentation must be a repository-relative Markdown pattern: \(pattern)")
            }
        }
        let names = Set(features.map(\.name))
        let boundaries = testRuntimeBoundaries ?? []
        guard Set(boundaries.map(\.target)).count == boundaries.count else {
            throw ImpactError("Test runtime boundary targets must be unique")
        }
        for boundary in boundaries {
            guard !boundary.target.isEmpty, !boundary.target.contains("/"),
                  !boundary.modules.isEmpty, !boundary.modules.contains(""),
                  !boundary.rationale.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ImpactError("Test runtime boundaries require a target, modules, and an isolation rationale")
            }
        }
        guard names.count == features.count, !names.contains("") else { throw ImpactError("UI feature names must be unique and nonempty.") }
        let conditionalNames = Set(features.filter { $0.when != nil }.map(\.name))
        for feature in features {
            if let condition = feature.when {
                guard version == 2 else { throw ImpactError("UI conditions require mapping version 2") }
                guard (feature.sources ?? []).isEmpty, (feature.symbols ?? []).isEmpty,
                      (feature.dependsOn ?? []).isEmpty else {
                    throw ImpactError("Conditional feature \(feature.name) cannot combine when with sources, symbols or dependsOn")
                }
                try condition.validate()
            }
            guard Set(feature.dependsOn ?? []).isDisjoint(with: conditionalNames) else {
                throw ImpactError("dependsOn cannot reference a conditional feature: \(feature.name)")
            }
            for dependency in feature.dependsOn ?? [] where !names.contains(dependency) {
                throw ImpactError("Unknown dependency \(dependency) in UI feature \(feature.name)")
            }
            for fixture in feature.fixtures ?? [] where fixtures?[fixture] == nil {
                throw ImpactError("Unknown fixture \(fixture) in UI feature \(feature.name)")
            }
            for pattern in (feature.sources ?? []) + (feature.symbols ?? []) where pattern.isEmpty {
                throw ImpactError("Empty source/symbol boundary in UI feature \(feature.name)")
            }
        }
        // Cycles are supported: traversal is a fixed point over a finite set.
    }

    static func fileURL(path: String, root: URL) throws -> URL {
        guard !path.hasPrefix("/") else { throw ImpactError("--mappings must be repository-relative.") }
        let file = root.appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath()
        guard file.path.hasPrefix(root.standardizedFileURL.resolvingSymlinksInPath().path + "/") else {
            throw ImpactError("Mapping file must be inside the repository.")
        }
        return file
    }

    func selectors(for feature: Feature) -> [String] {
        (feature.tests ?? []) + (feature.fixtures ?? []).flatMap { fixtures?[$0] ?? [] }
    }

    static func matches(_ value: String, pattern: String) -> Bool {
        guard pattern.contains("*") else { return value == pattern }
        var expression = "^"
        let chars = Array(pattern)
        var i = 0
        while i < chars.count {
            if chars[i] == "*" {
                if i + 1 < chars.count, chars[i + 1] == "*" { expression += ".*"; i += 1 }
                else { expression += "[^/]*" }
            } else { expression += NSRegularExpression.escapedPattern(for: String(chars[i])) }
            i += 1
        }
        expression += "$"
        return value.range(of: expression, options: .regularExpression) != nil
    }

    static func selects(_ test: String, selector: String) -> Bool {
        test == selector || test.hasPrefix(selector + "/") || matches(test, pattern: selector)
    }
}
