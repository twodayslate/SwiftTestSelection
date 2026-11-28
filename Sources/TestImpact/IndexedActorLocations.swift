// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
import CompilerIndex
import Foundation
import SwiftParser
import SwiftSyntax

/// Alternate position fingerprints when the build's primary-file index resolved
/// every bare @MainActor to Swift.MainActor. Keep native syntax for comparisons
/// in which the other revision's lookup is unknown.
struct IndexedActorLocations: Codable, Equatable, Sendable {
    struct Unit: Codable, Equatable, Sendable {
        let index: Int
        let key: String
        let callers: [String: String]?
        let names: Set<String>?
        let builders: [String: String]?
    }
    let triviaIdentity: String
    let remainingActorInputs: [String]?
    let units: [Unit]

    private final class References {
        let requested: Set<UInt64>
        init(_ requested: Set<UInt64>) { self.requested = requested }
        var actors = Set<UInt64>()
        var others = Set<UInt64>()
    }

    static func capture(file: URL, path: String, module: String, snapshot: SwiftSourceSnapshot,
                        compiler: URL, store: String, output: String) -> Self? {
        guard let text = try? String(contentsOf: file, encoding: .utf8), !text.contains("#sourceLocation") else { return nil }
        let tree = Parser.parse(source: text)
        guard !tree.hasError else { return nil }
        let converter = SourceLocationConverter(fileName: path, tree: tree)
        let positions = Set(tree.tokens(viewMode: .sourceAccurate).compactMap { token -> UInt64? in
            guard token.tokenKind == .atSign, let attr = token.parent?.as(AttributeSyntax.self), attr.isBareMainActor else { return nil }
            let point = converter.location(for: attr.attributeName.positionAfterSkippingLeadingTrivia)
            return UInt64(point.line) << 32 | UInt64(point.column)
        })
        guard !positions.isEmpty else { return nil }
        let refs = References(positions)
        let library = compiler.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("lib/libIndexStore.dylib")
        let read = sts_read_index(library.path, store, output, module, file.path, Unmanaged.passUnretained(refs).toOpaque()) {
            context, line, column, usr, length, roles in
            guard let context else { return }
            let refs = Unmanaged<References>.fromOpaque(context).takeUnretainedValue()
            let point = UInt64(line) << 32 | UInt64(column)
            guard refs.requested.contains(point) else { return }
            // INDEXSTORE_SYMBOL_ROLE_REFERENCE and the compiler USR for Swift.MainActor.
            if roles & 4 != 0, length == 5, let usr, memcmp(usr, "s:ScM", 5) == 0 {
                refs.actors.insert(point)
            } else { refs.others.insert(point) }
        }
        guard read, positions.isSubset(of: refs.actors), positions.isDisjoint(with: refs.others) else { return nil }
        return project(text, tree: tree, path: path, module: module, snapshot: snapshot)
    }

    static func project(_ text: String, tree: SourceFileSyntax, path: String, module: String, snapshot: SwiftSourceSnapshot) -> Self? {
        guard !tree.hasError else { return nil }
        let native = SwiftSourceSnapshot.parse(text, path: path, module: module, tree: tree, indexedMainActor: true)
        guard let blobs = native.sourceBlobIDs, snapshot.sourceBlobIDs == blobs, native.diagnostics.isEmpty,
              native.units.count == snapshot.units.count else { return nil }
        var changes: [Unit] = []
        for (index, unit) in native.units.enumerated() {
            let old = snapshot.units[index]
            guard old.key == unit.key, old.region == unit.region else { return nil }
            if unit.builderLocations != old.builderLocations || unit.callerLocations != old.callerLocations || unit.invocationNames != old.invocationNames {
                changes.append(.init(index: index, key: unit.key, callers: unit.callerLocations, names: unit.invocationNames, builders: unit.builderLocations))
            }
        }
        // Only newline trivia can vary. Preserve token kinds (including operator
        // fixity), literal contents, comments, and every other trivia byte.
        var identity = Data()
        func add(_ value: String) { identity.append(contentsOf: "\(value.utf8.count):\(value)".utf8) }
        func trivia(_ pieces: Trivia) {
            for piece in pieces {
                if case .newlines = piece { add("\n") } else { add(Trivia(pieces: [piece]).description) }
            }
            add("")
        }
        for token in tree.tokens(viewMode: .sourceAccurate) {
            trivia(token.leadingTrivia)
            add(String(describing: token.tokenKind))
            add(token.text)
            trivia(token.trailingTrivia)
        }
        return Self(triviaIdentity: XcodeGraphCache.digest(identity), remainingActorInputs: native.attachedAttributeInputs?["MainActor"], units: changes)
    }

    /// Historical lookup can reuse the head binding only for a complete, single-
    /// file trivia edit. Require identical inputs at every other expansion site.
    func historical(_ text: String, path: String, module: String, before: SwiftSourceSnapshot, after: SwiftSourceSnapshot) -> Self? {
        guard let old = Self.project(text, tree: Parser.parse(source: text), path: path, module: module, snapshot: before),
              old.triviaIdentity == triviaIdentity else { return nil }
        var beforeInputs = before.attachedAttributeInputs, afterInputs = after.attachedAttributeInputs
        beforeInputs?["MainActor"] = old.remainingActorInputs
        afterInputs?["MainActor"] = remainingActorInputs
        return beforeInputs == afterInputs ? old : nil
    }

    func apply(to snapshot: inout SwiftSourceSnapshot) {
        guard units.allSatisfy({ snapshot.units.indices.contains($0.index) && snapshot.units[$0.index].key == $0.key }) else { return }
        snapshot.attachedAttributeInputs?["MainActor"] = remainingActorInputs
        for field in units {
            snapshot.units[field.index].callerLocations = field.callers
            snapshot.units[field.index].invocationNames = field.names
            snapshot.units[field.index].builderLocations = field.builders
        }
    }

    static func compare(base: inout [String: SwiftSourceSnapshot], head: inout [String: SwiftSourceSnapshot], paths: Set<String>) {
        for (key, file) in head where file.indexedActor != nil {
            guard file.parserVersion == SwiftSourceSnapshot.currentParserVersion, base[key]?.parserVersion == file.parserVersion,
                  let id = file.sourceIdentity(storedAs: key), paths.contains(id.path),
                  let old = base[key]?.indexedActor, let new = file.indexedActor else { continue }
            old.apply(to: &base[key]!)
            new.apply(to: &head[key]!)
        }
    }
}
