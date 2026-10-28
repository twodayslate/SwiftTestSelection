// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation

public struct XcodeTarget: Codable, Sendable {
    public var name: String
    public var productType: String
    public var sourceFiles: Set<String>
    public var recoveredRole: RecoveredProductRole? = nil

    var hasProductionRole: Bool {
        !isTest && productType != "unknown" && (productType != XcodeSourceOwnership.productType || recoveredRole != nil)
    }

    public var isTest: Bool {
        ["com.apple.product-type.bundle.ui-testing", "com.apple.product-type.bundle.unit-test"].contains(productType)
    }
    public var isUITest: Bool { productType == "com.apple.product-type.bundle.ui-testing" }

    public init(name: String, productType: String, sourceFiles: Set<String>) {
        self.name = name
        self.productType = productType
        self.sourceFiles = sourceFiles
    }
}

/// Combines build ownership, compiler dependencies and explicit UI mappings.
/// Compiler edges alone never claim to cross the UI automation process boundary.
public struct XcodeTestGraph: Codable, Sendable {
    public var schemaVersion = 2
    public var analysisKind = "xcode-sil-and-ui-mappings"
    public var targets: [XcodeTarget]
    /// Exact identifiers emitted by xcodebuild test enumeration.
    public var tests: [String]
    public var diagnostics: [String]
    public var dependencies: DependencyGraph?
    public var sources: [String: SwiftSourceSnapshot] = [:]
    /// Compiler-owned modules with generated/external inputs outside repository
    /// semantic snapshots. Module edits remain conservative without invalidating
    /// independently resolved test-entry edits in other modules.
    public var unsupportedSourceInputs: [String: [String]]? = nil
    public var generatedSourceBoundaries: [String: [GeneratedSourceBoundary]]? = nil
    public var unresolvedProductRoles: [String: String]? = nil
    public var modules: [String: String] = [:]
    public var mappings: UIFeatureMappings? {
        didSet {
            // Older saved-graph clients do not validate mapping versions before
            // selecting. Make them reject archives containing conditions too.
            if mappings?.version == 2 || mappings?.features.contains(where: { $0.when != nil }) == true {
                schemaVersion = max(schemaVersion, 3)
            }
        }
    }
    /// Retain read/decode/schema failures even when invalid mappings are discarded.
    public var mappingLoadError: String? = nil
    public var runtimeInventory: XcodeRuntimeInventory? = nil
    /// Provenance and product fingerprints for an imported build-for-testing result.
    public var buildArtifact: XcodeBuildArtifact?

    public init(targets: [XcodeTarget], tests: [String], diagnostics: [String] = []) {
        self.targets = targets
        self.tests = tests
        self.diagnostics = diagnostics
    }

    public func dot() -> String {
        func quote(_ string: String) -> String {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .withoutEscapingSlashes
            return String(decoding: try! encoder.encode(string), as: UTF8.self)
        }
        var lines = ["digraph XcodeTestTargets {", "  rankdir=LR;", "  label=\"Build-target ownership; UI interaction crosses a process boundary\";"]
        for target in targets.sorted(by: { $0.name < $1.name }) {
            let label = target.name + (target.isUITest ? " (XCUITest runner)" : "")
            lines.append("  \(quote("target:" + target.name)) [label=\(quote(label)), shape=box];")
            for file in target.sourceFiles.sorted() {
                lines.append("  \(quote("target:" + target.name)) -> \(quote(file)) [label=\"compiles\"];")
            }
        }
        for test in tests.sorted() {
            let target = String(test.prefix(while: { $0 != "/" }))
            lines.append("  \(quote(test)) -> \(quote("target:" + target)) [label=\"belongs to\"];")
        }
        return (lines + ["}"]).joined(separator: "\n") + "\n"
    }
}

public enum XcodeSelector {
    public static func select(
        current: XcodeTestGraph, previous: XcodeTestGraph?, changes: [FileChange],
        baseRevision: String, additionalFallbacks: [String] = []
    ) -> ImpactReport {
        if current.dependencies != nil || [current.mappings, previous?.mappings].contains(where: { $0?.features.contains { $0.when != nil } == true }) {
            return XcodeFineSelector.select(current: current, previous: previous, changes: changes, baseRevision: baseRevision, additionalFallbacks: additionalFallbacks)
        }
        var reasons = additionalFallbacks
        var explanations: [TestExplanation] = []
        var selected = Set<String>()
        let inventory = Set(current.tests)
        if !changes.isEmpty {
            reasons += current.diagnostics
            reasons += previous?.diagnostics ?? ["Base Xcode build-target ownership is unavailable."]
        }
        // Ownership in both builds is necessary for removed/moved/shared files.
        let targets = current.targets + (previous?.targets ?? [])
        for change in changes {
            let owners = targets.filter { $0.sourceFiles.contains(change.path) }
            if !change.path.hasSuffix(".swift") || owners.isEmpty || owners.contains(where: { !$0.isTest }) || change.requiresFallback {
                reasons.append("App, resource, build, or unclassified change requires the full Xcode test selection: \(change.path). XCUITest app interactions cross a process boundary.")
                continue
            }
            let names = Set(owners.map(\.name))
            for test in current.tests where names.contains(String(test.prefix(while: { $0 != "/" }))) {
                selected.insert(test)
                explanations.append(TestExplanation(
                    test: test, reason: "Changed source belongs to this test target; conservatively include its tests",
                    revision: "base/current", path: [change.path, String(test.prefix(while: { $0 != "/" })), test]
                ))
            }
        }
        if !changes.isEmpty {
            for test in inventory.subtracting(previous.map { Set($0.tests) } ?? []) {
                selected.insert(test)
                explanations.append(TestExplanation(test: test, reason: "New or previously undiscovered Xcode test", revision: "current", path: []))
            }
        }
        reasons = Array(Set(reasons)).sorted()
        if !reasons.isEmpty { selected = inventory }
        return ImpactReport(
            baseRevision: baseRevision, totalTests: inventory.count, selectedTests: selected.sorted(),
            explanations: explanations.sorted { ($0.test, $0.reason, $0.path.joined()) < ($1.test, $1.reason, $1.path.joined()) },
            fullRunReasons: reasons, changedFiles: changes.map(\.path).sorted(), unreferencedChanges: [],
            limitations: [
                "Xcode selection currently uses build-target ownership, not function-level SIL reachability.",
                "UI automation crosses into the app process. App, resource, configuration, and unclassified changes select all discovered tests in the chosen scheme/test plan.",
                "Test-only Swift changes select their owning test targets, including setup, helpers, and shared source files.",
                "The inventory and build ownership apply only to the chosen scheme, destination, configuration, and test plan."
            ]
        )
    }
}
