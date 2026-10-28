// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation

extension UIFeatureMappings {
    /// Explicit selection policy over direct semantic changes in the whole comparison.
    public indirect enum Condition: Codable, Sendable {
        case all([Condition]), any([Condition])
        case symbolChanged(String), sourceChanged(String)

        private struct Key: CodingKey {
            var stringValue: String
            var intValue: Int? { nil }
            init(_ value: String) { stringValue = value }
            init?(stringValue: String) { self.init(stringValue) }
            init?(intValue: Int) { return nil }
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: Key.self)
            guard container.allKeys.count == 1, let key = container.allKeys.first else {
                throw ImpactError("A UI condition must have exactly one operator")
            }
            switch key.stringValue {
            case "all": self = .all(try container.decode([Condition].self, forKey: key))
            case "any": self = .any(try container.decode([Condition].self, forKey: key))
            case "symbolChanged": self = .symbolChanged(try container.decode(String.self, forKey: key))
            case "sourceChanged": self = .sourceChanged(try container.decode(String.self, forKey: key))
            default: throw ImpactError("Unsupported UI condition operator: \(key.stringValue)")
            }
            try validate()
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: Key.self)
            switch self {
            case .all(let children), .any(let children): try container.encode(children, forKey: Key(operation))
            case .symbolChanged(let pattern), .sourceChanged(let pattern): try container.encode(pattern, forKey: Key(operation))
            }
        }

        func validate() throws {
            switch self {
            case .all(let children), .any(let children):
                guard !children.isEmpty else { throw ImpactError("UI condition \(operation) must not be empty") }
                for child in children { try child.validate() }
            case .symbolChanged(let pattern), .sourceChanged(let pattern):
                guard !pattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw ImpactError("UI condition patterns must not be empty")
                }
                if case .sourceChanged = self {
                    guard !pattern.hasPrefix("/"), !pattern.split(separator: "/").contains("..") else {
                        throw ImpactError("sourceChanged requires a repository-relative path pattern")
                    }
                }
            }
        }

        var operation: String {
            switch self {
            case .all: return "all"
            case .any: return "any"
            case .symbolChanged: return "symbolChanged"
            case .sourceChanged: return "sourceChanged"
            }
        }
        var symbolPatterns: [String] {
            switch self {
            case .all(let children), .any(let children): return children.flatMap(\.symbolPatterns)
            case .symbolChanged(let pattern): return [pattern]
            case .sourceChanged: return []
            }
        }
        var sourcePatterns: [String] {
            switch self {
            case .all(let children), .any(let children): return children.flatMap(\.sourcePatterns)
            case .sourceChanged(let pattern): return [pattern]
            case .symbolChanged: return []
            }
        }
    }
}

public struct UIConditionResult: Codable, Sendable {
    public enum Status: String, Codable, Sendable { case matched, notMatched, unresolved }
    public var operation: String
    public var pattern: String?
    public var status: Status
    /// Module-qualified symbols or repository-relative paths, tagged with their revision.
    public var changes: [String]
    public var children: [UIConditionResult]
    public var reason: String?

    var explanation: String {
        let operand = pattern ?? children.map(\.explanation).joined(separator: ", ")
        return "\(operation)(\(operand)): \(status.rawValue)" +
            (changes.isEmpty ? "" : " [" + changes.joined(separator: ", ") + "]") +
            (reason.map { " (" + $0 + ")" } ?? "")
    }
}

public struct UIConditionDecision: Codable, Sendable {
    public var feature: String
    public var revision: String
    public var result: UIConditionResult
}

/// Uses the selector's already-computed semantic units; never traverses callers
/// to satisfy a predicate. Resolution spans both sides so deleted symbols remain
/// valid operands; strict validation separately checks only the head inventory.
struct UIConditionContext {
    struct Side {
        var revision: String
        var snapshot: XcodeTestGraph
        var changed: [SourceUnit]
        var unitsByFile: [String: [SourceUnit]]
        var changedKeys: Set<String>
        var sourcePaths: Set<String>

        init(revision: String, snapshot: XcodeTestGraph, changed: [SourceUnit]) {
            self.revision = revision; self.snapshot = snapshot; self.changed = changed
            unitsByFile = Dictionary(grouping: snapshot.sources.values.flatMap(\.units), by: { $0.region.path })
            changedKeys = Set(changed.map { $0.key + "@" + $0.region.path })
            // Captures key snapshots by module:path; legacy callers may use
            // bare paths. Include empty files, which have no source units.
            let modules = Set(snapshot.modules.values)
            sourcePaths = Set(snapshot.sources.keys.map { key in
                guard let separator = key.firstIndex(of: ":"), modules.contains(String(key[..<separator])) else { return key }
                return String(key[key.index(after: separator)...])
            }).union(unitsByFile.keys)
        }

