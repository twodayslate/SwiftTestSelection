// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
import Foundation

/// Exact input identities from the completed build's explicit import maps. No
/// dependency scan, compiler replay, base build, or inferred import ownership.
public struct HelperBindingBuildEvidence: Codable, Sendable {
    public var version = 1
    public var sourceInputs: String
    public var inputFiles: [String: String]
    public var importedModules: [String: [String]]
    public var buildLogDigest: String
    public var buildSettingsDigest: String
    public var productsDigest: String

    var fingerprint: String { HelperBindingContracts.digest(self) }
    func matches(_ artifact: XcodeBuildArtifact) -> Bool {
        version == 1 && !sourceInputs.isEmpty && !inputFiles.isEmpty && inputFiles.values.allSatisfy { !$0.isEmpty } &&
            !importedModules.isEmpty && importedModules.values.allSatisfy { !$0.isEmpty } &&
            buildLogDigest == artifact.buildLogDigest && buildSettingsDigest == artifact.buildSettingsDigest &&
            productsDigest == (try? XcodeGraphCache.key(artifact.products))
    }

    static func capture(log: String, source: URL, sourceInputs: [String: String], artifact: XcodeBuildArtifact) throws -> Self {
        guard XcodeGraphCache.digest(Data(log.utf8)) == artifact.buildLogDigest else {
            throw ImpactError("Binding-review compiler log does not match the captured artifact")
        }
        var files: [String: String] = [:], imported: [String: [String]] = [:], invocations: [String: [String]] = [:]
        func record(_ file: URL) throws {
            let path = file.standardizedFileURL.resolvingSymlinksInPath().path
            if files[path] == nil { files[path] = try ArtifactFiles.digest(URL(fileURLWithPath: path)) }
        }
        func directory(_ url: URL) throws {
            for (path, digest) in try ArtifactFiles.manifest(at: url) {
                guard !digest.hasPrefix("symlink:") else { throw ImpactError("Unbounded plugin resource symlink: " + path) }
                files[url.path + "/" + path] = digest
            }
        }
        var working = source
        for raw in log.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("cd ") {
                let paths = try XcodeSourceFileList.parse(String(line.dropFirst(3)))
                guard paths.count == 1 else { throw ImpactError("Ambiguous binding-review compiler directory") }
                working = URL(fileURLWithPath: paths[0], relativeTo: source).standardizedFileURL
            }
            guard let marker = line.range(of: "builtin-SwiftDriver -- ") else { continue }
            let args = try XcodeSourceFileList.parse(String(line[marker.upperBound...]))
            guard let i = args.firstIndex(of: "-module-name"), i + 1 < args.count,
                  args.contains("-explicit-module-build"), let compiler = args.first, compiler.hasPrefix("/") else {
                throw ImpactError("Missing explicit compiler import inventory for binding review")
            }
            let module = args[i + 1]
            guard invocations[module] == nil || invocations[module] == args else { throw ImpactError("Ambiguous binding-review module invocation") }
            if invocations[module] != nil { continue }
            invocations[module] = args
            guard !args.contains(where: { argument in
                ["-load-plugin-executable", "-load-plugin-library", "-external-plugin-path"].contains { argument == $0 || argument.hasPrefix($0 + "=") }
            }), !args.contains(where: { $0.hasPrefix("-plugin-path=") }) else {
                throw ImpactError("Custom macro plugin resource inputs are unsupported for binding review")
            }
            try record(URL(fileURLWithPath: compiler))
            let lists = args.filter { $0.hasPrefix("@") }
            guard lists.count == 1 else { throw ImpactError("Missing unique compiler source list for binding review") }
            let list = URL(fileURLWithPath: String(lists[0].dropFirst()), relativeTo: working).standardizedFileURL
            let maps = try FileManager.default.contentsOfDirectory(at: list.deletingLastPathComponent(), includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasPrefix(module + "-dependencies-") && $0.pathExtension == "json" }
            guard maps.count == 1, let map = maps.first,
                  let entries = try JSONSerialization.jsonObject(with: Data(contentsOf: map)) as? [[String: Any]], !entries.isEmpty else {
                throw ImpactError("Missing unique explicit import map for " + module)
            }
            try record(map)
            var names = Set<String>()
            for entry in entries {
                guard Set(entry.keys).isSubset(of: ["moduleName", "modulePath", "isFramework", "clangModulePath", "clangModuleMapPath", "isBridgingHeaderDependency"]),
                      let name = entry["moduleName"] as? String, !name.isEmpty,
                      entry["modulePath"] is String || entry["clangModulePath"] is String else {
                    throw ImpactError("Incomplete or unsupported import record for " + module)
                }
                names.insert(name)
                for key in ["modulePath", "clangModulePath", "clangModuleMapPath"] {
                    if let value = entry[key] {
                        guard let path = value as? String, path.hasPrefix("/") else { throw ImpactError("Invalid explicit import path") }
                        try record(URL(fileURLWithPath: path))
                    }
                }
            }
            imported[module] = names.sorted()
            let plugins = URL(fileURLWithPath: compiler).resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("lib/swift/host/plugins")
            try directory(plugins)
            for i in args.indices where args[i] == "-plugin-path" {
                guard i + 1 < args.count else { throw ImpactError("Missing macro plugin search path") }
                let path = URL(fileURLWithPath: args[i + 1]).resolvingSymlinksInPath()
                guard path.path.hasPrefix(plugins.resolvingSymlinksInPath().path + "/") else { throw ImpactError("Unbounded custom plugin search path") }
                // The default plugin-root manifest above already covers this subtree.
            }
        }
        guard !imported.isEmpty else { throw ImpactError("No captured import inventories") }
        // Ensure the captured map and module bytes remained stable throughout
        // evidence extraction; missing files never become an empty proof.
        for (path, digest) in files {
            let current = digest.hasPrefix("symlink:")
                ? "symlink:" + (try FileManager.default.destinationOfSymbolicLink(atPath: path))
                : try ArtifactFiles.digest(URL(fileURLWithPath: path))
            guard current == digest else { throw ImpactError("Binding-review input changed: " + path) }
        }
        guard try sourceInputs == ArtifactFiles.sourceInputs(log: log, directory: source) else {
            throw ImpactError("Compiler source input bytes changed during binding evidence capture")
        }
        return .init(sourceInputs: try XcodeGraphCache.key(sourceInputs), inputFiles: files, importedModules: imported,
            buildLogDigest: artifact.buildLogDigest, buildSettingsDigest: artifact.buildSettingsDigest,
            productsDigest: try XcodeGraphCache.key(artifact.products))
    }
}
