# SwiftTestSelection

Select Swift tests from a Git diff and a compiler-derived dependency graph. **No coverage baseline or initial full-suite run is required.**

A Swift package providing a `swift-test-impact` executable and reusable `TestImpact` library. SwiftPM packages use a function dependency graph with XCTest and Swift Testing discovery. Xcode projects/workspaces support XCUITest through conservative build-target selection. It is experimental static analysis, not a guarantee of the smallest safe test set.

## Build

Requires Swift 6+, Git, and a toolchain capable of building the target package. Validated with Apple Swift 6.3.3 on Apple Silicon macOS; Linux is not yet validated. No third-party package dependencies.

```sh
swift build -c release
.build/release/swift-test-impact --help
```

## Select tests

Point the tool at a Swift package in a Git repository:

```sh
swift run swift-test-impact select \
  --package-path /path/to/YourPackage \
  --base HEAD
```

`--base HEAD` compares the committed revision with the current working tree, including staged, unstaged, and untracked files. To compare against an ancestor, supply its revision or SHA. The tool uses the exact supplied revision; it does not automatically compute a merge base.

The default command reports a selection. Add `--run` to execute it:

```sh
swift run swift-test-impact select \
  --package-path /path/to/YourPackage \
  --base main \
  --run
```

An empty selection executes no test command. Test failures return the runner's nonzero exit status. Analysis/build failures return a nonzero exit status; failure to build the *base* revision instead produces an explicit full-suite fallback using the current test inventory.

Machine-readable output:

```sh
swift run swift-test-impact select \
  --package-path /path/to/YourPackage \
  --base HEAD \
  --format json \
  --output /path/to/YourPackage/.build/impact.json
```

Progress and test-run output go to stderr, so stdout remains usable as JSON. Keep reports under `.build` or another ignored directory so they do not become part of subsequent diffs.

## Xcode and XCUITest

Select and run tests from an Xcode scheme, using a destination available on your machine:

```sh
swift run swift-test-impact select \
  --project /path/to/App.xcodeproj \
  --scheme App \
  --destination 'platform=iOS Simulator,id=YOUR-SIMULATOR-UUID' \
  --base HEAD \
  --run
```

Use `--workspace /path/to/App.xcworkspace` instead of `--project` for a workspace. Optional `--configuration Debug` and `--test-plan SmokeTests` are passed to every build, discovery, and execution command. Omit `--run` for a report; add `--format json` for machine-readable output. The container must be inside the Git repository for selection.

XCUITest controls an app in a separate process, so a call graph from the test runner cannot establish which app functions an accessibility action reaches. This adapter therefore uses **target-level selection**:

| Change | Selection |
| --- | --- |
| Swift source used only by test targets | All enabled tests in those targets |
| Shared test helper | All enabled tests in every owning test target |
| App/framework source, resources, project settings, or unclassified files | All enabled tests in the chosen scheme/test plan |
| Missing base build or source ownership | Explicit full-selection fallback |
| Empty diff | No tests executed |

Both base and current compiled source-file lists establish ownership, covering moved/deleted sources. Newly discovered tests are included; deleted tests are excluded. Schemes containing unit tests use the same target-level policy in Xcode mode. Function-level selection remains available in SwiftPM mode.

The adapter builds with `xcodebuild build-for-testing`, reads build settings and `SwiftFileList` compiler inputs, then discovers exact identifiers with `test-without-building -enumerate-tests`. It does not run test bodies during analysis, but discovery launches test runners and may require UI automation permissions. Enumeration errors, missing test identifiers, and an empty inventory fail explicitly, including errors embedded in otherwise successful Xcode output. Execution passes literal `-only-testing:` identifiers and preserves the runner's exit status.

Requires macOS with Xcode's test-enumeration support (Xcode 15+) and a configured scheme/destination. The adapter preserves project signing settings. Analysis uses temporary DerivedData and rebuilds both revisions; these builds and discovery can cost more than a small suite. Selected runs retain `.xcresult` bundles under `.build/test-impact-results` beside the project/workspace. Current validation covers Xcode 26.6 on an iOS 26.2 simulator; macOS fixture builds passed, but local macOS UI discovery was blocked by an automation-mode timeout. Physical devices and other Apple platforms are not yet validated.

Inspect the Xcode ownership graph with the same options:

```sh
swift run swift-test-impact graph \
  --project /path/to/App.xcodeproj \
  --scheme App \
  --destination 'platform=iOS Simulator,id=YOUR-SIMULATOR-UUID' \
  --format dot --output /path/to/.build/ui-targets.dot
```

Xcode JSON identifies this graph as `analysisKind: "xcode-build-targets"`; DOT shows tests, targets, and compiled source ownership. Neither format claims to resolve UI interactions into app function calls.

## Inspect the graph

```sh
swift run swift-test-impact graph \
  --package-path /path/to/YourPackage \
  --output /path/to/YourPackage/.build/graph.json

swift run swift-test-impact graph \
  --package-path /path/to/YourPackage \
  --format dot \
  --output /path/to/YourPackage/.build/graph.dot
```

JSON includes function symbols, source regions, dependencies, uncertainties, and test entry points. DOT can be opened with Graphviz. Graph generation also works without Git.

For example, the included `Fixtures/Shop` package exposes:

```text
CheckoutTests.testCheckout()
  → assertion closure → checkout(_:) → calculateTax(_:)

CheckoutTests.testReceipt()
  → assertion closure → receipt(_:) → checkout(_:) → calculateTax(_:)

taxCalculation() → calculateTax(_:)

CheckoutTests.testGreeting() → greeting()
Greetings.saysHello()       → greeting()
```

A change inside `calculateTax` selects the three tax/checkout tests. Neither greeting test is selected in this example.

