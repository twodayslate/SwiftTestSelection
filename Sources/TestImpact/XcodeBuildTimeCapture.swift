// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// The analyzer owns export lifetime and revision provenance. The Python helper
/// owns compiler-wrapper setup and seals one build; it never creates a fake Git
/// checkout or guesses which revision an exported directory represents.
struct XcodeBuildTimeCapture {
    let helper: URL
    let identity: String

    init(helper: URL) throws {
        self.helper = helper.standardizedFileURL.resolvingSymlinksInPath()
        let scripts = [self.helper, self.helper.deletingLastPathComponent().appendingPathComponent("Experimental/prepare_sil_capture.py"),
            self.helper.deletingLastPathComponent().appendingPathComponent("Experimental/capture_swiftc.py"),
            self.helper.deletingLastPathComponent().appendingPathComponent("Experimental/capture_inputs.py")]
        identity = try XcodeGraphCache.key(Dictionary(uniqueKeysWithValues: scripts.map { ($0.lastPathComponent, try ArtifactFiles.digest($0)) }))
    }

    struct Result {
        var log: String
        var settings: Data
        var captured: CapturedSIL
        var buildSeconds: Double
    }

    func build(options: XcodeConfiguration, source: URL, workspace: URL, revision: String, context: String,
               diagnostics: URL? = nil, progress: (String) -> Void) throws -> Result {
        let source = URL(fileURLWithPath: source.path, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        var options = options
        options.path = URL(fileURLWithPath: options.path.path, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        let derived = URL(fileURLWithPath: workspace.appendingPathComponent("DerivedData").path, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        let diagnostics = diagnostics ?? workspace
        let session = diagnostics.appendingPathComponent("SILCapture")
        let helperLog = diagnostics.appendingPathComponent("capture.log")
        let manifest = diagnostics.appendingPathComponent("source-export.json")
        do {
            let sourceFiles = try ArtifactFiles.manifest(at: source)
            let export: [String: Any] = ["root": source.path, "revision": revision, "files": sourceFiles]
            try JSONSerialization.data(withJSONObject: export, options: [.sortedKeys]).write(to: manifest, options: .atomic)
            let digest = try ArtifactFiles.digest(manifest)
            var arguments = [helper.path, "--session", session.path, "--context", context,
                "--" + options.container.rawValue, options.path.path, "--scheme", options.scheme,
                "--destination", options.destination, "--derived-data", derived.path,
                "--export-manifest", manifest.path, "--only-use-package-versions-from-resolved-file"]
            if let plan = options.testPlan { arguments += ["--test-plan", plan] }
            if let configuration = options.configuration { arguments += ["--configuration", configuration] }
            progress("Capturing supplementary SIL during build-for-testing; diagnostics: \(diagnostics.path)")
            let run = try CommandRunner.run("python3", arguments, at: source, allowFailure: true, combinedLog: helperLog)
            // Preserve the usual retained log paths on both success and failure.
            for (original, destination) in [("build.log", "build.log"), ("settings.json", "build-settings.json")] {
                let file = session.appendingPathComponent(original)
                if FileManager.default.fileExists(atPath: file.path) {
                    try Data(contentsOf: file).write(to: workspace.appendingPathComponent(destination), options: .atomic)
                }
            }
            guard run.status == 0 else { throw ImpactError("Build-time SIL capture failed (exit \(run.status)):\n\(run.text.suffix(8000))") }
            guard try sourceFiles == ArtifactFiles.manifest(at: source), try digest == ArtifactFiles.digest(manifest),
                  try identity == Self(helper: helper).identity else { throw ImpactError("Source export or capture helper changed during build") }
            let logFile = session.appendingPathComponent("build.log"), settingsFile = session.appendingPathComponent("settings.json")
            let products = derived.appendingPathComponent("Build/Products")
            let runs = try FileManager.default.contentsOfDirectory(at: products, includingPropertiesForKeys: nil).filter { $0.pathExtension == "xctestrun" }
            guard runs.count == 1 else { throw ImpactError("Captured build requires exactly one test run product") }
            try ArtifactFiles.validateTestRun(runs[0], plan: options.testPlan, scheme: options.scheme)
            let log = try String(contentsOf: logFile, encoding: .utf8), data = try Data(contentsOf: settingsFile)
            guard log.contains("** TEST BUILD SUCCEEDED **") else { throw ImpactError("Capture has no successful build-for-testing log") }
            let settings = try JSONDecoder().decode([XcodeBuildSettings].self, from: data)
            try ArtifactFiles.validateSettings(settings, options: options, root: source, derived: derived)
            try ArtifactFiles.validateBuildLog(log, options: options, root: source, derived: derived, settings: settings)
            try ArtifactFiles.validateCompilerToolchain(log, at: source)
            let inputs = XcodeBuildInputs(derivedData: derived, buildLog: logFile, buildSettings: settingsFile, xctestrun: runs[0], revision: revision)
            var captured = try CapturedSIL.load(at: session, root: source, inputs: inputs,
                logDigest: ArtifactFiles.digest(logFile), settingsDigest: ArtifactFiles.digest(settingsFile),
                products: ArtifactFiles.manifest(at: products), toolchain: ArtifactFiles.toolchain(at: source),
                exportedRevision: revision, sourceExportDigest: digest, expectedContext: context, expectedHelper: identity)
            captured.exportedSources = (source, sourceFiles)
            captured.fingerprints[manifest.path] = digest
            let seal = try JSONDecoder().decode(CapturedSIL.Seal.self, from: Data(contentsOf: session.appendingPathComponent("build.json")))
            return Result(log: log, settings: data, captured: captured, buildSeconds: seal.buildSeconds ?? 0)
        } catch {
            throw ImpactError("\(error)\nDiagnostics retained at \(diagnostics.path)")
        }
    }
}
