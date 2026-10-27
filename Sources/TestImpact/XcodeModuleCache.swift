// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation
import SwiftParser
import SwiftSyntax

/// Parsed compiler fragments only: no inventory, policy, dispatch resolution or
/// executable products. Shares the enclosing revision cache's lock and budget.
final class XcodeModuleCache {
    let cache: XcodeGraphCache
    private let context: [String: String]
    private let source: URL
    private let derived: URL
    private let workspace: URL
    private let directory: URL
    private let workers: Int
    private let pathRoots: [(String, String)]
    var inspectIdentityInputs: ((String, [String: String]) -> Void)?
    private var identities: [String: [String: String]] = [:]
    private var pending: [(URL, [String: String])] = []

    deinit { discardPending() }
    private func discardPending() {
        for (path, _) in pending { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        pending = []
    }

    func stage(_ fragment: SILModule, identity: [String: String]) throws {
        // The existing cache recovery removes abandoned stage-* directories
        // after an interrupted process; never leave large orphan files in /tmp.
        let directory = cache.options.directory.appendingPathComponent("stage-module-" + UUID().uuidString)
        let path = directory.appendingPathComponent("fragment.graph")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try GraphArchive.encodeValue(fragment).write(to: path, options: .atomic)
            pending.append((path, identity))
        } catch { try? FileManager.default.removeItem(at: directory); throw error }
    }

    /// Recheck all inputs once before accepting any reused fragments or publishing
    /// newly extracted ones. Stage on disk so this does not retain every module.
    func finish(log: String) throws {
        defer { discardPending() }
        guard !identities.isEmpty else { return }
        let start = Date()
        guard try makeIdentities(log: log) == identities else {
            throw ImpactError("Compiler inputs changed during extraction; no fragments were published")
        }
        cache.progress(String(format: "Module cache final input recheck: %.3f s", Date().timeIntervalSince(start)))
        for (path, identity) in pending {
            do { try cache.storeModule(GraphArchive.decodeValue(SILModule.self, from: Data(contentsOf: path)), identity: identity) }
            catch { cache.progress("Module cache publication bypass: \(error)") }
        }
    }

    init(cache: XcodeGraphCache, identity: [String: String], source: URL, derived: URL, workspace: URL, directory: URL? = nil, workers: Int = 1) {
        self.workers = workers
        self.cache = cache
        var context = identity
        context.removeValue(forKey: "revision")
        context["schema"] = "xcode-module-fragment-11"
        self.context = context
        self.source = source
        self.derived = derived
        self.workspace = workspace
        self.directory = directory ?? source
        // Xcode's package paths can use /private/tmp while callers use /tmp.
        // Resolve only known roots, once; never rewrite arbitrary source text.
        self.pathRoots = [(source, "<SOURCE>"), (derived, "<DERIVED>"), (workspace, "<WORK>")].flatMap { root, token in
            var paths = Set([root.standardizedFileURL.path, root.standardizedFileURL.resolvingSymlinksInPath().path])
            // Foundation deliberately preserves /tmp on Darwin, even when
            // resolving symlinks. POSIX realpath supplies the actual alias.
            if let resolved = realpath(root.path, nil) {
                paths.insert(String(cString: resolved))
                free(resolved)
            }
            return paths.sorted().map { ($0, token) }
        }
    }

    private func normalized(_ path: String) -> String {
        // Normalize path arguments, never source contents or arbitrary flag text.
        Self.normalized(path, roots: pathRoots)
    }

    private static func normalized(_ path: String, roots: [(String, String)]) -> String {
        for prefix in ["", "@", "-I", "-F", "-L"] {
            let value = String(path.dropFirst(prefix.count))
            guard path.hasPrefix(prefix) else { continue }
            for (root, token) in roots {
                if value == root || value.hasPrefix(root + "/") {
                    return prefix + token + value.dropFirst(root.count)
                }
            }
        }
        return path
    }

    /// Unsupported or ambiguous metadata bypasses reuse; extraction still runs.
    func prepare(log: String) {
        discardPending()
        identities = [:]
        let start = Date()
        do { identities = try makeIdentities(log: log) }
        catch { cache.progress("Module cache bypass: \(error)") }
        cache.progress(String(format: "Module cache input validation: %.2f s (%d reusable identities)", Date().timeIntervalSince(start), identities.count))
    }

    func identity(for module: String) -> [String: String]? { identities[module] }

