// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
import Foundation

/// Git evidence for the complete comparison, independent of selection scopes.
/// No historical compiler graph or historical import inventory is fabricated.
struct HeadOnlyRuntimeSourceEvidence {
    let baseRevision: String
    let headRevision: String
    let changedPaths: Set<String>
    let sourcePaths: Set<String>
    let regularSourcePaths: Set<String>
    let sourceBlobIDs: [String: String]
    let structuralFailure: String?
    let buildInputPaths: Set<String>
    var failure: String? { validationFailure(ignoringDocumentation: []) }

    func validationFailure(ignoringDocumentation documentation: Set<String>, confirmedSources: Set<String> = []) -> String? {
        if let structuralFailure { return structuralFailure }
        return buildInputPaths.subtracting(documentation).subtracting(confirmedSources).sorted().first.map {
            "Changed build, resource or policy input requires historical evidence: " + $0
        }
    }

    static func read(head: String, root: URL, cache: XcodeBaseSourceCache) throws -> Self {
        guard let baseRevision = cache.resolvedRevision else { throw ImpactError("Cannot resolve historical runtime boundary source revision") }
        let headRevision = try GitChanges.revision(head, at: root)
        guard head == headRevision else { throw ImpactError("Runtime boundary requires a resolved captured head revision") }
        let changes = try GitChanges.readComparison(base: baseRevision, head: headRevision, at: root)
        let paths = Set(changes.flatMap(\.paths))
        let listing = try CommandRunner.run("git", ["ls-tree", "-r", "-z", headRevision, "--"], at: root)
        var headPaths = Set<String>(), regularPaths = Set<String>()
        var blobIDs: [String: String] = [:]
        for record in listing.stdout.split(separator: 0) {
            let fields = String(decoding: record, as: UTF8.self).split(separator: "\t", maxSplits: 1)
            guard fields.count == 2 else { throw ImpactError("Malformed Git source inventory") }
            let path = String(fields[1])
            guard path.hasSuffix(".swift") else { continue }
            headPaths.insert(path)
            if fields[0].hasPrefix("100644 blob ") || fields[0].hasPrefix("100755 blob ") {
                regularPaths.insert(path)
                blobIDs[path] = fields[0].split(separator: " ").last.map(String.init)
            }
        }
        let basePaths = try cache.paths().map { Set($0.filter { $0.hasSuffix(".swift") }) }
        let failure: String?
        if basePaths != headPaths { failure = "Added/deleted/moved Swift sources lack historical module ownership" }
        else if changes.contains(where: { $0.previousPath != nil || $0.requiresFallback }) {
            failure = "Moved or unclassified source lacks historical ownership"
        } else { failure = nil }
        return .init(baseRevision: baseRevision, headRevision: headRevision, changedPaths: paths, sourcePaths: headPaths, regularSourcePaths: regularPaths, sourceBlobIDs: blobIDs, structuralFailure: failure,
            buildInputPaths: paths.filter { !FileChange.isSwiftImplementation($0) })
    }
}

