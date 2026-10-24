// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import Testing
@testable import TestImpact

private func extractionFixture() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("parallel-extraction-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let script = #"""
    #!/usr/bin/env python3
    import fcntl, json, pathlib, sys, time
    root = pathlib.Path(__file__).parent
    args = sys.argv[1:]
    module = args[args.index('-module-name')+1]
    def event(delta):
        with (root/'events').open('a+') as stream:
            fcntl.flock(stream, fcntl.LOCK_EX)
            stream.write(json.dumps([module,delta])+'\n')
    event(1)
    time.sleep(0.25 if module == 'A' else 0.05)
    event(-1)
    if module == 'Failure': sys.exit(42)
    pathlib.Path(args[args.index('-o')+1]).write_text((root/(module+'.sil')).read_text())
    """#
    let compiler = root.appendingPathComponent("compiler")
    try Data(script.utf8).write(to: compiler)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: compiler.path)
    for module in ["A", "B", "C"] {
        let text = """
        // Owner.test(), loc "\(root.path)/\(module).swift":1:1
        sil hidden @shared : $@convention(thin) () -> () {
          %0 = function_ref @\(module) : $@convention(thin) () -> ()
          %1 = witness_method $T, #Protocol.helper : $@convention(witness_method: Protocol) () -> ()
        } // end sil function 'shared'
        // \(module)(), loc "\(root.path)/\(module).swift":3:1
        sil hidden @\(module) : $@convention(thin) () -> () {
        } // end sil function '\(module)'
        sil_witness_table hidden Concrete: Protocol module \(module) {
          method #Protocol.helper: <Self where Self : Protocol> (Self) -> () -> () : @\(module)
        }
        """
        try Data(text.utf8).write(to: root.appendingPathComponent(module + ".sil"))
    }
    return root
}

private func extractionLog(_ modules: [String], root: URL) -> String {
    modules.map { "builtin-SwiftDriver -- \(root.path)/compiler -module-name \($0) @\(root.path)/\($0).SwiftFileList" }.joined(separator: "\n")
}

@Test func parallelExtractionBoundsConcurrencyAndPreservesOrderedOwnership() throws {
    let root = try extractionFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let log = extractionLog(["A", "B", "C", "B"], root: root)
    var serial: DependencyGraph?
    for workers in [1, 2] {
        try Data().write(to: root.appendingPathComponent("events"))
        var graph = XcodeCompilerGraph.extract(log: log, sourceRoot: root, directory: root, derived: root, progress: { _ in }, ownership: ["A": ["A.swift"], "B": ["B.swift"], "C": ["C.swift"]], workers: workers)
        graph.tests = ["Tests/Owner/test()": ["shared"]]
        #expect(graph.diagnostics.isEmpty)
        #expect(graph.functions["shared"]?.module == "C")
        #expect(graph.functions["shared"]?.dependencies == ["A", "B", "C"])
        #expect(graph.functions["shared"]?.resolvedDynamicDeclarations == ["Protocol.helper"])
        if let serial {
            // Compare every field, including source regions, uncertainty and roots.
            #expect(serial.tests == graph.tests)
            #expect(serial.diagnostics == graph.diagnostics)
            #expect(serial.testDiagnostics == graph.testDiagnostics)
            #expect(serial.functions.keys.sorted() == graph.functions.keys.sorted())
            for (key, node) in serial.functions {
                let other = try #require(graph.functions[key])
                #expect(node.id == other.id && node.name == other.name && node.module == other.module)
                #expect(Set(node.regions) == Set(other.regions))
                #expect(node.dependencies == other.dependencies)
                #expect(node.dynamicDeclarations == other.dynamicDeclarations)
                #expect(node.resolvedDynamicDeclarations == other.resolvedDynamicDeclarations)
                #expect(node.uncertainties == other.uncertainties)
            }
            for symbol in ["A", "B", "C", "missing"] {
                let change = [FileChange(path: symbol + ".swift")]
                let expected = StaticSelector.select(current: serial, previous: serial, changes: change, baseRevision: "base")
                let actual = StaticSelector.select(current: graph, previous: graph, changes: change, baseRevision: "base")
                #expect(expected.selectedTests == actual.selectedTests)
                #expect(expected.fullRunReasons == actual.fullRunReasons)
            }
        } else { serial = graph }
        let events = try String(contentsOf: root.appendingPathComponent("events"), encoding: .utf8).split(separator: "\n")
        var active = 0, peak = 0
        for event in events {
            let values = try #require(JSONSerialization.jsonObject(with: Data(event.utf8)) as? [Any])
            active += try #require(values[1] as? Int)
            peak = max(peak, active)
        }
        #expect(active == 0 && peak == workers)
        #expect(events.count == 6) // Repeated identical module is not recompiled.
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).allSatisfy { !$0.hasPrefix("impact-") })
    }
}

@Test func parallelExtractionReportsFailureAmbiguityAndCancellation() throws {
    let root = try extractionFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let log = extractionLog(["A", "Failure", "B"], root: root) + "\n" + extractionLog(["A"], root: root) + " -DOTHER"
    let serial = XcodeCompilerGraph.extract(log: log, sourceRoot: root, directory: root, derived: root, progress: { _ in })
    let parallel = XcodeCompilerGraph.extract(log: log, sourceRoot: root, directory: root, derived: root, progress: { _ in }, workers: 2)
    #expect(serial.diagnostics == parallel.diagnostics)
    #expect(parallel.diagnostics.count == 2)
    let cancellation = XcodeExtractionCancellation()
    let cancel = Thread { Thread.sleep(forTimeInterval: 0.1); cancellation.cancel() }
    cancel.start()
    let stopped = XcodeCompilerGraph.extract(log: extractionLog(["A", "B", "C"], root: root), sourceRoot: root, directory: root, derived: root, progress: { _ in }, workers: 2, cancellation: cancellation)
    #expect(stopped.functions.isEmpty)
    #expect(stopped.diagnostics.contains { $0.contains("cancelled") })
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).allSatisfy { !$0.hasPrefix("impact-") })
}
