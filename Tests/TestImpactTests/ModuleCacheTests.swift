// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import Testing
@testable import TestImpact

private struct ModuleCacheFixture {
    let root: URL
    let source: URL
    let derived: URL
    let cache: XcodeGraphCache
    var log: String
    var context = ["revision": "base", "repository": "repo", "settings": "Debug", "analyzerExecutable": "analyzer", "toolchain": "swift", "sdks": "sdk", "externalInputs": "external"]

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("module-cache-" + UUID().uuidString)
        source = root.appendingPathComponent("source")
        derived = root.appendingPathComponent("derived")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: derived, withIntermediateDirectories: true)
        cache = try XcodeGraphCache(.init(directory: root.appendingPathComponent("cache"), context: "external"), progress: { _ in })
        let sdk = root.appendingPathComponent("Swift.swiftmodule")
        try Data("sdk".utf8).write(to: sdk)
        var lines: [String] = []
        for module in ["Core", "App", "Tests", "Other"] {
            let file = source.appendingPathComponent(module + ".swift")
            try Data("func \(module.lowercased())() {}".utf8).write(to: file)
            let list = derived.appendingPathComponent(module + ".SwiftFileList")
            try Data(file.path.utf8).write(to: list)
            var dependencies: [[String: Any]] = [["moduleName": "Swift", "modulePath": sdk.path, "isFramework": false]]
            if ["App", "Tests"].contains(module) {
                dependencies.append(["moduleName": "Core", "modulePath": derived.appendingPathComponent("Core.swiftmodule").path, "isFramework": false])
            }
            try JSONSerialization.data(withJSONObject: dependencies).write(to: derived.appendingPathComponent(module + "-dependencies-1.json"))
            lines.append("builtin-SwiftDriver -- /usr/bin/true -module-name \(module) -explicit-module-build -Onone -g @\(list.path)")
        }
        log = lines.joined(separator: "\n")
    }

    func identities(directory: URL? = nil) throws -> [String: [String: String]] {
        let fragments = XcodeModuleCache(cache: cache, identity: context, source: source, derived: derived, workspace: root, directory: directory)
        fragments.prepare(log: log)
        var result: [String: [String: String]] = [:]
        for name in ["Core", "App", "Tests", "Other"] {
            let value = try #require(fragments.identity(for: name))
            result[name] = value
        }
        return result
    }
}

