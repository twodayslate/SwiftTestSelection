// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation
import TestImpact

/// Separate authoring commands: ordinary graph/select paths never read coverage.
enum CoverageCommand {
    static func run(_ arguments: [String]) throws {
        guard let action = arguments.first, ["plan", "import", "apply"].contains(action) else {
            throw ImpactError("Expected coverage plan, import, or apply")
        }
        var values: [String: String] = [:], suites: [String] = [], targets: [String] = []
        var cursor = 1
        while cursor < arguments.count {
            let flag = arguments[cursor]; cursor += 1
            guard ["--graph", "--artifact", "--mappings", "--output", "--suite", "--app-target"].contains(flag), cursor < arguments.count else {
                throw ImpactError("Unknown coverage option or missing value: \(flag)")
            }
            let value = arguments[cursor]; cursor += 1
            if flag == "--suite" { suites.append(value) }
            else if flag == "--app-target" { targets.append(value) }
            else {
                guard values[flag] == nil else { throw ImpactError("Repeated coverage option: \(flag)") }
                values[flag] = value
            }
        }
        guard let graphPath = values["--graph"] else { throw ImpactError("Coverage authoring requires --graph") }
        if let output = values["--output"] {
            let outputURL = URL(fileURLWithPath: output).standardizedFileURL.resolvingSymlinksInPath()
            guard ["--graph", "--artifact", "--mappings"].compactMap({ values[$0] }).allSatisfy({ URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath() != outputURL }) else {
                throw ImpactError("Proposal output must not overwrite an input or mapping file")
            }
        }
        let graph = try XcodeAnalysis.executionGraph(at: URL(fileURLWithPath: graphPath))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data: Data
        var pendingWrite: (url: URL, data: Data, original: Data?)?
        if action == "plan" {
            guard values["--artifact"] == nil, values["--mappings"] == nil else { throw ImpactError("coverage plan does not accept --artifact or --mappings") }
            data = try encoder.encode(UICoverageMappings.plan(graph: graph, suites: suites, appTargets: targets))
        } else {
            guard suites.isEmpty, targets.isEmpty, let artifactPath = values["--artifact"] else {
                throw ImpactError("coverage import/apply requires --artifact; suites and app targets come from its collection evidence")
            }
            let artifact = try JSONDecoder().decode(UICoverageArtifact.self, from: Data(contentsOf: URL(fileURLWithPath: artifactPath)))
            let mappingURL = values["--mappings"].map { URL(fileURLWithPath: $0) }
            let original = try mappingURL.flatMap { FileManager.default.fileExists(atPath: $0.path) ? try Data(contentsOf: $0) : nil }
            let existing = try original.map { try JSONDecoder().decode(UIFeatureMappings.self, from: $0) }
            let proposal = try UICoverageMappings.propose(graph: graph, artifact: artifact, existing: existing)
            // Preserve extension fields and the exact JSON objects of user-authored
            // entries, even when this version's typed model does not know them.
            var mappingObject = try JSONSerialization.jsonObject(with: encoder.encode(proposal.mappings)) as! [String: Any]
            if let original {
                var preserved = try JSONSerialization.jsonObject(with: original) as! [String: Any]
                let added = try JSONSerialization.jsonObject(with: encoder.encode(proposal.additions)) as! [[String: Any]]
                preserved["features"] = (preserved["features"] as? [[String: Any]] ?? []) + added
                mappingObject = preserved
            }
            var payload = try JSONSerialization.jsonObject(with: encoder.encode(proposal)) as! [String: Any]
            payload["mappings"] = mappingObject
            data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            if action == "apply" {
                guard let mappingURL, proposal.validationPassed,
                      !proposal.diagnostics.contains(where: { $0.severity == "error" }) else {
                    throw ImpactError("Apply requires --mappings and a validated proposal without error diagnostics; inspect with coverage import")
                }
                let protected = [graphPath, artifactPath].map { URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath() }
                guard !protected.contains(mappingURL.standardizedFileURL.resolvingSymlinksInPath()) else { throw ImpactError("Mappings cannot overwrite graph or coverage artifacts") }
                pendingWrite = (mappingURL, try JSONSerialization.data(withJSONObject: mappingObject,
                    options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]), original)
            }
        }
        if let output = values["--output"] { try data.write(to: URL(fileURLWithPath: output), options: .atomic) }
        else { FileHandle.standardOutput.write(data + Data("\n".utf8)) }
        // Save review/provenance output before mutating selection configuration.
        if let pendingWrite {
            let current = FileManager.default.fileExists(atPath: pendingWrite.url.path) ? try Data(contentsOf: pendingWrite.url) : nil
            guard current == pendingWrite.original else { throw ImpactError("Mapping file changed during proposal generation; retry") }
            try pendingWrite.data.write(to: pendingWrite.url, options: .atomic)
        }
    }
}