        func hasSourceSnapshot(path: String, module: String?) -> Bool {
            if let module, snapshot.sources[module + ":" + path] != nil { return true }
            guard let legacy = snapshot.sources[path] else { return false }
            // A shared file captured for one module cannot prove that another
            // owning module's source evidence is present.
            guard let module, !legacy.units.isEmpty else { return true }
            return legacy.units.contains { $0.key.hasPrefix(module + ":") && $0.region.path == path }
        }
    }
    var sides: [Side]
    var unavailableReason: String?

    func evaluate(_ condition: UIFeatureMappings.Condition) -> UIConditionResult {
        do { try condition.validate() }
        catch { return .init(operation: condition.operation, status: .unresolved, changes: [], children: [], reason: String(describing: error)) }
        switch condition {
        case .all(let conditions), .any(let conditions):
            // Resolve every leaf, including branches that cannot change the truth value.
            let children = conditions.map(evaluate)
            let status: UIConditionResult.Status
            if children.contains(where: { $0.status == .unresolved }) { status = .unresolved }
            else if case .all = condition { status = children.allSatisfy { $0.status == .matched } ? .matched : .notMatched }
            else { status = children.contains { $0.status == .matched } ? .matched : .notMatched }
            return .init(operation: condition.operation, status: status, changes: [], children: children)
        case .symbolChanged(let pattern), .sourceChanged(let pattern):
            var resolved = false, changes = Set<String>()
            var reason = unavailableReason
            for side in sides {
                if side.snapshot.dependencies == nil { reason = "Missing \(side.revision) compiler evidence" }
                if !side.snapshot.diagnostics.isEmpty || !(side.snapshot.dependencies?.diagnostics.isEmpty ?? true) ||
                    side.snapshot.sources.values.contains(where: { !$0.diagnostics.isEmpty }) {
                    reason = "Incomplete \(side.revision) compiler/source evidence"
                }
                switch condition {
                case .sourceChanged:
                    resolved = resolved || side.sourcePaths.contains { UIFeatureMappings.matches($0, pattern: pattern) }
                    if side.snapshot.targets.contains(where: { target in
                        target.sourceFiles.contains { path in
                            UIFeatureMappings.matches(path, pattern: pattern) &&
                                !side.hasSourceSnapshot(path: path, module: side.snapshot.modules[target.name])
                        }
                    }) {
                        reason = "Missing source snapshot for a matching path in \(side.revision)"
                    }
                    if side.snapshot.unsupportedSourceInputs?.values.flatMap({ $0 }).contains(where: { UIFeatureMappings.matches($0, pattern: pattern) }) == true {
                        reason = "Unsupported source evidence in \(side.revision)"
                    }
                    for unit in side.changed where UIFeatureMappings.matches(unit.region.path, pattern: pattern) {
                        changes.insert(side.revision + ":" + unit.region.path)
                    }
                case .symbolChanged:
                    let nodes = side.snapshot.dependencies?.functions.values.filter {
                        UIFeatureMappings.matches($0.module + "." + $0.name, pattern: pattern)
                    } ?? []
                    resolved = resolved || !nodes.isEmpty
                    for node in nodes {
                        let paths = Set(node.regions.map(\.path))
                        let candidates: [SourceUnit] = paths.flatMap { side.unitsByFile[$0] ?? [] }
                        let units = candidates.filter { unit in
                            guard unit.kind == "function", node.module == String(unit.key.prefix(while: { $0 != ":" })) else { return false }
                            return node.regions.contains { $0.path == unit.region.path && $0.startLine >= unit.region.startLine && $0.startLine <= unit.region.endLine }
                        }
                        if units.isEmpty { reason = "No source declaration evidence for \(node.module).\(node.name) in \(side.revision)" }
                        if units.count > 1 { reason = "Ambiguous source declaration evidence for \(node.module).\(node.name) in \(side.revision)" }
                        if !(side.snapshot.unsupportedSourceInputs?[node.module]?.isEmpty ?? true) {
                            reason = "Unsupported source evidence for \(node.module) in \(side.revision)"
                        }
                        if units.contains(where: { side.changedKeys.contains($0.key + "@" + $0.region.path) }) {
                            changes.insert(side.revision + ":" + node.module + "." + node.name)
                        }
                    }
                default: break
                }
            }
            if !resolved { reason = "Pattern did not resolve on either comparison side in this build" }
            return .init(operation: condition.operation, pattern: pattern,
                status: reason != nil ? .unresolved : changes.isEmpty ? .notMatched : .matched,
                changes: changes.sorted(), children: [], reason: reason)
        }
    }
}