@Test func moduleCacheIncludesNestedCompilerWorkingDirectory() throws {
    let fixture = try ModuleCacheFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let base = try fixture.identities()
    let nested = fixture.source.appendingPathComponent("NestedProject")
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    let moved = try fixture.identities(directory: nested)
    for module in base.keys { #expect(base[module] != moved[module]) }
}

@Test func moduleCacheRecognizesKnownRootSymlinkAliases() throws {
    let fixture = try ModuleCacheFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let base = try fixture.identities()
    let alias = fixture.root.appendingPathComponent("alias")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.root)
    let moved = XcodeModuleCache(cache: fixture.cache, identity: fixture.context,
        source: alias.appendingPathComponent("source"), derived: alias.appendingPathComponent("derived"), workspace: alias)
    moved.prepare(log: fixture.log)
    for module in base.keys { #expect(moved.identity(for: module) == base[module]) }
    // Foundation can hide /private/tmp even after resolving symlinks. Exercise
    // physical paths in compiler file lists against the original known roots.
    let aliasedList = fixture.derived.appendingPathComponent("Core.SwiftFileList")
    let originalPath = fixture.source.appendingPathComponent("Core.swift").path
    let physical = try #require(realpath(originalPath, nil))
    defer { free(physical) }
    try Data(String(cString: physical).utf8).write(to: aliasedList)
    #expect(try fixture.identities() == base)
}

@Test func moduleCacheInvalidatesCompilerDependencyClosureAcrossRevisions() throws {
    var fixture = try ModuleCacheFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let base = try fixture.identities()
    fixture.context["revision"] = "new-head-or-stacked-pr"
    #expect(try fixture.identities() == base)
    try Data("func tests() { print(1) }".utf8).write(to: fixture.source.appendingPathComponent("Tests.swift"))
    let edited = try fixture.identities()
    #expect(edited["Tests"] != base["Tests"])
    for module in ["Core", "App", "Other"] { #expect(edited[module] == base[module]) }
    try Data("public func core(_ newAPI: Int) {}".utf8).write(to: fixture.source.appendingPathComponent("Core.swift"))
    let shared = try fixture.identities()
    for module in ["Core", "App", "Tests"] { #expect(shared[module] != edited[module]) }
    #expect(shared["Other"] == edited["Other"])
    try Data("{\"features\":[]}".utf8).write(to: fixture.source.appendingPathComponent(".swift-test-selection.json"))
    let policy = try fixture.identities()
    for module in base.keys { #expect(policy[module] != shared[module]) } // Policy is re-read; possible compiler inputs invalidate conservatively.
    for field in fixture.context.keys where field != "revision" {
        let previous = fixture.context[field]
        fixture.context[field] = "changed"
        let changed = try fixture.identities()
        for module in base.keys { #expect(changed[module] != policy[module]) }
        fixture.context[field] = previous
    }
}

@Test func moduleCacheCoversFileListsGeneratedInputsHeadersAndExternalModules() throws {
    let fixture = try ModuleCacheFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let base = try fixture.identities()
    let generated = fixture.derived.appendingPathComponent("Generated.swift")
    try Data("func generated() {}".utf8).write(to: generated)
    let list = fixture.derived.appendingPathComponent("Tests.SwiftFileList")
    try Data((fixture.source.appendingPathComponent("Tests.swift").path + "\n" + generated.path).utf8).write(to: list)
    let added = try fixture.identities()
    #expect(added["Tests"] != base["Tests"])
    #expect(added["Core"] == base["Core"])
    try Data("func generated() { print(2) }".utf8).write(to: generated)
    #expect(try fixture.identities()["Tests"] != added["Tests"])
    try Data(generated.path.utf8).write(to: list) // Deleted source from target inventory.
    #expect(try fixture.identities()["Tests"] != added["Tests"])
    let moved = fixture.derived.appendingPathComponent("Moved.swift")
    try FileManager.default.moveItem(at: generated, to: moved)
    try Data(moved.path.utf8).write(to: list)
    let renamed = try fixture.identities()
    #expect(renamed["Tests"] != added["Tests"])
    try Data("#define CONFIG 1".utf8).write(to: fixture.source.appendingPathComponent("Config.h"))
    let header = try fixture.identities()
    for module in base.keys { #expect(header[module] != renamed[module]) }
    try Data("changed sdk".utf8).write(to: fixture.root.appendingPathComponent("Swift.swiftmodule"))
    let sdk = try fixture.identities()
    for module in base.keys { #expect(sdk[module] != header[module]) }
}

@Test func moduleCacheRebindsPathsWithoutRewritingSourceContents() throws {
    let fixture = try ModuleCacheFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let base = try fixture.identities()
    let relocated = fixture.root.appendingPathComponent("relocated")
    try FileManager.default.createDirectory(at: relocated, withIntermediateDirectories: true)
    for name in ["source", "derived", "Swift.swiftmodule"] {
        try FileManager.default.copyItem(at: fixture.root.appendingPathComponent(name), to: relocated.appendingPathComponent(name))
    }
    for file in try FileManager.default.contentsOfDirectory(at: relocated.appendingPathComponent("derived"), includingPropertiesForKeys: nil) {
        if file.pathExtension == "json" {
            let maps = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [[String: Any]])
            let rebound = maps.map { $0.mapValues { value in
                (value as? String).map { $0.replacingOccurrences(of: fixture.root.path, with: relocated.path) } as Any? ?? value
            } }
            try JSONSerialization.data(withJSONObject: rebound).write(to: file)
        } else {
            let text = try String(contentsOf: file, encoding: .utf8).replacingOccurrences(of: fixture.root.path, with: relocated.path)
            try Data(text.utf8).write(to: file)
        }
    }
    let log = fixture.log.replacingOccurrences(of: fixture.root.path, with: relocated.path)
    let next = XcodeModuleCache(cache: fixture.cache, identity: fixture.context, source: relocated.appendingPathComponent("source"), derived: relocated.appendingPathComponent("derived"), workspace: relocated)
    next.prepare(log: log)
    for module in base.keys { #expect(next.identity(for: module) == base[module]) }
    let file = relocated.appendingPathComponent("source/Core.swift")
    try Data("let literal = \"\(relocated.path)\"".utf8).write(to: file)
    next.prepare(log: log)
    #expect(next.identity(for: "Core") != base["Core"])
    try FileManager.default.removeItem(at: relocated.appendingPathComponent("derived/Core-dependencies-1.json"))
    next.prepare(log: log)
    #expect(next.identity(for: "Core") == nil) // Missing metadata cannot become a hit.
    #expect(next.identity(for: "Tests") == nil)
}

@Test func moduleCachePayloadUsesSharedIntegrityAndEvictionSafeguards() throws {
    let fixture = try ModuleCacheFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let identity = try #require(try fixture.identities()["Core"])
    let node = FunctionNode(id: "core", module: "Core", name: "core()", regions: [.init(path: "Core.swift", startLine: 1, endLine: 1)], dependencies: ["callback"], uncertainties: ["Indirect function invocation"], dynamicDeclarations: ["P.run"])
    let fragment = SILModule(functions: ["core": node], dispatchTargets: ["P.run": ["core"]])
    try fixture.cache.storeModule(fragment, identity: identity)
    let loaded = try #require(try fixture.cache.loadModule(identity))
    #expect(loaded.functions["core"]?.regions == node.regions)
    #expect(loaded.functions["core"]?.dependencies == node.dependencies)
    #expect(loaded.functions["core"]?.uncertainties == node.uncertainties)
    #expect(loaded.dispatchTargets == fragment.dispatchTargets)
    let path = fixture.cache.options.directory.appendingPathComponent(try XcodeGraphCache.key(identity)).appendingPathComponent("graph.bin")
    try Data("corrupt".utf8).write(to: path)
    #expect(try fixture.cache.loadModule(identity) == nil)
    #expect(!FileManager.default.fileExists(atPath: path.path))
}

@Test func cachedModuleGraphsAndSelectionsMatchFreshAcrossRevisionChanges() throws {
    var fixture = try ModuleCacheFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let compiler = fixture.root.appendingPathComponent("compiler")
    let script = #"""
    #!/usr/bin/env python3
    import pathlib, re, shlex, sys
    args = sys.argv[1:]
    module = args[args.index('-module-name')+1]
    sources = shlex.split(pathlib.Path(next(a[1:] for a in args if a.startswith('@'))).read_text())
    output = []
    for source in sources:
        for number, line in enumerate(pathlib.Path(source).read_text().splitlines(), 1):
            match = re.search(r'func (\w+)\(', line)
            if not match: continue
            name = match[1]
            display = ('Case.' if module == 'Tests' else '') + name + '()'
            symbol = module + '.' + name
            output += [f'// {display}, loc "{source}":{number}:1', f'sil hidden @{symbol} : $@convention(thin) () -> () {{']
            for target in re.findall(r'(core|helper|other)\(\)', line.split('{',1)[-1]):
                owner = 'Other' if target == 'other' else 'Core'
                output += [f'  %0 = function_ref @{owner}.{target} : $@convention(thin) () -> ()']
            output += [f"}} // end sil function '{symbol}'"]
    pathlib.Path(args[args.index('-o')+1]).write_text('\n'.join(output))
    """#
    try Data(script.utf8).write(to: compiler)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: compiler.path)
    fixture.log = fixture.log.replacingOccurrences(of: "/usr/bin/true", with: compiler.path)
    let testsMap = fixture.derived.appendingPathComponent("Tests-dependencies-1.json")
    var imports = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: testsMap)) as? [[String: Any]])
    imports.append(["moduleName": "Other", "modulePath": fixture.derived.appendingPathComponent("Other.swiftmodule").path, "isFramework": false])
    try JSONSerialization.data(withJSONObject: imports).write(to: testsMap)
    var testNames = ["testCore", "testOther"]
    var testsPath = "Tests.swift"
    func write(_ file: String, _ text: String) throws { try Data(text.utf8).write(to: fixture.source.appendingPathComponent(file)) }
    try write("Core.swift", "public func core() {}\n")
    try write("Other.swift", "public func other() {}\n")
    try write("App.swift", "import Core\npublic func app() { core() }\n")
    let originalTests = "import Core\nimport Other\nclass Case {\nfunc testCore() { core() }\nfunc testOther() { other() }\n}\n"
    try write(testsPath, originalTests)
    func graph(cached: Bool) throws -> (XcodeTestGraph, Int) {
        var sources: [String: SwiftSourceSnapshot] = [:]
        var ownership: [String: Set<String>] = [:]
        var targets: [XcodeTarget] = []
        for module in ["Core", "App", "Tests", "Other"] {
            let path = module == "Tests" ? testsPath : module + ".swift"
            sources[module + ":" + path] = SwiftSourceSnapshot.parse(try String(contentsOf: fixture.source.appendingPathComponent(path), encoding: .utf8), path: path, module: module)
            ownership[module] = [path]
            targets.append(XcodeTarget(name: module, productType: module == "Tests" ? "com.apple.product-type.bundle.unit-test" : "com.apple.product-type.framework", sourceFiles: [path]))
        }
        let modules = Dictionary(uniqueKeysWithValues: ["Core", "App", "Tests", "Other"].map { ($0, $0) })
        let tests = testNames.map { "Tests/Case/" + $0 + "()" }.sorted()
        var compiled = 0
        let fragments = XcodeModuleCache(cache: fixture.cache, identity: fixture.context, source: fixture.source, derived: fixture.derived, workspace: fixture.root)
        var dependencies = XcodeCompilerGraph.extract(log: fixture.log, sourceRoot: fixture.source, directory: fixture.root, derived: fixture.derived, progress: { if $0.hasPrefix("Compiled ") { compiled += 1 } }, ownership: ownership, workers: cached ? 2 : 1, moduleCache: cached ? fragments : nil)
        #expect(dependencies.diagnostics.isEmpty)
        XcodeCompilerGraph.bind(tests: tests, modules: modules, sources: sources, graph: &dependencies)
        var graph = XcodeTestGraph(targets: targets, tests: tests)
        graph.modules = modules; graph.sources = sources; graph.dependencies = dependencies
        let policy = fixture.source.appendingPathComponent(".swift-test-selection.json")
        if FileManager.default.fileExists(atPath: policy.path) {
            graph.mappings = try JSONDecoder().decode(UIFeatureMappings.self, from: Data(contentsOf: policy))
            try graph.mappings?.validate()
        }
        return (graph, compiled)
    }
    var previous = try graph(cached: true).0
    func compare(_ changes: [FileChange], expectedCompilations: Int) throws {
        let (cached, compiled) = try graph(cached: true)
        let (fresh, _) = try graph(cached: false)
        #expect(compiled == expectedCompilations)
        #expect(try XcodeGraphCache.canonicalInventory(JSONEncoder().encode(cached)) == XcodeGraphCache.canonicalInventory(JSONEncoder().encode(fresh)))
        for base in [previous, nil] as [XcodeTestGraph?] { // Incompatible/unavailable base retains fallback semantics.
            let expected = XcodeSelector.select(current: fresh, previous: base, changes: changes, baseRevision: "base")
            let actual = XcodeSelector.select(current: cached, previous: base, changes: changes, baseRevision: "base")
            #expect(expected.selectedTests == actual.selectedTests)
            #expect(expected.fullRunReasons == actual.fullRunReasons)
            #expect(expected.onlyTestingArguments == actual.onlyTestingArguments)
            #expect(try XcodeGraphCache.canonicalInventory(JSONEncoder().encode(expected.explanations)) == XcodeGraphCache.canonicalInventory(JSONEncoder().encode(actual.explanations)))
        }
        previous = fresh
    }
    fixture.context["revision"] = "new-head"
    try compare([], expectedCompilations: 0)
    try write(testsPath, originalTests.replacingOccurrences(of: "core() }", with: "core(); core() }"))
    try compare([FileChange(path: testsPath)], expectedCompilations: 1)
    testNames.append("testAdded")
    try write(testsPath, originalTests.replacingOccurrences(of: "func testOther", with: "func testAdded() { core() }\nfunc testOther"))
    try compare([FileChange(path: testsPath)], expectedCompilations: 1)
    testNames = ["testCore"]
    try write(testsPath, "import Core\nclass Case {\nfunc testCore() { core() }\n}\n")
    try compare([FileChange(path: testsPath)], expectedCompilations: 1)
    try write("Core.swift", "public func core() { helper() }\nfunc helper() {}\n")
    try compare([FileChange(path: "Core.swift")], expectedCompilations: 3)
    let oldPath = testsPath
    testsPath = "MovedTests.swift"
    try FileManager.default.moveItem(at: fixture.source.appendingPathComponent(oldPath), to: fixture.source.appendingPathComponent(testsPath))
    try Data(fixture.source.appendingPathComponent(testsPath).path.utf8).write(to: fixture.derived.appendingPathComponent("Tests.SwiftFileList"))
    var move = FileChange(path: testsPath)
    move.previousPath = oldPath; move.isPureMove = true
    try compare([move], expectedCompilations: 1)
    try write(".swift-test-selection.json", #"{"version":1,"features":[{"name":"Core","sources":["Core.swift"],"tests":["Tests/Case/testCore()"]}]}"#)
    try compare([FileChange(path: ".swift-test-selection.json")], expectedCompilations: 4)
    #expect(previous.mappings?.features.first?.sources == ["Core.swift"])
    try write(".swift-test-selection.json", #"{"version":1,"features":[{"name":"Other","sources":["Other.swift"],"tests":["Tests/Case/testCore()"]}]}"#)
    try compare([FileChange(path: ".swift-test-selection.json")], expectedCompilations: 4)
    #expect(previous.mappings?.features.first?.sources == ["Other.swift"])
    fixture.context["externalInputs"] = "changed compiler environment"
    try compare([FileChange(path: "Core.swift")], expectedCompilations: 4)
    fixture.context["revision"] = "stacked-head"
    try compare([FileChange(path: "Core.swift")], expectedCompilations: 0)
}

@Test func moduleCacheTreatsAvailabilityAndUnknownPluginsConservatively() throws {
    var fixture = try ModuleCacheFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try Data("#if canImport(Core)\nfunc other() {}\n#endif".utf8).write(to: fixture.source.appendingPathComponent("Other.swift"))
    let before = try fixture.identities()
    try Data("public func core(_ changedAPI: Int) {}".utf8).write(to: fixture.source.appendingPathComponent("Core.swift"))
    #expect(try fixture.identities()["Other"] != before["Other"])
    let fragments = XcodeModuleCache(cache: fixture.cache, identity: fixture.context, source: fixture.source, derived: fixture.derived, workspace: fixture.root)
    fragments.prepare(log: fixture.log)
    let identity = try #require(fragments.identity(for: "Core"))
    try fragments.stage(SILModule(functions: [:], dispatchTargets: [:]), identity: identity)
    try Data("public func core() {}".utf8).write(to: fixture.source.appendingPathComponent("Core.swift"))
    #expect(throws: ImpactError.self) { try fragments.finish(log: fixture.log) }
    #expect(try fixture.cache.loadModule(identity) == nil)
    fixture.log += " -load-plugin-executable /custom/plugin#Macros"
    fragments.prepare(log: fixture.log)
    #expect(fragments.identity(for: "Core") == nil)
}

@Test func ordinaryCanImportPropertiesDoNotInvalidateUnrelatedModules() throws {
    let fixture = try ModuleCacheFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try Data("struct Other { var canImport: Bool { false } }\n#if DEBUG\nfunc debug() {}\n#endif".utf8).write(to: fixture.source.appendingPathComponent("Other.swift"))
    let before = try fixture.identities()
    try Data("public func core(_ changedAPI: Int) {}".utf8).write(to: fixture.source.appendingPathComponent("Core.swift"))
    #expect(try fixture.identities()["Other"] == before["Other"])
}

@Test func moduleCacheTracksGeneratedSourceSymlinkTargets() throws {
    let fixture = try ModuleCacheFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let first = fixture.derived.appendingPathComponent("First.swift")
    let second = fixture.derived.appendingPathComponent("Second.swift")
    let alias = fixture.derived.appendingPathComponent("Generated.swift")
    for file in [first, second] { try Data("func generated() {}".utf8).write(to: file) }
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: first)
    try Data(alias.path.utf8).write(to: fixture.derived.appendingPathComponent("Tests.SwiftFileList"))
    let before = try fixture.identities()
    try FileManager.default.removeItem(at: alias)
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: second)
    let after = try fixture.identities()
    // Derived inputs are outside the repository manifest. Equal bytes still
    // require a miss when the SIL source-region path changes.
    #expect(before["Tests"] != after["Tests"])
    for module in ["Core", "App", "Other"] { #expect(before[module] == after[module]) }
}

@Test func moduleCacheBypassesPresumedLocationsAndTransitiveImporters() throws {
    let fixture = try ModuleCacheFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try Data("#sourceLocation(file: \"/old/Generated.swift\", line: 1)\npublic func core() {}".utf8).write(to: fixture.source.appendingPathComponent("Core.swift"))
    // Tests imports App, which imports Core: the bypass must be transitive.
    let map = fixture.derived.appendingPathComponent("Tests-dependencies-1.json")
    var imports = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: map)) as? [[String: Any]])
    imports[1]["moduleName"] = "App"
    imports[1]["modulePath"] = fixture.derived.appendingPathComponent("App.swiftmodule").path
    try JSONSerialization.data(withJSONObject: imports).write(to: map)
    let fragments = XcodeModuleCache(cache: fixture.cache, identity: fixture.context,
        source: fixture.source, derived: fixture.derived, workspace: fixture.root)
    fragments.prepare(log: fixture.log)
    for module in ["Core", "App", "Tests"] { #expect(fragments.identity(for: module) == nil) }
    #expect(fragments.identity(for: "Other") != nil)
}

@Test func moduleCacheIgnoresSourceLocationMentionsInTriviaAndStrings() throws {
    let fixture = try ModuleCacheFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let text = #"""
    // #sourceLocation(file: "/old/File.swift", line: 1)
    let example = "#sourceLocation(file: \"/old/File.swift\", line: 1)"
    #sourceLocation()
    public func core() {}
    """#
    try Data(text.utf8).write(to: fixture.source.appendingPathComponent("Core.swift"))
    #expect(try fixture.identities().count == 4)
}
