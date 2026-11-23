// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation

/// Versioned binary graph interchange. JSON remains readable and is accepted by
/// decode; the compact representation interns repeated symbols, paths and text.
public enum GraphArchive {
    private static let magic = Data("STIGRAPH1\n".utf8)
    private struct Envelope: Codable {
        var metadata: Data
        var graph: PackedGraph?
        var importedSymbols: Set<String>? = nil
        var sharedSymbols: Set<String>? = nil
        var dispatch: [String: Set<String>]?
        var externalWitnesses: [String: Set<String>]? = nil
    }
    private struct PackedGraph: Codable {
        var strings: [String]
        var nodes: Data
        var tests: [String: [Int]]
        var toolchain: String
        var schema: Int
        var diagnostics: [String]
        var testDiagnostics: [String: [String]]
        var compilerClassIdentities: [String: CompilerClassIdentity]?
        var compilerImplicitImports: [String: Set<String>]?
        var assertionFormattingSites: [String: Set<String>]?
        var captureModules: [String: Set<String>]?
        var dynamicDeclarationModules: [String: [String: Set<String>]]?
        var concreteSelectorQueryFunctions: Set<String>?
        var nominalTypeContexts: [String: String]?
        /// Optional for archives written before factory-effect evidence existed.
        var testVTableEntries: [String: Set<String>]?
        var swiftTestingRegisteredFactories: [String: Set<String>]?
        var swiftTestingSuiteWitnesses: [String: Set<String>]?
        var swiftTestingFormattingRequirements: [String: Set<String>]?
        var swiftTestingDiscoveryReferences: [String: Set<String>]?
        var swiftTestingTraitProducers: [String: Set<String>]?
        var swiftTestingExistentialTypes: [String: Set<String>]?
        var swiftTestingFactoryTypes: [String: String]?
        var swiftTestingEmptyFactories: [String: String]?
        var swiftTestingDeferredProviderCounts: [String: Int]?
        var swiftTestingConditionsByFunction: [String: SwiftTestingFactoryProof.Conditions]?
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
                let optionalEvidence = [n.compilerReferences, n.dynamicCallSignatures, n.stateAccesses, n.receiverTypeOrigins, n.receiverGenericCalls, n.dynamicCallSites, n.receiverErrorEffects, n.receiverIndirectErrorEffects]
                let lastEvidence = n.mayDestroyValue == nil ? optionalEvidence.lastIndex(where: { $0 != nil }) : optionalEvidence.indices.last
                if let last = lastEvidence {
                    for values in optionalEvidence[...last] {
                        if let values { row.append(values.count); row += values.sorted().map(intern) }
                        else { row.append(-1) }
                    }
                }
                if let cleanup = n.mayDestroyValue { row.append(cleanup ? 1 : 0) }
                words.append(UInt64(row.count).littleEndian)
                words += row.map { UInt64(bitPattern: Int64($0)).littleEndian }
            }
            nodes = words.withUnsafeBytes { Data($0) }
            tests = graph.tests.mapValues { $0.sorted().map(intern) }
            strings = table; toolchain = graph.toolchain; schema = graph.schemaVersion
            diagnostics = graph.diagnostics; testDiagnostics = graph.testDiagnostics
            compilerClassIdentities = graph.compilerClassIdentities
            compilerImplicitImports = graph.compilerImplicitImports
            assertionFormattingSites = graph.functions.compactMapValues(\.assertionFormattingSites)
            concreteSelectorQueryFunctions = Set(graph.functions.values.filter { $0.selectorQueriesUseNSObject == true }.map(\.id))
            nominalTypeContexts = graph.functions.compactMapValues(\.nominalTypeContext)
            testVTableEntries = graph.testVTableEntries
            swiftTestingRegisteredFactories = graph.swiftTestingRegisteredFactories
            swiftTestingSuiteWitnesses = graph.swiftTestingSuiteWitnesses
            swiftTestingFormattingRequirements = graph.functions.compactMapValues(\.swiftTestingFormattingRequirements)
            swiftTestingDiscoveryReferences = graph.functions.compactMapValues(\.swiftTestingDiscoveryReferences)
            swiftTestingTraitProducers = graph.functions.compactMapValues(\.swiftTestingTraitProducers)
            swiftTestingExistentialTypes = graph.functions.compactMapValues(\.swiftTestingExistentialTypes)
            swiftTestingFactoryTypes = graph.functions.compactMapValues(\.swiftTestingFactoryType)
            swiftTestingEmptyFactories = graph.functions.compactMapValues(\.swiftTestingEmptyFactory)
            swiftTestingDeferredProviderCounts = graph.functions.compactMapValues(\.swiftTestingDeferredProviderCount)
            swiftTestingConditionsByFunction = graph.functions.compactMapValues(\.swiftTestingDeferredConditions)
            captureModules = graph.functions.compactMapValues(\.captureModules)
            dynamicDeclarationModules = graph.functions.compactMapValues(\.dynamicDeclarationModules)
        }
        func unpack() throws -> DependencyGraph {
            func string(_ id: Int) throws -> String {
                guard strings.indices.contains(id) else { throw ImpactError("Invalid compact graph string reference") }
                return strings[id]
            }
            var graph = DependencyGraph(toolchain: toolchain, diagnostics: diagnostics)
            graph.schemaVersion = schema; graph.testDiagnostics = testDiagnostics
            graph.testVTableEntries = testVTableEntries
            graph.swiftTestingRegisteredFactories = swiftTestingRegisteredFactories
            graph.swiftTestingSuiteWitnesses = swiftTestingSuiteWitnesses
            graph.compilerClassIdentities = compilerClassIdentities
            graph.compilerImplicitImports = compilerImplicitImports
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
                if cursor < row.count {
                    if row[cursor] == -1 { cursor += 1 }
                    else { node.compilerReferences = try values() }
                }
                if cursor < row.count {
                    if row[cursor] == -1 { cursor += 1 }
                    else { node.dynamicCallSignatures = try values() }
                }
                if cursor < row.count {
                    if row[cursor] == -1 { cursor += 1 }
                    else { node.stateAccesses = try values() }
                }
                if cursor < row.count {
                    if row[cursor] == -1 { cursor += 1 }
                    else { node.receiverTypeOrigins = try values() }
                }
                if cursor < row.count {
                    if row[cursor] == -1 { cursor += 1 }
                    else { node.receiverGenericCalls = try values() }
                }
                if cursor < row.count {
                    if row[cursor] == -1 { cursor += 1 }
                    else { node.dynamicCallSites = try values() }
                }
                if cursor < row.count {
                    if row[cursor] == -1 { cursor += 1 }
                    else { node.receiverErrorEffects = try values() }
                }
                if cursor < row.count {
                    if row[cursor] == -1 { cursor += 1 }
                    else { node.receiverIndirectErrorEffects = try values() }
                }
                if cursor < row.count {
                    guard row[cursor] == 0 || row[cursor] == 1 else { throw ImpactError("Invalid compact graph lifetime flag") }
                    node.mayDestroyValue = row[cursor] == 1
                    cursor += 1
                }
                guard cursor == row.count, graph.functions[node.id] == nil else { throw ImpactError("Invalid compact graph node record") }
                if concreteSelectorQueryFunctions?.contains(node.id) == true { node.selectorQueriesUseNSObject = true }
                node.nominalTypeContext = nominalTypeContexts?[node.id]
                node.swiftTestingFormattingRequirements = swiftTestingFormattingRequirements?[node.id]
                node.swiftTestingDiscoveryReferences = swiftTestingDiscoveryReferences?[node.id]
                node.swiftTestingTraitProducers = swiftTestingTraitProducers?[node.id]
                node.swiftTestingExistentialTypes = swiftTestingExistentialTypes?[node.id]
                node.swiftTestingFactoryType = swiftTestingFactoryTypes?[node.id]
                node.swiftTestingEmptyFactory = swiftTestingEmptyFactories?[node.id]
                node.swiftTestingDeferredProviderCount = swiftTestingDeferredProviderCounts?[node.id]
                node.swiftTestingDeferredConditions = swiftTestingConditionsByFunction?[node.id]
                node.captureModules = captureModules?[node.id]
                node.assertionFormattingSites = assertionFormattingSites?[node.id]
                node.dynamicDeclarationModules = dynamicDeclarationModules?[node.id]
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
            envelope = Envelope(metadata: Data(), graph: PackedGraph(DependencyGraph(functions: module.functions)), importedSymbols: module.importedSymbols, sharedSymbols: module.sharedSymbols, dispatch: module.dispatchTargets, externalWitnesses: module.externalWitnesses)
        } else { return try JSONEncoder().encode(value) }
        let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
        let payload = try encoder.encode(envelope)
        return magic + Data(XcodeGraphCache.digest(payload).utf8) + payload
    }
    /// Previous captures stored only the test's own factories. Rebind once on
    /// load so comparing retained graphs also includes eager discovery effects.
    private static func upgradeDiscovery(_ snapshot: inout XcodeTestGraph) {
        guard var graph = snapshot.dependencies, !graph.tests.isEmpty else { return }
        if graph.functions[SwiftTestingDiscoveryRoots.sharedDiscoveryID] != nil {
            SwiftTestingDiscoveryRoots.restoreIndirectDiscoveryCalls(&graph)
            snapshot.dependencies = graph
            return
        }
        guard graph.functions.values.contains(where: { $0.compilerReferences?.contains(where: SwiftTestingFactoryProof.isFactory) == true }) else { return }
        SwiftTestingDiscoveryRoots.bind(modules: snapshot.modules, sources: snapshot.sources, graph: &graph)
        graph.testDiagnostics = graph.testDiagnostics.mapValues { diagnostics in
            var seen = Set<String>()
            return diagnostics.filter { seen.insert($0).inserted }
        }
        snapshot.dependencies = graph
    }

    static func decodeValue<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        guard data.starts(with: magic) else {
            if type == XcodeTestGraph.self {
                var graph = try JSONDecoder().decode(XcodeTestGraph.self, from: data)
                upgradeDiscovery(&graph)
                return graph as! T
            }
            return try JSONDecoder().decode(type, from: data)
        }
        guard data.count >= magic.count + 64 else { throw ImpactError("Truncated compact graph") }
        let payload = data.dropFirst(magic.count + 64)
        guard String(decoding: data.dropFirst(magic.count).prefix(64), as: UTF8.self) == XcodeGraphCache.digest(payload) else {
            throw ImpactError("Compact graph checksum mismatch")
        }
        let envelope = try PropertyListDecoder().decode(Envelope.self, from: payload)
        if type == XcodeTestGraph.self {
            var graph = try JSONDecoder().decode(XcodeTestGraph.self, from: envelope.metadata)
            graph.dependencies = try envelope.graph?.unpack()
            upgradeDiscovery(&graph)
            return graph as! T
        }
        if type == SILModule.self, let packed = envelope.graph, let dispatch = envelope.dispatch {
            return try SILModule(importedSymbols: envelope.importedSymbols, sharedSymbols: envelope.sharedSymbols, functions: packed.unpack().functions, dispatchTargets: dispatch, externalWitnesses: envelope.externalWitnesses) as! T
        }
        throw ImpactError("Unsupported compact graph payload")
    }
}