## How SwiftPM analysis works

1. Build the current package and test targets in `.build/test-impact`, a separate scratch directory.
2. Read SwiftPM's compiler invocations and replay each root-package Swift target with `-emit-sil -whole-module-optimization -Onone -g`, reusing SDKs, search paths, defines, and plugin arguments.
3. Parse SIL function references, closure references, debug locations, and dispatch-table relationships. Function values passed as callbacks are retained conservatively, even without an immediate call.
4. Discover identifiers with `swift test list` and associate them with compiled functions. User-defined setup, teardown, and initialization hooks are included conservatively across their test module.
5. Export the base Git revision to a temporary directory and repeat the analysis. The user's checkout is never switched or reset. Temporary files are removed afterward.
6. Map both sides of the diff to source regions and walk dependencies back to current tests. Old relationships handle removed functions; new relationships handle additions. Reports explain the dependency paths behind selection.

**Builds are required; test-body execution is not.** SwiftPM manifests, plugins, compiler macros, and test discovery execute code during normal building/discovery. Discovery can run global initialization. Use repositories you trust to build.

The current build can reuse incremental artifacts. The base revision is rebuilt in isolation on each selection; for short suites this analysis can cost more than running tests. Persistent caching is future work.

## Conservative behavior and limits

- Dynamic dispatch, indirect calls, shared-state access, raw-pointer operations, and parameterized test arguments cause reachable tests to be selected conservatively on source changes. Dispatch tables add candidate edges; they do not prove all runtime targets are known.
- Changes outside mapped function regions, non-Swift files, manifests, unsupported targets, and graph/discovery diagnostics select the entire current suite. Even whitespace/comments outside mapped regions can broaden selection in this version.
- Newly added functions with resolvable caller-to-test paths need no historical coverage. Functions without an identified test path appear in `unreferencedChanges`; this does not prove they are unreachable or untested.
- Mapping uses compiler debug-location ranges rather than a full Swift syntax tree. Declaration/type-layout changes and ambiguous mappings deliberately broaden the run.
- External frameworks, runtime registration, Objective-C behavior, custom test traits, generated code, and implicit shared-state relationships can escape the graph. Conservative rules reduce omissions but do not make the analysis sound for arbitrary Swift programs. Validate against full-suite runs before using it as a CI gate.
- SwiftPM function analysis supports host-platform debug builds. Xcode uses the separate target-level adapter described above. Custom SwiftPM build flags and precompiled-binary-only input are not supported yet.
- Only root-package Swift targets are extracted. Dependency source changes that cannot be mapped fall back to all tests. Historical builds with unavailable dependencies, submodules, or external local paths may also fall back.
- SwiftPM's `description.json` and textual SIL are implementation formats. The adapter may need updates across Swift versions; unexpected build-description formats fail explicitly.
- Keep source files stable during analysis/execution. This version does not snapshot the current worktree.

## Library

Use this package as a dependency and add its `TestImpact` library product to your target:

```swift
import Foundation
import TestImpact

let analysis = ImpactAnalysis(packagePath: URL(fileURLWithPath: "/path/to/YourPackage"))
let report = try analysis.select(base: "HEAD")
print(report.selectedTests)

// Explicitly opt in to execution:
let exitCode = try analysis.run(report)
```

`PackageAnalyzer` builds graphs, `SILParser` reads compiler output, and `StaticSelector` accepts graphs and structured changes without subprocesses. The original in-memory `CoverageBaseline`/`TestSelector` API remains for optional coverage experiments; the CLI does not use it.

For Xcode, construct `XcodeConfiguration(container:path:scheme:destination:configuration:testPlan:)` and pass it to `XcodeAnalysis(options:)`. Its `graph()`, `select(base:)`, and `run(_:)` methods parallel the SwiftPM API. `XcodeSelector` accepts ownership graphs and changes directly for use without subprocesses.

## Validation

```sh
swift test
python3 Scripts/integration_test.py
```

The integration script creates a temporary Git repository from `Fixtures/Shop`, including paths with spaces. It checks real SIL, both test frameworks, empty selections, selected execution, additions, deletions, manifest fallbacks, untracked sources, and DOT export. Unrelated tests intentionally fail in the temporary fixture, so a successful selected run verifies those tests were skipped. The original fixture remains untouched.

For XCUITest, supply an available simulator destination:

```sh
python3 Scripts/xcode_integration_test.py \
  --destination 'platform=iOS Simulator,id=YOUR-SIMULATOR-UUID'
```

This script copies `Fixtures/XcodeUITests` into a temporary Git repository with spaces in its path. It verifies project/workspace discovery, compiled source ownership, empty selections, test-target narrowing, and app-change fallbacks. It actually runs one selected UI test while the unrelated target contains a deliberately failing test, proving that target was skipped. The fixture supports iOS and macOS; it requires a usable UI automation environment.

## Next work

- Cache graphs by source/build identity.
- Add compiler-index or syntax-based mapping for declaration changes.
- Improve dispatch, initializer, callback, and test-argument modeling.
- Improve Xcode function analysis and investigate explicit app-to-UI-test dependency mappings.
- Collect optional per-test coverage during ordinary selected runs.

References: [Swift compiler](https://www.swift.org/documentation/swift-compiler/), [SIL format](https://github.com/swiftlang/swift/blob/main/docs/SIL/SIL.md), [IndexStoreDB](https://github.com/swiftlang/indexstore-db).

## License

Copyright (c) 2026 Zachary Gorak.

Licensed under the **GNU Affero General Public License, version 3 only** (`AGPL-3.0-only`). See [LICENSE](LICENSE) for the complete terms. This is a strong-copyleft open-source license, including source-sharing requirements for modified versions used over a network. Commercial use is permitted under the license.
