// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation
@testable import TestImpact

// Frozen pre-#79 loader: independent parity oracle, including per-query Git
// reads and parsing. Keep separate from the production cache implementation.
func uncachedHeadOnlySources(current: XcodeTestGraph, changes: [FileChange], base: String, root: URL, mappingPath: String, measurement: (String) -> Void = { _ in }) throws -> XcodeHeadOnlySources {
    var result = XcodeHeadOnlySources(base: current.sources)
    let paths = Set(changes.flatMap { [$0.path] + ($0.previousPath.map { [$0] } ?? []) })
    // Internal SDK extensions are visible throughout their test module. A
    // scoped diff cannot substitute head syntax for changed base callers in
    // other files or targets: removed calls/escapes and overloads must remain
    // visible even when a file's target membership changed at head.
    let callerModules = Set(current.sources.compactMap { key, snapshot -> String? in
        guard let colon = key.firstIndex(of: ":"), paths.contains(String(key[key.index(after: colon)...])),
              snapshot.units.contains(where: { $0.sdkTestHelper != nil || $0.privateTestHelper != nil }) else { return nil }
        return String(key[..<colon])
    })
    var basePaths: Set<String>?
    if !callerModules.isEmpty {
        measurement("treeReads")
        let listing = try CommandRunner.run("git", ["ls-tree", "-r", "--name-only", "-z", base, "--"], at: root, allowFailure: true)
        if listing.status == 0 { basePaths = Set(listing.stdout.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }) }
        else { result.diagnostics.append("Cannot enumerate base sources at \(base)") }
    }
    for key in current.sources.keys.sorted() {
        guard let colon = key.firstIndex(of: ":") else { result.diagnostics.append("Invalid source snapshot key: \(key)"); continue }
        let module = String(key[..<colon]), path = String(key[key.index(after: colon)...])
        guard paths.contains(path) || !callerModules.isEmpty else { continue }
        // New files outside the scope have no old callers to audit. Do not
        // turn a proven absence into an unrelated scope diagnostic.
        if !paths.contains(path), let basePaths, !basePaths.contains(path) {
            result.base.removeValue(forKey: key)
            continue
        }
        measurement("blobReads")
        let data = try CommandRunner.run("git", ["show", base + ":" + path], at: root, allowFailure: true)
        if data.status == 0, let text = String(data: data.stdout, encoding: .utf8) {
            measurement("parses")
            result.base[key] = SwiftSourceSnapshot.parse(text, path: path, module: module)
        } else {
            result.base.removeValue(forKey: key)
            result.diagnostics.append("No base source boundary for \(path) at \(base)")
        }
    }
    if !callerModules.isEmpty {
        // Deleted/out-of-target files cannot be found by iterating the head
        // inventory. Inspect their base syntax without inventing module ownership.
        let captured = Set(current.sources.keys.compactMap { key in key.firstIndex(of: ":").map { String(key[key.index(after: $0)...]) } })
        if let basePaths {
            for path in basePaths.sorted() where path.hasSuffix(".swift") && !captured.contains(path) {
                measurement("blobReads")
                let data = try CommandRunner.run("git", ["show", base + ":" + path], at: root, allowFailure: true)
                if data.status == 0, let text = String(data: data.stdout, encoding: .utf8) {
                    measurement("parses")
                    result.unownedBaseSources[path] = .parse(text, path: path, module: "")
                } else { result.diagnostics.append("Cannot read unowned base source \(path) at \(base)") }
            }
        }
    }
    measurement("blobReads")
    let mapping = try CommandRunner.run("git", ["show", base + ":" + mappingPath], at: root, allowFailure: true)
    if mapping.status == 0 {
        do {
            result.mappings = try JSONDecoder().decode(UIFeatureMappings.self, from: mapping.stdout)
            try result.mappings?.validate()
        } catch { result.diagnostics.append("Invalid base mapping policy: \(error)") }
    }
    return result
}
