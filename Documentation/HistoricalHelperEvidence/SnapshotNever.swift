// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import SnapshotTesting
import UIKit

let files = FileManager.default
let directory = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
let artifacts = directory.appendingPathComponent("artifacts")
defer { try? files.removeItem(at: directory) }
setenv("SNAPSHOT_ARTIFACTS", artifacts.path, 1)
try files.createDirectory(at: directory, withIntermediateDirectories: true)
func image(_ color: UIColor) -> UIImage {
    UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16)).image { ctx in
        color.setFill()
        ctx.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
    }
}
let actual = image(.blue)
let reference = directory.appendingPathComponent("audit.case.png")
let referenceBytes = image(.red).pngData()!
try referenceBytes.write(to: reference)
func verify(_ dir: URL) -> String? {
    verifySnapshot(of: actual, as: .image(precision: 0.99, perceptualPrecision: 0.5),
                   named: "case", record: .never, snapshotDirectory: dir.path,
                   file: "/Probe/CalendarSnapshotUITests.swift", testName: "audit")
}
let failure = verify(directory)
let artifact = artifacts.appendingPathComponent("CalendarSnapshotUITests/audit.case.png")
let written = try Data(contentsOf: artifact)
let preserved = try Data(contentsOf: reference)
precondition(failure?.contains("does not match reference") == true && !written.isEmpty && preserved == referenceBytes)
let impossibleDirectory = directory.appendingPathComponent("file")
try Data().write(to: impossibleDirectory)
let ioFailure = verify(impossibleDirectory.appendingPathComponent("subdir"))
let expected: String
do {
    try files.createDirectory(at: impossibleDirectory.appendingPathComponent("subdir"), withIntermediateDirectories: true)
    fatalError("Expected filesystem error")
} catch { expected = error.localizedDescription }
precondition(ioFailure == expected)
print("PASS: mismatch produced an artifact of \(written.count) bytes, reference preserved. Directory error returned its localized description.")
