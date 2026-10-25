// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import Testing
@testable import TestImpact

/// Opt-in graph comparison, separate from production capture provenance.
/// Experimental outputs cannot authorize execution of retained products.
@Test func buildTimeCaptureProbe() throws {
    let env = ProcessInfo.processInfo.environment
    guard let configPath = env["IMPACT_CAPTURE_PROBE"] else { return }
    let config = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: URL(fileURLWithPath: configPath)))
    func url(_ key: String) throws -> URL { URL(fileURLWithPath: try #require(config[key])) }
    let root = try url("root")
    var reference: XcodeTestGraph
    if let saved = config["reference"] {
        reference = try GraphArchive.decode(Data(contentsOf: URL(fileURLWithPath: saved)))
    } else {
        let options = XcodeConfiguration(container: .project, path: try url("project"), scheme: try #require(config["scheme"]), destination: try #require(config["destination"]), testPlan: config["plan"])
        let analyzer = XcodeAnalysis(options: options, progress: { print($0) })
        reference = try analyzer.analyzeBuild(options, sourceRoot: root, derived: try url("derived"), log: String(contentsOf: try url("log"), encoding: .utf8), settingsData: Data(contentsOf: try url("settings")))
    }
    var graph = DependencyGraph()
    var tables: [String: Set<String>] = [:]
    let directory = try url("capture")
    var ownership = reference.sources.values.reduce(into: [String: Set<String>]()) { result, file in
        for unit in file.units {
            let module = String(unit.key.prefix { $0 != ":" })
            result[module, default: []].insert(unit.region.path)
        }
    }
    var fragments = 0
    var bytes = 0
    func announce(_ message: String) { FileHandle.standardOutput.write(Data((message + "\n").utf8)) }
    if let logPath = config["referenceLog"] {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("capture-reference-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        var fresh = XcodeCompilerGraph.extract(log: try String(contentsOfFile: logPath, encoding: .utf8),
            sourceRoot: root, directory: root, derived: scratch, progress: announce, ownership: ownership)
        XcodeCompilerGraph.bind(tests: reference.tests, modules: reference.modules, sources: reference.sources, graph: &fresh)
        reference.dependencies = fresh
        reference.buildArtifact = nil
        if let output = config["referenceGraph"] { try GraphArchive.encode(reference).write(to: URL(fileURLWithPath: output)) }
    }
    let original = try #require(reference.dependencies)
    try #require(!original.functions.isEmpty && original.diagnostics.isEmpty, "Reference extraction must succeed before comparing captures")
    var moduleFiles: [String: [URL]] = [:]
    var checkedInputs: [String: String] = [:]
    let archivedEmpty = Set(config["archivedEmptyFragments"]?.components(separatedBy: "|") ?? [])
    var excludedEmpty: [String] = []
    let start = Date()
    for folder in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).sorted(by: { $0.path < $1.path }) {
        let manifest = folder.appendingPathComponent("manifest.json")
        guard FileManager.default.fileExists(atPath: manifest.path) else { continue }
        let info = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any])
        try #require(info["status"] as? String == "complete", "Incomplete capture: \(folder)")
        let arguments = try #require(info["arguments"] as? [String])
        let index = try #require(arguments.firstIndex(of: "-module-name"))
        let module = arguments[index + 1]
        let prefix = root.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        for (source, hash) in try #require(info["sources"] as? [String: String]) {
            if let previous = checkedInputs[source] { try #require(previous == hash, "Conflicting captured source bytes") }
            else {
                let actual = try ArtifactFiles.digest(URL(fileURLWithPath: source))
                try #require(actual == hash, "Captured source changed: \(source)")
                checkedInputs[source] = hash
            }
            let absolute = URL(fileURLWithPath: source).standardizedFileURL.resolvingSymlinksInPath().path
            if absolute.hasPrefix(prefix) { ownership[module, default: []].insert(String(absolute.dropFirst(prefix.count))) }
        }
        for filename in info["silFiles"] as? [String] ?? ["output.sil"] {
            let sil = folder.appendingPathComponent(filename)
            let checksum = try ArtifactFiles.digest(sil)
            try #require((info["silSHA256"] as? [String: String])?[filename] == checksum, "Captured SIL changed: \(sil.path)")
            bytes += (try sil.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
            fragments += 1
            let relative = folder.lastPathComponent + "/" + filename
            if archivedEmpty.contains(relative) {
                let parsed = try SILParser.parse(file: sil, module: module, sourceRoot: root)
                try #require(parsed.functions.isEmpty && parsed.dispatchTargets.isEmpty, "Only genuinely empty archived fragments may be excluded")
                excludedEmpty.append(relative)
            } else { moduleFiles[module, default: []].append(sil) }
        }
    }
    try #require(fragments > 0)
    try #require(Set(excludedEmpty) == archivedEmpty, "Every archived exclusion must identify a verified fragment")
    // Use the production per-module fragment merger and the same ownership rule
    // as compiler replay. A global union would invent cross-module dependencies.
    let capture = CapturedSIL(modules: moduleFiles, fingerprints: [:], diagnostics: [])
    var definitions = Set<String>()
    for module in moduleFiles.keys.sorted() {
        let fragment = try capture.parse(module: module, sourceRoot: root)
        let parsed = try #require(fragment)
        for (id, node) in parsed.functions {
            let owns = node.regions.contains { ownership[module]?.contains($0.path) == true }
            if owns || !definitions.contains(id) && (graph.functions[id] == nil || !node.regions.isEmpty && graph.functions[id]!.regions.isEmpty) {
                graph.functions[id] = node
            }
            if owns { definitions.insert(id) }
        }
        for (key, values) in parsed.dispatchTargets { tables[key, default: []].formUnion(values) }
    }
    XcodeCompilerGraph.resolveDispatch(&graph, tables: tables)
    let parseSeconds = Date().timeIntervalSince(start)
    announce("Captured parse: \(fragments) fragments, \(bytes) bytes, \(parseSeconds) s")
    let bindingStart = Date()
    XcodeCompilerGraph.bind(tests: reference.tests, modules: reference.modules, sources: reference.sources, graph: &graph)
    let bindingSeconds = Date().timeIntervalSince(bindingStart)
    announce("Captured binding: \(bindingSeconds) s")
    var captured = reference
    captured.dependencies = graph
    // Experimental graph comparisons must never inherit executable provenance.
    captured.buildArtifact = nil
    try JSONEncoder().encode(captured).write(to: try url("capturedGraph"))
    let missing = original.functions.values.filter { !$0.regions.isEmpty && graph.functions[$0.id] == nil }.map(\.name).sorted()
    var differingFunctions: [[String: Any]] = []
    for (id, old) in original.functions where !old.regions.isEmpty {
        guard let new = graph.functions[id] else { continue }
        let missingEdges = old.dependencies.subtracting(new.dependencies)
        let addedEdges = new.dependencies.subtracting(old.dependencies)
        let uncertaintyChanged = old.uncertainties != new.uncertainties
        let dispatchChanged = old.dynamicDeclarations != new.dynamicDeclarations || old.resolvedDynamicDeclarations != new.resolvedDynamicDeclarations
        if !missingEdges.isEmpty || !addedEdges.isEmpty || Set(old.regions) != Set(new.regions) || uncertaintyChanged || dispatchChanged || old.module != new.module || old.name != new.name {
            differingFunctions.append(["symbol": id, "name": old.name, "missingEdges": missingEdges.sorted(), "addedEdges": addedEdges.sorted(), "regionsEqual": Set(old.regions) == Set(new.regions), "uncertaintiesEqual": !uncertaintyChanged, "oldUncertainties": old.uncertainties.sorted(), "newUncertainties": new.uncertainties.sorted(), "oldDispatch": old.dynamicDeclarations.sorted(), "newDispatch": new.dynamicDeclarations.sorted(), "oldResolvedDispatch": old.resolvedDynamicDeclarations.sorted(), "newResolvedDispatch": new.resolvedDynamicDeclarations.sorted(), "moduleEqual": old.module == new.module, "nameEqual": old.name == new.name])
        }
    }
    var selectionDifferences: [[String: Any]] = []
    var selectionSamples: [[String: Any]] = []
    let selectionStart = Date()
    var checked = 0
    let selectionLimit = config["selectionLimit"].flatMap(Int.init) ?? 20
    try #require(selectionLimit > 0)
    // Mutate one source-unit fingerprint at a time to isolate selector behavior
    // for edits without making or executing a fake source build.
    for (key, snapshot) in reference.sources.sorted(by: { $0.key < $1.key }) {
        if let patterns = config["selectionPaths"]?.components(separatedBy: "|"), !patterns.contains(where: { key.contains($0) }) { continue }
        var fileChecked = 0
        let perFile = config["selectionLimitPerFile"].flatMap(Int.init) ?? selectionLimit
        try #require(perFile > 0)
        for index in snapshot.units.indices where snapshot.units[index].kind == "function" {
            if fileChecked >= perFile { break }
            if checked >= selectionLimit { break }
            var oldHead = reference, newHead = captured
            oldHead.sources[key]!.units[index].fingerprint += "probe-edit"
            newHead.sources[key]!.units[index].fingerprint += "probe-edit"
            let change = FileChange(path: snapshot.units[index].region.path)
            for mixedDocumentation in [false, true] {
                let changes = [change] + (mixedDocumentation ? [FileChange(path: "README.md")] : [])
                let expected = XcodeSelector.select(current: oldHead, previous: reference, changes: changes, baseRevision: "probe")
                let actual = XcodeSelector.select(current: newHead, previous: captured, changes: changes, baseRevision: "probe")
                let added = Set(actual.selectedTests).subtracting(expected.selectedTests).sorted()
                let omitted = Set(expected.selectedTests).subtracting(actual.selectedTests).sorted()
                if !added.isEmpty || !omitted.isEmpty || expected.fullRunReasons != actual.fullRunReasons {
                    selectionDifferences.append(["unit": snapshot.units[index].key, "mixedDocumentation": mixedDocumentation,
                        "added": added, "omitted": omitted, "expectedFallbacks": expected.fullRunReasons, "actualFallbacks": actual.fullRunReasons])
                }
                selectionSamples.append(["path": change.path, "line": snapshot.units[index].region.startLine,
                    "mixedDocumentation": mixedDocumentation, "referenceCount": expected.selectedTests.count,
                    "captureCount": actual.selectedTests.count, "added": added, "omitted": omitted])
            }
            checked += 1
            fileChecked += 1
            announce("Compared edit \(checked)/\(selectionLimit): \(change.path):\(snapshot.units[index].region.startLine)")
        }
    }
    let result: [String: Any] = ["fragments": fragments, "excludedArchivedEmptyFragments": excludedEmpty.sorted(), "silBytes": bytes, "referenceFunctions": original.functions.count, "capturedFunctions": graph.functions.count, "tests": reference.tests.count, "missingProjectFunctions": missing, "rootParity": original.tests == graph.tests, "selectionsChecked": selectionSamples.count, "selectionDifferences": selectionDifferences, "diagnostics": graph.diagnostics, "differingFunctions": differingFunctions, "parseSeconds": parseSeconds, "bindingSeconds": bindingSeconds, "selectionValidationSeconds": Date().timeIntervalSince(selectionStart), "selectionSamples": selectionSamples]
    try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: try url("output"))
    announce("CAPTURE RESULT: \(checked) selections, \(selectionDifferences.count) differences, \(missing.count) missing project functions, roots equal: \(original.tests == graph.tests)")
}
