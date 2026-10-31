// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
import Foundation

public struct SelectionFallback: Codable, Sendable {
    public var changedSymbols: [String]
    public var changedRegions: [SourceRegion]
    public var scope: String
    public var selectionScope: String? = nil
    public var category: String
    public var firstBoundary: String
    public var path: [String]
    public var resolution: String
    public var requiredEvidence: String
    public var applicableRevisions: [String] = ["base", "head"]
    public var supportedDeclaration: String?
    public var validationFailures: [String] = []
    public var uncertaintyOnlyTests: [String] = []
    public var overlappingPositiveTests: [String] = []

    static func explain(code: String, message: String, units: [SourceUnit] = [], path: [String] = [], allTests: Bool = true) -> Self {
        let category: String, resolution: String, evidence: String
        var declaration: String?
        if code.contains("helper_contract") {
            category = "declarationValidation"; resolution = "reviewedDeclaration"
            evidence = "Correct the reported binding or revision failure and review the declaration again. Invalid or stale declarations cannot narrow selection."
        } else if message.contains("runtime formatting conformances") {
            category = "assertionFormatting"; resolution = "reviewedDeclaration"
            declaration = "helperFormattingContracts v1"
            evidence = "Review the exact helper, producer, XCTest overload and substitutions in formattingBoundaries. Bind both source digests, actual base revision and toolchain; establish all three formatting guarantees. Feature mappings cannot resolve this boundary."
        } else if message.contains("Incomplete helper declaration inventories") {
            category = "sourceOrBuildEvidence"; resolution = "compilerEvidence"
            evidence = "Inspect the named base/head source inventory. Refresh missing metadata; unsupported macros or attributes require expansion/ownership analysis. No formatting declaration overrides this requirement."
        } else if code.contains("mapping") || code.contains("unmapped") || code.contains("ui_runtime") {
            category = "productionOwnership"; resolution = "dependencyMapping"
            evidence = "Resolve the named production/UI source and test selectors in both revisions and review the cross-process runtime policy. This does not establish helper isolation."
        } else if code.contains("declaration") || code.contains("move") || code.contains("unsupported_body") {
            category = "declarationChange"; resolution = "compilerEvidence"
            evidence = "Capture base compiler ownership and callers for the named declaration (two-graph mode), or separate the structural edit. No supported helper formatting declaration resolves missing historical edges."
        } else if code.contains("shared_state") || message.lowercased().contains("shared") || message.lowercased().contains("global") {
            category = "sharedState"; resolution = "unsupported"
            evidence = "Remove or isolate the named shared/global state effect and recapture its callers. No supported declaration overrides shared-state analysis."
        } else if message.lowercased().contains("callback") || message.lowercased().contains("escaping") {
            category = "callbackLifetime"; resolution = "unsupported"
            evidence = "Provide source/compiler evidence that the named callback cannot escape or register cross-test effects. No user callback-lifetime declaration is supported."
        } else if message.lowercased().contains("lifecycle") || code.contains("test_host") {
            category = "lifecycle"; resolution = "compilerEvidence"
            evidence = "Resolve test host, setup/teardown and inherited lifecycle roots in the captured inventory. No supported helper formatting declaration overrides lifecycle effects."
        } else if code.contains("helper") || code.contains("runtime") {
            category = "helperOrRuntimeEffect"; resolution = "unsupported"
            evidence = "Resolve the first named producer/effect with complete compiler and historical source evidence. Only the exact XCTest failure-formatting boundary supports a reviewed declaration; no general helper/runtime isolation declaration is supported."
        } else {
            category = "sourceOrBuildEvidence"; resolution = "compilerEvidence"
            evidence = "Restore matching source, ownership, build inputs and complete compiler evidence for the named boundary; recapture the affected build. No helper formatting declaration resolves this fallback."
        }
        return .init(changedSymbols: Array(Set(units.map(\.key))).sorted(), changedRegions: units.map(\.region),
            scope: allTests ? "head-inventory" : "diagnostic-tests", category: category,
            firstBoundary: message, path: path, resolution: resolution, requiredEvidence: evidence, supportedDeclaration: declaration)
    }
}

extension ImpactReport {
    mutating func finishFallbackEvidence() {
        let positive = Set(explanations.filter { $0.kind != "fallback" }.map(\.test))
        for i in diagnostics.indices {
            if diagnostics[i].fallback == nil {
                diagnostics[i].fallback = .explain(code: diagnostics[i].code, message: diagnostics[i].message)
            }
            let tests = Set(diagnostics[i].tests)
            diagnostics[i].fallback?.uncertaintyOnlyTests = tests.subtracting(positive).sorted()
            diagnostics[i].fallback?.overlappingPositiveTests = tests.intersection(positive).sorted()
        }
    }
}
