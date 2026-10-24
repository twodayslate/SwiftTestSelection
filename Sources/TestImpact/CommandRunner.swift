// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

public struct ImpactError: Error, CustomStringConvertible, Sendable {
    public var description: String
    public init(_ description: String) { self.description = description }
}

struct CommandOutput {
    var status: Int32
    var stdout: Data
    var stderr: Data
    var text: String { String(decoding: stdout, as: UTF8.self) }
}

/// Uses argument arrays and file-backed streams: no shell expansion and no pipe
/// deadlocks when the compiler produces more than a pipe buffer of diagnostics.
enum CommandRunner {
    static func run(
        _ executable: String, _ arguments: [String], at directory: URL,
        input: Data? = nil, allowFailure: Bool = false
    ) throws -> CommandOutput {
        let fm = FileManager.default
        let temporary = fm.temporaryDirectory.appendingPathComponent("swift-test-impact-process-\(UUID().uuidString)")
        try fm.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temporary) }
        let outURL = temporary.appendingPathComponent("stdout")
        let errURL = temporary.appendingPathComponent("stderr")
        let inURL = temporary.appendingPathComponent("stdin")
        fm.createFile(atPath: outURL.path, contents: nil)
        fm.createFile(atPath: errURL.path, contents: nil)
        try (input ?? Data()).write(to: inURL)
        let out = try FileHandle(forWritingTo: outURL)
        let err = try FileHandle(forWritingTo: errURL)
        let stdin = try FileHandle(forReadingFrom: inURL)
        defer { try? out.close(); try? err.close(); try? stdin.close() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [executable] + arguments
        process.currentDirectoryURL = directory
        process.standardOutput = out
        process.standardError = err
        process.standardInput = stdin
        try process.run()
        process.waitUntilExit()
        let result = CommandOutput(
            status: process.terminationStatus, stdout: try Data(contentsOf: outURL), stderr: try Data(contentsOf: errURL)
        )
        if result.status != 0 && !allowFailure {
            let diagnostics = String(decoding: result.stderr + result.stdout, as: UTF8.self)
            throw ImpactError("\(executable) \(arguments.first ?? "") failed (\(result.status)):\n\(diagnostics.suffix(8000))")
        }
        return result
    }
}
