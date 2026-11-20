// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
import Foundation
import Testing
@testable import TestImpact

@Test func declarationInventoriesLocateWrappersBuildersActorsAndInactiveMacros() throws {
    let source = """
    import SwiftUI
    @MainActor struct Screen {
        @State var count = 0
        @Environment(\\.self) var environment
        @AppStorage("key") var value = false
        @ViewBuilder var body: some View { Text("Hello") }
    }
    #if NEVER_ENABLED
    @MakeMembers struct Inactive {}
    #makeGlobals()
    let result = #makeExpression()
    #endif
    """
    let snapshot = SwiftSourceSnapshot.parse(source, path: "Screen.swift", module: "App")
    #expect(snapshot.helperDeclarationsComplete == false)
    let issues = try #require(snapshot.helperDeclarationIssues)
    #expect(issues.map(\.spelling) == ["@MainActor", "@State", "@Environment", "@AppStorage", "@ViewBuilder", "@MakeMembers", "#makeGlobals", "#makeExpression"])
    #expect(issues.map(\.line) == [2, 3, 4, 5, 6, 9, 10, 11])
    #expect(issues[1].column == 5)
    #expect(issues[0].requiredEvidence.contains("SwiftUI"))
    #expect(issues.allSatisfy { !$0.requiredEvidence.isEmpty && !$0.possibleEffects.isEmpty })
    var graph = XcodeTestGraph(targets: [], tests: [])
    graph.sources["App:Screen.swift"] = snapshot
    #expect(try GraphArchive.decode(GraphArchive.encode(graph)).sources["App:Screen.swift"]?.helperDeclarationIssues == issues)
}

@Test func declarationInventoriesPreserveSupportedCompilerConstructs() throws {
    let snapshot = SwiftSourceSnapshot.parse("""
    import XCTest
    @available(macOS 13, *) @MainActor final class Suite: XCTestCase {
        @nonobjc func helper(_ body: @escaping @Sendable () -> Void) {
            let file = #fileID
            let line = #line
            let literal = "@Unknown #macro()"
            // @Unknown #macro()
        }
    }
    """, path: "Suite.swift", module: "UI")
    #expect(snapshot.helperDeclarationsComplete == true)
    #expect(snapshot.helperDeclarationIssues == [])
    // Adding an alias/reexport context must never grant an actor identity proof.
    let opaque = SwiftSourceSnapshot.parse("@_exported import Foreign\n@MainActor final class Suite {}", path: "Other.swift", module: "UI")
    #expect(opaque.helperDeclarationsComplete == false)
    #expect(opaque.helperImportsLocal == false)
    #expect(opaque.helperDeclarationIssues?.first?.spelling == "@MainActor")
}

@Test func declarationInventoryLegacyMetadataRemainsExplicitAndConservative() throws {
    var snapshot = SwiftSourceSnapshot.parse("@Expand struct Holder {}", path: "Old.swift", module: "App")
    snapshot.helperDeclarationIssues = nil
    for completeness in [false, nil] as [Bool?] {
        snapshot.helperDeclarationsComplete = completeness
        let boundaries = HelperDeclarationInventory.boundaries(current: ["App:Old.swift": snapshot], base: [:], unownedBase: ["Old.swift": snapshot])
        #expect(boundaries.count == 2)
        #expect(boundaries.allSatisfy { $0.issues.first?.kind == "missing-metadata" })
        #expect(boundaries.allSatisfy { $0.issues.first?.requiredEvidence.contains("Refresh source proofs") == true })
    }
}

@Test func compiledCompilerLookupExpressionsDoNotPretendToBeExpansionMacros() throws {
    let text = """
    import XCTest
    final class Holder: NSObject, @unchecked Sendable {
        @objc dynamic var title: String { "" }
        @objc func action() {}
    }
    func lookup() {
        _ = #selector(Holder.action)
        _ = #keyPath(Holder.title)
    }
    """
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let current = try boundaryGraph(["UI.swift": text], tests: [], root: root)
    let source = try #require(current.sources["UI:UI.swift"])
    #expect(source.helperDeclarationIssues == [])
    #expect(source.helperDeclarationsComplete == true)
    #expect(source.inheritance.values.contains { $0.contains { $0.contains("Sendable") } })
    #expect(source.units.first { $0.helperCallableName == "lookup" }?.headOnlyBodySupported == false)
    // Ordinary namesakes and arbitrary expression/declaration macros remain
    // inventoried; the language lookup exception grants no expansion contract.
    let opaque = SwiftSourceSnapshot.parse("""
    @unchecked struct Fake {}
    @Observable class Model { var value = 0 }
    let result = #customSelector()
    #generateBindings()
    """, path: "Other.swift", module: "UI")
    #expect(opaque.helperDeclarationsComplete == false)
    #expect(opaque.helperDeclarationIssues?.map(\.spelling) == ["@unchecked", "@Observable", "#customSelector", "#generateBindings"])
}
