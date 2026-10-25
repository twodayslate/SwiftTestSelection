// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// An explicit closed-world contract, not a coverage observation. All opaque
/// in-process and external effects of these tests must stay inside these modules.
public struct TestRuntimeBoundary: Codable, Sendable, Equatable {
    public var target: String
    public var modules: Set<String>
    public var rationale: String

    public init(target: String, modules: Set<String>, rationale: String) {
        self.target = target; self.modules = modules; self.rationale = rationale
    }
}

/// Compiler-produced transitive import inventories plus Xcode host ownership.
/// Optional on saved graphs: absence never establishes isolation.
public struct XcodeRuntimeInventory: Codable, Sendable {
    public var imports: [String: Set<String>]
    public var hosts: [String: Set<String>]
    public var diagnostics: [String]
    public var unavailableModules: [String: String]? = nil

    public init(imports: [String: Set<String>], hosts: [String: Set<String>], diagnostics: [String] = []) {
        self.imports = imports; self.hosts = hosts; self.diagnostics = diagnostics
    }

    static func capture(log: String, settings: [XcodeBuildSettings]) -> Self {
        do {
            var invocations: [String: [String]] = [:]
            for line in log.components(separatedBy: .newlines) {
                guard let marker = line.range(of: "builtin-SwiftDriver -- ") else { continue }
                let args = try XcodeSourceFileList.parse(String(line[marker.upperBound...]))
                guard let i = args.firstIndex(of: "-module-name"), i + 1 < args.count else {
                    throw ImpactError("Missing compiler module name")
                }
                let module = args[i + 1]
                if let old = invocations[module], old != args { throw ImpactError("Ambiguous compiler module: \(module)") }
                invocations[module] = args
            }
            guard !invocations.isEmpty else { throw ImpactError("Missing compiler module inventory") }
            var imports: [String: Set<String>] = [:]
            var unavailable: [String: String] = [:]
            for (module, args) in invocations {
                do {
                    guard args.contains("-explicit-module-build"),
                          !args.contains("-import-objc-header"),
                          let i = args.firstIndex(of: "-output-file-map"), i + 1 < args.count else {
                        throw ImpactError("Unsupported compiler import inventory: \(module)")
                    }
                    let directory = URL(fileURLWithPath: args[i + 1]).deletingLastPathComponent()
                    let maps = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                        .filter { $0.lastPathComponent.hasPrefix(module + "-dependencies-") && $0.pathExtension == "json" }
                    guard maps.count == 1 else { throw ImpactError("Missing/ambiguous compiler import map: \(module)") }
                    imports[module] = try projectImports(Data(contentsOf: maps[0]), inventory: Set(invocations.keys))
                } catch { unavailable[module] = String(describing: error) }
            }
            var hosts: [String: Set<String>] = [:]
            for entry in settings where entry.buildSettings["PRODUCT_TYPE"] == "com.apple.product-type.bundle.unit-test" {
                let values = entry.buildSettings
                guard let target = values["TARGET_NAME"], let module = values["PRODUCT_MODULE_NAME"], imports[module] != nil else {
                    throw ImpactError("Missing test target compiler inventory")
                }
                var roots: Set<String> = [module]
                if let host = values["TEST_HOST"], !host.isEmpty {
                    let path = URL(fileURLWithPath: host).standardizedFileURL.path
                    let owners = settings.filter { candidate in
                        guard let directory = candidate.buildSettings["TARGET_BUILD_DIR"],
                              let executable = candidate.buildSettings["EXECUTABLE_PATH"] else { return false }
                        return URL(fileURLWithPath: directory).appendingPathComponent(executable).standardizedFileURL.path == path
                    }
                    guard owners.count == 1, let hostModule = owners[0].buildSettings["PRODUCT_MODULE_NAME"], imports[hostModule] != nil else {
                        throw ImpactError("Cannot resolve test host for \(target)")
                    }
                    roots.insert(hostModule)
                }
                guard hosts[target] == nil else { throw ImpactError("Ambiguous test host inventory: \(target)") }
                hosts[target] = roots
            }
            var result = Self(imports: imports, hosts: hosts)
            result.unavailableModules = unavailable
            return result
        } catch {
            return Self(imports: [:], hosts: [:], diagnostics: ["Runtime boundary inventory unavailable: \(error)"])
        }
    }

