// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

/// Result-builder calls may have no source spelling or compiler edge. Compare
/// the body positions that can supply their defaults in either revision.
struct ResultBuilderLocations {
    let kinds: Set<String>
    let incompletePaths: Set<String>

    static func dimensions(_ policy: UIFeatureMappings.SourceLocationPolicy) -> Set<String> {
        switch policy {
        case .semantic: ["line", "column", "file", "fileID", "filePath"]
        case .diagnosticLineColumn: ["file", "fileID", "filePath"]
        case .diagnostic: []
        }
    }

    init(policy: UIFeatureMappings.SourceLocationPolicy, sources: [[String: SwiftSourceSnapshot]],
         modules: Set<String>, incompleteInputs: Bool, touching paths: Set<String>) {
        let dimensions = Self.dimensions(policy)
        guard !dimensions.isEmpty else { kinds = []; incompletePaths = []; return }
        let methods: Set<String> = ["buildExpression", "buildBlock", "buildPartialBlock", "buildOptional", "buildIf",
            "buildEither", "buildArray", "buildLimitedAvailability", "buildFinalResult"]
        var knownImports: Set<String> = ["import Testing"]
        for module in modules {
            knownImports.insert("import " + module)
            knownImports.insert("@testable import " + module)
        }
        var observed = Set<String>(), missing = Set<String>()
        var opaque = incompleteInputs
        for revision in sources {
            for file in revision.values {
                if let path = file.units.first?.region.path, paths.contains(path),
                   file.units.contains(where: { $0.builderLocations == nil }) {
                    missing.insert(path)
                }
                // A binary module, macro expansion or generated input can supply a builder
                // through a parameter or protocol witness in another file.
                guard !opaque else { continue }
                guard file.diagnostics.isEmpty,
                      file.helperDeclarationIssues?.contains(where: { $0.kind == "macro-declaration" }) == false,
                      file.units.first?.receiverUnsupportedImports?.isSubset(of: knownImports) ?? file.units.isEmpty else {
                    opaque = true
                    continue
                }
                for unit in file.units {
                    guard let defaults = unit.locationDefaultNames else {
                        opaque = true
                        break
                    }
                    for (name, values) in defaults where methods.contains(name) { observed.formUnion(values) }
                }
            }
        }
        kinds = opaque ? dimensions : observed.intersection(dimensions)
        incompletePaths = kinds.isEmpty ? [] : missing
    }
}
