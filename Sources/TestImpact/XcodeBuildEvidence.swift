// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

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
    public var documentationBlockers: [String: [String]]? = nil
    public var sourceLocations: [String]? = nil
    public var generatorInputs: [String: String]? = nil
    // Older versions did not validate Metal dependency paths and all overlay
    // argument forms. Recapture them before excluding documentation.
    public var documentationEvidenceVersion: Int? = 3
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
    private let resolveMetalTool: (String, String) -> String?

    private func canonical(_ path: String) -> String { URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path }

    private struct Command: Decodable {
        var tool: String
        var args: [String]?
        var env: [String: String]?
        var inputs: [String]?
        var outputs: [String]?
        var deps: [String]?
        var depsStyle: String?
        var workingDirectory: String?
        enum CodingKeys: String, CodingKey {
            case tool, args, env, inputs, outputs, deps
            case depsStyle = "deps-style", workingDirectory = "working-directory"
        }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            tool = try values.decode(String.self, forKey: .tool)
            args = try values.decodeIfPresent([String].self, forKey: .args)
            env = try values.decodeIfPresent([String: String].self, forKey: .env)
            inputs = try values.decodeIfPresent([String].self, forKey: .inputs)
            outputs = try values.decodeIfPresent([String].self, forKey: .outputs)
            // Built-in tasks use a scalar path; shell tasks use a list.
            if let path = try? values.decode(String.self, forKey: .deps) { deps = [path] }
            else { deps = try values.decodeIfPresent([String].self, forKey: .deps) }
            depsStyle = try values.decodeIfPresent(String.self, forKey: .depsStyle)
            workingDirectory = try values.decodeIfPresent(String.self, forKey: .workingDirectory)
        }
        var isMetal: Bool { args?.first.map { ["metal", "metallib"].contains(URL(fileURLWithPath: $0).lastPathComponent) } ?? false }
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
        let metadata = try files(log: log)
        var result = try Dictionary(uniqueKeysWithValues: metadata.map { ($0.path, try ArtifactFiles.digest($0)) })
        if let manifest = metadata.first {
            let commands = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifest)).commands
            for command in commands.values where command.isMetal {
                for path in command.deps ?? [] where path.hasPrefix("/") && FileManager.default.fileExists(atPath: path) {
                    result[path] = try ArtifactFiles.digest(URL(fileURLWithPath: path))
                }
            }
        }
        return result
    }

    init(log: String, root: URL, derived: URL, captured: CapturedSIL? = nil,
         resolveMetalTool: @escaping (String, String) -> String? = XcodeBuildEvidence.installedMetalTool) throws {
        self.captured = captured
        self.resolveMetalTool = resolveMetalTool
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
        let documentation = documentationEvidence(files: repositoryFiles, compiler: arguments.first ?? "")
        return GeneratedSourceBoundary(module: module, logicalPath: normalized(file.path), contentDigest: try ArtifactFiles.digest(file),
            generatorIdentity: identity, repositoryInputs: repositoryInputs,
            repositoryInputFiles: repositoryFiles, documentationInputs: documentation.allowed, documentationBlockers: documentation.blockers,
            sourceLocations: snapshot.units.flatMap { $0.fileLocationValues ?? [] }.sorted(), generatorInputs: generatorInputs)
    }

    /// Resolve only Apple's installed Metal toolchain, using the active compiler's
    /// Xcode and a clean environment (no PATH/TOOLCHAINS/xcrun overrides). Never
    /// execute a manifest-provided binary to discover its provenance.
    static func installedMetalTool(_ name: String, developer: String) -> String? {
        guard ["metal", "metallib"].contains(name), developer.hasPrefix("/") else { return nil }
        guard let result = try? CommandRunner.run("/usr/bin/env", ["-i", "DEVELOPER_DIR=" + developer,
            "PATH=/usr/bin:/bin", "/usr/bin/xcrun", "--toolchain", "com.apple.dt.toolchain.Metal", "--find", name],
            at: URL(fileURLWithPath: "/"), allowFailure: true), result.status == 0 else { return nil }
        let path = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.hasPrefix("/"), !path.contains("\n"), path.hasSuffix(".xctoolchain/usr/bin/" + name) else { return nil }
        return path
    }

    /// Exact Xcode tool locations, not a developer-directory prefix plus basename.
    /// Downloaded Metal tools live outside Xcode; they must match xcrun's explicit
    /// Apple Metal toolchain lookup. An unknown task still blocks exclusions.
    func documentationEvidence(files: [String: String], compiler: String) -> (allowed: [String], blockers: [String: [String]], uncertainty: [String]) {
        let developer = compiler.range(of: "/Toolchains/").map { String(compiler[..<$0.lowerBound]) }
        var supported = Set(["/usr/bin/touch", "/usr/bin/derq"].map(canonical))
        if let developer, developer.hasPrefix("/") {
            let developerTools = ["actool", "ibtool", "copypng", "xcstringstool", "embeddedBinaryValidationUtility"]
            let toolchainTools = ["clang", "clang++", "clang-stat-cache", "swiftc", "appintentsmetadataprocessor",
                                  "appintentsnltrainingprocessor", "lipo", "tapi", "metal", "metallib"]
            supported.formUnion(developerTools.map { canonical(developer + "/usr/bin/" + $0) })
            supported.formUnion(toolchainTools.map { canonical(developer + "/Toolchains/XcodeDefault.xctoolchain/usr/bin/" + $0) })
            let metalNames = Set(commands.values.filter { $0.tool == "shell" }.compactMap { $0.args?.first }
                .filter { !supported.contains(canonical($0)) }.map { URL(fileURLWithPath: $0).lastPathComponent })
                .intersection(["metal", "metallib"])
            for name in metalNames.sorted() {
                if let path = resolveMetalTool(name, developer) { supported.insert(canonical(path)) }
            }
        }
        let ordered = commands.sorted { $0.key < $1.key }
        var unknown = ordered.compactMap { key, command -> String? in
            guard command.tool == "shell" else { return nil }
            if let executable = command.args?.first, executable.hasPrefix("/"), supported.contains(canonical(executable)) { return nil }
            return "Unrecognized shell task \(normalized(key)): \(normalized(command.args?.first ?? "<missing executable>"))"
        }
        func inputPath(_ input: String, _ command: Command) -> String {
            let directory = command.workingDirectory.map { URL(fileURLWithPath: $0, relativeTo: root) } ?? root
            return canonical(URL(fileURLWithPath: input, relativeTo: directory.appendingPathComponent("", isDirectory: true)).path)
        }
        var inputRows = ordered.flatMap { key, command in
            (command.inputs ?? []).filter { !$0.hasPrefix("<") }.map { (key, $0, inputPath($0, command)) }
        }
        var hasMetalCompilation = false
        for (key, command) in ordered where command.tool == "shell" && command.isMetal {
            let args = command.args ?? []
            let dependencies = command.deps ?? []
            if args.contains("-c") || !dependencies.isEmpty {
                hasMetalCompilation = true
                // Includes need not appear in the manifest's direct inputs. Read
                // the compiler's makefile dependencies, which are also sealed by
                // fingerprints(log:) for capture/discovery/retained validation.
                let mf = args.firstIndex(of: "-MF"), mt = args.firstIndex(of: "-MT")
                guard command.depsStyle == "makefile", dependencies.count == 1,
                      let mf, mf + 1 < args.count, dependencies == [args[mf + 1]],
                      let mt, mt + 1 < args.count, args[mt + 1] == "dependencies",
                      let path = dependencies.first, path.hasPrefix("/"),
                      let text = try? String(contentsOfFile: path, encoding: .utf8),
                      let paths = Self.metalDependencies(text) else {
                    unknown.append("Unresolved Metal dependencies for task \(normalized(key)): \(dependencies.map(normalized).joined(separator: ", "))")
                    continue
                }
                let rows = paths.map { (key, $0, inputPath($0, command)) }
                for (_, input, resolved) in rows {
                    let values = try? URL(fileURLWithPath: resolved).resourceValues(forKeys: [.isRegularFileKey])
                    if !Self.supportedMetalDependencyPath(resolved) || values?.isRegularFile != true ||
                        !FileManager.default.isReadableFile(atPath: resolved) {
                        unknown.append("Unresolved or unsupported Metal dependency for task \(normalized(key)): \(normalized(input)) (resolved: \(normalized(resolved)))")
                    }
                }
                inputRows += rows
                if !Self.metalIncludesSystemHeaders(args) {
                    unknown.append("Incomplete Metal dependencies for task \(normalized(key)): system headers may be omitted; rebuild with MTL_COMPILER_FLAGS='$(inherited) -Xclang -sys-header-deps'")
                }
            } else {
                let inputs = (command.inputs ?? []).filter { !$0.hasPrefix("<") }
                if inputs.isEmpty || !inputs.allSatisfy({ $0.hasSuffix(".air") }) {
                    unknown.append("Unsupported Metal invocation for task \(normalized(key)): \(args.map(normalized).joined(separator: " "))")
                }
            }
        }
        let argumentRows = ordered.flatMap { key, command in (command.args ?? []).map { (key, $0, normalized($0)) } }
        // Retain the exact task/input responsible for a denied exclusion in the
        // graph, so a mixed documentation diff explains its conservative fallback.
        var blockers: [String: [String]] = [:], allowed: [String] = []
        for path in files.keys.sorted() where path.hasSuffix(".md") {
            let absolute = canonical(root.appendingPathComponent(path).path)
            var reasons = unknown
            // Metal can rewrite a literal backslash into a slash in its depfile.
            // Even if that rewritten path happens to exist, it cannot establish
            // whether this differently spelled repository input was consumed.
            if hasMetalCompilation && !Self.supportedMetalDependencyPath(absolute) {
                reasons.append("Unsupported repository path in Metal dependency evidence: \(normalized(absolute))")
            }
            for (key, input, consumed) in inputRows where absolute == consumed || absolute.hasPrefix(consumed + "/") {
                reasons.append("Task \(normalized(key)) consumes input \(normalized(input))")
            }
            for (key, argument, normalizedArgument) in argumentRows where normalizedArgument.contains("<Source>/" + path) || argument.contains(path) {
                reasons.append("Task \(normalized(key)) references argument \(normalizedArgument)")
            }
            if reasons.isEmpty { allowed.append(path) }
            else { blockers[path] = Array(Set(reasons)).sorted() }
        }
        return (allowed, blockers, Array(Set(unknown)).sorted())
    }

    private static func supportedMetalDependencyPath(_ path: String) -> Bool {
        !path.contains { $0 == "\\" || $0.isNewline }
    }

    /// -MMD omits system headers, including repository headers reached through
    /// -isystem or marked by #pragma clang system_header. Even adding -MD does
    /// not override -MMD. Xcode's ordinary -MMD invocation needs the explicit
    /// cc1 system-header dependency option. Do not infer completeness through
    /// opaque argument files or other preprocessor/cc1 forwarding.
    static func metalIncludesSystemHeaders(_ args: [String]) -> Bool {
        var systemHeaders = false
        var index = 1
        while index < args.count {
            let argument = args[index]
            if argument == "-Xclang", index + 1 < args.count, args[index + 1] == "-sys-header-deps" {
                systemHeaders = true
                index += 2
                continue
            }
            if argument.hasPrefix("@") || argument.hasPrefix("-Xclang") || argument.hasPrefix("-Xpreprocessor") ||
                argument.hasPrefix("-Wp,") || argument.hasPrefix("-Xarch_") || argument.hasPrefix("--config") ||
                argument.hasPrefix("-ivfsoverlay") || argument.hasPrefix("-vfsoverlay") ||
                ["-cc1", "-M", "-MM"].contains(argument) { return false }
            index += 1
        }
        guard args.contains("-MD") || args.contains("-MMD") else { return false }
        return systemHeaders || (args.contains("-MD") && !args.contains("-MMD"))
    }

    /// Xcode Metal emits one `-MT dependencies` makefile rule. Reject unknown
    /// syntax rather than accidentally treating an unparsed include as unused.
    static func metalDependencies(_ text: String) -> [String]? {
        let text = text.replacingOccurrences(of: "\\\r\n", with: " ").replacingOccurrences(of: "\\\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("dependencies:") else { return nil }
        var paths: [String] = [], token = "", escaped = false
        for character in text.dropFirst("dependencies:".count) {
            if escaped { token.append(character); escaped = false }
            else if character == "\\" { escaped = true }
            else if character == ":" || character == "$" || character == "#" { return nil }
            else if character.isWhitespace {
                if !token.isEmpty { paths.append(token); token = "" }
            } else { token.append(character) }
        }
        guard !escaped else { return nil }
        if !token.isEmpty { paths.append(token) }
        return paths.isEmpty ? nil : paths
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
