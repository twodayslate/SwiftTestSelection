// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

public struct SILModule: Sendable {
    public var functions: [String: FunctionNode]
    public var dispatchTargets: [String: Set<String>]
}

/// A deliberately conservative reader of textual SIL. It retains function
/// references even when they only escape as values and flags indirect execution.
public enum SILParser {
    public static func parse(_ text: String, module: String, sourceRoot: URL) -> SILModule {
        var functions: [String: FunctionNode] = [:]
        var tables: [String: Set<String>] = [:]
        var current: FunctionNode?
        var pendingName = ""
        var pendingLocation: SourceRegion?
        var locations: [String: ClosedRange<Int>] = [:]
        var knownValues = Set<String>()
        let root = sourceRoot.standardizedFileURL.resolvingSymlinksInPath().path + "/"

        func location(_ line: String) -> SourceRegion? {
            guard let fields = Pattern.groups(#"\bloc (?:\* )?"((?:[^"\\]|\\.)+)":([0-9]+):[0-9]+"#, in: line),
                  let lineNumber = Int(fields[1]), lineNumber > 0 else { return nil }
            let rawPath = fields[0].replacingOccurrences(of: #"\""#, with: "\"")
                .replacingOccurrences(of: #"\\"#, with: "\\")
            guard rawPath.hasPrefix("/") else { return nil }
            let path = URL(fileURLWithPath: rawPath).standardizedFileURL.resolvingSymlinksInPath().path
            guard path.hasPrefix(root), !path.dropFirst(root.count).hasPrefix(".build/") else { return nil }
            return SourceRegion(path: String(path.dropFirst(root.count)), startLine: lineNumber, endLine: lineNumber)
        }

        func addLocation(_ region: SourceRegion) {
            if let range = locations[region.path] {
                locations[region.path] = min(range.lowerBound, region.startLine)...max(range.upperBound, region.endLine)
            } else {
                locations[region.path] = region.startLine...region.endLine
            }
        }

        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw).trimmingCharacters(in: .whitespaces)
            if current == nil {
                if line.hasPrefix("// "), !line.hasPrefix("// Isolation:") {
                    let name = String(line.dropFirst(3))
                    pendingName = name.components(separatedBy: ", loc ")[0].components(separatedBy: ", scope ")[0]
                    pendingLocation = location(line)
                }
                if line.hasPrefix("sil "), line.hasSuffix("{"),
                   let match = Pattern.groups(#"@([^\s:]+)\s*:"#, in: line) {
                    current = FunctionNode(id: match[0], module: module, name: pendingName.isEmpty ? match[0] : pendingName)
                    locations = [:]
                    knownValues = []
                    if let pendingLocation { addLocation(pendingLocation) }
                    pendingName = ""
                    pendingLocation = nil
                } else if let match = Pattern.groups(#"#([^\s:]+).*:\s*@([^\s:]+)"#, in: line) {
                    let key = match[0].components(separatedBy: "!")[0]
                    tables[key, default: []].insert(match[1])
                }
                continue
            }

            if line.hasPrefix("} // end sil function") {
                current!.regions = locations.map {
                    SourceRegion(path: $0.key, startLine: $0.value.lowerBound, endLine: $0.value.upperBound)
                }.sorted { ($0.path, $0.startLine) < ($1.path, $1.startLine) }
                functions[current!.id] = current!
                current = nil
                continue
            }
            if let found = location(line) { addLocation(found) }
            if line.hasPrefix("//") { continue }

            if let match = Pattern.groups(#"(%[\w]+) = (?:function_ref|dynamic_function_ref|previous_dynamic_function_ref) @([^\s:]+)"#, in: line) {
                knownValues.insert(match[0])
                current!.dependencies.insert(match[1])
            }
            if let match = Pattern.groups(#"\b(class_method|super_method|witness_method|objc_method|objc_super_method)\b.*#([^\s:]+)"#, in: line) {
                current!.dynamicDeclarations.insert(match[1].components(separatedBy: "!")[0])
                current!.uncertainties.insert("Dynamic dispatch: \(match[0]) \(match[1])")
            }
            // Retain dependency flow through common function-value conversions.
            if let match = Pattern.groups(#"(%[\w]+) = (?:thin_to_thick_function|convert_function|convert_escape_to_noescape|copy_value|move_value|begin_borrow|partial_apply)(?: \[[^\]]*\])* (%[\w]+)"#, in: line), knownValues.contains(match[1]) {
                knownValues.insert(match[0])
            }
            if let match = Pattern.groups(#"\b(?:apply|try_apply|begin_apply)(?: \[[^\]]*\])* (%[\w]+)"#, in: line), !knownValues.contains(match[0]) {
                current!.uncertainties.insert("Indirect function invocation")
            }
            if line.contains("global_addr ") || line.contains("global_value ") || line.contains("ref_element_addr ") {
                current!.uncertainties.insert("Shared state access")
            }
            if line.contains("builtin \""), line.contains("RawPointer") {
                current!.uncertainties.insert("Raw pointer operation")
            }
        }
        return SILModule(functions: functions, dispatchTargets: tables)
    }
}
