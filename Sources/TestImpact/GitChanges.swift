// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation

public struct FileChange: Codable, Sendable {
    public var path: String
    public var oldRegions: [SourceRegion]
    public var newRegions: [SourceRegion]
    public var previousPath: String?
    public var isPureMove: Bool = false
    public var requiresFallback: Bool

    public init(path: String, oldRegions: [SourceRegion] = [], newRegions: [SourceRegion] = [], requiresFallback: Bool = false) {
        self.path = path
        self.oldRegions = oldRegions
        self.newRegions = newRegions
        self.requiresFallback = requiresFallback
    }
}

public enum GitChanges {
    public static func repositoryRoot(at package: URL) throws -> URL {
        let path = try CommandRunner.run("git", ["rev-parse", "--show-toplevel"], at: package).text
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
    }

    public static func revision(_ ref: String, at root: URL) throws -> String {
        try CommandRunner.run("git", ["rev-parse", "--verify", "--end-of-options", ref + "^{commit}"], at: root).text
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Diff base against the current worktree, including staged and untracked files.
    public static func read(base: String, at root: URL) throws -> [FileChange] {
        let tracked = try CommandRunner.run("git", ["diff", "--no-ext-diff", "--no-textconv", "--no-renames", "--name-only", "-z", base, "--"], at: root).stdout
        let untracked = try CommandRunner.run("git", ["ls-files", "--others", "--exclude-standard", "-z"], at: root).stdout
        let newPaths = Set(untracked.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
            .filter { !$0.split(separator: "/").contains(".build") })
        let paths = Set(tracked.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }).union(newPaths)
        return try paths.sorted().map { path in
            if newPaths.contains(path) {
                let url = root.appendingPathComponent(path)
                guard path.hasSuffix(".swift"), let text = try? String(contentsOf: url, encoding: .utf8) else {
                    return FileChange(path: path, requiresFallback: true)
                }
                let lines = max(1, text.split(separator: "\n", omittingEmptySubsequences: false).count - (text.hasSuffix("\n") ? 1 : 0))
                return FileChange(path: path, newRegions: [SourceRegion(path: path, startLine: 1, endLine: lines)])
            }
            let diff = try CommandRunner.run("git", ["--literal-pathspecs", "diff", "--no-ext-diff", "--no-textconv", "--no-renames", "--unified=0", base, "--", path], at: root).text
            return parseHunks(diff, path: path)
        }
    }

    public static func parseHunks(_ diff: String, path: String) -> FileChange {
        var change = FileChange(path: path)
        for line in diff.split(separator: "\n") {
            guard let match = Pattern.groups(#"^@@ -([0-9]+)(?:,([0-9]+))? \+([0-9]+)(?:,([0-9]+))? @@"#, in: String(line)) else { continue }
            let oldStart = Int(match[0])!
            let oldCount = Int(match[1]) ?? 1
            let newStart = Int(match[2])!
            let newCount = Int(match[3]) ?? 1
            if oldCount > 0 {
                change.oldRegions.append(SourceRegion(path: path, startLine: oldStart, endLine: oldStart + oldCount - 1))
            }
            if newCount > 0 {
                change.newRegions.append(SourceRegion(path: path, startLine: newStart, endLine: newStart + newCount - 1))
            }
        }
        change.requiresFallback = change.oldRegions.isEmpty && change.newRegions.isEmpty
        return change
    }

    static func export(base: String, from root: URL, into destination: URL) throws {
        // An archive leaves the user's checkout and Git worktree registry untouched.
        let archive = try CommandRunner.run("git", ["archive", "--format=tar", base], at: root).stdout
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        _ = try CommandRunner.run("tar", ["-xf", "-", "-C", destination.path], at: root, input: archive)
    }
}
