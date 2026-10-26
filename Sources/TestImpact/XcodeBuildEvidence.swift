// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// A comparison boundary, not a claim that generated code has no effects.
/// Any change to this evidence broadens selection. Physical build paths never
/// substitute for the generated source's content or its generator provenance.
public struct GeneratedSourceBoundary: Codable, Sendable, Equatable {
    public var module: String
    public var logicalPath: String
    public var contentDigest: String
    public var generatorIdentity: String
    public var repositoryInputs: String
    // Optional for archive compatibility; old opaque seals remain conservative.
    public var repositoryInputFiles: [String: String]? = nil
    public var documentationInputs: [String]? = nil
    public var sourceLocations: [String]? = nil
    public var generatorInputs: [String: String]? = nil
}

public struct RecoveredProductRole: Codable, Sendable, Equatable {
    public var targetName: String
    public var productType: String
    public var evidence: String
}

/// Read only the manifest named by this successful build's log. A directory scan
/// must never select a stale build description. PIF records are joined by the
/// active compiler task's target GUID, not by a module/target basename guess.
struct XcodeBuildEvidence {
    private let commands: [String: Command]
    private let records: [[String: Any]]
    private let root: URL
    private let derived: URL
    private let inputs: [String: String]
    private let pathRoots: [(String, String)]
    private let captured: CapturedSIL?

    private func canonical(_ path: String) -> String { URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path }

    private struct Command: Decodable {
        var tool: String
        var args: [String]?
        var env: [String: String]?
        var inputs: [String]?
        var outputs: [String]?
    }
    private struct Manifest: Decodable { var commands: [String: Command] }

    static func files(log: String) throws -> [URL] {
        let paths = Set(log.components(separatedBy: .newlines).filter { $0.hasPrefix("Build description path: ") }
            .map { String($0.dropFirst("Build description path: ".count)) })
        guard paths.count == 1, let path = paths.first, path.hasPrefix("/"), path.hasSuffix(".xcbuilddata") else { return [] }
        let directory = URL(fileURLWithPath: path)
        let manifest = directory.appendingPathComponent("manifest.json")
        guard FileManager.default.fileExists(atPath: manifest.path) else { return [] }
        let pif = directory.deletingLastPathComponent().appendingPathComponent("PIFCache/target")
        let records = (try? FileManager.default.contentsOfDirectory(at: pif, includingPropertiesForKeys: nil)) ?? []
        return [manifest] + records.filter { $0.lastPathComponent.hasSuffix("-json") }.sorted { $0.path < $1.path }
    }

    static func fingerprints(log: String) throws -> [String: String] {
        try Dictionary(uniqueKeysWithValues: files(log: log).map { ($0.path, try ArtifactFiles.digest($0)) })
    }

