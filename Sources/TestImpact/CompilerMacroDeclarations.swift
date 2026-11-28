// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation
import SwiftParser
import SwiftSyntax

/// Macro names visible through the compiled modules in an explicit import map.
/// Private/SPI interfaces include declarations from serialized Swift modules.
/// Source inputs separately cover internal macros in the module being built.
struct CompilerMacroDeclarations: Codable, Sendable {
    var version = 1
    var buildInputs: String
    var namesByModule: [String: Set<String>]
    private var declarationsDigest: String

    init(buildInputs: String, namesByModule: [String: Set<String>]) {
        self.buildInputs = buildInputs
        self.namesByModule = namesByModule
        declarationsDigest = HelperBindingContracts.digest(namesByModule)
    }

    func matches(_ artifact: XcodeBuildArtifact) -> Bool {
        guard version == 1, let build = artifact.helperBindingBuild, build.matches(artifact),
              buildInputs == artifact.helperBindingInputs, build.fingerprint == buildInputs else { return false }
        return declarationsDigest == HelperBindingContracts.digest(namesByModule)
    }

    private struct ImportedModule: Decodable {
        var moduleName: String
        var modulePath: String?
        var clangModulePath: String?
        var clangModuleMapPath: String?
    }

    /// Decode the token following each possible declaration keyword in isolation.
    /// Newer interface syntax elsewhere in the file cannot hide a declaration
    /// from the pinned Swift parser. Matches inside comments only widen lookup.
    static func names(in text: String) -> Set<String> {
        guard text.contains("macro") else { return [] }
        let bytes = Data(text.utf8), keyword = Data("macro".utf8)
        var names = Set<String>(), cursor = bytes.startIndex
        while let match = bytes.range(of: keyword, in: cursor..<bytes.endIndex) {
            cursor = match.upperBound
            let remaining = bytes.distance(from: match.lowerBound, to: bytes.endIndex)
            var length = min(256, remaining)
            while true {
                let fragment = bytes[match.lowerBound..<(match.lowerBound + length)]
                var tokens = Parser.parse(source: String(decoding: fragment, as: UTF8.self))
                    .tokens(viewMode: .sourceAccurate).makeIterator()
                guard tokens.next()?.text == "macro", let name = tokens.next() else { break }
                if length == remaining || (name.tokenKind != .endOfFile && name.endPositionBeforeTrailingTrivia.utf8Offset < length) {
                    if let identifier = name.identifier { names.insert(identifier.name) }
                    break
                }
                // A long name or comment separating the keyword and name crossed
                // the chunk boundary. Retry with enough bytes to see the whole token.
                length = min(remaining, length * 2)
            }
        }
        return names
    }

    private static func completeInterface(_ output: CommandOutput) -> Bool {
        guard output.status == 0 else { return false }
        let diagnostics = String(decoding: output.stderr, as: UTF8.self).components(separatedBy: .newlines)
        return diagnostics.allSatisfy { line in
            if line.contains("error:") { return false }
            guard line.contains("warning:") else { return true }
            // The map already includes scoped imports. These warnings concern
            // import spelling, ABI resilience, and the OSLog section name.
            return line.hasSuffix("[#UnsupportedScopedImport]") || line.hasSuffix("[#OSLog]") ||
                line.hasSuffix("module interfaces are only supported with -enable-library-evolution")
        }
    }

