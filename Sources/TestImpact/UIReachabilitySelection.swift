// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation

/// Threshold selection over the supplied function/test pairs, not a full-suite inventory.
public struct UIReachabilitySelection: Codable, Sendable {
    public static let defaultConfidenceThreshold = 75

    public struct TestDecision: Codable, Sendable {
        public var revision: String
        public var testIdentifier: String
        public var caseIDs: [String]
        public var maximumConfidencePercent: Int?
        public var retainedForUnknown: Bool
        public var selected: Bool
    }

    public var schemaVersion = 1
    public var confidenceThreshold: Int
    public var datasetDigest: String
    public var promptVersion: String? = nil
    public var templateDigest: String? = nil
    public var unknownPolicy = "retain"
    public var decisions: [TestDecision]
    public var selectedTestsByRevision: [String: [String]]
    public var scope = "Only tests and function pairs present in the supplied dataset; not a complete suite inventory."

    public static func validateThreshold(_ value: Int) throws {
        guard (0...100).contains(value) else {
            throw ImpactError("Confidence threshold must be an integer from 0 through 100")
        }
    }

    public static func select(_ dataset: UIReachabilityDataset, report: UIReachabilityEvaluation,
                              confidenceThreshold: Int = defaultConfidenceThreshold) throws -> Self {
        try validateThreshold(confidenceThreshold)
        try dataset.validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let digest = XcodeGraphCache.digest(try encoder.encode(dataset))
        guard report.schemaVersion == 2, report.datasetDigest == digest,
              report.rows.count == dataset.cases.count,
              Set(report.rows.map(\.id)) == Set(dataset.cases.map(\.id)) else {
            throw ImpactError("AI selection requires a percentage report containing exactly this dataset's cases")
        }
        let rows = Dictionary(uniqueKeysWithValues: report.rows.map { ($0.id, $0) })
        struct Key: Hashable { var revision: String; var test: String }
        var decisions: [Key: TestDecision] = [:]
        for item in dataset.cases {
            guard let row = rows[item.id], row.inputDigest == XcodeGraphCache.digest(try encoder.encode(item.input)) else {
                throw ImpactError("AI report input digest mismatch for \(item.id)")
            }
            try row.prediction.validate()
            let key = Key(revision: item.input.revision, test: item.input.testIdentifier)
            var decision = decisions[key] ?? TestDecision(revision: key.revision, testIdentifier: key.test,
                caseIDs: [], maximumConfidencePercent: nil, retainedForUnknown: false, selected: false)
            decision.caseIDs.append(item.id)
            if row.prediction.error == nil, let score = row.prediction.confidencePercent {
                decision.maximumConfidencePercent = max(decision.maximumConfidencePercent ?? score, score)
            } else {
                decision.retainedForUnknown = true
            }
            // Any function pair can retain the test. Scores are not averaged and
            // results from different revisions must never be merged.
            decision.selected = decision.retainedForUnknown || (decision.maximumConfidencePercent.map { $0 >= confidenceThreshold } ?? false)
            decisions[key] = decision
        }
        let ordered = decisions.values.sorted { ($0.revision, $0.testIdentifier) < ($1.revision, $1.testIdentifier) }.map { value in
            var result = value; result.caseIDs.sort(); return result
        }
        var selected: [String: [String]] = [:]
        for decision in ordered {
            if selected[decision.revision] == nil { selected[decision.revision] = [] }
            if decision.selected { selected[decision.revision]!.append(decision.testIdentifier) }
        }
        return .init(confidenceThreshold: confidenceThreshold, datasetDigest: digest,
                     promptVersion: report.promptVersion, templateDigest: report.templateDigest,
                     decisions: ordered, selectedTestsByRevision: selected)
    }
}
