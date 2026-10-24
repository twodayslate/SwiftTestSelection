# SwiftTestSelection

Select Swift tests from a Git diff and a compiler-derived dependency graph. **No coverage baseline or initial full-suite run is required.**

A Swift package providing a `swift-test-impact` executable and reusable `TestImpact` library. SwiftPM packages use a function dependency graph with XCTest and Swift Testing discovery. Xcode projects/workspaces select individual XCTest methods through syntax and compiler dependencies, with explicit feature mappings for XCUITest. It is experimental static analysis, not a guarantee of the smallest safe test set.

## Build

Requires Swift 6+, Git, and a toolchain capable of building the target package. Validated with Apple Swift 6.3.3 on Apple Silicon macOS; Linux is not yet validated. SwiftSyntax/SwiftParser 600.0.1 is pinned for source parsing; unsupported syntax produces a diagnostic and conservative fallback.

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

`--base HEAD` compares the committed revision with the current working tree, including staged, unstaged, and untracked files. To compare against an ancestor, supply its revision or SHA. The default uses the exact supplied revision. Add `--head REVISION` for two committed revisions and `--merge-base` for a PR comparison against their common ancestor. Without `--head`, merge-base uses `HEAD` as the ancestry anchor and still analyzes the worktree. Explicit head revisions are exported for both analysis and execution; dirty worktree changes are excluded.

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

## Fine-grained Xcode and XCUITest selection

All tests can live in **one target and one test plan**. A test-method edit does not require running its entire target:

```sh
swift run swift-test-impact select \
  --project /path/to/App.xcodeproj \
  --scheme App --test-plan AllTests \
  --destination 'platform=iOS Simulator,id=YOUR-SIMULATOR-UUID' \
  --base HEAD --format json
```

Use `--workspace /path/to/App.xcworkspace` instead of `--project` for a workspace. `--configuration Debug` is optional. These settings are used consistently for building, discovery, and execution. The container must be inside the Git repository. Omit `--run` to review the report without executing test bodies; add it to execute the selected exact identifiers.

| Change | Selection |
| --- | --- |
| Edit one test method | That method and any compiled callers |
| Add a method | The newly discovered method |
| Edit a helper | Tests that reach it through compiler references |
| Edit setup/teardown | Tests in its class and dependent subclasses |
| Edit an inherited method | Tests reaching that implementation, including inherited lifecycle roots |
| Edit production code | Dependent unit tests and affected mapped UI tests |
| Edit a shared production dependency | Tests for every feature whose compiled roots reach it, plus explicitly declared dependent features |
| Comments/formatting | No additional tests when parsed syntax and compiled dependencies are unchanged |
| Pure Swift file move | No additional tests when syntax, module ownership, and compiled dependencies are unchanged |
| Missing/unresolved information | Structured diagnostic and conservative fallback |

Both revisions are analyzed. Removed functions and dependencies retain their old callers; deleted tests are excluded. New tests are always included. Initializers and lifecycle hooks are associated with their class and ancestors. Stored state/type-layout changes broaden selection to the affected class; file-level declarations may broaden it further. Simple `PBXFileReference` path updates accompanying unchanged Swift file renames are recognized; other project/build changes fall back. Resource renames are not assumed to preserve behavior.

### Explicit UI feature mappings

XCUITest runs across a process boundary. A test-runner call graph cannot tell which app code an accessibility action exercises. Check in `.swift-test-selection.json` at the **repository root** to declare those relationships:

```json
{
  "version": 1,
  "fixtures": {
    "sharing": [
      "AppUITests/SharingTests",
      "AppUITests/AttachmentTests/testShareAttachment()"
    ]
  },
  "features": [
    {
      "name": "sharing",
      "sources": ["App/Features/Sharing/**"],
      "fixtures": ["sharing"],
      "dependsOn": ["account"]
    },
    {
      "name": "notes",
      "symbols": ["App.notesTitle()"],
      "tests": ["AppUITests/NotesTests"],
      "dependsOn": ["account"]
    },
    {
      "name": "account",
      "sources": ["App/Account/**"],
      "tests": ["AppUITests/AccountTests"]
    }
  ]
}
```

- `sources` matches repository-relative compiled source paths. `*` matches within one path component; `**` spans components. A source boundary includes all compiled functions in the matched files.
- `symbols` matches the graph's `module + "." + name`, such as `App.notesTitle()`. Use it when several features share one source file. The same wildcard rules apply.
- `tests` accepts exact discovered method IDs, class prefixes, target prefixes, or wildcard patterns. Copy identifiers from `graph` output, including parentheses.
- `fixtures` defines named reusable lists of test selectors. It does not infer runtime fixture coverage.
- `dependsOn` declares feature dependencies outside the compiler graph. A change to `account` affects both sharing and notes. Cycles are handled with finite traversal.

