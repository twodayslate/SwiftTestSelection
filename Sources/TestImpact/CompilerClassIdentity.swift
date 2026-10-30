// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation

/// Exact compiler USRs from the built module, not names inferred from imports.
public struct CompilerClassIdentity: Codable, Equatable, Sendable {
    public var symbol: String
    public var superclass: String
    public var path: String
    public var line: Int
}

enum CompilerClassIdentities {
    static func extract(job: XcodeModuleJob, sourceRoot: URL, directory: URL, scratch: URL,
                        ownership: Set<String>) throws -> [String: CompilerClassIdentity] {
        guard let index = job.arguments.firstIndex(of: "-emit-module-path"), index + 1 < job.arguments.count else {
            throw ImpactError("Missing built Swift module path")
        }
        let moduleFile = URL(fileURLWithPath: job.arguments[index + 1], relativeTo: directory).standardizedFileURL
        let moduleInputs = [moduleFile] + ["swiftdoc", "swiftsourceinfo"].map { moduleFile.deletingPathExtension().appendingPathExtension($0) }
        func identity() throws -> [String: String] {
            var result: [String: String] = [:]
            for file in moduleInputs {
                result[file.path] = FileManager.default.fileExists(atPath: file.path) ? try ArtifactFiles.digest(file) : "<absent>"
            }
            guard result[moduleFile.path] != "<absent>" else { throw ImpactError("Built Swift module unavailable") }
            return result
        }
        let before = try identity()
        let output = scratch.appendingPathComponent("ancestry-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: output) }
        let extractor = job.compiler.hasPrefix("/")
            ? URL(fileURLWithPath: job.compiler).deletingLastPathComponent().appendingPathComponent("swift-symbolgraph-extract").path
            : "swift-symbolgraph-extract"
        var arguments = ["-module-name", job.module, "-minimum-access-level", "private", "-skip-synthesized-members",
                         "-output-dir", output.path, "-I", moduleFile.deletingLastPathComponent().path]
        let pairs: Set<String> = ["-sdk", "-target", "-target-variant", "-I", "-F", "-Fsystem", "-Isystem", "-Xcc", "-resource-dir", "-swift-version"]
        var position = 0
        while position < job.arguments.count {
            let flag = job.arguments[position]
            if pairs.contains(flag), position + 1 < job.arguments.count {
                // The extractor uses the Clang spelling for the zippered target.
                arguments += [flag == "-target-variant" ? "-clang-target-variant" : flag, job.arguments[position + 1]]
                position += 2
            } else { position += 1 }
        }
        _ = try CommandRunner.run(extractor, arguments, at: directory)
        guard try identity() == before else { throw ImpactError("Built Swift module changed during ancestry extraction") }
        return try parse(Data(contentsOf: output.appendingPathComponent(job.module + ".symbols.json")),
                         module: job.module, sourceRoot: sourceRoot, ownership: ownership)
    }

    static func parse(_ data: Data, module: String, sourceRoot: URL,
                      ownership: Set<String>) throws -> [String: CompilerClassIdentity] {
        struct Document: Decodable {
            struct Module: Decodable { var name: String }
            struct Symbol: Decodable {
                struct Identifier: Decodable { var precise: String }
                struct Kind: Decodable { var identifier: String }
                struct Location: Decodable {
                    struct Position: Decodable { var line: Int }
                    var uri: String; var position: Position
                }
                var identifier: Identifier; var kind: Kind; var pathComponents: [String]; var location: Location?
            }
            struct Relationship: Decodable { var kind: String; var source: String; var target: String }
            var module: Module; var symbols: [Symbol]; var relationships: [Relationship]
        }
        let document = try JSONDecoder().decode(Document.self, from: data)
        guard document.module.name == module else { throw ImpactError("Compiler ancestry module mismatch") }
        let parents = Dictionary(grouping: document.relationships.filter { $0.kind == "inheritsFrom" }, by: \.source)
        var result: [String: CompilerClassIdentity] = [:]
        var ambiguous = Set<String>()
        for symbol in document.symbols where symbol.kind.identifier == "swift.class" {
            guard let location = symbol.location, let url = URL(string: location.uri), url.isFileURL,
                  let parent = parents[symbol.identifier.precise], parent.count == 1,
                  !symbol.pathComponents.isEmpty, location.position.line >= 0 else { continue }
            let root = sourceRoot.resolvingSymlinksInPath().path + "/"
            let absolute = url.resolvingSymlinksInPath().path
            guard absolute.hasPrefix(root) else { continue }
            let path = String(absolute.dropFirst(root.count))
            guard ownership.contains(path) else { continue }
            let key = module + "." + symbol.pathComponents.joined(separator: ".")
            let identity = CompilerClassIdentity(symbol: symbol.identifier.precise, superclass: parent[0].target,
                                                 path: path, line: location.position.line + 1)
            if result[key] != nil { ambiguous.insert(key) }
            result[key] = identity
        }
        for key in ambiguous { result.removeValue(forKey: key) }
        return result
    }
}
