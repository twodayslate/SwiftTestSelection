// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation

/// Owned by one synchronous selection invocation. Only immutable Git evidence
/// and native syntax are shared; scope policy and diagnostics are never cached.
/// The repository and resolved commit bind every entry. Parser identity is the
/// running executable: this cache is neither serialized nor reused across runs.
final class XcodeBaseSourceCache {
    struct Counts: Equatable {
        var blobReads = 0
        var blobHits = 0
        var treeReads = 0
        var treeHits = 0
        var parses = 0
        var parseHits = 0

        var detail: String {
            "blobReads=\(blobReads), blobHits=\(blobHits), treeReads=\(treeReads), treeHits=\(treeHits), parses=\(parses), parseHits=\(parseHits)"
        }
    }
    private struct SyntaxKey: Hashable {
        let path: String
        let module: String
    }
    private enum Evidence<Value> {
        case available(Value)
        case unavailable
        var value: Value? { if case .available(let value) = self { value } else { nil } }
    }
    private let root: URL
    private let requestedRevision: String
    private let revision: String?
    private var blobs: [String: Evidence<Data>] = [:]
    private var tree: Evidence<Set<String>>?
    private var syntax: [SyntaxKey: SwiftSourceSnapshot] = [:]
    private(set) var counts = Counts()

    init(root: URL, base: String) throws {
        self.root = root.standardizedFileURL
        requestedRevision = base
        // Pin symbolic references once, including a failed resolution. Later
        // ref movement must not mix revisions inside one evidence set.
        let resolved = try CommandRunner.run("git", ["rev-parse", "--verify", "--end-of-options", base + "^{commit}"], at: root, allowFailure: true)
        revision = resolved.status == 0 ? resolved.text.trimmingCharacters(in: .whitespacesAndNewlines) : nil
    }

    func validate(root: URL, base: String) throws {
        guard root.standardizedFileURL == self.root, base == requestedRevision else {
            throw ImpactError("Base source cache belongs to a different repository or comparison")
        }
    }

    func paths() throws -> Set<String>? {
        if let tree { counts.treeHits += 1; return tree.value }
        guard let revision else { tree = .unavailable; return nil }
        counts.treeReads += 1
        let listing = try CommandRunner.run("git", ["ls-tree", "-r", "--name-only", "-z", revision, "--"], at: root, allowFailure: true)
        tree = listing.status == 0
            ? .available(Set(listing.stdout.split(separator: 0).map { String(decoding: $0, as: UTF8.self) })) : .unavailable
        return tree?.value
    }

    func content(path: String) throws -> Data? {
        if let blob = blobs[path] { counts.blobHits += 1; return blob.value }
        guard let revision else { blobs[path] = .unavailable; return nil }
        counts.blobReads += 1
        let output = try CommandRunner.run("git", ["show", revision + ":" + path], at: root, allowFailure: true)
        let blob: Evidence<Data> = output.status == 0 ? .available(output.stdout) : .unavailable
        blobs[path] = blob
        return blob.value
    }

    func snapshot(path: String, module: String) throws -> SwiftSourceSnapshot? {
        let key = SyntaxKey(path: path, module: module)
        if let snapshot = syntax[key] { counts.parseHits += 1; return snapshot }
        guard let data = try content(path: path), let text = String(data: data, encoding: .utf8) else { return nil }
        counts.parses += 1
        let snapshot = SwiftSourceSnapshot.parse(text, path: path, module: module)
        syntax[key] = snapshot
        return snapshot
    }
}
