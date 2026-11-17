// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation
import TestImpact

enum AICommand {
    static func run(_ arguments: [String]) async throws -> Int32 {
        guard let action = arguments.first, ["status", "prepare", "evaluate", "render"].contains(action) else {
            throw ImpactError("Expected ai status, prepare, render, or evaluate. Enable AI selection with select --ai.")
        }
        let allowed: Set<String>
        switch action {
        case "prepare": allowed = ["--repository", "--cases", "--graph", "--mappings", "--output"]
        case "evaluate": allowed = ["--dataset", "--confidence-threshold", "--prompt-template", "--instructions-template", "--output"]
        case "render": allowed = ["--dataset", "--prompt-template", "--instructions-template", "--output"]
        default: allowed = ["--output"]
        }
        var values: [String: String] = [:], cursor = 1
        while cursor < arguments.count {
            let key = arguments[cursor]
            guard allowed.contains(key), values[key] == nil, cursor + 1 < arguments.count else {
                throw ImpactError("Unknown/repeated ai option or missing value: \(key)")
            }
            values[key] = arguments[cursor + 1]; cursor += 2
        }
        if let output = values["--output"] {
            let destination = URL(fileURLWithPath: output).standardizedFileURL.resolvingSymlinksInPath()
            for key in ["--dataset", "--cases", "--graph", "--report", "--prompt-template", "--instructions-template"] {
                if let path = values[key], URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath() == destination {
                    throw ImpactError("AI output must not overwrite an input")
                }
            }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        func read(_ key: String) throws -> Data {
            guard let path = values[key] else { throw ImpactError("ai \(action) requires \(key)") }
            return try Data(contentsOf: URL(fileURLWithPath: path))
        }
        func templates() throws -> UIReachabilityPromptTemplates {
            let instructions = try values["--instructions-template"].map { try String(contentsOfFile: $0, encoding: .utf8) }
            let prompt = try values["--prompt-template"].map { try String(contentsOfFile: $0, encoding: .utf8) }
            return .init(instructionsTemplate: instructions ?? UIReachabilityPrompt.instructions,
                         promptTemplate: prompt ?? UIReachabilityPromptTemplates.defaultPrompt)
        }
        let threshold: Int
        if let raw = values["--confidence-threshold"] {
            guard let parsed = Int(raw) else { throw ImpactError("Confidence threshold must be an integer from 0 through 100") }
            threshold = parsed
        } else { threshold = UIReachabilitySelection.defaultConfidenceThreshold }
        try UIReachabilitySelection.validateThreshold(threshold)
        let data: Data
        var exitStatus: Int32 = 0
        switch action {
        case "status":
            data = try encoder.encode(["provider": "Apple Foundation Models (on-device)", "availability": FoundationModelUIReachability.availability])
        case "prepare":
            guard let repository = values["--repository"] else { throw ImpactError("ai prepare requires --repository") }
            let specs = try JSONDecoder().decode([UIReachabilityCaseSpec].self, from: read("--cases"))
            let graph = try values["--graph"].map { try GraphArchive.decode(Data(contentsOf: URL(fileURLWithPath: $0))) }
            let root = URL(fileURLWithPath: repository)
            if let output = values["--output"] {
                let repositoryRoot = try GitChanges.repositoryRoot(at: root)
                let mapping = repositoryRoot.appendingPathComponent(values["--mappings"] ?? ".swift-test-selection.json")
                    .standardizedFileURL.resolvingSymlinksInPath()
                guard URL(fileURLWithPath: output).standardizedFileURL.resolvingSymlinksInPath() != mapping else {
                    throw ImpactError("AI output must not overwrite the mapping file")
                }
            }
            data = try encoder.encode(UIReachabilityPreparation.prepare(specs, repository: root,
                graph: graph, mappingsPath: values["--mappings"]))
        case "render":
            let dataset = try JSONDecoder().decode(UIReachabilityDataset.self, from: read("--dataset"))
            try dataset.validate()
            let templates = try templates()
            try templates.validate()
            let rows = try dataset.cases.map { PromptPreview.Row(id: $0.id, rendered: try templates.render($0.input)) }
            data = try encoder.encode(PromptPreview(templateVersion: templates.version,
                templateDigest: templates.digest, engine: templates.engine, contextVersion: templates.contextVersion,
                templates: templates, rows: rows))
        default:
            let dataset = try JSONDecoder().decode(UIReachabilityDataset.self, from: read("--dataset"))
            let status = FoundationModelUIReachability.availability
            let report = try await UIReachabilityEvaluation.run(dataset, provider: "Apple Foundation Models (on-device)",
                availability: status, confidenceThreshold: threshold, templates: templates()) { _, rendered in
                try await FoundationModelUIReachability.predict(rendered: rendered)
            }
            data = try encoder.encode(report)
            if report.rows.contains(where: { $0.prediction.error != nil }) { exitStatus = 2 }
        }
        if let output = values["--output"] { try data.write(to: URL(fileURLWithPath: output), options: .atomic) }
        else { FileHandle.standardOutput.write(data + Data("\n".utf8)) }
        return exitStatus
    }
}

private struct PromptPreview: Encodable {
    struct Row: Encodable {
        var id: String
        var rendered: UIReachabilityPromptTemplates.Rendered
    }
    var templateVersion: String
    var templateDigest: String
    var engine: String
    var contextVersion: String
    var templates: UIReachabilityPromptTemplates
    var rows: [Row]
}