    static func projectImports(_ data: Data, inventory: Set<String>) throws -> Set<String> {
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]], !rows.isEmpty else {
            throw ImpactError("Empty compiler import map")
        }
        var result = Set<String>(), seen = Set<String>()
        for row in rows {
            guard Set(row.keys).isSubset(of: ["moduleName", "modulePath", "isFramework", "clangModulePath", "clangModuleMapPath", "isBridgingHeaderDependency"]),
                  let name = row["moduleName"] as? String, !name.isEmpty,
                  seen.insert((row["modulePath"] is String ? "swift:" : "clang:") + name).inserted,
                  row["isBridgingHeaderDependency"] as? Bool != true,
                  row["modulePath"] is String || row["clangModulePath"] is String else {
                throw ImpactError("Unsupported compiler import record")
            }
            if inventory.contains(name) { result.insert(name) }
        }
        return result
    }

    func requiredModules(for target: String) -> Set<String>? {
        guard diagnostics.isEmpty, let roots = hosts[target], !roots.isEmpty else { return nil }
        var modules = roots, pending = Array(roots)
        while let module = pending.popLast() {
            guard let dependencies = imports[module] else { return nil }
            for dependency in dependencies where modules.insert(dependency).inserted { pending.append(dependency) }
        }
        return modules
    }
}

public struct RuntimeBoundaryDecision: Codable, Sendable {
    public var target: String
    public var revision: String
    public var modules: [String]
    public var changedModules: [String]
    /// Only the uncertainty fallback is excluded; direct dependency selection wins.
    public var boundedUncertaintyTests: [String]
    public var rationale: String
}

extension TestRuntimeBoundary {
    func validationFailure(in snapshot: XcodeTestGraph) -> String? {
        guard let targetInfo = snapshot.targets.first(where: { $0.name == target }), targetInfo.isTest, !targetInfo.isUITest,
              let ownModule = snapshot.modules[target], modules.contains(ownModule),
              let inventory = snapshot.runtimeInventory, inventory.diagnostics.isEmpty,
              inventory.hosts[target]?.contains(ownModule) == true,
              let required = inventory.requiredModules(for: target) else {
            return "Missing compiler imports or test-host evidence for \(target)"
        }
        guard modules.isSubset(of: Set(inventory.imports.keys)), required.isSubset(of: modules) else {
            return "Contract for \(target) omits compiler-imported/host modules or names unavailable modules; required: \(required.sorted().joined(separator: ", "))"
        }
        guard let graph = snapshot.dependencies, graph.diagnostics.isEmpty, snapshot.diagnostics.isEmpty,
              snapshot.sources.values.allSatisfy({ $0.diagnostics.isEmpty }) else {
            return "Incomplete compiler/source graph for \(target)"
        }
        let tests = snapshot.tests.filter { $0.hasPrefix(target + "/") }
        guard !tests.isEmpty, tests.allSatisfy({
            graph.tests[$0]?.isEmpty == false && (graph.testDiagnostics[$0]?.isEmpty ?? true)
        }) else { return "Missing test entries or lifecycle evidence for \(target)" }
        var visited = Set(tests.flatMap { graph.tests[$0] ?? [] }), pending = visited.sorted().reversed().map { $0 }
        while let symbol = pending.popLast() {
            guard let node = graph.functions[symbol] else { continue }
            for dependency in node.dependencies.sorted() {
                if let destination = graph.functions[dependency], !destination.regions.isEmpty,
                   !modules.contains(destination.module) {
                    guard let references = node.compilerReferences else {
                        return "Missing compiler-reference provenance for \(target): \(node.module).\(node.name)"
                    }
                    if references.contains(dependency) {
                        return "Compiled reference contradicts \(target)'s contract: \(node.module).\(node.name) reaches \(destination.module).\(destination.name)"
                    }
                    // A whole-program dispatch candidate cannot run in the closed
                    // module universe asserted here. Explicit function references
                    // (including escaped callback addresses) are never discarded.
                    continue
                }
                if visited.insert(dependency).inserted { pending.append(dependency) }
            }
        }
        return nil
    }
}
