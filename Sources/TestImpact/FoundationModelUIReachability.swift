// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation
#if canImport(FoundationModels)
import FoundationModels

@available(macOS 26.0, *)
@Generable
private struct ModelAnswer {
    @Guide(description: "A short explanation of the execution route or missing context")
    var reason: String
    @Guide(description: "Estimated probability (percent) that the test executes the function; nil if evidence is insufficient", .range(0...100))
    var confidencePercent: Int?
}
#endif

/// Optional on-device provider; ordinary selection works without this framework or model.
public enum FoundationModelUIReachability {
    public static var availability: String {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return "available"
            case .unavailable(let reason): return "unavailable: \(reason)"
            }
        }
        #endif
        return "unavailable: Foundation Models requires a supported SDK and macOS 26+"
    }

    public static func predict(_ input: UIReachabilityInput,
                               templates: UIReachabilityPromptTemplates = .init()) async throws -> UIReachabilityPrediction {
        try templates.validate()
        return try await predict(rendered: templates.render(input))
    }

    public static func predict(rendered: UIReachabilityPromptTemplates.Rendered) async throws -> UIReachabilityPrediction {
        guard availability == "available" else { throw ImpactError(availability) }
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            // A fresh session for every pair prevents historical labels or other cases leaking in.
            let session = LanguageModelSession(instructions: rendered.instructions)
            let answer = try await session.respond(to: rendered.prompt, generating: ModelAnswer.self,
                options: GenerationOptions(sampling: .greedy, maximumResponseTokens: 256)).content
            let prediction = UIReachabilityPrediction(confidencePercent: answer.confidencePercent, reason: answer.reason)
            try prediction.validate()
            return prediction
        }
        #endif
        throw ImpactError(availability)
    }
}