Compiler dependencies propagate transitively from feature roots. If sharing and notes both call a common function, changing that function selects both features without listing the common file in each mapping. Explicit dependencies supplement this graph for service, runtime, or other relationships it cannot infer. Mappings are read independently from the base and head revisions. Use `--mappings path/to/mappings.json` to choose another repository-relative file.

**Mappings are dependency declarations, not measured coverage.** They must cover app startup, shared services, and other cross-process behavior relevant to each UI test. An incorrect but syntactically valid mapping cannot be detected automatically. Narrowing is conditional on the declared boundaries being complete.

### Diagnostics and fallback policy

- No mapping file on a production change: select every enabled UI test; compiler-based unit selection still applies.
- A UI test belongs to no feature: keep that test conservatively selected on production changes.
- Changed production code has no mapped boundary or reachable feature: select every enabled UI test.
- Missing feature boundary, unmatched test selector, or an affected feature with no tests: report it explicitly and conservatively include UI tests.
- Opaque function calls, global state, raw pointers, or unresolved project dispatch: include tests or mapped features that reach the uncertainty. Compiled candidate edges model known dispatch; SDK UI calls are not treated as app-function edges.
- A test entry point cannot be bound: include that test on semantic changes.
- Unsupported syntax/compiler formats, invalid mapping configuration, missing base graph, unclassified files, or other build changes: explicit full-selection fallback.

Resource and build-configuration changes currently fall back; this version does not infer resource dependencies from UI mappings. Unsupported inheritance across external modules and runtime registration may also broaden selection. The graph is experimental, and dynamic dependencies can still escape analysis. Validate with full runs before using selection as a CI gate.

Reports use schema version 2 in Xcode mode. `selectedTests` and `onlyTestingArguments` contain exact IDs and literal `-only-testing:` arguments. Every selected test has an explanation whose `kind` distinguishes `dependency`, `explicitMapping`, `fallback`, `newTest`, or `fullSuite`. `revision` identifies the relevant side and `path` describes the dependency or mapping. `diagnostics` includes stable `code`, `message`, and affected `tests`; `fullRunReasons` lists suite-wide fallbacks. `ignoredChanges` lists changes ignored as semantic no-ops. `uiMappingCoverage` always lists mapped/unmapped UI tests, unresolved feature boundaries, and unmatched selectors, including on no-op or test-only changes; these are declarations, not measured coverage. `baseRevision`, `headRevision`, and `comparisonMode` identify the comparison.

### Local and PR CI usage

Use the same executable locally and in CI. Fetch both refs and their history before using merge-base mode:

```sh
.build/release/swift-test-impact select \
  --workspace App.xcworkspace --scheme App --test-plan AllTests \
  --destination "$TEST_DESTINATION" \
  --base "$PR_BASE_SHA" --head "$PR_HEAD_SHA" --merge-base \
  --format json --output .build/selection.json --run
```

`--head` exports and builds that exact commit, and `--run` executes from another export of the same commit. It never switches the user's checkout. Merge-base mode rejects histories with multiple merge bases rather than choosing an arbitrary ancestor. An empty selection executes no test command. Test failures preserve Xcode's nonzero exit status.

Full-suite execution remains explicit:

```sh
.build/release/swift-test-impact select \
  --project App.xcodeproj --scheme App --test-plan AllTests \
  --destination "$TEST_DESTINATION" \
  --base HEAD --full-suite --run
```

"Full suite" means all **enabled** tests in the chosen plan/configuration, not disabled tests. During adoption, retain selected-run reports and run the full plan at the same head/configuration. Compare failures and investigate any failing test omitted by selection; account for flaky tests and shared environment effects. Keep periodic full runs after adoption. The fixture validation does not validate the mappings for your own application.

### Xcode implementation and requirements

The adapter builds with `xcodebuild build-for-testing`, reads source ownership from compiler file lists, and replays supported `builtin-SwiftDriver` commands to emit SIL with debug locations. It parses source declarations with SwiftParser and compares syntax structure without trivia, while retaining literal contents and checking compiled dependency changes. It discovers exact enabled IDs with `test-without-building -enumerate-tests`. Discovery launches test runners and may require UI automation permissions; test bodies run only with `--run`. Enumeration errors are fatal even if Xcode exits successfully. Known empty XCTest base classes are excluded from the executable inventory.

Requires macOS, Swift 6+, Xcode test enumeration (Xcode 15+), and a configured scheme/destination. The adapter preserves project signing settings. Compiler-driver output and SIL are version-sensitive; extraction failures and multiple distinct compiler invocations for one module produce fallback diagnostics. Analysis uses temporary DerivedData and rebuilds both revisions, which can cost more than a small suite. Selected runs retain `.xcresult` bundles under `.build/test-impact-results` beside the project/workspace. Validation covers Xcode 26.6 on an iOS 26.2 simulator. macOS UI execution, physical devices, and other Apple platforms are not yet validated for fine-grained selection.

