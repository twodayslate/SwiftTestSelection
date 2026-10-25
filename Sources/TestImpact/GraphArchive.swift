// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// Versioned binary graph interchange. JSON remains readable and is accepted by
/// decode; the compact representation interns repeated symbols, paths and text.
public enum GraphArchive {
    private static let magic = Data("STIGRAPH1\n".utf8)
    private struct Envelope: Codable { var metadata: Data; var graph: PackedGraph?; var dispatch: [String: Set<String>]? }
    private struct PackedGraph: Codable {
        var strings: [String]
        var nodes: Data
        var tests: [String: [Int]]
        var toolchain: String
        var schema: Int
        var diagnostics: [String]
        var testDiagnostics: [String: [String]]
        init(_ graph: DependencyGraph) {
            var table: [String] = [], ids: [String: Int] = [:]
            func intern(_ s: String) -> Int {
                if let id = ids[s] { return id }
                let id = table.count; table.append(s); ids[s] = id; return id
            }
            var words: [UInt64] = []
            for key in graph.functions.keys.sorted() {
                let n = graph.functions[key]!
                var row = [intern(key), intern(n.module), intern(n.name), n.regions.count]
                for r in n.regions { row += [intern(r.path), r.startLine, r.endLine] }
                for values in [n.dependencies, n.uncertainties, n.dynamicDeclarations, n.resolvedDynamicDeclarations] {
                    row.append(values.count); row += values.sorted().map(intern)
                }
                words.append(UInt64(row.count).littleEndian)
                words += row.map { UInt64(bitPattern: Int64($0)).littleEndian }
            }
            nodes = words.withUnsafeBytes { Data($0) }
            tests = graph.tests.mapValues { $0.sorted().map(intern) }
            strings = table; toolchain = graph.toolchain; schema = graph.schemaVersion
            diagnostics = graph.diagnostics; testDiagnostics = graph.testDiagnostics
        }
        func unpack() throws -> DependencyGraph {
            func string(_ id: Int) throws -> String {
                guard strings.indices.contains(id) else { throw ImpactError("Invalid compact graph string reference") }
                return strings[id]
            }
            var graph = DependencyGraph(toolchain: toolchain, diagnostics: diagnostics)
            graph.schemaVersion = schema; graph.testDiagnostics = testDiagnostics
            guard nodes.count.isMultiple(of: 8) else { throw ImpactError("Truncated compact graph integers") }
            let words: [Int] = nodes.withUnsafeBytes { bytes in
                stride(from: 0, to: bytes.count, by: 8).map {
                    Int(Int64(bitPattern: UInt64(littleEndian: bytes.loadUnaligned(fromByteOffset: $0, as: UInt64.self))))
                }
            }
            var offset = 0
            while offset < words.count {
                let length = words[offset]; offset += 1
                guard length >= 0, length <= words.count - offset else { throw ImpactError("Invalid compact graph record length") }
                let row = Array(words[offset..<(offset + length)])
                offset += length
                var cursor = 0
                func next() throws -> Int {
                    guard row.indices.contains(cursor) else { throw ImpactError("Truncated compact graph node") }
                    defer { cursor += 1 }; return row[cursor]
                }
                func count() throws -> Int {
                    let n = try next()
                    guard n >= 0, n <= row.count - cursor else { throw ImpactError("Invalid compact graph count") }
                    return n
                }
                var node = try FunctionNode(id: string(next()), module: string(next()), name: string(next()))
                for _ in 0..<(try count()) {
                    node.regions.append(try SourceRegion(path: string(next()), startLine: next(), endLine: next()))
                }
                func values() throws -> Set<String> {
                    try Set((0..<(try count())).map { _ in try string(next()) })
                }
                node.dependencies = try values(); node.uncertainties = try values()
                node.dynamicDeclarations = try values(); node.resolvedDynamicDeclarations = try values()
                guard cursor == row.count, graph.functions[node.id] == nil else { throw ImpactError("Invalid compact graph node record") }
                graph.functions[node.id] = node
            }
            graph.tests = try tests.mapValues { try Set($0.map(string)) }
            return graph
        }
    }
    public static func encode(_ graph: XcodeTestGraph) throws -> Data { try encodeValue(graph) }
    public static func decode(_ data: Data) throws -> XcodeTestGraph { try decodeValue(XcodeTestGraph.self, from: data) }

    static func encodeValue<T: Encodable>(_ value: T) throws -> Data {
        let envelope: Envelope
        if var graph = value as? XcodeTestGraph {
            let packed = graph.dependencies.map(PackedGraph.init); graph.dependencies = nil
            envelope = try Envelope(metadata: JSONEncoder().encode(graph), graph: packed)
        } else if let module = value as? SILModule {
            envelope = Envelope(metadata: Data(), graph: PackedGraph(DependencyGraph(functions: module.functions)), dispatch: module.dispatchTargets)
        } else { return try JSONEncoder().encode(value) }
        let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
        let payload = try encoder.encode(envelope)
        return magic + Data(XcodeGraphCache.digest(payload).utf8) + payload
    }
    static func decodeValue<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        guard data.starts(with: magic) else { return try JSONDecoder().decode(type, from: data) }
        guard data.count >= magic.count + 64 else { throw ImpactError("Truncated compact graph") }
        let payload = data.dropFirst(magic.count + 64)
        guard String(decoding: data.dropFirst(magic.count).prefix(64), as: UTF8.self) == XcodeGraphCache.digest(payload) else {
            throw ImpactError("Compact graph checksum mismatch")
        }
        let envelope = try PropertyListDecoder().decode(Envelope.self, from: payload)
        if type == XcodeTestGraph.self {
            var graph = try JSONDecoder().decode(XcodeTestGraph.self, from: envelope.metadata)
            graph.dependencies = try envelope.graph?.unpack()
            return graph as! T
        }
        if type == SILModule.self, let packed = envelope.graph, let dispatch = envelope.dispatch {
            return try SILModule(functions: packed.unpack().functions, dispatchTargets: dispatch) as! T
        }
        throw ImpactError("Unsupported compact graph payload")
    }
}
