// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
import Foundation

/// An in-place mutation check, not an identity for reusing a previous build.
/// Capture seals separately authenticate SIL, exported sources and products.
struct XcodeFreshExtractionInputs {
    let files: [String: String]
    let imports: [String: [String]]
    let sources: [String: String]

    static func read(log: String, source: URL) throws -> Self {
        let sources = try ArtifactFiles.sourceInputs(log: log, directory: source)
        let (files, imports) = try HelperBindingBuildEvidence.compilerInputs(log: log, source: source)
        return .init(files: files, imports: imports, sources: sources)
    }

    func validate(log: String, source: URL) throws {
        let current = try Self.read(log: log, source: source)
        guard files == current.files, imports == current.imports, sources == current.sources else {
            throw ImpactError("Compiler inputs changed during fresh extraction")
        }
    }
}