extension TestRuntimeBoundary {
    func headOnlyValidationFailure(current: XcodeTestGraph, source: XcodeHeadOnlySources,
                                   baseRevision: String, buildEvidenceFailure: String?) -> String? {
        let prefix = "Cannot validate head-only runtime boundary for \(target): "
        guard source.mappings?.testRuntimeBoundaries?.filter({ $0.target == target }) == [self],
              current.mappings?.testRuntimeBoundaries?.filter({ $0.target == target }) == [self],
              !rationale.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return prefix + "missing, changed or ambiguous closed runtime contract"
        }
        if let reason = validationFailure(in: current) { return prefix + reason }
        guard let ownModule = current.modules[target], current.runtimeInventory?.hosts[target] == [ownModule] else {
            return prefix + "only a compiler-validated hostless target is supported"
        }
        guard let artifact = current.buildArtifact,
              artifact.headOnlyBuildEvidence?.matches(artifact) == true,
              artifact.headOnlyBuildEvidence?.uncertainty == nil,
              artifact.helperFormattingBuild?.matches(artifact) == true,
              artifact.helperBindingBuild?.matches(artifact) == true,
              buildEvidenceFailure == nil else {
            return prefix + "missing or uncertain captured compiler, dependency-input and build audit"
        }
        guard let evidence = source.runtimeBoundaryEvidence, evidence.baseRevision == baseRevision,
              evidence.headRevision == artifact.revision else {
            return prefix + "missing full Git comparison at the exact resolved base/head revisions"
        }
        // Exclusions are authenticated against the complete comparison, not a
        // selection scope. A suffix or the caller's ignored-path list alone is
        // insufficient: the capture must prove the file is not a build input.
        let owned = Set(current.targets.flatMap(\.sourceFiles))
        let unchangedPolicy = current.mappings?.ignoredDocumentation == source.mappings?.ignoredDocumentation
        let documentation = Set(artifact.headOnlyBuildEvidence?.documentation ?? []).filter { path in
            unchangedPolicy && path.hasSuffix(".md") && !owned.contains(path) &&
                current.mappings?.ignoredDocumentation?.contains { UIFeatureMappings.matches(path, pattern: $0) } == true
        }
        let confirmed = current.manifestNamedImplementations(in: current.sources)
            .intersection(current.manifestNamedImplementations(in: source.base))
        if let failure = evidence.validationFailure(ignoringDocumentation: documentation, confirmedSources: confirmed) { return prefix + failure }
        guard source.diagnostics.isEmpty, source.unownedBaseSources.isEmpty else {
            return prefix + "missing or unowned historical Swift sources"
        }
        // Byte-identical closed modules retain their imports, lifecycle, macros,
        // callbacks and storage. A changed source elsewhere may change bodies,
        // but never declaration/binding structure under this initial proof.
        for (key, snapshot) in current.sources.sorted(by: { $0.key < $1.key }) {
            let module = String(key.prefix { $0 != ":" })
            let path = String(key.dropFirst(module.count + 1))
            guard evidence.regularSourcePaths.contains(path), let old = source.base[key],
                  snapshot.diagnostics.isEmpty, old.diagnostics.isEmpty else {
                return prefix + "missing historical source/ownership for " + key
            }
            guard let blob = evidence.sourceBlobIDs[path], snapshot.sourceBlobIDs?.contains(blob) == true else {
                return prefix + "captured source bytes are not authenticated by Git (archive substitution or missing byte identity): " + key
            }
            if modules.contains(module), snapshot.helperDeclarationsComplete != true || old.helperDeclarationsComplete != true {
                let issues = (old.helperDeclarationIssues ?? []) + (snapshot.helperDeclarationIssues ?? [])
                let detail = issues.first.map { ":\($0.line):\($0.column) \($0.spelling) (\($0.kind)); \($0.requiredEvidence)" }
                    ?? "; refresh the missing declaration inventory"
                return prefix + "historical macro/attribute expansion is not authenticated: " + key + detail
            }
            if modules.contains(module), current.hasUninspectedSwiftInputs(in: module) || current.unresolvedProductRoles?[module] != nil {
                return prefix + "generated inputs or module ownership require historical build evidence: " + module
            }
            let before = Dictionary(grouping: old.units, by: \.key)
            let after = Dictionary(grouping: snapshot.units, by: \.key)
            // Native syntax fingerprints retain semantic source-location
            // values. Also retain caller locations, since default arguments can
            // observe them without a literal in the caller's own body.
            if modules.contains(module), evidence.changedPaths.contains(path) {
                guard Set(before.keys) == Set(after.keys), before.allSatisfy({ key, units in
                    let next = after[key]!
                    return units.count == 1 && next.count == 1 &&
                        units[0].fingerprint == next[0].fingerprint && units[0].callerLocations == next[0].callerLocations
                }), InlineUIMappings.policyPaths([key: old]) == InlineUIMappings.policyPaths([key: snapshot]),
                    HelperFormattingContracts.declarations([key: old], nil) == HelperFormattingContracts.declarations([key: snapshot], nil) else {
                    return prefix + "closed runtime source changed: " + key
                }
            }
            guard Set(before.keys) == Set(after.keys), before.allSatisfy({ key, units in
                let next = after[key]!
                if units.map(\.fingerprint).sorted() == next.map(\.fingerprint).sorted() { return true }
                return !modules.contains(module) && units.count == 1 && next.count == 1 &&
                    units[0].kind == "function" && next[0].kind == "function" &&
                    units[0].headOnlyBodySupported == true && next[0].headOnlyBodySupported == true
            }) else { return prefix + "historical declarations or unsupported body changed: " + key }
        }
        guard Set(source.base.keys) == Set(current.sources.keys),
              modules.allSatisfy({ module in current.sources.keys.contains { $0.hasPrefix(module + ":") } }) else {
            return prefix + "incomplete historical module source inventory"
        }
        return nil
    }
}
