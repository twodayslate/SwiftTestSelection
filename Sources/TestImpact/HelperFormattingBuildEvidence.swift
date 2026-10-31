// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
import Foundation

/// Stable effective build inputs, authenticated against the captured raw files.
/// Keeping raw digests outside the review fingerprint permits equivalent
/// recaptures without accepting changed flags or stale derived evidence.
public struct HelperFormattingBuildEvidence: Codable, Sendable {
    public var version = 1
    public var fingerprint: String
    public var buildLogDigest: String
    public var buildSettingsDigest: String

    func matches(_ artifact: XcodeBuildArtifact) -> Bool {
        version == 1 && !fingerprint.isEmpty && !buildLogDigest.isEmpty && !buildSettingsDigest.isEmpty &&
            buildLogDigest == artifact.buildLogDigest && buildSettingsDigest == artifact.buildSettingsDigest
    }

    static func capture(log: Data, settings: Data, source: URL, derived: URL) throws -> Self {
        guard let text = String(data: log, encoding: .utf8), !settings.isEmpty else {
            throw ImpactError("Missing formatting review build inputs")
        }
        let decoded = try JSONDecoder().decode([XcodeBuildSettings].self, from: settings)
        guard !decoded.isEmpty, decoded.allSatisfy({ !$0.buildSettings.isEmpty }) else {
            throw ImpactError("Missing effective build settings for formatting review")
        }
        var directory = source
        var commands = Set<Data>()
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        func absolute(_ path: String, at directory: URL) -> URL {
            URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: directory.path, isDirectory: true)).standardizedFileURL
        }
        func expand(_ args: [String], at directory: URL, visited: Set<String> = []) throws -> [String] {
            var result: [String] = []
            for arg in args {
                guard arg.hasPrefix("@") else { result.append(arg); continue }
                let file = absolute(String(arg.dropFirst()), at: directory).resolvingSymlinksInPath()
                guard visited.count < 64, !visited.contains(file.path) else { throw ImpactError("Recursive formatting review response file") }
                let contents = try XcodeSourceFileList.parse(String(contentsOf: file, encoding: .utf8))
                result += try expand(contents, at: directory, visited: visited.union([file.path]))
            }
            return result
        }
        func normalize(_ data: Data) throws -> Data {
            // Distinct tokens preserve source-vs-product path identity. Only
            // proven root paths are rewritten, using existing boundary rules.
            let first = try XcodeGraphCache.normalizedSettings(data, workspace: derived)
            let renamed = Data(String(decoding: first, as: UTF8.self).replacingOccurrences(of: "<CACHE-WORK>", with: "<FORMATTING-DERIVED>").utf8)
            let second = try XcodeGraphCache.normalizedSettings(renamed, workspace: source)
            return Data(String(decoding: second, as: UTF8.self).replacingOccurrences(of: "<CACHE-WORK>", with: "<FORMATTING-SOURCE>").utf8)
        }
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("cd ") {
                let paths = try XcodeSourceFileList.parse(String(line.dropFirst(3)))
                guard paths.count == 1 else { throw ImpactError("Ambiguous compiler working directory") }
                directory = absolute(paths[0], at: source)
            }
            guard let marker = line.range(of: "builtin-SwiftDriver -- ") else { continue }
            let args = try expand(XcodeSourceFileList.parse(String(line[marker.upperBound...])), at: directory)
            guard let module = args.firstIndex(of: "-module-name"), module + 1 < args.count else {
                throw ImpactError("Missing compiler module identity for formatting review")
            }
            var working = directory
            if let i = args.lastIndex(of: "-working-directory") {
                guard i + 1 < args.count else { throw ImpactError("Missing compiler working directory") }
                working = absolute(args[i + 1], at: directory)
            }
            // Store ordered arguments as indexed entries: the settings helper
            // sorts JSON arrays, but compiler argument order is semantic.
            var row = ["directory": working.path]
            for (i, arg) in args.enumerated() { row[String(format: "arg%08d", i)] = arg }
            for i in args.indices where args[i] == "-filelist" {
                guard i + 1 < args.count else { throw ImpactError("Missing compiler source list") }
                let file = absolute(args[i + 1], at: working)
                let paths = try String(contentsOf: file, encoding: .utf8).split(whereSeparator: \.isNewline)
                for (offset, path) in paths.enumerated() {
                    row[String(format: "list%08d-%08d", i, offset)] = absolute(String(path), at: working).path
                }
            }
            commands.insert(try normalize(encoder.encode(row)))
        }
        guard !commands.isEmpty else { throw ImpactError("Missing compiler invocations for formatting review") }
        let commandDigests = commands.map(XcodeGraphCache.digest).sorted().joined(separator: "\n")
        let fingerprint = try XcodeGraphCache.key(["version": "1", "settings": XcodeGraphCache.digest(normalize(settings)), "compilerInvocations": commandDigests])
        return .init(fingerprint: fingerprint, buildLogDigest: XcodeGraphCache.digest(log), buildSettingsDigest: XcodeGraphCache.digest(settings))
    }
}
