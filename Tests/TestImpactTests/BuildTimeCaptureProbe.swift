// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import Testing
@testable import TestImpact

/// Opt-in investigation harness. Captured fragments are never accepted by the
/// production CLI; completeness/provenance validation is a separate requirement.
@Test func buildTimeCaptureProbe() throws {
    let env = ProcessInfo.processInfo.environment
    guard let configPath = env["IMPACT_CAPTURE_PROBE"] else { return }
    let config = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: URL(fileURLWithPath: configPath)))
    func url(_ key: String) throws -> URL { URL(fileURLWithPath: try #require(config[key])) }
    let root = try url("root")
    var reference: XcodeTestGraph
    if let saved = config["reference"] {
        reference = try JSONDecoder().decode(XcodeTestGraph.self, from: Data(contentsOf: URL(fileURLWithPath: saved)))
    } else {
        let options = XcodeConfiguration(container: .project, path: try url("project"), scheme: try #require(config["scheme"]), destination: try #require(config["destination"]), testPlan: config["plan"])
        let analyzer = XcodeAnalysis(options: options, progress: { print($0) })
        reference = try analyzer.analyzeBuild(options, sourceRoot: root, derived: try url("derived"), log: String(contentsOf: try url("log"), encoding: .utf8), settingsData: Data(contentsOf: try url("settings")))
    }
    let original = try #require(reference.dependencies)
    try #require(!original.functions.isEmpty && original.diagnostics.isEmpty, "Reference extraction must succeed before comparing captures")
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
        for source in (info["sources"] as? [String: String] ?? [:]).keys {
            let absolute = URL(fileURLWithPath: source).standardizedFileURL.resolvingSymlinksInPath().path
            if absolute.hasPrefix(prefix) { ownership[module, default: []].insert(String(absolute.dropFirst(prefix.count))) }
        }
        for filename in info["silFiles"] as? [String] ?? ["output.sil"] {
            let sil = folder.appendingPathComponent(filename)
            let parsed = try SILParser.parse(file: sil, module: module, sourceRoot: root)
            bytes += (try sil.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
            fragments += 1
            for (symbol, node) in parsed.functions {
                if var existing = graph.functions[symbol] {
                    // Union fragments conservatively, preferring the owning module's
                    // definition for identity. Never drop edges from another fragment.
                    let owns = node.regions.contains { ownership[module]?.contains($0.path) == true }
                    if owns || existing.regions.isEmpty && !node.regions.isEmpty {
                        let old = existing
                        existing = node
                        existing.dependencies.formUnion(old.dependencies)
                        existing.dynamicDeclarations.formUnion(old.dynamicDeclarations)
                        existing.uncertainties.formUnion(old.uncertainties)
                        existing.regions = Array(Set(old.regions + node.regions))
                    } else {
                        existing.dependencies.formUnion(node.dependencies)
                        existing.dynamicDeclarations.formUnion(node.dynamicDeclarations)
                        existing.uncertainties.formUnion(node.uncertainties)
                        existing.regions = Array(Set(existing.regions + node.regions))
                    }
                    graph.functions[symbol] = existing
                } else { graph.functions[symbol] = node }
            }
            for (key, values) in parsed.dispatchTargets { tables[key, default: []].formUnion(values) }
        }
    }
    try #require(fragments > 0)
    for symbol in graph.functions.keys {
        for declaration in graph.functions[symbol]!.dynamicDeclarations {
            graph.functions[symbol]!.dependencies.formUnion(tables[declaration] ?? [])
            if tables[declaration]?.isEmpty == false { graph.functions[symbol]!.resolvedDynamicDeclarations.insert(declaration) }
        }
    }
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
        if !missingEdges.isEmpty || !addedEdges.isEmpty || Set(old.regions) != Set(new.regions) || uncertaintyChanged || old.module != new.module || old.name != new.name {
            differingFunctions.append(["symbol": id, "name": old.name, "missingEdges": missingEdges.sorted(), "addedEdges": addedEdges.sorted(), "regionsEqual": Set(old.regions) == Set(new.regions), "uncertaintiesEqual": !uncertaintyChanged, "moduleEqual": old.module == new.module, "nameEqual": old.name == new.name])
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
            let expected = XcodeSelector.select(current: oldHead, previous: reference, changes: [change], baseRevision: "probe")
            let actual = XcodeSelector.select(current: newHead, previous: captured, changes: [change], baseRevision: "probe")
            if expected.selectedTests != actual.selectedTests || expected.fullRunReasons != actual.fullRunReasons {
                selectionDifferences.append(["unit": snapshot.units[index].key, "expected": expected.selectedTests, "actual": actual.selectedTests, "expectedFallbacks": expected.fullRunReasons, "actualFallbacks": actual.fullRunReasons])
            }
            checked += 1
            fileChecked += 1
            selectionSamples.append(["path": change.path, "line": snapshot.units[index].region.startLine, "referenceCount": expected.selectedTests.count, "captureCount": actual.selectedTests.count])
            announce("Compared edit \(checked)/\(selectionLimit): \(change.path):\(snapshot.units[index].region.startLine)")
        }
    }
    let result: [String: Any] = ["fragments": fragments, "silBytes": bytes, "referenceFunctions": original.functions.count, "capturedFunctions": graph.functions.count, "tests": reference.tests.count, "missingProjectFunctions": missing, "rootParity": original.tests == graph.tests, "selectionsChecked": checked, "selectionDifferences": selectionDifferences, "diagnostics": graph.diagnostics, "differingFunctions": differingFunctions, "parseSeconds": parseSeconds, "bindingSeconds": bindingSeconds, "selectionValidationSeconds": Date().timeIntervalSince(selectionStart), "selectionSamples": selectionSamples]
    try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: try url("output"))
    announce("CAPTURE RESULT: \(checked) selections, \(selectionDifferences.count) differences, \(missing.count) missing project functions, roots equal: \(original.tests == graph.tests)")
}
