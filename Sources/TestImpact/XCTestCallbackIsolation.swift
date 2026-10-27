// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation

/// XCTest invokes these hooks from its binary, without a caller edge in the
/// captured SIL. An assertion or wait can therefore reach project effects even
/// when every explicit helper call is an SDK operation. Until those callback
/// effects are modeled, their presence prevents the helper-isolation exemption.
enum XCTestCallbackIsolation {
    // Include Swift and Objective-C spellings, plus test-run customization:
    // execution/reporting hooks can observe failures and change shared state.
    private static let hooks: Set<String> = [
        "record", "recordIssue", "recordFailure", "recordFailureWithDescription",
        "invokeTest", "perform", "performTest", "testRunClass", "testRun",
        "defaultTestSuite", "testInvocations"
    ]
    private static let owners: Set<String> = [
        "XCTest", "XCTestCase", "XCTestSuite", "XCTestRun", "XCTestCaseRun", "XCTestSuiteRun"
    ]
    // Observers can live outside the changed helper's caller closure, including
    // in another file or a base-only source. Registration and conformance are
    // both relevant; an inherited/external observer may have no local methods.
    private static let observation: Set<String> = [
        "XCTestObservation", "XCTestObservationCenter", "addTestObserver", "removeTestObserver"
    ]

    static func blocker(current: XcodeTestGraph, base: [String: SwiftSourceSnapshot],
                        unownedBase: [String: SwiftSourceSnapshot]) -> String? {
        let revisions = [Array(current.sources.values), Array(base.values) + Array(unownedBase.values)]
        for sources in revisions {
            for source in sources {
                guard source.diagnostics.isEmpty, let names = source.identifierNames,
                      source.dispatchMembers != nil, source.dispatchOverrides != nil,
                      source.superclasses != nil, source.typeAliases != nil else {
                    return "Missing XCTest callback evidence; refresh source proofs"
                }
                if let name = observation.sorted().first(where: { names.contains($0) || names.contains("`" + $0 + "`") }) {
                    return "Unproven XCTest observation callbacks: " + name
                }
            }
        }
        // A known XCTest subclass may override other framework entry points,
        // such as name/description. Do not try to enumerate every reporting
        // callback. Only the lifecycle hooks already bound into every test root
        // are exempt; their implementations still undergo the caller audit.
        let boundLifecycle: Set<String> = ["setUp", "setUpWithError", "tearDown", "tearDownWithError", "init", "deinit"]
        for sources in revisions {
            var nominalNames: [String: String] = [:]
            func nominal(_ spelling: String) -> String? {
                if let cached = nominalNames[spelling] { return cached.isEmpty ? nil : cached }
                let name = SwiftSourceSnapshot.nominalTypeName(spelling).map(SDKTestHelperSyntax.canonicalName)
                nominalNames[spelling] = name ?? ""
                return name
            }
            let parents = sources.flatMap { $0.superclasses!.map {
                (SDKTestHelperSyntax.canonicalName($0.key), $0.value.compactMap(nominal))
            } }
            var related = Set<String>()
            var changed = true
            while changed {
                changed = false
                for (owner, bases) in parents where !related.contains(owner) {
                    if bases.contains(where: { name in
                        return owners.contains(name.split(separator: ".").last.map(String.init) ?? name) ||
                            related.contains(name) || related.contains(where: { $0.hasSuffix("." + name) })
                    }) { related.insert(owner); changed = true }
                }
            }
            for declaration in sources.flatMap({ $0.dispatchOverrides! }).map(SDKTestHelperSyntax.canonicalName).sorted() {
                let parts = declaration.split(separator: ".")
                if related.contains(parts.dropLast().joined(separator: ".")),
                   let member = parts.last, !boundLifecycle.contains(String(member)) {
                    return "Unproven XCTest framework callback effects: " + declaration
                }
            }
        }
        guard SDKTestHelperIsolation.overridesUnshadowed(revisions: revisions, members: hooks, sdkReceivers: owners),
              SDKTestHelperIsolation.memberBindingsUnshadowed(revisions: revisions, members: hooks, sdkOwners: owners) else {
            return "Unproven XCTest failure-recording or execution callback effects"
        }
        return nil
    }
}