`graph` accepts the same container/build/mapping options and `--format json|dot`. Xcode JSON uses `analysisKind: "xcode-sil-and-ui-mappings"` and includes source snapshots, compiled dependencies, exact tests, ownership, and mappings. DOT currently shows compiled source ownership; the JSON `dependencies` graph contains function edges. No inferred compiler edge claims to cross the UI automation process boundary.

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

## SwiftPM conservative behavior and limits

- Dynamic dispatch, indirect calls, shared-state access, raw-pointer operations, and parameterized test arguments cause reachable tests to be selected conservatively on source changes. Dispatch tables add candidate edges; they do not prove all runtime targets are known.
- Changes outside mapped function regions, non-Swift files, manifests, unsupported targets, and graph/discovery diagnostics select the entire current suite. Even whitespace/comments outside mapped regions can broaden selection in this version.
- Newly added functions with resolvable caller-to-test paths need no historical coverage. Functions without an identified test path appear in `unreferencedChanges`; this does not prove they are unreachable or untested.
- Mapping uses compiler debug-location ranges rather than a full Swift syntax tree. Declaration/type-layout changes and ambiguous mappings deliberately broaden the run.
- External frameworks, runtime registration, Objective-C behavior, custom test traits, generated code, and implicit shared-state relationships can escape the graph. Conservative rules reduce omissions but do not make the analysis sound for arbitrary Swift programs. Validate against full-suite runs before using it as a CI gate.
- SwiftPM function analysis supports host-platform debug builds. Xcode uses the separate syntax/SIL/mapping adapter described above. Custom SwiftPM build flags and precompiled-binary-only input are not supported yet.
- Only root-package Swift targets are extracted. Dependency source changes that cannot be mapped fall back to all tests. Historical builds with unavailable dependencies, submodules, or external local paths may also fall back.
- SwiftPM's `description.json` and textual SIL are implementation formats. The adapter may need updates across Swift versions; unexpected build-description formats fail explicitly.
- Keep source files stable during worktree analysis/execution. Explicit `--head` comparisons use isolated commit exports.

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

For Xcode, construct `XcodeConfiguration(container:path:scheme:destination:configuration:testPlan:)` and pass it to `XcodeAnalysis(options:)`. Its `graph()`, `select(base:head:mergeBase:fullSuite:)`, and `run(_:)` methods parallel the SwiftPM API. Set `mappingsPath` on the configuration to override the mapping file. `XcodeFineSelector` accepts populated Xcode graphs and structured changes directly without subprocesses. Legacy graphs without compiler data retain target-level fallback behavior.

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

This script copies `Fixtures/XcodeUITests` into a temporary repository with spaces in its path. A single plan contains seven UI tests in one target and two unit tests. It checks method additions/edits/deletions, helpers, setup, inheritance, mapped production dependencies, trivia, pure moves, fallback diagnostics, explicit heads, merge-base comparisons, and workspace discovery. A selected method actually runs while another method in the same target deliberately fails. Explicit-head execution is checked with an invalid dirty worktree. A healthy full-plan run verifies all nine tests. The package tests also model selecting one method from a 393-test target. Use `--keep-work` to retain integration artifacts and result bundles.

The SIL parser also has an optimized large-input regression benchmark:

```sh
python3 Scripts/benchmark_sil.py --output /tmp/sil-benchmark.json
```

It checks peak RSS and physical footprint, memory growth, and regex compilation
counts as input grows. Xcode extraction reports elapsed time and analyzer memory
for every module. See [SIL performance measurements](Documentation/SILPerformance.md)
for the investigation, budgets, and release measurement procedure.

The real ChainOfCustody combined-plan graph now completes, but its one-method
precision check still selects all 1,969 tests. Imported-symbol attribution changes
and conservative runtime fallbacks remain blockers to using that project as a
selective CI gate; the performance report documents these findings separately
from the passing synthetic acceptance tests.

## Next work

- Cache graphs by source/build identity.
- Extend precise declaration mapping to more language constructs and SwiftPM.
- Improve dispatch, initializer, callback, and test-argument modeling.
- Expand compiler-version, Swift Testing, external inheritance, and resource modeling coverage.
- Collect optional per-test coverage during ordinary selected runs.

References: [Swift compiler](https://www.swift.org/documentation/swift-compiler/), [SIL format](https://github.com/swiftlang/swift/blob/main/docs/SIL/SIL.md), [IndexStoreDB](https://github.com/swiftlang/indexstore-db).

## License

Copyright (c) 2026 Zachary Gorak.

Licensed under the **GNU Affero General Public License, version 3 only** (`AGPL-3.0-only`). See [LICENSE](LICENSE) for the complete terms. This is a strong-copyleft open-source license, including source-sharing requirements for modified versions used over a network. Commercial use is permitted under the license.
