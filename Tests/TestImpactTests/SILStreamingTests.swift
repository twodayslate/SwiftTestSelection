// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import Testing
@testable import TestImpact

@Test func streamedSILPreservesLocationsDispatchAndValueFlow() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("input.sil")
    let source = root.appendingPathComponent("Café.swift").path
    let text = """
    // Example.test(), loc "\(source)":1:1
    sil hidden @test : $@convention(thin) () -> () {
      %0 = function_ref @callback : $@convention(thin) () -> (), loc "\(source)":2:1
      %1 = copy_value %0 : $@convention(thin) () -> ()
      %2 = partial_apply [callee_guaranteed] %1() : $@convention(thin) () -> ()
      %3 = apply %2() : $@convention(thin) () -> ()
      %4 = class_method\t%self : $Example, #Example.helper : $@convention(method) () -> ()
      %5 = apply %4() : $@convention(method) () -> (), loc "\(source)":9:1
      %6 = global_addr @global : $*Int, loc "/external/Other.swift":8:1
      %7 = apply %unknown() : $@convention(thin) () -> ()
    } // end sil function 'test'
    sil_vtable Example {
      #Example.helper: (Example) -> () -> () : @helper
    }
    """
    // A line larger than the reader's chunk and non-ASCII bytes at boundaries.
    let input = text.replacingOccurrences(of: "  %0", with: "  // " + String(repeating: "é", count: 100_000) + "\n  %0")
        .replacingOccurrences(of: "\n", with: "\r\n")
    try Data(input.utf8).write(to: file)
    let streamed = try SILParser.parse(file: file, module: "Tests", sourceRoot: root)
    let memory = SILParser.parse(input, module: "Tests", sourceRoot: root)
    for parsed in [streamed, memory] {
        let node = try #require(parsed.functions["test"])
        #expect(node.name == "Example.test()")
        #expect(node.regions == [SourceRegion(path: "Café.swift", startLine: 1, endLine: 9)])
        #expect(node.dependencies == ["callback"])
        #expect(node.dynamicDeclarations == ["Example.helper"])
        #expect(node.uncertainties == ["Dynamic dispatch: class_method Example.helper", "Indirect function invocation", "Global state access", "Shared state access"])
        #expect(parsed.dispatchTargets == ["Example.helper": ["helper"]])
    }
}

@Test func lineReaderHandlesUTF8BoundariesEmptyLinesAndFinalLine() throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: file) }
    try Data("é\n\n😀\r\nlast".utf8).write(to: file)
    for size in [1, 2, 3, 7, 64 * 1024] {
        var lines: [String] = []
        try SILLineReader.read(file: file, chunkSize: size) { lines.append($0) }
        #expect(lines == ["é", "", "😀\r", "last"])
    }
    try Data([0x61, 0x0a, 0xff]).write(to: file)
    #expect(throws: CocoaError.self) { try SILLineReader.read(file: file, chunkSize: 1) { _ in } }
    try FileManager.default.removeItem(at: file)
    #expect(throws: (any Error).self) { try SILParser.parse(file: file, module: "Tests", sourceRoot: file) }
}

@Test func indexedDispatchBindingPreservesPrefixMatchingAndFallbacks() {
    let names = ["Owner.run()", "Owner.run.getter", "Owner.runner()", "static Owner.run()",
                 "closure #1 in Owner.run()", "Owner.run(_:).nested()", "Owner.value.getter"]
    let region = SourceRegion(path: "Owner.swift", startLine: 1, endLine: 1)
    var graph = DependencyGraph()
    for (index, name) in names.enumerated() {
        graph.functions["f\(index)"] = FunctionNode(id: "f\(index)", module: "App", name: name, regions: [region])
    }
    graph.functions["external"] = FunctionNode(id: "external", module: "SDK", name: "Owner.run()")
    let declarations: Set<String> = ["Owner.run", "Owner.value", "Owner.run(_:)", "Owner.missing"]
    for index in 0..<100 {
        graph.functions["caller\(index)"] = FunctionNode(id: "caller\(index)", module: "Tests", name: "caller\(index)()",
            dependencies: ["existing"], dynamicDeclarations: declarations)
    }
    let source = SwiftSourceSnapshot.parse("class Owner {}", path: "Owner.swift", module: "App")
    XcodeCompilerGraph.bind(tests: [], modules: [:], sources: ["App:Owner.swift": source], graph: &graph)
    for index in 0..<100 {
        let node = graph.functions["caller\(index)"]!
        #expect(node.dependencies == ["existing", "f0", "f1", "f5", "f6"])
        #expect(node.resolvedDynamicDeclarations == ["Owner.run", "Owner.value", "Owner.run(_:)"])
        #expect(node.uncertainties == ["Unresolved project dispatch: Owner.missing"])
    }
}
