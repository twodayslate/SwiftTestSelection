// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

struct RevisionComparison {
    var base: String
    var head: String?
    var mode: String

    init(base: String, head: String?, mergeBase: Bool, root: URL) throws {
        let resolvedBase = try GitChanges.revision(base, at: root)
        self.head = try head.map { try GitChanges.revision($0, at: root) }
        if mergeBase {
            let anchor = try self.head ?? GitChanges.revision("HEAD", at: root)
            // --all rejects ambiguous criss-cross histories rather than choosing
            // an arbitrary ancestor and reporting misleading PR coverage.
            let bases = try CommandRunner.run("git", ["merge-base", "--all", resolvedBase, anchor], at: root).text.split(separator: "\n")
            guard bases.count == 1 else { throw ImpactError("Comparison requires a unique merge base.") }
            self.base = String(bases[0])
        } else { self.base = resolvedBase }
        mode = mergeBase ? "merge-base" : "direct"
    }
}

extension GitChanges {
    static func readComparison(base: String, head: String?, at root: URL) throws -> [FileChange] {
        let revisions = [base] + (head.map { [$0] } ?? [])
        var changes: [FileChange]
        if head == nil { changes = try read(base: base, at: root) }
        else {
            let names = try CommandRunner.run("git", ["diff", "--no-ext-diff", "--no-textconv", "--no-renames", "--name-only", "-z"] + revisions + ["--"], at: root).stdout
            changes = try names.split(separator: 0).map { raw in
                let path = String(decoding: raw, as: UTF8.self)
                let diff = try CommandRunner.run("git", ["--literal-pathspecs", "diff", "--no-ext-diff", "--no-textconv", "--no-renames", "--unified=0"] + revisions + ["--", path], at: root).text
                return parseHunks(diff, path: path)
            }
        }
        let status = try CommandRunner.run("git", ["diff", "--no-ext-diff", "--no-textconv", "--find-renames=100%", "--name-status", "-z"] + revisions + ["--"], at: root).stdout
            .split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
        var moves: [String: String] = [:]
        var index = 0
        while index < status.count {
            let kind = status[index]; index += 1
            if kind.hasPrefix("R"), index + 1 < status.count {
                if kind == "R100" { moves[status[index]] = status[index + 1] }
                index += 2
            } else { index += 1 }
        }
        for (old, new) in moves {
            changes.removeAll { $0.path == old || $0.path == new }
            var move = FileChange(path: new)
            move.previousPath = old
            move.isPureMove = true
            changes.append(move)
        }
        // A normal Xcode file move also updates PBXFileReference paths. Ignore
        // only proven reference-path substitutions; other project edits remain
        // build/configuration changes and trigger fallback.
        if !moves.isEmpty {
            for index in changes.indices where changes[index].path.hasSuffix(".pbxproj") {
                let path = changes[index].path
                let before = try? CommandRunner.run("git", ["show", base + ":" + path], at: root).stdout
                let after: Data?
                if let head { after = try? CommandRunner.run("git", ["show", head + ":" + path], at: root).stdout }
                else { after = try? Data(contentsOf: root.appendingPathComponent(path)) }
                if let before, let after, projectMoveOnly(before: before, after: after, moves: moves) {
                    changes[index].isPureMove = true
                }
            }
        }
        return changes.sorted { $0.path < $1.path }
    }

    private static func projectMoveOnly(before: Data, after: Data, moves: [String: String]) -> Bool {
        guard var old = try? PropertyListSerialization.propertyList(from: before, format: nil) as? [String: Any],
              let new = try? PropertyListSerialization.propertyList(from: after, format: nil) as? [String: Any],
              var objects = old["objects"] as? [String: [String: Any]] else { return false }
        for (id, var object) in objects where object["isa"] as? String == "PBXFileReference" {
            for field in ["path", "name"] {
                guard let value = object[field] as? String else { continue }
                for (source, destination) in moves {
                    let from = source.split(separator: "/"), to = destination.split(separator: "/")
                    for count in 1...from.count where count <= to.count {
                        if value == from.suffix(count).joined(separator: "/") { object[field] = to.suffix(count).joined(separator: "/") }
                    }
                }
            }
            objects[id] = object
        }
        old["objects"] = objects
        return NSDictionary(dictionary: old).isEqual(to: new)
    }
}
