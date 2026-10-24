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

To use declared UI boundaries as the complete runtime dependency contract, add
`"runtimeDependencyPolicy": "declared"` at the mapping file's top level in both
review revisions. The default remains `"conservative"`. In declared mode, an
opaque startup/global-state/SDK dependency does not by itself select an unrelated
UI feature for production edits. Compiled paths and `dependsOn` still propagate
impact, including shared startup dependencies. Declare cross-feature relationships
that the compiler cannot see with `dependsOn`. Unit-test uncertainty, UI test
helper/lifecycle changes, unresolved boundaries, unmapped production changes, and
missing UI coverage retain their conservative fallbacks. Mixed production and
resolved test-entry edits can use the declared contract; ambiguous test changes
cannot. Reports disclose this assumption in `limitations`.

Optionally add `"ignoredDocumentation": ["README.md", "AGENTS.md", "Documentation/**.md"]`
to exclude explicitly reviewed Markdown paths in mixed changes as well as
standalone documentation changes. Patterns must be repository-relative and end
in `.md`; compiled source paths cannot be ignored. Both base and head must allow
each path (including both sides of a rename). The report retains the paths in
`changedFiles` and lists exclusions in `ignoredChanges`. Configuration, resources,
and other unclassified changes still request a full run.

### Diagnostics and fallback policy

- No mapping file on a production change: select every enabled UI test; compiler-based unit selection still applies.
- A UI test belongs to no feature: keep that test conservatively selected on production changes.
- Changed production code has no mapped boundary or reachable feature: select every enabled UI test.
- Missing feature boundary, unmatched test selector, or an affected feature with no tests: report it explicitly and conservatively include UI tests.
- Opaque function calls, global state, raw pointers, or unresolved project dispatch: by default include tests or mapped features that reach the uncertainty (see the opt-in declared UI policy above), except when every changed declaration in both revisions is a resolved test entry point. In that case select the changed entries and their compiled callers. Helpers, setup/teardown, mixed production edits, and ambiguous source boundaries retain the conservative fallback. Compiled candidate edges model known dispatch; SDK UI calls are not treated as app-function edges.
- A test entry point cannot be bound: include that test on semantic changes.
- Unsupported syntax/compiler formats, invalid mapping configuration, missing base graph, unclassified files, or other build changes: explicit full-selection fallback.

Test-entry selection assumes independent tests. Hidden reflective calls between tests and order-dependent state shared by test bodies are not inferred; use full-suite runs for suites that rely on those behaviors. Missing entry points, unknown inheritance, extraction diagnostics, and missing production mappings still produce explicit fallbacks. Imported symbols are compared by compiler identity rather than the module that happened to emit their SIL; uniquely matched owned definitions also support private-symbol file moves.

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

### Reuse an existing build-for-testing

CI can build each revision once, capture its graph, and reuse the head products
for selected execution. A cached **base graph** is enough for comparison; no base
products or historical test execution/coverage baseline are required. This is an
explicit cache: store graph JSON in your CI artifacts and supply it on later runs.

Capture immediately after a successful build, from a **clean checkout of the built
commit**. Use absolute paths, a fresh DerivedData directory, and an unfiltered build
log; an incremental log may omit compiler commands needed for dependency extraction.
The source checkout, compiler file lists, and dependencies must stay at their original
paths until capture finishes. `--revision` asserts which commit produced the build;
keep build, settings export, and capture in the same CI step without source changes.
Store these outputs outside the repository or in an ignored directory.

For example, in Bash (substitute your project, scheme, plan, and runnable simulator):

