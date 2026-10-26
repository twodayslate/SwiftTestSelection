// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation

public struct SILModule: Codable, Sendable {
    /// Bodies imported from another module; source locations alone cannot prove
    /// definition ownership when multiple modules compile the same file.
    public var importedSymbols: Set<String>? = nil
    /// Shared bodies whose declaration owner may need demangling.
    public var sharedSymbols: Set<String>? = nil
    public var functions: [String: FunctionNode]
    public var dispatchTargets: [String: Set<String>]
    /// Concrete imported conformances, keyed by emitting module and declaration.
    /// SIL display names are not globally unique across compilation units.
    public var externalWitnesses: [String: Set<String>]? = nil
}

/// A deliberately conservative reader of textual SIL. It retains function
/// references even when they only escape as values and flags indirect execution.
public enum SILParser {
    /// In-memory convenience API. File consumers should use `parse(file:module:sourceRoot:)`.
    public static func parse(_ text: String, module: String, sourceRoot: URL) -> SILModule {
        let state = State(module: module, sourceRoot: sourceRoot)
        var cursor = text.startIndex
        while cursor < text.endIndex {
            withSILAutoreleasePool {
                for _ in 0..<512 where cursor < text.endIndex {
                    let end = text[cursor...].firstIndex { $0 == "\n" || $0 == "\r\n" } ?? text.endIndex
                    state.consume(String(text[cursor..<end]))
                    cursor = end == text.endIndex ? end : text.index(after: end)
                }
            }
        }
        return state.result
    }

    /// Reads bounded chunks; transient storage scales with the longest line, not
    /// the SIL file. Graph nodes and edges necessarily remain resident.
    public static func parse(file: URL, module: String, sourceRoot: URL) throws -> SILModule {
        let state = State(module: module, sourceRoot: sourceRoot)
        try SILLineReader.read(file: file) { state.consume($0) }
        return state.result
    }

    /// Read binders from the function-type prefix only. Type applications in
    /// parameters/results (Array<Element>) do not declare generic parameters.
    /// Unknown/truncated syntax disables concrete narrowing for this function.
    static func genericParameters(in header: String) -> Set<String>? {
        guard let marker = header.range(of: ": $") else { return nil }
        var cursor = marker.upperBound
        var names = Set<String>()
        func skipWhitespace() {
            while cursor < header.endIndex, header[cursor].isWhitespace { cursor = header.index(after: cursor) }
        }
        func group(_ open: Character, _ close: Character) -> Substring? {
            let start = header.index(after: cursor)
            var depth = 1, quoted = false, escaped = false
            cursor = start
            while cursor < header.endIndex {
                let character = header[cursor]
                if quoted {
                    if escaped { escaped = false }
                    else if character == "\\" { escaped = true }
                    else if character == "\"" { quoted = false }
                } else if character == "\"" { quoted = true }
                else if character == open { depth += 1 }
                else if character == close && !(close == ">" && header[header.index(before: cursor)] == "-") {
                    depth -= 1
                    if depth == 0 {
                        let contents = header[start..<cursor]
                        cursor = header.index(after: cursor)
                        return contents
                    }
                }
                cursor = header.index(after: cursor)
            }
            return nil
        }
        while cursor < header.endIndex {
            skipWhitespace()
            guard cursor < header.endIndex else { return nil }
            switch header[cursor] {
            case "@":
                cursor = header.index(after: cursor)
                let start = cursor
                while cursor < header.endIndex, header[cursor].isLetter || header[cursor].isNumber || header[cursor] == "_" {
                    cursor = header.index(after: cursor)
                }
                guard cursor != start else { return nil }
                if cursor < header.endIndex, header[cursor] == "(" {
                    guard group("(", ")") != nil else { return nil }
                }
            case "<":
                guard let signature = group("<", ">") else { return nil }
                let binders = signature.components(separatedBy: " where ")[0]
                var depth = 0
                let parameters = binders.split { character in
                    if character == "<" { depth += 1 }
                    else if character == ">" { depth -= 1 }
                    return character == "," && depth == 0
                }
                for parameter in parameters {
                    var name = parameter.trimmingCharacters(in: .whitespaces)
                    if name.hasPrefix("each ") { name = String(name.dropFirst(5)) }
                    name = name.components(separatedBy: ":")[0].trimmingCharacters(in: .whitespaces)
                    guard !name.isEmpty, name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { return nil }
                    names.insert(name)
                }
            case "(": return names
            default: return nil
            }
        }
        return nil
    }

