// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation

/// Pack whole pieces of optional evidence against the actual serialized budget.
/// Reserve omissions metadata first, then interleave mappings, source and edges
/// rather than prioritizing one category exclusively.
enum UIReachabilityContextBudget {
    static func pack(_ original: UIReachabilityInput,
                     compilerSourceRegions: [String: [SourceRegion]] = [:],
                     omittedEdges: Int = 0) throws -> UIReachabilityInput {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var result = original
        let contexts = original.context
        let edges = original.compilerEdges ?? []
        let rules = try (original.mappings?.rules ?? []).map { try project($0, test: original.testIdentifier, encoder: encoder) }
        result.context = []
        result.compilerEdges = original.compilerEdges == nil ? nil : []
        result.mappings?.rules = []
        result.mappings?.omittedRuleCount += rules.count
        result.contextBudget = .init(omittedCompilerEdges: omittedEdges + edges.count,
            omittedCompilerSourceNodes: compilerSourceRegions.count, omittedSourceFragments: contexts.count,
            omittedMappingRules: (original.mappings?.omittedRuleCount ?? 0) + rules.count)
        result.limitations.append("Optional evidence is byte-budgeted. Inspect contextBudget and mappings.omittedRuleCount; omitted routes or associations are not evidence of non-execution.")

        // If even the complete subject envelope cannot fit, discard optional
        // metadata too and distinguish that case from a model/context failure.
        if try encoder.encode(result).count > UIReachabilityPrompt.maximumInputBytes {
            result.mappings = nil
            result.limitations = ["Optional mapping metadata was omitted to fit the input budget. Inspect contextBudget for omissions; absence is not negative execution evidence. Subjects were not truncated."]
            if try encoder.encode(result).count > UIReachabilityPrompt.maximumInputBytes {
                result.contextBudget?.subjectsExceedBudget = true
                return result
            }
            // No room for the mapping envelope; all its rules remain omitted.
        }

        var sourceBytes = 0
        for index in 0..<max(rules.count, contexts.count, edges.count) {
            if index < rules.count, result.mappings != nil, result.mappings!.rules.count < 16 {
                var trial = result
                trial.mappings?.rules.append(rules[index])
                trial.mappings?.omittedRuleCount -= 1
                trial.contextBudget?.omittedMappingRules -= 1
                if try encoder.encode(trial).count <= UIReachabilityPrompt.maximumInputBytes { result = trial }
            }
            if index < contexts.count, sourceBytes + contexts[index].source.utf8.count <= 4_000 {
                var trial = result
                trial.context.append(contexts[index])
                trial.contextBudget?.omittedSourceFragments -= 1
                if try encoder.encode(trial).count <= UIReachabilityPrompt.maximumInputBytes {
                    result = trial
                    sourceBytes += contexts[index].source.utf8.count
                }
            }
            if index < edges.count {
                var trial = result
                trial.compilerEdges?.append(edges[index])
                trial.contextBudget?.omittedCompilerEdges -= 1
                if try encoder.encode(trial).count <= UIReachabilityPrompt.maximumInputBytes { result = trial }
            }
        }
        let represented = [result.function.region, result.test.region] + result.context.map(\.region)
        result.contextBudget?.omittedCompilerSourceNodes = compilerSourceRegions.values.filter { regions in
            !regions.contains { node in represented.contains { $0.intersects(node) } }
        }.count
        return result
    }

    private static func project(_ original: UIReachabilityMappings.Rule, test: String,
                                encoder: JSONEncoder) throws -> UIReachabilityMappings.Rule {
        guard try encoder.encode(original).count > 900 else { return original }
        var rule = original
        // Keep conditions, fixture names and dependency declarations intact.
        // Only omit associations known not to match this pair. Unknown symbol
        // matches retain their original scope rather than guessing an identity.
        rule.feature.sources = original.feature.sources?.filter { original.matchingFunctionSourcePatterns.contains($0) }
        if let matches = original.matchingFunctionSymbolPatterns {
            rule.feature.symbols = original.feature.symbols?.filter { matches.contains($0) }
        }
        rule.feature.tests = original.feature.tests?.filter { UIFeatureMappings.selects(test, selector: $0) }
        rule.expandedTestSelectors = original.expandedTestSelectors.filter { UIFeatureMappings.selects(test, selector: $0) }
        let omitted = [
            "sources": (original.feature.sources?.count ?? 0) - (rule.feature.sources?.count ?? 0),
            "symbols": (original.feature.symbols?.count ?? 0) - (rule.feature.symbols?.count ?? 0),
            "tests": (original.feature.tests?.count ?? 0) - (rule.feature.tests?.count ?? 0),
            "expandedTestSelectors": original.expandedTestSelectors.count - rule.expandedTestSelectors.count
        ].filter { $0.value > 0 }
        guard !omitted.isEmpty else { return original }
        rule.projection = .init(originalFeatureDigest: XcodeGraphCache.digest(try encoder.encode(original.feature)),
                                omittedAssociations: omitted)
        return try encoder.encode(rule).count < encoder.encode(original).count ? rule : original
    }
}
