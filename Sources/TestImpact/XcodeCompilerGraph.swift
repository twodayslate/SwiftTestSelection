// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation

enum XcodeCompilerGraph {
    static func extract(log: String, sourceRoot: URL, directory: URL, derived: URL,
                        progress: (String) -> Void, ownership: [String: Set<String>] = [:],
                        workers: Int = 1, cancellation: XcodeExtractionCancellation = .init(), moduleCache: XcodeModuleCache? = nil, captured: CapturedSIL? = nil, measurement: (String, Double) -> Void = { _, _ in }) -> DependencyGraph {
        var graph = DependencyGraph()
        graph.compilerImplicitImports = [:]
        guard (1...8).contains(workers) else {
            graph.diagnostics.append("Extraction workers must be between 1 and 8.")
            return graph
        }
        let cacheLog: String
        do { cacheLog = try captured?.replayLog(log) ?? log }
        catch { graph.diagnostics.append("Cannot validate captured compiler commands: \(error)"); return graph }
        moduleCache?.prepare(log: cacheLog)
        captured?.diagnostics.forEach(progress)
        var seen: [String: [String]] = [:]
        var jobs: [XcodeModuleJob] = []
        // Validate inventory before scheduling; identical/ambiguous duplicates keep
        // their original behavior regardless of worker completion order.
        for line in log.components(separatedBy: .newlines) {
            guard let marker = line.range(of: "builtin-SwiftDriver -- ") else { continue }
            do {
                let invocation = try XcodeSourceFileList.parse(String(line[marker.upperBound...]))
                guard let compiler = invocation.first,
                      let index = invocation.firstIndex(of: "-module-name"), index + 1 < invocation.count else {
                    throw ImpactError("Unrecognized SwiftDriver invocation")
                }
                let module = invocation[index + 1]
                graph.compilerImplicitImports?[module] = try implicitImports(invocation)
                if let earlier = seen[module] {
                    if earlier != invocation {
                        graph.compilerImplicitImports = nil
                        graph.diagnostics.append("Multiple distinct compiler invocations for module \(module); architecture/target ambiguity requires a full selection.")
                    }
                    continue
                }
                seen[module] = invocation
                jobs.append(XcodeModuleJob(module: module, compiler: compiler, arguments: Array(invocation.dropFirst())))
            } catch {
                graph.compilerImplicitImports = nil
                graph.diagnostics.append("Compiler dependency extraction failed: \(error)")
            }
        }
        if seen.isEmpty { graph.diagnostics.append("No supported SwiftDriver invocations found in Xcode build output.") }
        progress("Extracting \(jobs.count) Xcode modules with \(workers) worker(s)…")
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = workers
        let results = jobs.map { _ in XcodeModuleResult() }
        let access = ModuleCacheAccess(moduleCache)
        // Only workers retain parsed fragments. Completed jobs publish small disk
        // references, allowing the next job to start even if ordered merge waits.
        let spool = derived.appendingPathComponent("impact-spool-" + UUID().uuidString)
        do { try FileManager.default.createDirectory(at: spool, withIntermediateDirectories: true) }
        catch { graph.diagnostics.append("Cannot stage compiler fragments: \(error)"); return graph }
        defer { queue.waitUntilAllOperationsAreFinished(); try? FileManager.default.removeItem(at: spool) }
        func schedule(_ index: Int) {
            let job = jobs[index]
            let result = results[index]
            queue.addOperation {
                result.complete {
                    try cancellation.check()
                    let cached = access.load(job.module)
                    let stage = spool.appendingPathComponent(String(index))
                    func publish(_ fragment: SILModule) throws -> XcodeModuleFragment {
                        let module = try SILOwnership.resolve(fragment, module: job.module, compiler: job.compiler, directory: directory)
                        if workers == 1 { return .memory(module) }
                        try GraphArchive.encodeValue(module).write(to: stage)
                        return .file(stage)
                    }
                    if let cached {
                        return (try publish(cached), ["Module cache \(job.module): hit: compatible compiler inputs; skipped compiler and parser"], true)
                    }
                    var captureMessages: [String] = []
                    let consumption = AnalysisMeasurement()
                    let captureStart = Date()
                    do {
                        if let capturedModule = try captured?.parse(module: job.module, sourceRoot: sourceRoot) {
                            result.measurements["captureConsumption"] = Date().timeIntervalSince(captureStart)
                            return (try publish(capturedModule), [consumption.report("Captured SIL \(job.module): validated primary coverage; skipped compiler replay")], false)
                        }
                    } catch let error as CapturedSIL.UnsupportedLayout {
                        captureMessages.append("Captured SIL \(job.module): \(error); replaying module")
                    }
                    let output = derived.appendingPathComponent("impact-\(UUID().uuidString).sil")
                    defer { try? FileManager.default.removeItem(at: output) }
                    let args = arguments(captured?.replayArguments(job.arguments) ?? job.arguments) + ["-emit-sil", "-whole-module-optimization", "-Onone", "-g", "-o", output.path]
                    let compilation = AnalysisMeasurement()
                    let compilationStart = Date()
                    _ = try CommandRunner.run(job.compiler, args, at: directory)
                    result.measurements["compilerReplay"] = Date().timeIntervalSince(compilationStart)
                    let compiled = compilation.report("Compiled \(job.module)")
                    try cancellation.check()
                    let parsing = AnalysisMeasurement()
                    let parsingStart = Date()
                    let parsed = try SILParser.parse(file: output, module: job.module, sourceRoot: sourceRoot)
                    result.measurements["silParsing"] = Date().timeIntervalSince(parsingStart)
                    let bytes = (try? output.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    try cancellation.check()
                    guard !parsed.functions.isEmpty else { throw ImpactError("No SIL functions for \(job.module)") }
                    let message = parsing.report("Parsed \(job.module) (\(bytes) SIL bytes, \(parsed.functions.count) functions)")
                    return (try publish(parsed), captureMessages + [compiled, message], false)
                }
            }
        }
        for index in 0..<(workers == 1 ? min(1, jobs.count) : jobs.count) { schedule(index) }
        var definingSymbols = Set<String>()
        var dispatch: [String: Set<String>] = [:]
        var externalWitnesses: [String: Set<String>] = [:]
        for (index, job) in jobs.enumerated() {
            let result = results[index]
            defer { if workers == 1 && index + 1 < jobs.count { schedule(index + 1) } }
            do {
                let (fragment, messages, hit) = try result.take()
                for (phase, seconds) in result.measurements.sorted(by: { $0.key < $1.key }) { measurement(phase, seconds) }
                defer { fragment.remove() }
                let parsed = try fragment.load()
                messages.forEach(progress)
                if !hit, let identity = moduleCache?.identity(for: job.module) {
                    do { try moduleCache?.stage(parsed, identity: identity) }
                    catch { progress("Module cache publication bypass \(job.module): \(error)") }
                }
                for (symbol, node) in parsed.functions {
                    // Imported bodies can point into files also compiled by this module.
                    let isDefinition = !(parsed.importedSymbols?.contains(symbol) ?? false) && node.regions.contains { ownership[job.module]?.contains($0.path) == true }
                    if isDefinition || !definingSymbols.contains(symbol) && (graph.functions[symbol] == nil || !node.regions.isEmpty && graph.functions[symbol]!.regions.isEmpty) {
                        graph.functions[symbol] = node
                    }
                    if isDefinition { definingSymbols.insert(symbol) }
                }
                for (declaration, symbols) in parsed.dispatchTargets { dispatch[declaration, default: []].formUnion(symbols) }
                for (key, owners) in parsed.externalWitnesses ?? [:] { externalWitnesses[key, default: []].formUnion(owners) }
            } catch {
                let diagnostic = "Compiler dependency extraction failed: \(job.module): \(error)"
                graph.diagnostics.append(diagnostic)
                progress(diagnostic)
            }
        }
        queue.waitUntilAllOperationsAreFinished()
        if cancellation.isCancelled {
            // Never expose a partially merged success on cooperative cancellation.
            graph = DependencyGraph()
            graph.diagnostics = ["Compiler dependency extraction cancelled; a full selection is required."]
            return graph
        }
        do { try moduleCache?.finish(log: cacheLog) }
        catch {
            graph = DependencyGraph()
            graph.diagnostics = ["Compiler dependency extraction failed: \(error)"]
            return graph
        }
        resolveDispatch(&graph, tables: dispatch, externalWitnesses: externalWitnesses, projectModules: Set(jobs.map(\.module)))

        return graph
    }

    static func resolveDispatch(_ graph: inout DependencyGraph, tables: [String: Set<String>],
                                externalWitnesses: [String: Set<String>] = [:], projectModules: Set<String>? = nil) {
        let localModules = projectModules ?? Set(graph.functions.values.filter { !$0.regions.isEmpty }.map(\.module))
        for symbol in graph.functions.keys {
            for declaration in graph.functions[symbol]!.dynamicDeclarations {
                if let candidates = tables[declaration], !candidates.isEmpty {
                    graph.functions[symbol]!.dependencies.formUnion(candidates)
                    graph.functions[symbol]!.resolvedDynamicDeclarations.insert(declaration)
                } else if let separator = declaration.range(of: "@witness:") {
                    let general = String(declaration[..<separator.lowerBound])
                    let requirement = general.split(separator: ".").dropLast().joined(separator: ".")
                    let key = requirement + declaration[separator.lowerBound...]
                    if let owners = externalWitnesses[graph.functions[symbol]!.module + ":" + key], owners.count == 1, owners.isDisjoint(with: localModules) {
                        // The compiler, not a Foundation/type-name allowlist,
                        // establishes the concrete conformance's external owner.
                        // This resolves ownership, not the implementation body.
                        // SDK classes/type erasers may call project overrides or
                        // conformances: retain runtime uncertainty until a valid
                        // closed-module boundary can exclude the changed module.
                        graph.functions[symbol]!.resolvedDynamicDeclarations.insert(declaration)
                        graph.functions[symbol]!.uncertainties.insert("Imported conformance: " + key + " module " + owners.first!)
                        continue
                    }
                    // Never turn a missing concrete table into proof of no impact.
                    graph.functions[symbol]!.dependencies.formUnion(tables[general] ?? [])
                    graph.functions[symbol]!.uncertainties.insert("Unresolved project dispatch: " + declaration)
                }
            }
        }
    }

    static func arguments(_ arguments: [String]) -> [String] {
        let remove: Set<String> = ["-use-frontend-parseable-output", "-save-temps", "-emit-dependencies", "-emit-const-values", "-experimental-emit-module-separately", "-explicit-module-build", "-O", "-Osize", "-Ounchecked", "-Onone", "-whole-module-optimization"]
        return PackageAnalyzer.silArguments(arguments).filter { !remove.contains($0) }
    }

    static func implicitImports(_ arguments: [String]) throws -> Set<String> {
        // Driver forwarding markers do not change frontend option/operand pairs.
        let args = arguments.filter { $0 != "-Xfrontend" }
        let options: Set<String> = ["-import-module", "-testable-import-module"]
        var imports = Set<String>()
        for (index, argument) in args.enumerated() {
            if options.contains(argument) {
                guard index + 1 < args.count, !args[index + 1].hasPrefix("-") else {
                    throw ImpactError("Missing implicit import operand: \(argument)")
                }
                imports.insert(args[index + 1])
            } else if let separator = argument.firstIndex(of: "="), options.contains(String(argument[..<separator])) {
                let name = String(argument[argument.index(after: separator)...])
                guard !name.isEmpty else { throw ImpactError("Empty implicit import operand") }
                imports.insert(name)
            }
        }
        return imports
    }

    static func bind(tests: [String], modules: [String: String], sources: [String: SwiftSourceSnapshot], graph: inout DependencyGraph) {
        let inheritance = sources.values.reduce(into: [String: [String]]()) { result, file in
            result.merge(file.inheritance) { Array(Set($0 + $1)) }
        }
        let projectTypes = Set(sources.values.flatMap { $0.units.filter { $0.kind == "type" }.map(\.scope) })
        let projectMembers = Set(sources.values.flatMap { $0.dispatchMembers ?? [] })
        // Index the exact prefixes used by the conservative dispatch matcher.
        // Re-scanning every function for every unresolved declaration is quadratic
        // on large XCTest targets. Store only prefixes present in declarations.
        let declarations = Set(graph.functions.values.flatMap(\.dynamicDeclarations))
        // Imported Objective-C methods have no project Swift vtable slot. A
        // dispatch through the base class must still reach declared overrides.
        let superclasses = sources.values.reduce(into: [String: [String]]()) { result, file in
            result.merge(file.superclasses ?? file.inheritance) { Array(Set($0 + $1)) }
        }
        let nominalParents = Dictionary(uniqueKeysWithValues: Set(superclasses.values.flatMap { $0 }).compactMap { spelling in
            SwiftSourceSnapshot.nominalTypeName(spelling).map { (spelling, $0) }
        })
        let typeAliases = Set(sources.values.flatMap { $0.typeAliases ?? [] })
        let nominalTypes = Set(sources.values.flatMap { file in
            file.units.filter { $0.kind == "type" }.map {
                String($0.key.prefix { $0 != ":" }) + "." + $0.scope
            }
        })
        func containsAlias(_ name: String) -> Bool {
            typeAliases.contains(name) || name.indices.contains {
                name[$0] == "." && typeAliases.contains(String(name[..<$0]))
            }
        }
        func resolveSuperclass(_ parent: String, of owner: String) -> (candidates: [String], complete: Bool) {
            // Swift resolves an unqualified name from its enclosing scopes
            // outward. A module-level class must not hide a nested superclass.
            var scope = owner.split(separator: ".").dropLast()
            let qualifier = parent.firstIndex(of: ".").map { String(parent[..<$0]) }
            while !scope.isEmpty {
                let enclosingType = scope.joined(separator: ".")
                let prefix = enclosingType + "."
                let candidate = prefix + parent
                if containsAlias(candidate) { return ([], false) }
                if superclasses[candidate] != nil { return ([candidate], true) }
                // A nearer nominal qualifier shadows outer names even if its
                // member is inherited and absent from this declaration index.
                // Keep that ancestry unknown instead of choosing an unrelated
                // outer class with the same qualified spelling.
                if let qualifier, nominalTypes.contains(prefix + qualifier) { return ([], false) }
                // Inherited members of the enclosing class precede outer
                // lexical scopes too. This includes unqualified nested classes,
                // aliases, and the first component of a qualified name. Their
                // absence from the declaration index does not prove absence
                // from the inherited scope, so do not accept an outer match.
                if let parents = superclasses[enclosingType], !parents.isEmpty { return ([], false) }
                scope = scope.dropLast()
            }
            if containsAlias(parent) { return ([], false) }
            if superclasses[parent] != nil { return ([parent], true) }
            let candidates = superclasses.keys.filter { $0.hasSuffix("." + parent) }
            // Imports are not resolved by this index. Retain possible imported
            // classes without treating a same-named class as proof of ancestry.
            return (candidates, candidates.isEmpty)
        }
        let declarationsByMember = Dictionary(grouping: declarations, by: { $0.split(separator: ".").last.map(String.init) ?? $0 })
        var overrides: [String: Set<String>] = [:]
        var unresolvedOverrideDeclarations = Set<String>()
        var ancestorCache: [String: (names: Set<String>, complete: Bool)] = [:]
        for member in sources.values.flatMap({ $0.dispatchOverrides ?? [] }) {
            guard let dot = member.lastIndex(of: "."), let moduleEnd = member.firstIndex(of: ".") else { continue }
            let owner = String(member[..<dot]), method = String(member[member.index(after: dot)...])
            let implementation = String(member[member.index(after: moduleEnd)...])
            let ancestors: (names: Set<String>, complete: Bool)
            if let cached = ancestorCache[owner] { ancestors = cached }
            else {
                var names = Set<String>(), visited = Set<String>(), pending = [owner]
                var complete = true
                while let type = pending.popLast() {
                    guard visited.insert(type).inserted else { continue }
                    guard let parents = superclasses[type] else { complete = false; continue }
                    for spelling in parents {
                        guard let parent = nominalParents[spelling] else { complete = false; continue }
                        names.insert(parent)
                        let resolution = resolveSuperclass(parent, of: type)
                        let candidates = resolution.candidates
                        if !resolution.complete { complete = false }
                        for candidate in candidates {
                            names.insert(String(candidate.dropFirst(candidate.prefix { $0 != "." }.count + 1)))
                            pending.append(candidate)
                        }
                        // SIL omits an imported type's module qualifier.
                        if candidates.isEmpty, let separator = parent.firstIndex(of: ".") {
                            names.insert(String(parent[parent.index(after: separator)...]))
                        }
                        // The same SDK roots are recognized by test binding.
                        // Other external/aliased bases have unknown ancestors.
                        if candidates.isEmpty {
                            if ["XCTestCase", "XCTest.XCTestCase"].contains(parent) { names.insert("NSObject") }
                            else if !["NSObject", "Foundation.NSObject"].contains(parent) { complete = false }
                        }
                    }
                }
                ancestors = (names, complete); ancestorCache[owner] = ancestors
            }
            let knownDeclarations = Set(ancestors.names.map { $0 + "." + method }).union([implementation])
            if !ancestors.complete {
                unresolvedOverrideDeclarations.formUnion(Set(declarationsByMember[method] ?? []).subtracting(knownDeclarations))
            }
            for ancestor in ancestors.names where declarations.contains(ancestor + "." + method) {
                overrides[ancestor + "." + method, default: []].insert(implementation)
            }
        }
        let overrideNames = Set(overrides.values.flatMap { $0 })
        let implementationNames = declarations.union(overrideNames)
        var implementations: [String: Set<String>] = [:]
        for node in graph.functions.values where !node.regions.isEmpty {
            let name = node.name.hasPrefix("static ") ? String(node.name.dropFirst(7)) : node.name
            for index in name.indices {
                let character = name[index]
                if character == "." || character == "(" {
                    let prefix = String(name[..<index])
                    if (node.name.hasPrefix("static ") ? overrideNames : implementationNames).contains(prefix) { implementations[prefix, default: []].insert(node.id) }
                }
            }
        }
        for symbol in graph.functions.keys {
            for declaration in graph.functions[symbol]!.dynamicDeclarations {
                // Super dispatch cannot target a descendant override, even when
                // that descendant's ancestry is only partially known.
                let checkOverrides = overrides[declaration] != nil || unresolvedOverrideDeclarations.contains(declaration)
                let dispatches = checkOverrides ? graph.functions[symbol]!.uncertainties.filter {
                    $0.hasPrefix("Dynamic dispatch:") && ($0.hasSuffix(" " + declaration) || $0.contains(" " + declaration + "!"))
                } : []
                let onlySuper = !dispatches.isEmpty && dispatches.allSatisfy {
                    $0.hasPrefix("Dynamic dispatch: super_method ") || $0.hasPrefix("Dynamic dispatch: objc_super_method ")
                }
                if unresolvedOverrideDeclarations.contains(declaration) && !onlySuper {
                    graph.functions[symbol]!.uncertainties.insert("Unresolved project dispatch: " + declaration + " (incomplete override ancestry)")
                }
                var overrideCandidates = Set<String>()
                if let members = overrides[declaration] {
                    for implementation in onlySuper ? [] : members {
                        if let candidates = implementations[implementation], !candidates.isEmpty {
                            overrideCandidates.formUnion(candidates)
                        } else {
                            graph.functions[symbol]!.uncertainties.insert("Unresolved project dispatch: " + declaration)
                        }
                    }
                }
                graph.functions[symbol]!.dependencies.formUnion(overrideCandidates)
                if !graph.functions[symbol]!.resolvedDynamicDeclarations.contains(declaration) {
                    // Objective-C entry points (including XCTest initializers)
                    // may have no Swift vtable slot. Include all matching
                    // compiled implementations rather than dropping the edge.
                    let candidates = (implementations[declaration] ?? []).union(overrideCandidates)
                    if !candidates.isEmpty {
                        graph.functions[symbol]!.dependencies.formUnion(candidates)
                        graph.functions[symbol]!.resolvedDynamicDeclarations.insert(declaration)
                        continue
                    }
                    let ownedType = declaration.indices.contains { declaration[$0] == "." && projectTypes.contains(String(declaration[..<$0])) }
                    if ownedType || projectMembers.contains(declaration) {
                        graph.functions[symbol]!.uncertainties.insert("Unresolved project dispatch: " + declaration)
                    }
                }
            }
        }
        // Preserve every matching symbol, including thunks and duplicate names.
        var entries: [String: [String: Set<String>]] = [:]
        var hooks: [String: [String: Set<String>]] = [:]
        let hookPrefixes = ["setUp(", "setUpWithError(", "tearDown(", "tearDownWithError(",
                            "init(", "__allocating_init(", "deinit", "__deallocating_deinit"]
        for node in graph.functions.values where !node.regions.isEmpty {
            entries[node.module, default: [:]][node.name, default: []].insert(node.id)
            let variablePrefix = "variable initialization expression of "
            let variable = node.name.hasPrefix(variablePrefix)
            let name = variable ? String(node.name.dropFirst(variablePrefix.count)) :
                node.name.hasPrefix("static ") ? String(node.name.dropFirst(7)) : node.name
            // Every dotted prefix is considered, preserving nested-type and
            // variable-initializer prefix semantics of the original matcher.
            for dot in name.indices where name[dot] == "." {
                let suffix = name[name.index(after: dot)...]
                if variable || hookPrefixes.contains(where: { suffix.hasPrefix($0) }) {
                    hooks[node.module, default: [:]][String(name[..<dot]), default: []].insert(node.id)
                }
            }
        }
        struct ClassBinding {
            var classes: [String: Set<String>]
            var hooks: Set<String>
            var diagnostics: [String]
        }
        var bindings: [String: ClassBinding] = [:]
        for test in tests {
            let parts = test.split(separator: "/").map(String.init)
            if parts.count == 2, let module = modules[parts[0]], parts[1].hasSuffix(")") {
                graph.tests[test] = entries[module]?[parts[1]] ?? []
                continue
            }
            guard parts.count == 3, let module = modules[parts[0]] else {
                graph.tests[test] = []
                continue
            }
            let classKey = module + "." + parts[1]
            let binding: ClassBinding
            if let cached = bindings[classKey] { binding = cached }
            else {
                var classes: [String: Set<String>] = [module: [parts[1]]]
                var diagnostics: [String] = []
                var visited = Set<String>()
                var queue = [classKey]
                while let key = queue.popLast() {
                    guard visited.insert(key).inserted else { continue }
                    let definingModule = String(key.prefix { $0 != "." })
                    for parent in inheritance[key] ?? [] {
                        if ["XCTestCase", "XCTest.XCTestCase", "NSObject", "Foundation.NSObject"].contains(parent) { continue }
                        let local = definingModule + "." + parent
                        let candidates = inheritance[local] != nil ? [local] : inheritance.keys.filter { $0 == parent || $0.hasSuffix("." + parent) }
                        if candidates.isEmpty {
                            diagnostics.append("Cannot resolve inherited lifecycle/fixture type: " + parent)
                        }
                        for candidate in candidates {
                            let parentModule = String(candidate.prefix { $0 != "." })
                            let parentClass = String(candidate.dropFirst(parentModule.count + 1))
                            classes[parentModule, default: []].insert(parentClass)
                            queue.append(candidate)
                        }
                    }
                }
                var roots = Set<String>()
                for (owner, names) in classes {
                    for name in names { roots.formUnion(hooks[owner]?[name] ?? []) }
                }
                binding = ClassBinding(classes: classes, hooks: roots, diagnostics: diagnostics)
                bindings[classKey] = binding
            }
            if !binding.diagnostics.isEmpty {
                graph.testDiagnostics[test, default: []].append(contentsOf: binding.diagnostics)
            }
            let method = parts[2].contains("(") ? parts[2] : parts[2] + "()"
            var roots = Set<String>()
            for (owner, names) in binding.classes {
                for name in names { roots.formUnion(entries[owner]?[name + "." + method] ?? []) }
            }
            // Hooks belong only to tests with a known entry, as before.
            if !roots.isEmpty { roots.formUnion(binding.hooks) }
            graph.tests[test] = roots
        }
    }
}