```bash
set -euo pipefail
PROJECT="$PWD/App.xcodeproj"
ARTIFACTS="$PWD/.build/ci-head"
DERIVED_DATA="$ARTIFACTS/DerivedData"
DESTINATION='platform=iOS Simulator,name=iPhone 17 Pro'
mkdir -p "$ARTIFACTS"

build_options=(-project "$PROJECT" -scheme App -testPlan AllTests
               -configuration Debug -destination "$DESTINATION"
               -derivedDataPath "$DERIVED_DATA")
xcodebuild build-for-testing "${build_options[@]}" > "$ARTIFACTS/build.log" 2>&1
xcodebuild build-for-testing "${build_options[@]}" -showBuildSettings -json \
  > "$ARTIFACTS/settings.json"

# Choose the .xctestrun for AllTests if the build produced several plans.
test_runs=("$DERIVED_DATA"/Build/Products/*.xctestrun)
(( ${#test_runs[@]} == 1 ))
swift-test-impact graph \
  --project "$PROJECT" --scheme App --test-plan AllTests \
  --configuration Debug --destination "$DESTINATION" \
  --derived-data "$DERIVED_DATA" --build-log "$ARTIFACTS/build.log" \
  --build-settings "$ARTIFACTS/settings.json" --xctestrun "${test_runs[0]}" \
  --revision "$(git rev-parse HEAD)" --output "$ARTIFACTS/head-graph.json"
```

Graph capture **does not rebuild app/test executables**, but still replays compiler
commands to emit SIL and initializes runners to enumerate tests. It requires more
than binaries or dSYMs. The capture fingerprints the complete `Build/Products`
directory, including the `.xctestrun`, and records the revision, toolchain, build
context, and input digests. SHA-256 file hashing uses bounded chunks.

Produce a base graph the same way on the base commit (for PRs, the resolved merge
base), using matching build options/toolchain. Then select and execute:

```bash
swift-test-impact select \
  --project "$PROJECT" --scheme App --test-plan AllTests \
  --configuration Debug --destination "$DESTINATION" \
  --base "$PR_BASE_SHA" --head "$PR_HEAD_SHA" --merge-base \
  --base-graph /path/to/cached-base-graph.json \
  --head-graph "$ARTIFACTS/head-graph.json" \
  --format json --output "$ARTIFACTS/selection.json" --run
```

Omit `--run` for report-only analysis: cached selection invokes Git and the selection
engine, with **no Xcode build, enumeration, or compiler replay**. It does not need
DerivedData or build products. Fetch the required Git history first. In this mode,
`--head` defaults to the committed `HEAD`; dirty worktree changes are intentionally
excluded. A wrong revision (including a graph for the PR target tip instead of its
merge base), incompatible configuration/toolchain, or legacy graph without capture
metadata is an error. There is no silent rebuild or substitution of a different cache.
Use the regular selection workflow if you need uncommitted-worktree analysis.

With `--run`, the tool verifies the head product fingerprints and invokes
`xcodebuild test-without-building -xctestrun … -only-testing:…`. It never rebuilds
the checkout. The report's `buildArtifactID` binds execution to the captured head
graph. Empty selections issue no Xcode command; `--full-suite --run` runs all enabled
tests from the same products. Xcode failures retain their nonzero exit status.
To run the head's full plan without a base cache, supply the head graph for both
graph flags and its commit for both revisions, with `--full-suite --run`.

To move execution to another CI job, archive the **entire head `Build/Products`
directory**, preserving symlinks and executable permissions, alongside its graph.
Supply `--test-products /downloaded/Products` with `--run`. This changes only the
product location; fingerprints must still match, and the original selected toolchain
and compatible destination must be available. The supported version-2 `.xctestrun`
uses product-relative paths. External product references are rejected; the supplied
fixture validates relocated iOS Simulator UI and app-hosted unit-test products.
Build settings, log, intermediate files, and original source paths are needed for
capture, but not for cached selection or execution. The Git checkout/history is
still needed for the comparison. Base products can be discarded after capture.

Cache graphs by commit, artifact schema/tool version, toolchain, container, scheme,
plan, configuration, SDK/architectures, destination, and mapping configuration.
Retain conservative diagnostics in reports; cache reuse does not improve graph or
mapping completeness. Validate selected runs against full runs before using a CI gate.

### Xcode implementation and requirements

The adapter builds with `xcodebuild build-for-testing`, reads source ownership from compiler file lists, and replays supported `builtin-SwiftDriver` commands to emit SIL with debug locations. It parses source declarations with SwiftParser and compares syntax structure without trivia, while retaining literal contents and checking compiled dependency changes. It discovers exact enabled IDs with `test-without-building -enumerate-tests`. Discovery launches test runners and may require UI automation permissions; test bodies run only with `--run`. Enumeration errors are fatal even if Xcode exits successfully. Known empty XCTest base classes are excluded from the executable inventory.