    static func capture(modules: Set<String>, sil: CapturedSIL, build: HelperBindingBuildEvidence) throws -> Self {
        guard sil.diagnostics.isEmpty, let sources = sil.compiledSourcePaths else { throw ImpactError("Incomplete Swift source inventory for macro lookup") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("module-interfaces-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var sourceNames = Set<String>()
        for path in sources {
            guard let digest = sil.fingerprints[path] else { throw ImpactError("Missing compiled source fingerprint for macro lookup") }
            let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
            guard XcodeGraphCache.digest(bytes) == digest, let text = String(data: bytes, encoding: .utf8) else {
                throw ImpactError("Cannot authenticate Swift input for macro lookup")
            }
            sourceNames.formUnion(names(in: text))
        }

        var results: [String: Set<String>] = [:]
        for module in modules.sorted() {
            guard let command = sil.moduleInterfaceCommands[module], let frontend = command.first,
                  let expected = build.importedModules[module] else { continue }
            let maps = build.inputFiles.keys.filter {
                let name = URL(fileURLWithPath: $0).lastPathComponent
                return name.hasPrefix(module + "-dependencies-") && name.hasSuffix(".json")
            }
            guard maps.count == 1, let map = maps.first else { continue }
            let data = try Data(contentsOf: URL(fileURLWithPath: map))
            guard XcodeGraphCache.digest(data) == build.inputFiles[map] else { continue }
            let imports = try JSONDecoder().decode([ImportedModule].self, from: data)
            guard !imports.isEmpty, imports.allSatisfy({ $0.modulePath != nil || $0.clangModulePath != nil }),
                  Set(imports.map(\.moduleName)) == Set(expected) else { continue }
            // The interface printer also reads transitive Swift and Clang modules.
            let files = Set(imports.flatMap { [$0.modulePath, $0.clangModulePath, $0.clangModuleMapPath].compactMap { $0 } } + [map, frontend])
            func sealedInputsMatch() throws -> Bool {
                try files.allSatisfy { path in
                    let file = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
                    guard let expected = build.inputFiles[file.path] else { return false }
                    return try ArtifactFiles.digest(file) == expected
                }
            }
            guard try sealedInputsMatch() else { continue }
            var names = sourceNames
            var complete = true
            for imported in imports {
                guard let path = imported.modulePath else { continue } // A Clang PCM cannot declare a Swift macro.
                let file = URL(fileURLWithPath: path).resolvingSymlinksInPath()
                let output = directory.appendingPathComponent(UUID().uuidString + ".private.swiftinterface")
                var args = Array(command.dropFirst()) + ["-module-name", imported.moduleName, "-explicit-swift-module-map-file", map,
                    "-disable-implicit-swift-modules", "-Xcc", "-fno-implicit-modules", "-enable-library-evolution",
                    "-emit-private-module-interface-path", output.path, "-merge-modules", "-o", "/dev/null"]
                if imported.moduleName == "Swift" { args.append("-parse-stdlib") }
                let dump = try CommandRunner.run(frontend, args + [file.path], at: directory, allowFailure: true)
                guard completeInterface(dump), let text = try? String(contentsOf: output, encoding: .utf8),
                      text.hasPrefix("// swift-interface-format-version: 1.0\n") else {
                    complete = false
                    break
                }
                names.formUnion(Self.names(in: text))
                try FileManager.default.removeItem(at: output)
            }
            if complete, try sealedInputsMatch() { results[module] = names }
        }
        return Self(buildInputs: build.fingerprint, namesByModule: results)
    }
}

extension XcodeTestGraph {
    func hasUnsupportedMacroSources(module: String) -> Bool {
        let modules = Set(buildArtifact?.helperBindingBuild?.importedModules[module] ?? []).union([module])
        return modules.contains { name in
            if unsupportedSourceInputs?[name]?.isEmpty == false || unresolvedProductRoles?[name] != nil { return true }
            return (generatedSourceBoundaries?[name] ?? []).contains { boundary in
                guard let inputs = boundary.generatorInputs, let generator = inputs["generator"],
                      generator == "xcode-auxiliary-file-v1" || generator.hasPrefix("xcode-actool-symbols-v1\n"),
                      (try? XcodeGraphCache.key(inputs)) == boundary.generatorIdentity,
                      let files = boundary.repositoryInputFiles,
                      (try? XcodeGraphCache.key(files)) == boundary.repositoryInputs else { return true }
                return false
            }
        }
    }
}

extension XcodeBaseSourceCache {
    /// An independent scope may omit a project, package, import or generator
    /// change. Only the full Git comparison can establish that the external
    /// module inventory is also an upper bound on historical lookup.
    func macroBuildInputsUnchanged(current: XcodeTestGraph, baseMappings: UIFeatureMappings?) throws -> Bool {
        guard let artifact = current.buildArtifact, artifact.macroDeclarations?.matches(artifact) == true,
              let audit = artifact.headOnlyBuildEvidence, audit.matches(artifact), audit.uncertainty == nil,
              current.mappings?.ignoredDocumentation == baseMappings?.ignoredDocumentation else { return false }
        let evidence = try runtimeEvidence(headRevision: artifact.revision)
        let owned = Set(current.targets.flatMap(\.sourceFiles))
        let documentation = Set(audit.documentation).filter { path in
            !owned.contains(path) && path.hasSuffix(".md") && current.mappings?.ignoredDocumentation?.contains { UIFeatureMappings.matches(path, pattern: $0) } == true
        }
        guard evidence.buildInputPaths.isSubset(of: documentation), let basePaths = try paths(), allBaseSwiftSourcesRegular,
              basePaths.filter({ $0.hasSuffix(".swift") }).isSubset(of: evidence.regularSourcePaths) else { return false }
        let byPath = Dictionary(grouping: current.sources, by: { $0.value.sourceIdentity(storedAs: $0.key)?.path })
        for path in evidence.changedPaths.subtracting(documentation) {
            guard FileChange.isSwiftImplementation(path), !path.contains(".xcassets/"),
                  evidence.regularSourcePaths.contains(path), let blob = evidence.sourceBlobIDs[path],
                  let files = byPath[path], !files.isEmpty else { return false }
            for (key, head) in files {
                guard head.sourceBlobIDs?.contains(blob) == true, head.diagnostics.isEmpty,
                      let id = head.sourceIdentity(storedAs: key) else { return false }
                guard basePaths.contains(path) else { continue }
                guard let old = try snapshot(path: path, module: id.module), old.diagnostics.isEmpty else { return false }
                func imports(_ file: SwiftSourceSnapshot) -> Set<String> {
                    Set(file.units.filter { $0.kind == "import" }.map { $0.comparisonFingerprint(.diagnostic) })
                }
                if !imports(old).isSubset(of: imports(head)) { return false }
            }
        }
        return true
    }
}
