// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// Recovers compiler module ownership omitted by scheme build settings. These
/// records deliberately do not invent a product type or a test-target identity.
enum XcodeSourceOwnership {
    static let productType = "compiler-module"

    static func recover(log: String, sourceRoot: URL, derived: URL, activeInputs: Set<String>?,
                        targets: inout [XcodeTarget], modules: inout [String: String],
                        listOwners: [URL: Set<String>], unsupportedInputs: inout [String: [String]], classifiedLists: inout Set<URL>, diagnostics: inout [String]) {
        func canonical(_ file: URL) -> URL { file.standardizedFileURL.resolvingSymlinksInPath() }
        let root = canonical(sourceRoot).path + "/", generatedRoot = canonical(derived).path + "/"
        var invocations: [String: [String]] = [:], invalid = Set<String>()
        for line in log.components(separatedBy: .newlines) {
            guard let marker = line.range(of: "builtin-SwiftDriver -- ") else { continue }
            do {
                let args = try XcodeSourceFileList.parse(String(line[marker.upperBound...]))
                let indices = args.indices.filter { args[$0] == "-module-name" }
                guard indices.count == 1, let index = indices.first, index + 1 < args.count,
                      !args[index + 1].isEmpty, !args[index + 1].hasPrefix("-") else {
                    throw ImpactError("Missing or ambiguous compiler module name")
                }
                let module = args[index + 1]
                if let old = invocations[module], old != args { invalid.insert(module) }
                invocations[module] = args
            } catch { diagnostics.append("Compiler source ownership unavailable: \(error)") }
        }
        var lists: [String: URL] = [:]
        for (module, args) in invocations.sorted(by: { $0.key < $1.key }) {
            do {
                guard !invalid.contains(module) else { throw ImpactError("Conflicting compiler invocations") }
                let responses = args.filter { $0.hasPrefix("@") }
                guard responses.count == 1, let response = responses.first,
                      String(response.dropFirst()).hasPrefix("/"), response.hasSuffix(".SwiftFileList") else {
                    throw ImpactError("Expected one absolute compiler Swift file list")
                }
                let list = canonical(URL(fileURLWithPath: String(response.dropFirst())))
                guard activeInputs?.contains(list.path) ?? true else { throw ImpactError("Compiler file list is not an active artifact input") }
                lists[module] = list
            } catch { diagnostics.append("Compiler source ownership unavailable for \(module): \(error)") }
        }
        let claimants = Dictionary(grouping: lists.keys, by: { lists[$0]! })
        for module in lists.keys.sorted() {
            let list = lists[module]!
            do {
                guard claimants[list]?.count == 1 else { throw ImpactError("Compiler file list claimed by multiple modules") }
                let knownOwners = targets.indices.filter { modules[targets[$0].name] == module }
                guard knownOwners.count <= 1 else { throw ImpactError("Multiple build targets claim the compiler module") }
                guard (listOwners[list] ?? []).allSatisfy({ modules[$0] == module }) else {
                    throw ImpactError("Compiler module contradicts build-settings file-list ownership")
                }
                let entries = try XcodeSourceFileList.parse(String(contentsOf: list, encoding: .utf8))
                guard !entries.isEmpty, entries.allSatisfy({ $0.hasPrefix("/") && $0.hasSuffix(".swift") }) else {
                    throw ImpactError("Empty or unsupported compiler source list")
                }
                let files = entries.map { canonical(URL(fileURLWithPath: $0)) }
                let repositoryFiles = files.filter { $0.path.hasPrefix(root) && !$0.path.hasPrefix(generatedRoot) }
                if knownOwners.isEmpty {
                    // Keep proven repository ownership even when the same module
                    // also compiles inputs with no repository semantic boundary.
                    // The selector must retain a fallback for edits to that module.
                    if repositoryFiles.isEmpty {
                        // External packages can also compile generated resource
                        // accessors. A checkout source establishes that external
                        // boundary; generated inputs alone do not.
                        let hasPackageSources = files.contains { $0.path.hasPrefix(generatedRoot + "SourcePackages/checkouts/") }
                        if !hasPackageSources && files.contains(where: { $0.path.hasPrefix(generatedRoot) }) {
                            throw ImpactError("Generated source ownership is unsupported")
                        }
                        classifiedLists.insert(list)
                        continue
                    }
                    let repositorySet = Set(repositoryFiles)
                    let unsupported = files.filter { !repositorySet.contains($0) }.map { file in
                        file.path.hasPrefix(generatedRoot) ? "<DerivedData>/" + file.path.dropFirst(generatedRoot.count) : file.path
                    }
                    if !unsupported.isEmpty { unsupportedInputs[module] = Array(Set(unsupported)).sorted() }
                }
                guard repositoryFiles.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else {
                    throw ImpactError("Missing compiler source file")
                }
                let paths = Set(repositoryFiles.map { String($0.path.dropFirst(root.count)) })
                if let index = knownOwners.first {
                    targets[index].sourceFiles.formUnion(paths)
                } else {
                    let name = "Compiler module: " + module
                    guard !targets.contains(where: { $0.name == name }) else { throw ImpactError("Compiler ownership identity conflicts with a build target") }
                    targets.append(XcodeTarget(name: name, productType: productType, sourceFiles: paths))
                    modules[name] = module
                }
                classifiedLists.insert(list)
            } catch { diagnostics.append("Compiler source ownership unavailable for \(module): \(error)") }
        }
    }
}
