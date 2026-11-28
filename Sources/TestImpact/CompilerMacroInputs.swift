// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation
#if canImport(MachO)
import MachO
#endif

/// Swift records the plugin binary used by each primary input in its make
/// dependencies. This also covers macro declarations imported from binary modules.
enum CompilerMacroInputs {
    static func annotate(_ sources: inout [String: SwiftSourceSnapshot], invocations: [String: [String]], root: URL) {
        let candidates = sources.keys.filter { sources[$0]?.attachedAttributeInputs?.isEmpty == false }
        guard !candidates.isEmpty else { return }
        var byModule: [String: [String: String]] = [:]
        for key in candidates {
            guard let id = sources[key]?.sourceIdentity(storedAs: key) else { continue }
            byModule[id.module, default: [:]][root.appendingPathComponent(id.path).resolvingSymlinksInPath().path] = key
            sources[key]?.usesUnmodeledMacroPlugin = true
        }
        var binaryInputs: [String: Bool] = [:]
        for (module, args) in invocations {
            guard let files = byModule[module], let compiler = args.first else { continue }
            guard let i = args.firstIndex(of: "-output-file-map"), i + 1 < args.count,
                  let data = try? Data(contentsOf: URL(fileURLWithPath: args[i + 1])),
                  let outputs = try? JSONDecoder().decode([String: [String: String]].self, from: data) else { continue }
            let testing = URL(fileURLWithPath: compiler).deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("lib/swift/host/plugins/testing/libTestingMacros.dylib").resolvingSymlinksInPath()
            for (path, output) in outputs where !path.isEmpty {
                guard let key = files[URL(fileURLWithPath: path).resolvingSymlinksInPath().path],
                      let dependencyFile = output["dependencies"],
                      let text = try? String(contentsOfFile: dependencyFile, encoding: .utf8),
                      let delimiter = text.range(of: " : "),
                      let inputs = XcodeBuildEvidence.makefileInputs(text[delimiter.upperBound...]),
                      inputs.contains(path) else { continue }
                let usesPlugin = inputs.contains { input in
                    let binary = binaryInputs[input] ?? canLoadPlugin(input)
                    binaryInputs[input] = binary
                    // The SDK Testing plugin's registration/traits have their own comparison.
                    return binary && URL(fileURLWithPath: input).resolvingSymlinksInPath() != testing
                }
                sources[key]?.usesUnmodeledMacroPlugin = usesPlugin
            }
        }
    }

    /// Plugin executables and loadable libraries can have arbitrary names.
    /// A missing compiler input leaves the file's expansion provenance unknown.
    private static func canLoadPlugin(_ path: String) -> Bool {
        if FileManager.default.isExecutableFile(atPath: path) { return true }
        #if canImport(MachO)
        guard let file = FileHandle(forReadingAtPath: path) else { return true }
        defer { try? file.close() }
        let header: Data
        do { header = try file.read(upToCount: 4) ?? Data() }
        catch { return true }
        guard header.count == 4 else { return false }
        let magic = header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        return [MH_MAGIC, MH_CIGAM, MH_MAGIC_64, MH_CIGAM_64, FAT_MAGIC, FAT_CIGAM, FAT_MAGIC_64, FAT_CIGAM_64].contains(magic)
        #else
        return true
        #endif
    }
}