    private func makeIdentities(log: String) throws -> [String: [String: String]] {
        var invocations: [String: [String]] = [:]
        for line in log.components(separatedBy: .newlines) {
            guard let marker = line.range(of: "builtin-SwiftDriver -- ") else { continue }
            let arguments = try XcodeSourceFileList.parse(String(line[marker.upperBound...]))
            guard let index = arguments.firstIndex(of: "-module-name"), index + 1 < arguments.count else { throw ImpactError("Missing module name") }
            let module = arguments[index + 1]
            if let previous = invocations[module], previous != arguments { throw ImpactError("Ambiguous invocations for \(module)") }
            invocations[module] = arguments
        }
        guard !invocations.isEmpty else { throw ImpactError("No compiler inventory") }
        let fileHashes = CompilerInputHashes()
        func hash(_ path: String) throws -> String {
            try fileHashes.digest(path, normalize: normalized)
        }
        // Header/module-map/build-script/configuration changes can affect implicit
        // compiler inputs. Include all repository non-Swift files conservatively.
        // Even policy files may be consumed by a custom build script or macro.
        // Recompute policy separately, but conservatively invalidate these inputs.
        var sharedInputs: [String: String] = [:]
        let files = try ArtifactFiles.manifest(at: source, workers: workers)
        // A Swift symlink can change source-region ownership with identical bytes.
        for (path, digest) in files where !path.hasSuffix(".swift") || digest.hasPrefix("symlink:") {
            sharedInputs[path] = digest
        }
        let scanDirectory = directory, roots = pathRoots, projectModules = Set(invocations.keys)
        let scanResults = try BoundedWork.map(invocations.sorted { $0.key < $1.key }, workers: workers) { module, original in
            let result = Result { try XcodeDependencyInputs.scan(compiler: original[0],
                arguments: XcodeCompilerGraph.arguments(Array(original.dropFirst())), directory: scanDirectory,
                projectModules: projectModules, normalize: { Self.normalized($0, roots: roots) },
                hash: { try fileHashes.digest($0, normalize: { Self.normalized($0, roots: roots) }) }) }
            return (module, result)
        }
        let scans = Dictionary(uniqueKeysWithValues: scanResults)
        var localKeys: [String: String] = [:]
        var imports: [String: Set<String>] = [:]
        var availabilityQueries: [String: Set<String>] = [:]
        var unresolvedAvailability = Set<String>()
        var sourceLocationModules = Set<String>()
        let canImport = try NSRegularExpression(pattern: #"\bcanImport\s*\(\s*`?([A-Za-z_][A-Za-z_0-9.]*)`?"#)
        for (module, original) in invocations {
            let arguments = XcodeCompilerGraph.arguments(Array(original.dropFirst()))
            guard original.contains("-explicit-module-build") else { throw ImpactError("\(module) has no explicit import inventory") }
            guard !original.contains(where: { ["-load-plugin-executable", "-load-plugin-library", "-external-plugin-path"].contains($0) }) else {
                throw ImpactError("Custom compiler plugins require a complete resource-input contract: \(module)")
            }
            let lists = original.filter { $0.hasPrefix("@") }
            guard lists.count == 1 else { throw ImpactError("\(module) requires one unambiguous Swift file list") }
            let list = URL(fileURLWithPath: String(lists[0].dropFirst()))
            let sources = try XcodeSourceFileList.parse(String(contentsOf: list, encoding: .utf8))
            guard !sources.isEmpty, sources.allSatisfy({ $0.hasSuffix(".swift") && $0.hasPrefix("/") }) else {
                throw ImpactError("Unsupported source/response file for \(module)")
            }
            var inputs = sharedInputs
            if directory.standardizedFileURL.path != source.standardizedFileURL.path {
                inputs["compilerWorkingDirectory"] = normalized(directory.path)
            }
            inputs["orderedSources"] = XcodeGraphCache.digest(try JSONEncoder().encode(sources.map(normalized)))
            // Match SILParser's path resolution, including generated inputs outside
            // the repository manifest. Root relocation is still normalized.
            let resolvedSources = sources.map {
                normalized(URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath().path)
            }
            inputs["resolvedSources"] = XcodeGraphCache.digest(try JSONEncoder().encode(resolvedSources))
            for path in sources {
                inputs[normalized(path)] = try hash(path)
                let text = try String(contentsOfFile: path, encoding: .utf8)
                if text.contains("#sourceLocation") || text.contains("canImport") && (text.contains("#if") || text.contains("#elseif")) {
                    let conditions = ModuleInputConditions(viewMode: .sourceAccurate)
                    conditions.walk(Parser.parse(source: text))
                    if conditions.hasSourceLocation { sourceLocationModules.insert(module) }
                    for text in conditions.values where text.contains("canImport") {
                        let matches = canImport.matches(in: text, range: NSRange(text.startIndex..., in: text))
                        // Unknown spellings are conservative. Extra matches in trivia
                        // can only invalidate more fragments, never remove a key.
                        if matches.count != text.components(separatedBy: "canImport").count - 1 { unresolvedAvailability.insert(module) }
                        for match in matches {
                            if let range = Range(match.range(at: 1), in: text) {
                                let name = String(text[range]).split(separator: ".").first.map(String.init) ?? ""
                                if invocations[name] != nil { availabilityQueries[module, default: []].insert(name) }
                            }
                        }
                    }
                }
            }
            inputs["availableProjectModules"] = XcodeGraphCache.digest(try JSONEncoder().encode(invocations.keys.sorted()))
            for index in original.indices where original[index] == "-plugin-path" {
                guard index + 1 < original.count else { throw ImpactError("Incomplete plugin path") }
                let path = URL(fileURLWithPath: original[index + 1])
                let compilerRoot = URL(fileURLWithPath: original[0]).deletingLastPathComponent().deletingLastPathComponent()
                guard path.path.hasPrefix(compilerRoot.appendingPathComponent("lib/swift/host/plugins").path + "/") else {
                    throw ImpactError("Custom plugin search path requires complete resource inputs: \(path.path)")
                }
                for (relative, digest) in try ArtifactFiles.manifest(at: path) { inputs["plugin:" + path.path + "/" + relative] = digest }
            }
            // The driver emits a transitive import map next to its output map.
            // Do not guess when the toolchain changes that layout or emits variants.
            let maps = try FileManager.default.contentsOfDirectory(at: list.deletingLastPathComponent(), includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasPrefix(module + "-dependencies-") && $0.pathExtension == "json" }
            guard maps.count == 1,
                  let dependencies = try JSONSerialization.jsonObject(with: Data(contentsOf: maps[0])) as? [[String: Any]],
                  !dependencies.isEmpty else { throw ImpactError("Missing/ambiguous explicit import map for \(module)") }
            // A fresh compiler scan makes SDK module identities independent of
            // generated PCM/module filenames. If unavailable, exact binary hashes
            // below remain safe, but may miss across build directories.
            let scanned: XcodeDependencyInputs.Inventory?
            do {
                scanned = try scans[module]!.get()
            } catch {
                scanned = nil
                cache.progress("Module cache \(module): exact binary input identities (dependency scan unavailable: \(String(describing: error).prefix(240)))")
            }
            if let scanned {
                inputs["scannedDependencies"] = scanned.digest
                imports[module, default: []].formUnion(scanned.projectImports)
            }
            var importMetadata: [[String: String]] = []
            for dependency in dependencies {
                guard Set(dependency.keys).isSubset(of: ["moduleName", "modulePath", "isFramework", "clangModulePath", "clangModuleMapPath", "isBridgingHeaderDependency"]) else {
                    throw ImpactError("Unsupported explicit import input fields for \(module)")
                }
                guard let name = dependency["moduleName"] as? String else { throw ImpactError("Unknown import metadata for \(module)") }
                var metadata: [String: String] = [:]
                for (key, value) in dependency {
                    if let value = value as? String { metadata[key] = normalized(value) }
                    else if let value = value as? Bool { metadata[key] = String(value) }
                    else { throw ImpactError("Unsupported import metadata for \(module)") }
                }
                if let scanned {
                    let kind = dependency["clangModulePath"] != nil ? "clang:" : "swift:"
                    guard scanned.modules.contains(kind + name) else { throw ImpactError("Explicit import absent from fresh scan: \(name)") }
                    for key in ["modulePath", "clangModulePath"] where metadata[key] != nil { metadata[key] = "<MODULE:" + kind + name + ">" }
                }
                if let path = dependency["modulePath"] as? String {
                    if invocations[name] != nil {
                        imports[module, default: []].insert(name)
                    } else if scanned == nil { inputs[normalized(path)] = try hash(path) }
                } else if let path = dependency["clangModulePath"] as? String,
                          let map = dependency["clangModuleMapPath"] as? String {
                    if scanned == nil { inputs[normalized(path)] = try hash(path) }
                    inputs[normalized(map)] = try hash(map)
                } else { throw ImpactError("Incomplete import paths for \(module).\(name)") }
                importMetadata.append(metadata)
            }
            // Hash additional explicit file inputs (overlays, bridging headers,
            // plugins, protocol lists, etc.). Unknown inputs err toward misses.
            var transientFiles = Set<Int>()
            for index in arguments.indices {
                if ["-clang-build-session-file", "-dependency-scan-serialize-diagnostics-path"].contains(arguments[index]) {
                    transientFiles.insert(index + 1)
                }
                if arguments[index] == "-ivfsstatcache", index + 1 < arguments.count {
                    transientFiles.insert(index + (arguments[index + 1] == "-Xcc" ? 2 : 1))
                }
            }
            for (index, argument) in arguments.enumerated() where !argument.hasPrefix("@") && !transientFiles.contains(index) {
                let path = argument.components(separatedBy: "#")[0]
                var isDirectory: ObjCBool = false
                if path.hasPrefix("/"), FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue {
                    inputs[normalized(path)] = try hash(path)
                }
            }
            inputs["compiler"] = try hash(original[0])
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            inputs["arguments"] = XcodeGraphCache.digest(try encoder.encode(arguments.map(normalized)))
            let sortedImports = try importMetadata.map { try XcodeGraphCache.key($0) }.sorted()
            inputs["imports"] = XcodeGraphCache.digest(try encoder.encode(sortedImports))
            inspectIdentityInputs?(module, inputs)
            localKeys[module] = try XcodeGraphCache.key(inputs)
        }
        let availableModuleInputs = try XcodeGraphCache.key(localKeys)
        var completed: [String: String] = [:]
        var visiting = Set<String>()
        func closure(_ module: String) throws -> String {
            if let key = completed[module] { return key }
            guard visiting.insert(module).inserted, let own = localKeys[module] else { throw ImpactError("Cyclic/missing module input: \(module)") }
            defer { visiting.remove(module) }
            var keys = [module: own]
            if unresolvedAvailability.contains(module) { keys["canImportInputs"] = availableModuleInputs }
            for query in availabilityQueries[module] ?? [] { keys["canImport:" + query] = localKeys[query] }
            for dependency in imports[module] ?? [] {
                keys[dependency] = try closure(dependency)
                // Imported definitions can also carry the original module's
                // presumed locations into this module's SIL.
                if sourceLocationModules.contains(dependency) { sourceLocationModules.insert(module) }
            }
            let key = try XcodeGraphCache.key(keys)
            completed[module] = key
            return key
        }
        var result: [String: [String: String]] = [:]
        for module in invocations.keys.sorted() {
            let inputs = try closure(module)
            // Parsed regions are relative to the current checkout, but an
            // absolute #sourceLocation may point into an older checkout or
            // through a symlink outside the compiler source inventory. Until
            // those presumed paths are validated, replay affected modules.
            if sourceLocationModules.contains(module) {
                cache.progress("Module cache \(module): bypass: #sourceLocation in compiler inputs or an imported project module")
                continue
            }
            var identity = context
            identity["module"] = module
            identity["inputs"] = inputs
            result[module] = identity
        }
        return result
    }
}

private final class ModuleInputConditions: SyntaxVisitor {
    var values: [String] = []
    var hasSourceLocation = false
    override func visit(_ node: PoundSourceLocationSyntax) -> SyntaxVisitorContinueKind {
        if node.arguments != nil { hasSourceLocation = true }
        return .skipChildren
    }
    override func visit(_ node: IfConfigClauseSyntax) -> SyntaxVisitorContinueKind {
        if let condition = node.condition { values.append(condition.trimmedDescription) }
        return .visitChildren
    }
}

/// Shared across concurrent dependency scans. Hash outside the lock so independent
/// files proceed in parallel; simultaneous first reads may duplicate work, but
/// subsequent imports reuse the result. Each validation pass gets a fresh memo.
private final class CompilerInputHashes: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    func digest(_ path: String, normalize: (String) -> String) throws -> String {
        if let found = lock.withLock({ values[path] }) { return found }
        let value: String
        if path.hasSuffix(".hmap"), let normalized = try XcodeHeaderMap.digest(Data(contentsOf: URL(fileURLWithPath: path)), normalize: normalize) {
            value = normalized
        } else { value = try ArtifactFiles.digest(URL(fileURLWithPath: path)) }
        lock.withLock { values[path] = value }
        return value
    }
}
