// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation
import Stencil

/// Value-only configuration; each render creates its own Stencil environment.
public struct UIReachabilityPromptTemplates: Codable, Sendable {
    public static let defaultPrompt = "Assess this source snapshot:\n{{ inputJSON }}"
    public static let maximumInstructionsBytes = 4_000
    public static let maximumPromptBytes = UIReachabilityPrompt.maximumInputBytes + "Assess this source snapshot:\n".utf8.count
    public static let outputContract = "Return confidencePercent as an integer from 0 through 100 estimating execution probability, or null for insufficient evidence, and reason as a short explanation."

    public var instructionsTemplate: String
    public var promptTemplate: String
    // Snapshot built-in template values so saved configurations can reproduce
    // their prompts even after a later release changes the defaults.
    var builtInInstructions = UIReachabilityPrompt.instructions
    var builtInOutputContract = Self.outputContract
    public var engine: String { "Stencil 0.15.1" }
    public var contextVersion: String { "ui-reachability-template-context-v2" }

    public init(instructionsTemplate: String = UIReachabilityPrompt.instructions,
                promptTemplate: String = defaultPrompt) {
        self.instructionsTemplate = instructionsTemplate
        self.promptTemplate = promptTemplate
    }

    private enum CodingKeys: String, CodingKey {
        case instructionsTemplate, promptTemplate, builtInInstructions, builtInOutputContract
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        instructionsTemplate = try container.decode(String.self, forKey: .instructionsTemplate)
        promptTemplate = try container.decode(String.self, forKey: .promptTemplate)
        // Older configurations did not record these values; preserve their
        // existing behavior of using the installed version's defaults.
        builtInInstructions = try container.decodeIfPresent(String.self, forKey: .builtInInstructions) ?? UIReachabilityPrompt.instructions
        builtInOutputContract = try container.decodeIfPresent(String.self, forKey: .builtInOutputContract) ?? Self.outputContract
    }

    public struct Rendered: Codable, Sendable {
        public var instructions: String
        public var prompt: String
        public var digest: String
    }

    public var digest: String {
        get throws {
            try textDigest(["engine": engine, "contextVersion": contextVersion,
                            "instructionsTemplate": instructionsTemplate, "promptTemplate": promptTemplate,
                            "builtInInstructions": builtInInstructions, "builtInOutputContract": builtInOutputContract])
        }
    }

    public var version: String {
        get throws {
            if instructionsTemplate == UIReachabilityPrompt.instructions && promptTemplate == Self.defaultPrompt {
                return UIReachabilityPrompt.version
            }
            return "custom-stencil-v1:" + (try digest)
        }
    }

    private func environment() -> Environment {
        let filters = Extension()
        filters.registerFilter("json") { value in
            let data = try JSONSerialization.data(withJSONObject: value ?? NSNull(),
                options: [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes])
            return String(decoding: data, as: UTF8.self)
        }
        filters.registerFilter("required") { value in
            guard let value, !(value is NSNull),
                  !((value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? false) else {
                throw ImpactError("A required prompt-template variable is missing or empty")
            }
            return value
        }
        // No file loader: each pair of template strings is self-contained and
        // reports capture all template source, rather than mutable partial files.
        return Environment(extensions: [filters])
    }

    public func validate() throws {
        let environment = environment()
        for (name, source) in [("instructions", instructionsTemplate), ("prompt", promptTemplate)] {
            guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ImpactError("The \(name) template must not be empty")
            }
            let template = Template(templateString: source, environment: environment, name: name)
            _ = try TokenParser(tokens: template.tokens, environment: environment).parse()
        }
    }

    public func render(_ input: UIReachabilityInput) throws -> Rendered {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(input)
        guard data.count <= UIReachabilityPrompt.maximumInputBytes else {
            throw UIReachabilityPromptSizeError(description: input.contextBudget?.subjectsExceedBudget == true
                ? "Complete subject pair exceeds \(UIReachabilityPrompt.maximumInputBytes) UTF-8 bytes after optional evidence was removed; declarations were not truncated"
                : "Source snapshot exceeds \(UIReachabilityPrompt.maximumInputBytes) UTF-8 bytes")
        }
        let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        // Only model input is exposed: no expected labels, case IDs, review
        // rationale, report outcomes, environment variables, or selection threshold.
        var context = object
        context["input"] = object
        context["inputJSON"] = String(decoding: data, as: UTF8.self)
        context["defaultInstructions"] = builtInInstructions
        context["outputContract"] = builtInOutputContract
        let environment = environment()
        let instructions = try environment.renderTemplate(string: instructionsTemplate, context: context)
        let prompt = try environment.renderTemplate(string: promptTemplate, context: context)
        guard !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ImpactError("Prompt templates must render nonempty instructions and input")
        }
        guard instructions.utf8.count <= Self.maximumInstructionsBytes, prompt.utf8.count <= Self.maximumPromptBytes else {
            throw UIReachabilityPromptSizeError(description: "Rendered prompt exceeds the \(Self.maximumInstructionsBytes)-byte instructions or \(Self.maximumPromptBytes)-byte input budget")
        }
        return .init(instructions: instructions, prompt: prompt,
                     digest: try textDigest(["instructions": instructions, "prompt": prompt]))
    }

    private func textDigest(_ values: [String: String]) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return XcodeGraphCache.digest(try encoder.encode(values))
    }
}

struct UIReachabilityPromptSizeError: Error, CustomStringConvertible {
    var description: String
}
