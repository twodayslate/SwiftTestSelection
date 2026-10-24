// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

public struct UIFeatureMappings: Codable, Sendable {
    public struct Feature: Codable, Sendable {
        public var name: String
        public var sources: [String]?
        public var symbols: [String]?
        public var tests: [String]?
        public var fixtures: [String]?
        public var dependsOn: [String]?

        public init(name: String, sources: [String] = [], symbols: [String] = [], tests: [String] = [], fixtures: [String] = [], dependsOn: [String] = []) {
            self.name = name; self.sources = sources; self.symbols = symbols
            self.tests = tests; self.fixtures = fixtures; self.dependsOn = dependsOn
        }
    }
    public var version: Int
    public var fixtures: [String: [String]]?
    public var features: [Feature]

    public init(version: Int = 1, fixtures: [String: [String]] = [:], features: [Feature]) {
        self.version = version; self.fixtures = fixtures; self.features = features
    }

    public func validate() throws {
        guard version == 1 else { throw ImpactError("Unsupported UI mapping version: \(version)") }
        let names = Set(features.map(\.name))
        guard names.count == features.count, !names.contains("") else { throw ImpactError("UI feature names must be unique and nonempty.") }
        for feature in features {
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

    func selectors(for feature: Feature) -> [String] {
        (feature.tests ?? []) + (feature.fixtures ?? []).flatMap { fixtures?[$0] ?? [] }
    }

    static func matches(_ value: String, pattern: String) -> Bool {
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
