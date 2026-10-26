// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation
import Testing
@testable import TestImpact

@Test func explicitHeadAndMergeBaseIgnoreUnrelatedBranchAndWorktreeChanges() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("comparison with spaces \(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    @discardableResult func git(_ arguments: String...) throws -> String { try CommandRunner.run("git", arguments, at: root).text.trimmingCharacters(in: .whitespacesAndNewlines) }
    try git("init", "-q")
    try git("config", "user.name", "Test")
    try git("config", "user.email", "test@example.invalid")
    try "func original() {}\n".write(to: root.appendingPathComponent("Code.swift"), atomically: true, encoding: .utf8)
    try git("add", "."); try git("commit", "-qm", "Base")
    let base = try git("rev-parse", "HEAD")
    try git("checkout", "-qb", "target")
    try "target only".write(to: root.appendingPathComponent("Target.txt"), atomically: true, encoding: .utf8)
    try git("add", "."); try git("commit", "-qm", "Target")
    try git("checkout", "-qb", "feature", base)
    try "func changed() {}\n".write(to: root.appendingPathComponent("Code.swift"), atomically: true, encoding: .utf8)
    try git("add", "."); try git("commit", "-qm", "Head")
    let head = try git("rev-parse", "HEAD")
    try "dirty".write(to: root.appendingPathComponent("Dirty.swift"), atomically: true, encoding: .utf8)
    let comparison = try RevisionComparison(base: "target", head: "feature", mergeBase: true, root: root)
    #expect(comparison.base == base && comparison.head == head)
    #expect(try GitChanges.readComparison(base: comparison.base, head: comparison.head, at: root).map(\.path) == ["Code.swift"])
    let direct = try RevisionComparison(base: "target", head: head, mergeBase: false, root: root)
    #expect(try GitChanges.readComparison(base: direct.base, head: direct.head, at: root).map(\.path) == ["Code.swift", "Target.txt"])
    #expect(try GitChanges.readComparison(base: base, head: nil, at: root).map(\.path) == ["Code.swift", "Dirty.swift"])
}

@Test(arguments: [false, true])
func projectReferenceMoveProofRejectsAccompanyingSettingsEdits(settingsChanged: Bool) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("project-move-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    @discardableResult func git(_ args: String...) throws -> String {
        try CommandRunner.run("git", args, at: root).text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    try git("init", "-q"); try git("config", "user.name", "Test"); try git("config", "user.email", "test@example.invalid")
    let project = root.appendingPathComponent("project.pbxproj")
    func writeProject(path: String, flag: String) throws {
        let value: [String: Any] = ["objects": [
            "FILE": ["isa": "PBXFileReference", "path": path],
            "CONFIG": ["isa": "XCBuildConfiguration", "buildSettings": ["OTHER_SWIFT_FLAGS": flag]]]]
        try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0).write(to: project)
    }
    try Data("func value() {}\n".utf8).write(to: root.appendingPathComponent("Original.swift"))
    try writeProject(path: "Original.swift", flag: "")
    try git("add", "."); try git("commit", "-qm", "base")
    let base = try git("rev-parse", "HEAD")
    try git("mv", "Original.swift", "Moved.swift")
    try writeProject(path: "Moved.swift", flag: settingsChanged ? "-DCHANGED" : "")
    try git("add", "."); try git("commit", "-qm", "move")
    let changes = try GitChanges.readComparison(base: base, head: "HEAD", at: root)
    #expect(changes.first { $0.path == "Moved.swift" }?.isPureMove == true)
    #expect(changes.first { $0.path == "project.pbxproj" }?.isPureMove == !settingsChanged)
}
