// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: AGPL-3.0-only

/// A function identity from a particular baseline build. Collectors should qualify
/// the symbol with its module and normalize paths relative to the repository.
public struct FunctionID: Hashable, Codable, Sendable {
    public var path: String
    public var symbol: String

    public init(path: String, symbol: String) {
        self.path = path
        self.symbol = symbol
    }
}

/// Coverage from a complete baseline run, attributed to individual test IDs.
public struct CoverageBaseline: Codable, Sendable {
    public var revision: String
    /// Identifies toolchain, platform, configuration, and relevant environment.
    public var configuration: String
    /// An empty set means successfully measured with no covered functions;
    /// a missing test means no usable measurement was collected.
    public var functionsByTest: [String: Set<FunctionID>]

    public init(
        revision: String,
        configuration: String,
        functionsByTest: [String: Set<FunctionID>]
    ) {
        self.revision = revision
        self.configuration = configuration
        self.functionsByTest = functionsByTest
    }
}

/// Produced by a future diff/source mapper. Function identities and locations
/// must refer to the old side of the diff, matching the coverage baseline.
public struct ChangeSet: Sendable {
    public var baseRevision: String
    public var configuration: String
    public var changedFunctions: Set<FunctionID>
    public var changedTests: Set<String>
    /// Changes that cannot be safely narrowed to measured functions, including
    /// new declarations, dependencies, resources, and build settings.
    public var unresolvedReasons: [String]

    public init(
        baseRevision: String,
        configuration: String,
        changedFunctions: Set<FunctionID> = [],
        changedTests: Set<String> = [],
        unresolvedReasons: [String] = []
    ) {
        self.baseRevision = baseRevision
        self.configuration = configuration
        self.changedFunctions = changedFunctions
        self.changedTests = changedTests
        self.unresolvedReasons = unresolvedReasons
    }
}

public struct Selection: Sendable {
    public enum Reason: Hashable, Sendable {
        case coversChangedFunction(FunctionID)
        case testChanged
        case missingTestCoverage
    }

    public var selectedTests: [String]
    public var reasonsByTest: [String: Set<Reason>]
    /// Nonempty means every currently discovered test is selected. These reasons
    /// apply to the entire run, in addition to any individual test reasons.
    public var fullRunReasons: [String]
}

public enum TestSelector {
    /// Selects using historical execution evidence. This does not prove that
    /// unselected tests cannot fail following a behavioral change.
    public static func select(
        availableTests: Set<String>,
        baseline: CoverageBaseline?,
        changes: ChangeSet
    ) -> Selection {
        guard let baseline else {
            return Selection(
                selectedTests: availableTests.sorted(), reasonsByTest: [:],
                fullRunReasons: ["No coverage baseline is available."]
            )
        }

        var fullRunReasons = changes.unresolvedReasons
        if baseline.revision != changes.baseRevision {
            fullRunReasons.append("Coverage does not match the diff's base revision.")
        }
        if baseline.configuration != changes.configuration {
            fullRunReasons.append("Coverage does not match the requested build configuration.")
        }

        let measuredFunctions = baseline.functionsByTest.values.reduce(into: Set<FunctionID>()) {
            $0.formUnion($1)
        }
        if !changes.changedFunctions.isSubset(of: measuredFunctions) {
            fullRunReasons.append("Changed functions have no recorded test coverage.")
        }

        var reasons: [String: Set<Selection.Reason>] = [:]
        for test in availableTests {
            var testReasons = Set<Selection.Reason>()
            if changes.changedTests.contains(test) {
                testReasons.insert(.testChanged)
            }
            if let covered = baseline.functionsByTest[test] {
                for function in covered.intersection(changes.changedFunctions) {
                    testReasons.insert(.coversChangedFunction(function))
                }
            } else {
                testReasons.insert(.missingTestCoverage)
            }
            if !testReasons.isEmpty {
                reasons[test] = testReasons
            }
        }

        return Selection(
            selectedTests: fullRunReasons.isEmpty ? reasons.keys.sorted() : availableTests.sorted(),
            reasonsByTest: reasons,
            fullRunReasons: fullRunReasons
        )
    }
}
