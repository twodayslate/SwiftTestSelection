// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// Only sealed builds from capture-build.py are eligible. Missing/stale primary
/// coverage is a per-module replay, never an empty dependency graph.
struct CapturedSIL: Sendable {
    let modules: [String: [URL]]
    let fingerprints: [String: String]
    let diagnostics: [String]
    var frontendPath: String? = nil

    private static func canonical(_ path: String) -> String {
        if let resolved = realpath(path, nil) { defer { free(resolved) }; return String(cString: resolved) }
        return URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    struct Seal: Decodable {
        var schemaVersion: Int
        var root: String
        var revision: String
        var toolchain: String
        var buildLogDigest: String
        var buildSettingsDigest: String
        var products: [String: String]
        var manifests: [String: String]
        var inventory: [String: [String]]
    }
    struct Job: Decodable {
        var status: String
        var arguments: [String]
        var directory: String
        var sources: [String: String]
        var sourceFiles: [String]
        var primaryFiles: [String]
        var silFiles: [String]
        var silSHA256: [String: String]
    }
    static func load(at directory: URL, root: URL, inputs: XcodeBuildInputs,
                     logDigest: String, settingsDigest: String, products: [String: String], toolchain: String) throws -> Self {
        let sealPath = directory.appendingPathComponent("build.json")
        let seal = try JSONDecoder().decode(Seal.self, from: Data(contentsOf: sealPath))
        guard seal.schemaVersion == 1, URL(fileURLWithPath: seal.root).resolvingSymlinksInPath() == root.resolvingSymlinksInPath(),
              seal.revision == (try GitChanges.revision(inputs.revision, at: root)), seal.toolchain == toolchain,
              seal.buildLogDigest == logDigest, seal.buildSettingsDigest == settingsDigest, seal.products == products else {
            throw ImpactError("SIL capture does not belong to this revision, toolchain, log, settings and exact test products. Run capture-build.py again.")
        }
        // Independently reconcile the seal with the compiler's complete source
        // lists. A self-consistent but partial capture inventory is insufficient.
        var expected: [String: Set<String>] = [:]
        let log = try String(contentsOf: inputs.buildLog, encoding: .utf8)
        for line in log.components(separatedBy: .newlines) {
            guard let marker = line.range(of: "builtin-SwiftDriver -- ") else { continue }
            let arguments = try XcodeSourceFileList.parse(String(line[marker.upperBound...]))
            guard let i = arguments.firstIndex(of: "-module-name"), i + 1 < arguments.count else { throw ImpactError("Capture compiler inventory has no module") }
            var sources: [String] = []
            for argument in arguments {
                if argument.hasPrefix("@") {
                    let list = URL(fileURLWithPath: String(argument.dropFirst()), relativeTo: root)
                    sources += try XcodeSourceFileList.parse(String(contentsOf: list, encoding: .utf8))
                } else if argument.hasSuffix(".swift") { sources.append(argument) }
            }
            expected[arguments[i + 1], default: []].formUnion(sources.filter { $0.hasSuffix(".swift") }.map {
                canonical(URL(fileURLWithPath: $0, relativeTo: root).path)
            })
        }
        guard !expected.isEmpty, expected == seal.inventory.mapValues({ Set($0.map(canonical)) }) else {
            throw ImpactError("SIL capture inventory differs from the build's complete compiler source inventory")
        }
        var modules: [String: [URL]] = [:], covered: [String: Set<String>] = [:]
        var fingerprints = [sealPath.path: try ArtifactFiles.digest(sealPath)]
        func record(_ path: String, _ digest: String) throws {
            if let earlier = fingerprints[path], earlier != digest {
                throw ImpactError("Captured jobs disagree about input bytes: \(path)")
            }
            fingerprints[path] = digest
        }
        var invalid = Set<String>(), diagnostics: [String] = []
        for (relative, digest) in seal.manifests.sorted(by: { $0.key < $1.key }) {
            let path = directory.appendingPathComponent(relative).standardizedFileURL.resolvingSymlinksInPath()
            guard path.path.hasPrefix(directory.resolvingSymlinksInPath().path + "/"), try ArtifactFiles.digest(path) == digest else {
                throw ImpactError("SIL capture manifest changed or escapes its session: \(relative)")
            }
            fingerprints[path.path] = digest
            let job = try JSONDecoder().decode(Job.self, from: Data(contentsOf: path))
            guard let i = job.arguments.firstIndex(of: "-module-name"), i + 1 < job.arguments.count else { throw ImpactError("Captured job has no module") }
            let module = job.arguments[i + 1]
            let optimizations = job.arguments.filter { ["-Onone", "-O", "-Osize", "-Ounchecked"].contains($0) }
            guard job.status == "complete", optimizations.last == "-Onone", job.arguments.contains("-g"),
                  Set(job.sourceFiles) == Set(job.sources.keys), !job.sources.isEmpty,
                  Set(job.primaryFiles).isSubset(of: Set(job.sourceFiles)),
                  job.silFiles.count == max(1, job.primaryFiles.count), Set(job.silFiles).count == job.silFiles.count else {
                invalid.insert(module); continue
            }
            func absolute(_ s: String) -> URL {
                let url = URL(fileURLWithPath: s, relativeTo: URL(fileURLWithPath: job.directory, isDirectory: true)).standardizedFileURL.resolvingSymlinksInPath()
                if let resolved = realpath(url.path, nil) { defer { free(resolved) }; return URL(fileURLWithPath: String(cString: resolved)) }
                return url
            }
            let sources = Set(job.sourceFiles.map { absolute($0).path })
            guard sources == Set((seal.inventory[module] ?? []).map(canonical)) else { invalid.insert(module); continue }
            for (source, hash) in job.sources { try record(absolute(source).path, hash) }
            covered[module, default: []].formUnion((job.primaryFiles.isEmpty ? job.sourceFiles : job.primaryFiles).map { absolute($0).path })
            for name in job.silFiles {
                guard name == URL(fileURLWithPath: name).lastPathComponent, let hash = job.silSHA256[name] else {
                    throw ImpactError("Invalid captured SIL file")
                }
                let file = path.deletingLastPathComponent().appendingPathComponent(name)
                guard file.resolvingSymlinksInPath().path.hasPrefix(directory.resolvingSymlinksInPath().path + "/") else { throw ImpactError("SIL file escapes capture directory") }
                fingerprints[file.path] = hash; modules[module, default: []].append(file)
            }
        }
        for (module, inventory) in seal.inventory {
            if invalid.contains(module) || covered[module] != Set(inventory.map(canonical)) {
                modules.removeValue(forKey: module)
                diagnostics.append("Capture \(module): incomplete or unsupported primary coverage; replaying module")
            }
        }
        let result = Self(modules: modules, fingerprints: fingerprints, diagnostics: diagnostics, frontendPath: directory.appendingPathComponent("wrapper/bin/swift-frontend").path)
        try result.validateFiles()
        return result
    }
    func replayArguments(_ arguments: [String]) -> [String] {
        var result: [String] = [], index = 0
        while index < arguments.count {
            if arguments[index] == "-driver-use-frontend-path", index + 1 < arguments.count,
               let frontendPath,
               URL(fileURLWithPath: arguments[index + 1]).resolvingSymlinksInPath() == URL(fileURLWithPath: frontendPath).resolvingSymlinksInPath() {
                index += 2
            } else { result.append(arguments[index]); index += 1 }
        }
        return result
    }
    func validateFiles() throws {
        for (path, digest) in fingerprints {
            guard try ArtifactFiles.digest(URL(fileURLWithPath: path)) == digest else {
                throw ImpactError("SIL capture input/output changed: \(path)")
            }
        }
    }
    func parse(module: String, sourceRoot: URL) throws -> SILModule? {
        guard let files = modules[module] else { return nil }
        var result = SILModule(importedSymbols: [], functions: [:], dispatchTargets: [:])
        for file in files.sorted(by: { $0.path < $1.path }) {
            let parsed = try SILParser.parse(file: file, module: module, sourceRoot: sourceRoot)
            guard !parsed.functions.isEmpty else { throw ImpactError("Empty captured SIL: \(file.path)") }
            for (id, node) in parsed.functions {
                if parsed.importedSymbols?.contains(id) == true {
                    if result.functions[id] == nil { result.importedSymbols!.insert(id) }
                } else { result.importedSymbols!.remove(id) }
                if var old = result.functions[id] {
                    old.dependencies.formUnion(node.dependencies)
                    if let before = old.compilerReferences, let after = node.compilerReferences {
                        old.compilerReferences = before.union(after)
                    } else { old.compilerReferences = nil }
                    old.dynamicDeclarations.formUnion(node.dynamicDeclarations)
                    old.uncertainties.formUnion(node.uncertainties)
                    old.regions = Set(old.regions + node.regions).sorted { ($0.path, $0.startLine, $0.endLine) < ($1.path, $1.startLine, $1.endLine) }
                    result.functions[id] = old
                } else { result.functions[id] = node }
            }
            for (key, values) in parsed.dispatchTargets { result.dispatchTargets[key, default: []].formUnion(values) }
            if result.externalWitnesses == nil { result.externalWitnesses = [:] }
            for (key, owners) in parsed.externalWitnesses ?? [:] { result.externalWitnesses![key, default: []].formUnion(owners) }
        }
        return result
    }
}