Requires macOS, Swift 6+, Xcode test enumeration (Xcode 15+), and a configured scheme/destination. The adapter preserves project signing settings. Compiler-driver output and SIL are version-sensitive; extraction failures and multiple distinct compiler invocations for one module produce fallback diagnostics. The default workflow uses temporary DerivedData and rebuilds both revisions, which can cost more than a small suite; the existing-build workflow above reuses captured graphs and products. Selected runs retain `.xcresult` bundles under `.build/test-impact-results` beside the project/workspace. Validation covers Xcode 26.6 on an iOS 26.2 simulator. macOS UI execution, physical devices, and other Apple platforms are not yet validated for fine-grained selection.

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

JSON includes function symbols, source regions, dependencies, uncertainties, and test entry points. DOT can be opened with Graphviz. Normal graph generation also works without Git; existing-build Xcode capture requires Git revision provenance.

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

For Xcode, construct `XcodeConfiguration(container:path:scheme:destination:configuration:testPlan:)` and pass it to `XcodeAnalysis(options:)`. Its `graph()`, `select(base:head:mergeBase:fullSuite:)`, and `run(_:)` methods parallel the SwiftPM API. Set `mappingsPath` on the configuration to override the mapping file. `XcodeFineSelector` accepts populated Xcode graphs and structured changes directly without subprocesses. Legacy graphs without compiler data retain target-level fallback behavior. For existing Xcode builds, use `graph(from: XcodeBuildInputs)`, `select(base:head:mergeBase:fullSuite:baseGraph:headGraph:)`, and `run(_:using:productsDirectory:)`. The optional `XcodeTestGraph.buildArtifact` stores capture metadata; cached selection requires it.

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

Existing-build acceptance is exercised separately:

```sh
python3 Scripts/xcode_artifact_integration_test.py \
  --destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

It records Xcode invocations to check that capture never rebuilds and cached
selection invokes no Xcode commands. It deletes original DerivedData, relocates
products, makes the checkout invalid, executes one selected UI method while a
neighbor deliberately fails, and checks revision mismatch, merge-base selection,
product tampering, empty execution, and full-suite execution. The full artifact
run executes both UI and app-hosted unit tests and intentionally fails the neighbor
test to verify nonzero failure propagation.

The SIL parser also has an optimized large-input regression benchmark:

```sh
python3 Scripts/benchmark_sil.py --output /tmp/sil-benchmark.json
```

It checks peak RSS and physical footprint, memory growth, and regex compilation
counts as input grows. Xcode extraction reports elapsed time and analyzer memory
for every module. See [SIL performance measurements](Documentation/SILPerformance.md)
for the investigation, budgets, and release measurement procedure.

The real ChainOfCustody combined-plan graph completes, and replaying its two
independently compiled graphs for an assertion-message edit selects exactly one
method out of 1,969 tests. The performance report records the earlier over-selection
and the precision fix. App-feature mappings and validation against full project
runs are still required before relying on production-change selection as a CI gate.

## Next work

- Add automatic cache lookup and eviction; Xcode graphs can currently be cached explicitly with build provenance.
- Extend precise declaration mapping to more language constructs and SwiftPM.
- Improve dispatch, initializer, callback, and test-argument modeling.
- Expand compiler-version, Swift Testing, external inheritance, and resource modeling coverage.
- Collect optional per-test coverage during ordinary selected runs.

References: [Swift compiler](https://www.swift.org/documentation/swift-compiler/), [SIL format](https://github.com/swiftlang/swift/blob/main/docs/SIL/SIL.md), [IndexStoreDB](https://github.com/swiftlang/indexstore-db).

## License

Copyright (c) 2026 Zachary Gorak.

Licensed under the **GNU Affero General Public License, version 3 only** (`AGPL-3.0-only`). See [LICENSE](LICENSE) for the complete terms. This is a strong-copyleft open-source license, including source-sharing requirements for modified versions used over a network. Commercial use is permitted under the license.
