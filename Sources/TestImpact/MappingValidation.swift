// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation

public struct MappingValidationDiagnostic: Codable, Sendable {
    public var code: String
    public var mappingFile: String
    /// Absent for file-level loading or schema errors.
    public var feature: String?
    public var pattern: String?
    public var revision: String
    public var buildContext: [String: String]
    public var message: String
}

/// Emitted as one JSON object on stderr by the CLI, with exit status 4.
public struct MappingValidationError: Error, Codable, Sendable, CustomStringConvertible {
    public var code = "strict_mapping_validation_failed"
    public var diagnostics: [MappingValidationDiagnostic]
    public var description: String {
        diagnostics.map { diagnostic in
            [diagnostic.mappingFile, diagnostic.feature.map { "feature " + $0 },
             diagnostic.pattern.map { "pattern " + $0 }, "revision " + diagnostic.revision,
             diagnostic.message].compactMap { $0 }.joined(separator: ": ")
        }.joined(separator: "\n")
    }
}

extension XcodeTestGraph {
    /// Validate the current mapping against this build, independently of changes
    /// or test selection. Low-level selector clients can invoke this explicitly.
    /// Base mappings are intentionally not validated by strict head policy.
    public func validateMappingSymbols(mappingFile: String, revision: String, buildContext: [String: String]) throws {
        func invalidFile(_ reason: String) -> MappingValidationError {
            MappingValidationError(diagnostics: [.init(code: "invalid_mapping_file", mappingFile: mappingFile,
                revision: revision, buildContext: buildContext,
                message: "Cannot validate mapping symbols because the mapping file could not be loaded or is invalid: " + reason)])
        }
        // Older saved graphs recorded only this diagnostic and discarded the
        // mappings. They must fail strict validation just like fresh captures.
        let legacyError = self.diagnostics.first { $0.hasPrefix("Invalid UI mappings: ") }
        if let error = mappingLoadError ?? legacyError { throw invalidFile(error) }
        let inline = InlineUIMappings.resolve(self)
        var diagnostics = inline.diagnostics.map {
            MappingValidationDiagnostic(code: $0.code, mappingFile: "<inline>", feature: $0.tests.joined(separator: ", "),
                pattern: "<directive>", revision: revision, buildContext: buildContext, message: $0.message)
        }
        guard let mappings = inline.applying(to: self).mappings else {
            if !diagnostics.isEmpty { throw MappingValidationError(diagnostics: diagnostics) }
            return
        }
        do { try mappings.validate() }
        catch { throw invalidFile(String(describing: error)) }
        for feature in mappings.features {
            let matches = dependencies.map { MappingIndex.symbolMatches(feature, graph: $0) }
                ?? ((feature.symbols ?? []) + (feature.when?.symbolPatterns ?? [])).map { (pattern: $0, roots: Set<String>()) }
            for match in matches where match.roots.isEmpty {
                diagnostics.append(.init(code: dependencies == nil ? "mapping_symbol_graph_unavailable" : "unresolved_mapping_symbol",
                    mappingFile: mappingFile, feature: feature.name, pattern: match.pattern, revision: revision,
                    buildContext: buildContext,
                    message: dependencies == nil
                        ? "Cannot validate this symbol pattern because this build has no compiled dependency graph. Recapture the graph."
                        : "Symbol pattern did not resolve in this build. Check the mapping and selected build configuration."))
            }
        }
        if !inline.features.isEmpty, let dependencies {
            let index = MappingIndex(UIFeatureMappings(features: inline.features), snapshot: self, graph: dependencies, index: DependencyIndex(dependencies))
            for feature in inline.features {
                for entry in index.unresolvedEntries[feature.name] ?? [] where entry.hasPrefix("sources: ") {
                    diagnostics.append(.init(code: "unresolved_inline_source", mappingFile: "<inline>", feature: feature.name,
                        pattern: String(entry.dropFirst(9)), revision: revision, buildContext: buildContext,
                        message: "Source pattern did not resolve in this build. Check the directive and selected configuration."))
                }
            }
        }
        if !diagnostics.isEmpty { throw MappingValidationError(diagnostics: diagnostics) }
    }
}

extension XcodeAnalysis {
    func validateMappings(in graph: XcodeTestGraph, revision: String) throws {
        guard options.strictMappings else { return }
        var context = graph.buildArtifact?.context ?? [
            "container": options.container.rawValue, "path": options.path.path,
            "scheme": options.scheme, "destination": options.destination,
            "configuration": options.configuration ?? "<scheme default>",
            "testPlan": options.testPlan ?? "<scheme default>"
        ]
        context["toolchain"] = graph.buildArtifact?.toolchain ?? graph.dependencies?.toolchain ?? "<unavailable>"
        try graph.validateMappingSymbols(mappingFile: options.mappingsPath, revision: revision, buildContext: context)
    }
}