    private enum Expressions {
        static let location = try! NSRegularExpression(pattern: #"\bloc (?:\* )?"((?:[^"\\]|\\.)+)":([0-9]+):[0-9]+"#)
        static let function = try! NSRegularExpression(pattern: #"@([^\s:]+)\s*:"#)
        static let dispatch = try! NSRegularExpression(pattern: #"#([^\s:]+).*:\s*@([^\s:]+)"#)
        static let reference = try! NSRegularExpression(pattern: #"(%[\w]+) = (?:function_ref|dynamic_function_ref|previous_dynamic_function_ref) @([^\s:]+)"#)
        static let method = try! NSRegularExpression(pattern: #"\b(class_method|super_method|witness_method|objc_method|objc_super_method)\b.*#([^\s:]+)"#)
        static let witnessType = try! NSRegularExpression(pattern: #"\bwitness_method \$([\w.]+),"#)
        static let witnessTable = try! NSRegularExpression(pattern: #"^sil_witness_table(?: [\w]+)* ([\w.]+): [\w.]+ module [\w]+ \{"#)
        static let externalWitness = try! NSRegularExpression(pattern: #"^sil_witness_table(?: [\w]+| \[[^\]]+\])* ([\w.]+): ([\w.]+) module ([\w]+)$"#)
        static let value = try! NSRegularExpression(pattern: #"^(%[\w]+) ="#)
        static let conversion = try! NSRegularExpression(pattern: #"(%[\w]+) = (?:thin_to_thick_function|convert_function|convert_escape_to_noescape|copy_value|move_value|begin_borrow|partial_apply)(?: \[[^\]]*\])* (%[\w]+)"#)
        static let apply = try! NSRegularExpression(pattern: #"\b(?:apply|try_apply|begin_apply)(?: \[[^\]]*\])* (%[\w]+)"#)
    }

    private final class State {
        let module: String
        let root: String
        // Empty values cache paths outside the source root as well.
        var paths: [String: String] = [:]
        init(module: String, sourceRoot: URL) {
            self.module = module
            self.root = sourceRoot.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        }
        var result: SILModule { SILModule(importedSymbols: importedSymbols, sharedSymbols: sharedSymbols, functions: functions, dispatchTargets: tables, externalWitnesses: externalWitnesses) }

        var importedSymbols = Set<String>()
        var sharedSymbols = Set<String>()
        var functions: [String: FunctionNode] = [:]
        var tables: [String: Set<String>] = [:]
        var externalWitnesses: [String: Set<String>] = [:]
        var current: FunctionNode?
        var pendingName = ""
        var pendingLocation: SourceRegion?
        var locations: [String: ClosedRange<Int>] = [:]
        var knownValues = Set<String>()
        var witnessType: String?
        var genericParameters: Set<String>?

        func location(_ line: String) -> SourceRegion? {
            guard line.containsASCII("loc "), let fields = Pattern.groups(Expressions.location, in: line),
                  let lineNumber = Int(fields[1]), lineNumber > 0 else { return nil }
            let rawPath = fields[0].replacingOccurrences(of: #"\""#, with: "\"")
                .replacingOccurrences(of: #"\\"#, with: "\\")
            guard rawPath.hasPrefix("/") else { return nil }
            let relative: String
            if let cached = paths[rawPath] {
                relative = cached
            } else {
                let path = URL(fileURLWithPath: rawPath).standardizedFileURL.resolvingSymlinksInPath().path
                relative = path.hasPrefix(root) && !path.dropFirst(root.count).hasPrefix(".build/")
                    ? String(path.dropFirst(root.count)) : ""
                // Bound this optimization even for generated SIL with many paths.
                if paths.count >= 4096 { paths.removeAll(keepingCapacity: true) }
                paths[rawPath] = relative
            }
            guard !relative.isEmpty else { return nil }
            return SourceRegion(path: relative, startLine: lineNumber, endLine: lineNumber)
        }

        func addLocation(_ region: SourceRegion) {
            if let range = locations[region.path] {
                locations[region.path] = min(range.lowerBound, region.startLine)...max(range.upperBound, region.endLine)
            } else {
                locations[region.path] = region.startLine...region.endLine
            }
        }

        func consume(_ raw: String) {
            let line = raw.trimmingSILWhitespace()
            if current == nil {
                if line.hasPrefix("sil_witness_table") {
                    witnessType = Pattern.groups(Expressions.witnessTable, in: line)?.first
                    if let fields = Pattern.groups(Expressions.externalWitness, in: line) {
                        externalWitnesses[module + ":" + fields[1] + "@witness:" + fields[0], default: []].insert(fields[2])
                    }
                } else if line.hasPrefix("sil_vtable") || line == "}" { witnessType = nil }
                if line.hasPrefix("// "), !line.hasPrefix("// Isolation:") {
                    let name = String(line.dropFirst(3))
                    pendingName = name.components(separatedBy: ", loc ")[0].components(separatedBy: ", scope ")[0]
                    pendingLocation = location(line)
                }
                if line.hasPrefix("sil "), line.hasSuffix("{"),
                   let match = Pattern.groups(Expressions.function, in: line) {
                    if line.split(separator: " ", maxSplits: 2)[1].hasSuffix("_external") {
                        importedSymbols.insert(match[0])
                    }
                    if line.split(separator: " ", maxSplits: 2)[1] == "shared" { sharedSymbols.insert(match[0]) }
                    current = FunctionNode(id: match[0], module: module, name: pendingName.isEmpty ? match[0] : pendingName)
                    // Canonical capture can retain source parameter names (e.g.
                    // Element), while replay usually spells them τ_0_0. A local
                    // nominal type may have the same name; it is not that receiver.
                    genericParameters = SILParser.genericParameters(in: line)
                    locations = [:]
                    knownValues = []
                    if let pendingLocation { addLocation(pendingLocation) }
                    pendingName = ""
                    pendingLocation = nil
                } else if line.containsASCII("#"), let match = Pattern.groups(Expressions.dispatch, in: line) {
                    let key = match[0].components(separatedBy: "!")[0]
                    tables[key, default: []].insert(match[1])
                    if let witnessType { tables[key + "@witness:" + witnessType, default: []].insert(match[1]) }
                }
                return
            }

            if line.hasPrefix("} // end sil function") {
                current!.regions = locations.map {
                    SourceRegion(path: $0.key, startLine: $0.value.lowerBound, endLine: $0.value.upperBound)
                }.sorted { ($0.path, $0.startLine) < ($1.path, $1.startLine) }
                current!.compilerReferences = current!.dependencies
                functions[current!.id] = current!
                current = nil
                return
            }
            if let found = location(line) { addLocation(found) }
            if line.hasPrefix("//") { return }

            if line.containsASCII("function_ref "), let match = Pattern.groups(Expressions.reference, in: line) {
                knownValues.insert(match[0])
                current!.dependencies.insert(match[1])
            }
            if line.containsASCII(" = keypath ") {
                // Key paths carry getter/setter and captured-index equality/hash
                // functions without function_ref instructions. Keep those escaped
                // references, including their helpers' dependencies/uncertainty.
                let text = line as NSString
                for match in Expressions.function.matches(in: line, range: NSRange(location: 0, length: text.length)) {
                    current!.dependencies.insert(text.substring(with: match.range(at: 1)))
                }
                current!.uncertainties.insert("Key path access")
            }
            if line.containsASCII("_method"), let match = Pattern.groups(Expressions.method, in: line) {
                if let value = Pattern.groups(Expressions.value, in: line)?.first { knownValues.insert(value) }
                var declaration = match[1].components(separatedBy: "!")[0]
                // Narrow only a concrete nominal receiver. Generic, existential,
                // compound and unfamiliar forms retain the broad candidate set.
                if match[0] == "witness_method", let type = Pattern.groups(Expressions.witnessType, in: line)?.first,
                   !type.contains("τ_"), !["Self", "T", "U", "V"].contains(type), genericParameters?.contains(type.components(separatedBy: ".")[0]) == false {
                    declaration += "@witness:" + type
                }
                if match[0] == "witness_method", genericParameters == nil {
                    current!.uncertainties.insert("Unresolved project dispatch: " + declaration)
                }
                current!.dynamicDeclarations.insert(declaration)
                current!.uncertainties.insert("Dynamic dispatch: \(match[0]) \(match[1])")
            }
            // Retain dependency flow through common function-value conversions.
            if line.containsASCII(" = "), let match = Pattern.groups(Expressions.conversion, in: line), knownValues.contains(match[1]) {
                knownValues.insert(match[0])
            }
            if line.containsASCII("apply "), let match = Pattern.groups(Expressions.apply, in: line), !knownValues.contains(match[0]) {
                current!.uncertainties.insert("Indirect function invocation")
            }
            if line.containsASCII("global_addr ") || line.containsASCII("global_value ") {
                current!.uncertainties.insert("Global state access")
            }
            if line.containsASCII("global_addr ") || line.containsASCII("global_value ") || line.containsASCII("ref_element_addr ") {
                current!.uncertainties.insert("Shared state access")
            }
            if line.containsASCII("builtin \""), line.containsASCII("RawPointer") {
                current!.uncertainties.insert("Raw pointer operation")
            }
        }
    }
}

// SIL keywords are ASCII. Avoid Foundation's Unicode substring-search machinery
// on every instruction; Unicode source paths and identifiers stay intact.
private extension String {
    func containsASCII(_ token: StaticString) -> Bool {
        token.withUTF8Buffer { needle in
            let bytes = utf8
            guard let first = needle.first else { return true }
            for start in bytes.indices where bytes[start] == first {
                var cursor = start
                var matched = true
                for byte in needle {
                    guard cursor != bytes.endIndex, bytes[cursor] == byte else { matched = false; break }
                    bytes.formIndex(after: &cursor)
                }
                if matched {
                    // Preserve Foundation matching at a Unicode grapheme edge.
                    // Ordinary SIL instruction tokens stay on the byte fast path.
                    if cursor != bytes.endIndex, bytes[cursor] >= 128 {
                        return contains(String(decoding: needle, as: UTF8.self))
                    }
                    return true
                }
            }
            return false
        }
    }

    func trimmingSILWhitespace() -> String {
        let bytes = utf8
        func isSpace(_ byte: UInt8) -> Bool { byte == 32 || (9...13).contains(byte) }
        let trimmed = bytes.drop(while: isSpace).reversed().drop(while: isSpace).reversed()
        // Preserve Foundation's handling of non-ASCII whitespace at either edge.
        if let first = trimmed.first, first >= 128 { return trimmingCharacters(in: .whitespacesAndNewlines) }
        if let last = trimmed.last, last >= 128 { return trimmingCharacters(in: .whitespacesAndNewlines) }
        return String(decoding: trimmed, as: UTF8.self)
    }
}