    init(log: String, root: URL, derived: URL, captured: CapturedSIL? = nil) throws {
        self.captured = captured
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
        self.derived = derived.standardizedFileURL.resolvingSymlinksInPath()
        pathRoots = [(derived, "<DerivedData>"), (root, "<Source>")].flatMap { url, token in
            var paths = Set([url.standardizedFileURL.path, url.standardizedFileURL.resolvingSymlinksInPath().path])
            if let resolved = realpath(url.path, nil) { paths.insert(String(cString: resolved)); free(resolved) }
            for path in paths where path.hasPrefix("/private/var/") || path.hasPrefix("/private/tmp/") { paths.insert(String(path.dropFirst("/private".count))) }
            return paths.sorted().map { ($0, token) }
        }
        let files = try Self.files(log: log)
        guard let manifest = files.first,
              manifest.resolvingSymlinksInPath().path.hasPrefix(self.derived.path + "/Build/Intermediates.noindex/XCBuildData/") else {
            throw ImpactError("Missing active Xcode build manifest; preserve XCBuildData and the complete build log")
        }
        inputs = try Self.fingerprints(log: log)
        commands = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifest)).commands
        records = try files.dropFirst().map {
            guard let record = try JSONSerialization.jsonObject(with: Data(contentsOf: $0)) as? [String: Any] else {
                throw ImpactError("Unsupported Xcode target metadata")
            }
            return record
        }
    }

    func validate(log: String, boundaries: [GeneratedSourceBoundary] = []) throws {
        guard try inputs == Self.fingerprints(log: log) else { throw ImpactError("Xcode build metadata changed during graph capture") }
        if !boundaries.isEmpty {
            let repository = try Self.repositoryInputs(root: root, derived: derived)
            for boundary in boundaries {
                guard boundary.logicalPath.hasPrefix("<DerivedData>/"), boundary.repositoryInputs == repository else {
                    throw ImpactError("Generated source inputs changed during graph capture")
                }
                let file = derived.appendingPathComponent(String(boundary.logicalPath.dropFirst("<DerivedData>/".count)))
                guard try ArtifactFiles.digest(file) == boundary.contentDigest else { throw ImpactError("Generated source changed during graph capture") }
            }
        }
    }

    private func record(module: String, list: URL) throws -> [String: Any] {
        let tasks = commands.filter { $0.value.tool == "swift-driver-compilation" &&
            ($0.value.inputs ?? []).contains { $0.hasPrefix("/") && canonical($0) == list.path } }
        guard tasks.count == 1, let task = tasks.first else {
            throw ImpactError("Missing or ambiguous active compiler task for \(module)")
        }
        let matches = records.filter { record in
            guard let name = record["name"] as? String, let guid = record["guid"] as? String else { return false }
            return task.key.hasPrefix("P0:target-" + name + "-" + guid + "-") ||
                task.key.hasPrefix("P2:target-" + name + "-" + guid + "-")
        }
        guard matches.count == 1, let record = matches.first, record["type"] as? String == "standard",
              let configurations = record["buildConfigurations"] as? [[String: Any]], !configurations.isEmpty else {
            throw ImpactError("Missing, conflicting or unsupported active target metadata for \(module)")
        }
        // The file-list join establishes the module. Explicit contradictory PIF
        // module/host settings still forbid promoting it to production.
        for config in configurations {
            guard let settings = config["buildSettings"] as? [String: Any] else { throw ImpactError("Missing target settings") }
            if let declared = settings["PRODUCT_MODULE_NAME"] as? String,
               !declared.contains("$("), declared != module { throw ImpactError("Contradictory target module for \(module)") }
            for key in ["TEST_HOST", "BUNDLE_LOADER", "TEST_TARGET_NAME"] {
                if let value = settings[key] as? String, !value.isEmpty { throw ImpactError("Test/host-bearing recovered target: \(module)") }
            }
        }
        return record
    }

    func role(module: String, list: URL) throws -> RecoveredProductRole {
        let record = try record(module: module, list: list)
        let supported: Set<String> = ["com.apple.product-type.application", "com.apple.product-type.framework",
            "com.apple.product-type.app-extension", "com.apple.product-type.app-extension.messages", "com.apple.product-type.library.static",
            "com.apple.product-type.library.dynamic", "org.swift.product-type.library.static",
            "org.swift.product-type.library.dynamic"]
        guard let type = record["productTypeIdentifier"] as? String, supported.contains(type),
              let name = record["name"] as? String else { throw ImpactError("Recovered target has an unknown or test product role: \(module)") }
        return RecoveredProductRole(targetName: name, productType: type, evidence: "active-xcode-manifest+pif-v1")
    }

    private func normalized(_ text: String) -> String {
        pathRoots.reduce(text) { result, pair in
            if result == pair.0 { return pair.1 }
            return result.replacingOccurrences(of: pair.0 + "/", with: pair.1 + "/")
                .replacingOccurrences(of: "\"" + pair.0 + "\"", with: "\"" + pair.1 + "\"")
        }
    }

    func boundary(file: URL, module: String, list: URL, arguments: [String], repositoryInputs: String, repositoryInputFiles: [String: String]? = nil) throws -> GeneratedSourceBoundary {
        let record = try record(module: module, list: list)
        guard file.path.hasPrefix(derived.path + "/Build/Intermediates.noindex/") else {
            throw ImpactError("Generated source is outside the active build intermediates")
        }
        let producers = commands.filter { ($0.value.outputs ?? []).contains { $0.hasPrefix("/") && canonical($0) == file.path } }
        guard producers.count == 1, let producer = producers.first,
              let name = record["name"] as? String, let guid = record["guid"] as? String,
              let dependencies = producer.value.inputs,
              producer.key.hasPrefix("P0:target-" + name + "-" + guid + "-") ||
                producer.key.hasPrefix("P2:target-" + name + "-" + guid + "-") else {
            throw ImpactError("Missing or conflicting generated Swift producer")
        }
        let generator: String
        if producer.value.tool == "auxiliary-file", producer.value.outputs?.map(canonical) == [file.path], dependencies.count == 1,
           dependencies[0].hasPrefix("<target-" + name + "-" + guid + "-"), dependencies[0].hasSuffix("-immediate>") {
            generator = "xcode-auxiliary-file-v1"
        } else if producer.value.tool == "shell", let args = producer.value.args,
                  let compiler = arguments.first, let toolchain = compiler.range(of: "/Toolchains/"),
                  args.first == String(compiler[..<toolchain.lowerBound]) + "/usr/bin/actool",
                  let index = args.firstIndex(of: "--generate-swift-asset-symbols"), index + 1 < args.count,
                  canonical(args[index + 1]) == file.path, producer.value.env?.isEmpty == true,
                  dependencies.contains(where: { $0.hasPrefix("/") && canonical($0).hasPrefix(root.path + "/") && $0.hasSuffix(".xcassets/") }),
                  dependencies.allSatisfy({ ($0.hasPrefix("/") && canonical($0).hasPrefix(root.path + "/")) || $0.hasPrefix("<target-" + name + "-" + guid + "-") || $0 == "<WorkspaceHeaderMapVFSFilesWritten>" }) {
            generator = "xcode-actool-symbols-v1\n" + args.map(normalized).joined(separator: "\n")
        } else { throw ImpactError("Unsupported generated Swift producer; preserve auxiliary-file or actool provenance") }
        let configs = (record["buildConfigurations"] as! [[String: Any]]).map { config in
            config.filter { $0.key != "guid" }
        }
        let settings = try JSONSerialization.data(withJSONObject: configs, options: [.sortedKeys, .withoutEscapingSlashes])
        let generatorInputs = ["target": name, "type": record["productTypeIdentifier"] as? String ?? "",
            "settings": normalized(String(decoding: settings, as: UTF8.self)),
            "compiler": (captured?.replayArguments(arguments) ?? arguments).map(normalized).joined(separator: "\n"), "generator": generator,
            "captureHelper": captured?.helperIdentity ?? "replay"]
        let identity = try XcodeGraphCache.key(generatorInputs)
        let snapshot = SwiftSourceSnapshot.parse(try String(contentsOf: file, encoding: .utf8), path: file.path, module: module)
        guard snapshot.diagnostics.isEmpty else { throw ImpactError("Unsupported generated Swift syntax") }
        // Physical #filePath values are semantic, even though artifact locations
        // use stable logical paths. Never normalize literals inside source text.
        let repositoryFiles = try repositoryInputFiles ?? Self.repositoryInputFiles(root: root, derived: derived)
        return GeneratedSourceBoundary(module: module, logicalPath: normalized(file.path), contentDigest: try ArtifactFiles.digest(file),
            generatorIdentity: identity, repositoryInputs: repositoryInputs,
            repositoryInputFiles: repositoryFiles, documentationInputs: documentationInputs(files: repositoryFiles, compiler: arguments.first ?? ""),
            sourceLocations: snapshot.units.flatMap { $0.fileLocationValues ?? [] }.sorted(), generatorInputs: generatorInputs)
    }

    /// A declared documentation policy cannot hide a resource or an input to a
    /// build task. Unknown shell tools may read undeclared inputs, so their
    /// presence prevents documentation exclusions for this build.
    private func documentationInputs(files: [String: String], compiler: String) -> [String] {
        let developer = compiler.range(of: "/Toolchains/").map { String(compiler[..<$0.lowerBound]) + "/" }
        let xcodeTools: Set<String> = ["actool", "ibtool", "clang", "clang++", "clang-stat-cache", "swiftc",
            "appintentsmetadataprocessor", "appintentsnltrainingprocessor", "embeddedBinaryValidationUtility", "lipo", "tapi"]
        for command in commands.values where command.tool == "shell" {
            guard let executable = command.args?.first,
                  ["/usr/bin/touch", "/usr/bin/derq"].contains(executable) ||
                    (developer.map { executable.hasPrefix($0) } == true && xcodeTools.contains(URL(fileURLWithPath: executable).lastPathComponent)) else { return [] }
        }
        let consumed = commands.values.flatMap { $0.inputs ?? [] }.filter { !$0.hasPrefix("<") }.map {
            canonical(URL(fileURLWithPath: $0, relativeTo: URL(fileURLWithPath: root.path, isDirectory: true)).path)
        }
        let arguments = commands.values.flatMap { $0.args ?? [] }
        return files.keys.filter { path in
            guard path.hasSuffix(".md") else { return false }
            let absolute = canonical(root.appendingPathComponent(path).path)
            return !consumed.contains { absolute == $0 || absolute.hasPrefix($0 + "/") } &&
                !arguments.contains { normalized($0).contains("<Source>/" + path) || $0.contains(path) }
        }.sorted()
    }

    /// Non-Swift inputs include resource membership/content, package manifests
    /// (added separately), project settings, scripts and generator configuration.
    /// Swift changes are compared by semantic snapshots, not this opaque seal.
    static func repositoryInputs(root: URL, derived: URL) throws -> String {
        try XcodeGraphCache.key(repositoryInputFiles(root: root, derived: derived))
    }

    static func repositoryInputFiles(root: URL, derived: URL) throws -> [String: String] {
        let root = root.standardizedFileURL.resolvingSymlinksInPath()
        let derived = derived.standardizedFileURL.resolvingSymlinksInPath()
        var result: [String: String] = [:]
        func walk(_ directory: URL, prefix: String = "") throws {
            for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) {
                if [".git", ".build"].contains(file.lastPathComponent) || file.standardizedFileURL.resolvingSymlinksInPath() == derived { continue }
                let values = try file.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if values.isSymbolicLink == true { throw ImpactError("Generated input validation does not support repository symlinks") }
                if values.isDirectory == true { try walk(file, prefix: prefix + file.lastPathComponent + "/") }
                else if file.pathExtension != "swift" || file.lastPathComponent == "Package.swift" {
                    result[prefix + file.lastPathComponent] = try ArtifactFiles.digest(file)
                }
            }
        }
        try walk(root)
        return result
    }
}
