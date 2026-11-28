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
        var headSyntaxReuse = 0

        var detail: String {
            "blobReads=\(blobReads), blobHits=\(blobHits), treeReads=\(treeReads), treeHits=\(treeHits), parses=\(parses), parseHits=\(parseHits), headSyntaxReuse=\(headSyntaxReuse)"
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
    private(set) var allBaseSwiftSourcesRegular = false
    private var syntax: [SyntaxKey: SwiftSourceSnapshot] = [:]
    private var macroDeclarations: Evidence<Set<String>>?
    private var runtimeComparisons: [String: HeadOnlyRuntimeSourceEvidence] = [:]
    private(set) var counts = Counts()
    var resolvedRevision: String? { revision }
    func recordHeadSyntaxReuse() { counts.headSyntaxReuse += 1 }

    /// Any historical source can re-export a binary macro or declare a macro
    /// missing from the head inventory. Search the pinned commit independently
    /// of the requested paths. An unknown owner widens the candidate set.
    func historicalMacroNames() throws -> Set<String>? {
        if let macroDeclarations { return macroDeclarations.value }
        guard let revision else { return nil }
        let matches = try CommandRunner.run("git", ["grep", "--no-textconv", "--text", "-l", "-z",
            "-e", "_exported", "-e", "macro", revision, "--", "*.swift"], at: root, allowFailure: true)
        guard matches.status == 0 || matches.status == 1 else { macroDeclarations = .unavailable; return nil }
        var names = Set<String>()
        for record in matches.stdout.split(separator: 0) {
            let prefix = revision + ":"
            guard let entry = String(data: record, encoding: .utf8), entry.hasPrefix(prefix),
                  let data = try content(path: String(entry.dropFirst(prefix.count))),
                  let source = String(data: data, encoding: .utf8),
                  let declared = AttachedMacroInputs.historicalDeclarations(source) else {
                macroDeclarations = .unavailable
                return nil
            }
            names.formUnion(declared)
        }
        macroDeclarations = .available(names)
        return names
    }

    func runtimeEvidence(headRevision: String) throws -> HeadOnlyRuntimeSourceEvidence {
        if let result = runtimeComparisons[headRevision] { return result }
        let result = try HeadOnlyRuntimeSourceEvidence.read(head: headRevision, root: root, cache: self)
        runtimeComparisons[headRevision] = result
        return result
    }

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
        let listing = try CommandRunner.run("git", ["ls-tree", "-r", "-z", revision, "--"], at: root, allowFailure: true)
        guard listing.status == 0 else { tree = .unavailable; return nil }
        var paths = Set<String>(), regular = true
        for record in listing.stdout.split(separator: 0) {
            guard let tab = record.firstIndex(of: 9),
                  let path = String(data: record.suffix(from: tab + 1), encoding: .utf8) else {
                tree = .unavailable
                return nil
            }
            paths.insert(path)
            let mode = record.prefix(upTo: tab)
            if path.hasSuffix(".swift") && !mode.starts(with: "100644 blob ".utf8) && !mode.starts(with: "100755 blob ".utf8) {
                regular = false
            }
        }
        allBaseSwiftSourcesRegular = regular
        tree = .available(paths)
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
