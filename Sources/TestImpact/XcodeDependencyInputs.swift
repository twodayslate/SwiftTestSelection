// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// A fresh dependency scan describes the inputs to generated PCMs/Swift modules.
/// Their binary bytes and context-hashed output names contain build-root details.
/// Never remove those details from opaque binaries: fingerprint the compiler's
/// input inventory instead, retaining all options and hashing every input file.
enum XcodeDependencyInputs {
    struct Inventory {
        var digest: String
        var modules: Set<String>
        var projectImports: Set<String>
    }

    static func scan(compiler: String, arguments: [String], directory: URL,
                     projectModules: Set<String>, normalize: (String) -> String,
                     hash: (String) throws -> String) throws -> Inventory {
        // Swift 6.4's standalone scan can crash while resolving overlays through
        // a bridging PCH. Keep the exact-artifact fallback for this input form.
        guard !arguments.contains("-import-objc-header") else {
            throw ImpactError("Bridging-header scans are unsupported; retaining exact artifact identities")
        }
        let result = try CommandRunner.run(compiler,
            arguments + ["-whole-module-optimization", "-Onone", "-g", "-scan-dependencies"], at: directory)
        return try fingerprint(result.stdout, projectModules: projectModules, normalize: normalize, hash: hash)
    }

    static func fingerprint(_ data: Data, projectModules: Set<String>,
                            normalize: (String) -> String, hash: (String) throws -> String) throws -> Inventory {
        guard let document = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let main = document["mainModuleName"] as? String,
              let modules = document["modules"] as? [[String: Any]], !modules.isEmpty,
              modules.count.isMultiple(of: 2) else { throw ImpactError("Unsupported dependency scan inventory") }
        var outputs: [String: String] = [:]
        var names = Set<String>()
        var imports = Set<String>()
        var entries: [(String, String, [String: Any])] = []
        for index in stride(from: 0, to: modules.count, by: 2) {
            let identifier = modules[index]
            guard identifier.count == 1, let kind = identifier.keys.first,
                  ["swift", "clang", "swiftPrebuiltExternal"].contains(kind),
                  let name = identifier[kind] as? String,
                  let path = modules[index + 1]["modulePath"] as? String else {
                throw ImpactError("Unsupported dependency scan module")
            }
            let id = (kind == "clang" ? "clang:" : "swift:") + name
            guard names.insert(id).inserted else { throw ImpactError("Ambiguous dependency scan module: \(id)") }
            outputs[path] = "<MODULE:\(id)>"
            if name != main, projectModules.contains(name), kind != "clang" { imports.insert(name) }
            entries.append((kind, name, modules[index + 1]))
        }
        let paths = outputs.keys.sorted { $0.count > $1.count }
        func normalizedString(_ value: String) -> String {
            if let replacement = outputs[value] { return replacement }
            // These are compiler-generated argv entries, never source text.
            // Only rewrite an exact module-file operand, including its = prefix.
            for path in paths where value.hasSuffix("=" + path) {
                return String(value.dropLast(path.count)) + outputs[path]!
            }
            return normalize(value)
        }
        func canonical(_ value: Any) throws -> Any {
            if let text = value as? String { return normalizedString(text) }
            if let array = value as? [Any] { return try array.map(canonical) }
            if let dictionary = value as? [String: Any] {
                // Context hashes encode output location; full compiler options,
                // imported modules and raw input bytes below replace that hash.
                return try dictionary.filter { $0.key != "contextHash" }.mapValues(canonical)
            }
            return value
        }
        var inputs: [String: String] = [:]
        func input(_ path: String) throws {
            inputs[normalize(path)] = try hash(path)
        }
        for (kind, name, module) in entries {
            guard let details = module["details"] as? [String: [String: Any]],
                  let detail = details[kind] else { throw ImpactError("Missing dependency scan details") }
            let sources = module["sourceFiles"] as? [String] ?? []
            if kind == "clang", sources.isEmpty { throw ImpactError("Missing Clang input files") }
            for path in sources {
                try input(path)
                if kind == "clang" {
                    let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
                    for token in ["__TIME__", "__DATE__", "__TIMESTAMP__"] where bytes.range(of: Data(token.utf8)) != nil {
                        throw ImpactError("Time-dependent Clang input: \(path)")
                    }
                }
            }
            if kind == "swiftPrebuiltExternal" {
                guard let path = detail["compiledModulePath"] as? String else { throw ImpactError("Missing prebuilt module input") }
                if !projectModules.contains(name) { try input(path) }
            } else if kind == "swift", name != main {
                guard let path = detail["moduleInterfacePath"] as? String else { throw ImpactError("Missing Swift interface input") }
                try input(path)
                for candidate in detail["compiledModuleCandidates"] as? [String] ?? [] { try input(candidate) }
            }
            if let map = detail["moduleMapPath"] as? String { try input(map) }
            for plugin in detail["macroDependencies"] as? [[String: Any]] ?? [] {
                for key in ["libraryPath", "executablePath"] {
                    if let path = plugin[key] as? String, !path.isEmpty { try input(path) }
                }
            }
            guard kind == "swiftPrebuiltExternal" || detail["commandLine"] is [String] else {
                throw ImpactError("Missing dependency compiler options")
            }
        }
        // Sort module records by semantic identifier; scan traversal order is
        // irrelevant, but preserve argv and source order inside each record.
        let records = try entries.sorted { ($0.0, $0.1) < ($1.0, $1.1) }.map { kind, name, value in
            ["kind": kind, "name": name, "details": try canonical(value)] as [String: Any]
        }
        inputs["scan"] = XcodeGraphCache.digest(try JSONSerialization.data(withJSONObject: records, options: [.sortedKeys]))
        return Inventory(digest: try XcodeGraphCache.key(inputs), modules: names, projectImports: imports)
    }
}
