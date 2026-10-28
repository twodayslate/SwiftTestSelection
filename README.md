# SwiftTestSelection

Select Swift tests from a Git diff and a compiler-derived dependency graph. **No coverage baseline or initial full-suite run is required.**

A Swift package providing a `swift-test-impact` executable and reusable `TestImpact` library. SwiftPM packages use a function dependency graph with XCTest and Swift Testing discovery. Xcode projects/workspaces select individual XCTest methods through syntax and compiler dependencies, with explicit feature mappings for XCUITest. It is experimental static analysis, not a guarantee of the smallest safe test set.

## Install a prebuilt executable

Versioned [GitHub Releases](https://github.com/twodayslate/SwiftTestSelection/releases)
provide `swift-test-impact-vX.Y.Z-macos-universal.tar.gz` and `SHA256SUMS`.
The executable supports macOS 13+ on Apple Silicon and Intel. SwiftSyntax and
SwiftParser are linked into the executable, so installing it does not compile
this package or its dependencies. Git and a Swift 6+ toolchain are still needed
to analyze/build your project; Xcode analysis requires Xcode.

Pin a published version in CI, download both files, verify the checksum, and
add the extracted `bin` directory to `PATH`:

```sh
set -eu
VERSION=vX.Y.Z # Replace with a published release tag.
RELEASE_URL="https://github.com/twodayslate/SwiftTestSelection/releases/download/$VERSION"
INSTALL_DIR="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/swift-test-impact/$VERSION"
mkdir -p "$INSTALL_DIR"
curl --fail --location --retry 3 "$RELEASE_URL/swift-test-impact-$VERSION-macos-universal.tar.gz" \
  --output "$INSTALL_DIR/swift-test-impact-$VERSION-macos-universal.tar.gz"
curl --fail --location --retry 3 "$RELEASE_URL/SHA256SUMS" --output "$INSTALL_DIR/SHA256SUMS"
(
  cd "$INSTALL_DIR"
  shasum -a 256 -c SHA256SUMS
  tar -xzf "swift-test-impact-$VERSION-macos-universal.tar.gz"
)
export PATH="$INSTALL_DIR/bin:$PATH"
export SWIFT_TEST_SELECTION="$INSTALL_DIR"
swift-test-impact --help
```

Run this example as a shell script or CI step; `set -eu` stops the script on
download, checksum, or extraction failures. The default uses the CI runner's
temporary directory, or the system temporary directory, outside your checkout.
Installing the tool therefore does not add files to the analyzed Git diff or
require changes to `.gitignore`.

In GitHub Actions, append
`echo "$INSTALL_DIR/bin" >> "$GITHUB_PATH"` and
`echo "SWIFT_TEST_SELECTION=$INSTALL_DIR" >> "$GITHUB_ENV"` to the install step
to make the executable and helper location available in subsequent steps.
Use `swift-test-impact` in place of `swift run swift-test-impact` in the examples
below to use the binary.

The archive also includes `Scripts/capture-build.py` and its three companion
scripts under `Scripts/Experimental`. For build-time SIL capture and `--head-only`,
pass `--build-time-sil "$SWIFT_TEST_SELECTION/Scripts/capture-build.py"` using the
same installation as the executable. These modes additionally require Python 3.9+.

Archives include the project and dependency licenses plus `BUILD-INFO.txt` with
the version, source revisions, and build toolchain. Binaries are ad-hoc signed;
they are not Developer ID signed or notarized. Linux binaries are not currently
published.

## Build from source

Requires Swift 6+, Git, and a toolchain capable of building the target package. Validated with Apple Swift 6.3.3 on Apple Silicon macOS; Linux is not yet validated. SwiftSyntax/SwiftParser 600.0.1 is pinned for source parsing; unsupported syntax produces a diagnostic and conservative fallback.

```sh
swift build -c release
.build/release/swift-test-impact --help
```

### Build and publish releases

The [Build and release CLI workflow](.github/workflows/binaries.yml) uses the
attached macOS runner with labels `self-hosted`, `macOS`, and `ARM64`. It requires
full Xcode selected with `xcode-select`, Swift 6+, and Python 3. It runs the Swift
tests and capture-script tests, builds both architectures, checks the executable's
runtime dependencies, and runs the SwiftPM integration suite and installation
regressions against the extracted archive. It also compiles a Swift fixture through
the bundled capture helpers. Intel execution is smoke-tested when Rosetta is already available;
building the Intel slice does not require it.

Pushes to `main` and manual runs produce downloadable workflow artifacts retained
for 14 days. A tag such as `v1.2.3` also publishes those verified files to a GitHub
Release; `v1.2.3-rc.1` publishes a prerelease. Choose the intended version and tag
the reviewed commit after this workflow has landed:

```sh
git tag vX.Y.Z <reviewed-commit>
git push origin vX.Y.Z
```

The publishing job runs on a GitHub-hosted runner with `contents: write`; the
build job has read-only repository permissions. Pull requests do not execute on
the persistent self-hosted runner. A failed publish can be rerun while the release
is still a draft. Published assets are never overwritten; use a new version for
changes. A manual run on a version tag follows the same publishing rules.

To reproduce the packaging and integration checks locally:

```sh
bash Scripts/package-release.sh dev-local
# Outputs: .build/distribution/dev-local/
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

### Documentation and source-location literals

Swift comparisons preserve parsed syntax, operators, strings, and regex contents
while ignoring comments and whitespace. Location sensitivity is per expression:
an unrelated `#line` never makes a later class header change. Bare location
literals used as parameter defaults (as in XCTest assertion helpers) capture the
caller's location, so moving the helper does not change its fingerprint. Callers of
source-declared defaults compare their invocation locations, including across
source files. Syntactic callable names supplement compiler dependencies so
mandatory inlining (such as `@_transparent`) and enum constructor lowering cannot
hide shifted location arguments. Enum associated-value defaults use caller
locations too. A shifted call can therefore select its test even if its
syntax is unchanged. Calls with explicit arguments, ambiguous bindings, matching
names in unrelated modules/overloads, constructor aliases, and implicit
`callAsFunction` invocations remain conservative because syntax and
dependency edges do not prove the selected declaration or omitted argument slots. Body
expressions and parenthesized/arithmetic defaults retain their evaluated location;
`#sourceLocation` adjusts presumed file/line values, and `#column` tracks its own
expression position.

By default, actual location-value changes remain semantic. Choose a policy in
`.swift-test-selection.json` only when the values it ignores are diagnostic and
never control application or test behavior:

| `sourceLocationPolicy` | Implicit line/column changes | File identity changes (`#file`, `#fileID`, `#filePath`) |
| --- | --- | --- |
| `semantic` (default) | Select affected tests | Select affected tests |
| `diagnosticLineColumn` | Ignore with sufficient saved evidence | Select affected tests |
| `diagnostic` | Ignore with sufficient saved evidence | Ignore with sufficient saved evidence |

Use `diagnosticLineColumn` when line and column values are diagnostic but file
paths locate repository sources or snapshot fixtures. The policy preserves file
identity in body expressions and caller-evaluated defaults, including when a file
is renamed or a declaration moves between existing files. `#fileID` retains its
module/filename identity; a directory-only move with the same identity adds no
tests solely for that literal. `#filePath` remains sensitive to the path.

Opt in to the **same valid policy in both revisions**:

```json
{
  "version": 1,
  "sourceLocationPolicy": "diagnosticLineColumn",
  "ignoredDocumentation": ["*.md", "**/*.md"],
  "features": []
}
```

Add these fields to the existing mapping file, preserving feature mappings and
runtime contracts. Under `diagnosticLineColumn`, comment/doc-comment and whitespace
shifts of diagnostic line/column values add no candidates, including in mixed
executable-code/documentation changes and caller-evaluated defaults. Explicit
macro/directive edits, literal contents, operator changes, and compiled dependency
changes still count. The broader `diagnostic` option also ignores implicit file
identity changes and must not be used for semantic fixture paths.

Missing, one-sided, mismatched, or invalid opt-ins retain semantic comparison.
Introduce the policy before relying on it for later PR comparisons; both retained
graphs must carry that policy. Unresolved ownership remains conservative.
Regenerate saved graphs to capture the new body file-location evidence. With
`diagnosticLineColumn`, older snapshots lacking that evidence keep their original
semantic body fingerprints and may select extra tests for comments. Under either
`semantic` or `diagnosticLineColumn`, snapshots without caller metadata request a
full run with `incomplete_caller_locations`. Legacy evidence is never treated as
proof that a file identity change is harmless.

### Non-UI runtime boundaries (opt-in)

Validated boundaries continue to apply to mixed production changes and edits to
proven test entry bodies. Every changed/added test and explicit dependency remains
eligible for selection, and changed test modules stay in the boundary comparison.
Shared helpers, lifecycle hooks, class state, unknown ownership, and changed or
invalid contracts keep conservative uncertainty selection.

A reachable opaque call is uncertainty, not a proven dependency on the changed
feature. The default still selects its callers conservatively. For a genuinely
isolated test target, you can declare a **closed runtime module contract**:

```json
"testRuntimeBoundaries": [
  {
    "target": "CoreTests",
    "modules": ["CoreTests", "Core"],
    "rationale": "Hostless tests execute only Core and SDK code; no dynamic loading, app IPC, or app-owned shared state."
  }
]
```

This top-level field in `.swift-test-selection.json` applies only to non-UI test
targets. Module names are Swift `PRODUCT_MODULE_NAME` values; the target is the
exact Xcode test-target name. Include the test module, all transitively imported
project modules, and the app host and its imports for hosted tests. **The contract
also asserts that opaque callbacks, SDK calls, reflection, dynamic loading, IPC,
shared files/preferences, and other runtime effects cannot depend on project code
outside those modules.** Compiler imports cannot prove that assertion. Do not add
a contract to a suite with such dependencies merely to reduce the selected count.

Both revisions must declare the identical contract. The analyzer validates
compiler-produced explicit-module import inventories, test-host settings, bound
entries/lifecycle evidence, and explicit compiler references in each revision.
Broad dispatch candidates outside the declared runtime universe do not contradict
that contract; explicit references (including escaped callback addresses) do.
Graphs lacking the edge provenance needed to make that distinction fall back. Missing,
ambiguous, unsupported, or contradictory evidence produces an
`invalid_runtime_boundary` fallback. Old saved graphs without that inventory
cannot establish isolation. Bridging headers are unsupported for a boundary's
module closure; an unrelated test target’s bridging header, missing import map,
or unresolved host does not invalidate a complete hostless boundary. These failures
are recorded per target and retain conservative selection for the affected target.
Missing target identities or an ambiguous compiler inventory still invalidate the
whole runtime inventory.

Only production changes **entirely outside** that validated module closure can
exclude its runtime-uncertainty fallback. Direct dependency selections always
win. Shared module changes, helpers/setup, configuration/resources, unknown
ownership, and changed contracts keep conservative behavior. This is module-level
isolation: it does not separate features inside the same app module. Full runs
remain available with `--full-suite`, and representative full-run comparisons are
required before adopting a contract as a CI gate.

Reports expose `runtimeBoundaryDecisions` with the target, revision, declared
modules, changed modules, rationale, and exact `boundedUncertaintyTests`. These
identify suppressed uncertainty fallbacks, not a list of tests guaranteed absent
from `selectedTests`; a separate dependency/mapping/fallback can still select a
test. Remaining `unresolved_dependency` messages identify the missing boundary
evidence instead of claiming a proven dependency on the changed feature.

The SIL reader also recognizes compiler-emitted concrete imported-conformance
declarations, such as UUID/Date equality witnesses. Proofs are scoped to the
emitting module and retained in cached fragments. Existing project witness tables
win; missing, ambiguous, generic, unsupported, or project-owned declarations
remain conservative. An external declaration proves ownership, not absence of
callbacks (for example NSObject overrides or type-erased equality). Without an
implementation summary it retains runtime uncertainty; only a validated boundary
can exclude unrelated changes. This is not a Foundation allowlist and does not
ignore shared state or escaped callbacks.

See [the issue #29 validation](Documentation/Issue29Validation.md) for the real-project comparison, exact identifiers, execution evidence, and remaining consumer CI gate.

### Diagnostics and fallback policy

- No mapping file on a production change: select every enabled UI test; compiler-based unit selection still applies.
- A UI test belongs to no feature: keep that test conservatively selected on production changes.
- Changed production code has no mapped boundary or reachable feature: select every enabled UI test.
- Missing feature boundary, unmatched test selector, or an affected feature with no tests: report it explicitly and conservatively include UI tests.
- Opaque function calls, global state, raw pointers, or unresolved project dispatch: by default include tests or mapped features that reach the uncertainty (see the opt-in UI and non-UI contracts above), except when every changed declaration in both revisions is a resolved test entry point. In that case select the changed entries and their compiled callers. Helpers, setup/teardown, mixed production edits, and ambiguous source boundaries retain the conservative fallback. Compiled candidate edges model known dispatch; SDK UI calls are not treated as app-function edges.
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
               -derivedDataPath "$DERIVED_DATA"
               'MTL_COMPILER_FLAGS=$(inherited) -Xclang -sys-header-deps')
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
To skip compiler replay, opt in to [sealed build-time SIL capture](#build-time-sil-capture-opt-in). Ordinary build-for-testing does not retain SIL automatically.

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

### Build-time SIL capture (opt-in)

Cached/retained selection can own capture for both revisions. To limit a PR job
to one executable build, use the [cache-only baseline policy](#limit-pr-jobs-to-one-executable-build)
with a baseline produced by main's ordinary build.

```sh
swift-test-impact select \
  --project MyApp.xcodeproj --scheme MyApp --test-plan AllTests \
  --configuration Debug --destination "$DESTINATION" \
  --base origin/main --head HEAD --merge-base \
  --analysis-cache "$CACHE" --cache-context "$BUILD_INPUT_DIGEST" \
  --retain-build "$NEW_BUNDLE" \
  --build-time-sil "$SWIFT_TEST_SELECTION/Scripts/capture-build.py" \
  --format json --output "$REPORT"
```

`--build-time-sil` takes the helper from the **same release archive or pinned source
checkout as the binary**. For a prebuilt installation, use
`"$SWIFT_TEST_SELECTION/Scripts/capture-build.py"` as set up above. Capture
requires Python 3.9+. It is distinct from `--sil-capture`, which imports an
already sealed session with existing-build `graph` inputs. Capture is opt-in;
ordinary builds and the default selection mode still use compiler replay.

The analyzer seals each Git archive export against its exact revision and file
manifest, preserves locked package resolution, and builds the retained head once.
It validates capture sources, outputs, context and products before publishing the
retained completion marker. In the default capture mode both revisions must succeed before
that marker is published, and the head products, log and settings must still match
the original capture seal after the base build finishes.

With `--retain-build`, head diagnostics remain in the bundle's `capture.log` and
`SILCapture`; base capture diagnostics are written directly to
`base-capture-failure`. Without retention, each fresh capture uses a separate
`swift-test-impact-capture-*` temporary directory outside the disposable analysis
cache. The command prints its path before launching the helper. Failures and
cancellation preserve this directory, including combined helper stdout/stderr in
`capture.log`, the source-export manifest, and any session build log/settings/SIL
already written. Successful analysis removes temporary capture diagnostics.
Remove failed capture directories explicitly when no longer needed. Verify and run
the resulting report with the same `verify-build` / `run` commands as ordinary
retained selection. Identical base/head revisions share one analysis/build.

Cache identity includes capture mode and all four helper implementation files.
Warm graph hits explicitly report reuse; when retaining products, a fresh head
build and capture validation still occur. Unsupported/incomplete primary coverage
replays that module and explains why. Valid canonical fragments from empty or
platform-excluded Swift primaries contribute no functions but retain the other
fragments in their module. Unsupported function-free layouts replay; missing or
changed sealed files are integrity failures and never silently replay.

`analysisEvents` separates build wall time, `captureValidation` (wrapper setup,
settings and seals), per-module `captureConsumption`, `compilerReplay`,
`silParsing`, enumeration, evidence processing and total extraction. Per-module
times can overlap with multiple extraction workers; supplementary SIL overhead
inside the original compiler job is included in build time. Measure the entire
workflow against full runs before treating capture or smaller selections as a
CI speedup. A capture-mode graph is not evidence of full-suite equivalence.

See [generated-input, role and capture validation](Documentation/Issues41-44Validation.md)
for real-project results, fixture execution, cache/replay parity and reproduction commands.

`Scripts/capture-build.py` wraps **your build-for-testing step** to add supplementary
SIL output to normal object compilation. `graph --sil-capture SESSION` validates
and parses those fragments without recompiling complete captured modules. It does
not execute test bodies. Keep this path opt-in while validating selections against
full runs; normal-build SIL and whole-module replay are not universally equivalent.

```bash
# Use a dedicated, stable session OUTSIDE the source checkout and one build at a time.
python3 /path/to/SwiftTestSelection/Scripts/capture-build.py \
  --session /tmp/app-impact-capture --context "$EXTERNAL_BUILD_INPUT_DIGEST" \
  --project "$PWD/App.xcodeproj" --scheme App --test-plan AllTests \
  --configuration Debug --destination "$DESTINATION" \
  --derived-data /tmp/app-impact-derived

swift-test-impact graph \
  --project "$PWD/App.xcodeproj" --scheme App --test-plan AllTests \
  --configuration Debug --destination "$DESTINATION" \
  --derived-data /tmp/app-impact-derived \
  --build-log /tmp/app-impact-capture/build.log \
  --build-settings /tmp/app-impact-capture/settings.json \
  --xctestrun /tmp/app-impact-derived/Build/Products/App_AllTests_iphonesimulator.xctestrun \
  --revision HEAD --sil-capture /tmp/app-impact-capture \
  --extraction-workers 2 --format binary --output /tmp/head.impactgraph
```

Replace the `.xctestrun` filename with the actual generated file. Use a clean
committed checkout and a fresh DerivedData directory on the first run. Subsequent
builds may be incremental. The session retains a complete compiler inventory and
checks primary-file coverage for each module. Fresh complete captures skip replay;
missing or unsupported modules explicitly replay. Previous fragments are reused
only when the full source tree, settings, compiler, command and external context
match. A source edit may therefore replay unchanged modules: partial capture is
never accepted as proof that omitted code has no impact. Fresh captures replace
superseded jobs in the active seal; older batches remain only when needed to cover
unchanged primary files. New or incompatible sessions require fresh DerivedData
to establish a complete compiler inventory. Compatible incremental builds ignore
source lists belonging to inactive configurations or removed targets; changing
toolchains also requires a new session.

The wrapper seals the revision, log, settings, source fingerprints, SIL checksums
and exact product hashes after a successful build. Failed builds invalidate the
seal and retain the full log. Analysis checks the seal and rechecks inputs before
returning a graph. `--context` must fingerprint ignored/generated inputs, external
packages, scripts and relevant environment settings outside Git. Keep these inputs
stable during the build and analysis. Sessions retain SIL and logs until you remove
them; manage their disk space explicitly. Capture supports `-Onone -g`, one compiler
invocation per module and supported Xcode SwiftDriver formats.

Concrete witness dispatch keeps the receiver's conformance (for example,
`UIApplication.State` equality), avoiding unrelated equality implementations.
Generic, existential and unsupported receiver forms remain conservative. Missing
concrete witness tables produce explicit unresolved-dependency handling.

Source snapshots distinguish project type declarations from extensions of imported
types. An `extension XCTestCase` helper owns that member, not unrelated framework
initializers. Missing project members still produce conservative dispatch
diagnostics, and compiled helpers and lifecycle overrides remain dependencies.
Specialized superclass references such as `Parent<Int>` resolve through `Parent`,
including qualified and nested types. Unresolved override ancestry (for example,
a type alias the source index cannot resolve) produces an explicit conservative
fallback for matching member dispatches rather than proof of no impact.
Superclass lookup checks enclosing scopes before module-level names. Required
initializer implementations participate in dispatch binding even when Swift does
not spell them with `override`.
A nearer nominal qualifier also shadows outer types. If its nested superclass
member is inherited and cannot be resolved by the source index, matching callers
remain selected with an explicit incomplete-ancestry fallback.
Unqualified names and qualifiers inherited by an enclosing class receive the
same fallback before lookup can accept an outer type. Direct declarations in the
current scope still take precedence.
Regenerate older saved graphs to acquire this ownership metadata; legacy snapshots
retain their conservative classification.

The original [investigation](Documentation/BuildTimeSILInvestigation.md) records
prototype measurements and remaining normal-build/replay differences.

### Compact graphs and reuse of test discovery

Use `graph --format binary --output head.impactgraph` for a checksummed binary
archive with interned symbols, paths and graph strings. `--base-graph` and
`--head-graph` automatically accept binary or existing JSON graphs; JSON remains
the readable interchange/report format. Persistent graph and module caches use the
compact representation too. A bad checksum or unsupported archive fails explicitly.

Existing-build graph capture also accepts:

```text
--discovery-cache /path/to/dedicated-cache --discovery-context INPUT_DIGEST
```

This reuses the **inventory and entire bound analysis**, saving enumeration,
parsing and binding when the products, source revision and compiler source inputs,
selected `.xctestrun`, log, settings, destination, plan, toolchain, simulator runtime,
analyzer, mapping-file contents/existence, and capture seal match exactly. This
includes gitignored or generated mapping files. Source fingerprints follow the supplied
build log’s compiler invocations; stale source lists from inactive configurations
in DerivedData are ignored, while missing active inputs remain errors. A changed or new test, changed products or discovery context
misses the cache. The context must cover external data and runner initialization
inputs; disable caching for nondeterministic/dynamic discovery without a stable
input contract. Cache reuse does not discover new runtime-generated tests on its
own. The cache shares the validated, locked publication and 5 GiB eviction policy.

Selection builds a dense forward/reverse index once per revision and traverses
backward once per changed destination set. Test explanations retain the original
shortest-path tie breaking. File and feature indexes avoid repeated full-graph
scans; selection does not need a coverage baseline.

### Xcode implementation and requirements

The adapter builds with `xcodebuild build-for-testing`, reads source ownership from compiler file lists, and replays supported `builtin-SwiftDriver` commands to emit SIL with debug locations. It parses source declarations with SwiftParser and compares syntax structure without trivia, while retaining literal contents and checking compiled dependency changes. It discovers exact enabled IDs with `test-without-building -enumerate-tests`. Discovery launches test runners and may require UI automation permissions; test bodies run only with `--run`. Enumeration errors are fatal even if Xcode exits successfully. Known empty XCTest base classes are excluded from the executable inventory.

A scheme's `-showBuildSettings` output can omit implicitly built local Swift
packages and embedded app extensions. **No additional ownership build setting or
explicit scheme entry is required for those dependencies.** Keep normal target
and package dependencies configured so `build-for-testing` compiles them, use the
same scheme/plan/configuration/destination for the build and settings export, and
preserve the full build log and its compiler file lists. A clean build or a fresh
DerivedData directory is important: an incremental log can omit unchanged modules.

For modules omitted by scheme settings, the tool pairs each supported
`builtin-SwiftDriver` invocation's `-module-name` with its `.SwiftFileList`, then
parses in-repository sources under that module. JSON represents these owners as
`Compiler module: <name>` with product type `compiler-module`. A file compiled by
several modules retains a separate semantic snapshot for each module. Imported
SIL bodies retain their external linkage so shared source paths cannot overwrite
the defining module or its feature mappings. For source-bearing `shared` bodies
(including `@_alwaysEmitIntoClient`), the compiler's adjacent `swift-demangle`
resolves the declaration module, including extension and protocol-conformance
ownership. Objective-C async closure wrappers retain their enclosing declaration's
owner. Type-only global-actor reabstraction and key-path equality/hash adapters have no declaration owner:
their bodies remain separate per emitting module, with dependencies and runtime
uncertainty intact. Key-path instructions retain embedded accessor and index-helper
references as compiler edges, plus conservative key-path uncertainty.
Their incidental conversion-site debug locations are not
shared source declarations. Their persisted per-module identities keep opaque
runtime dependencies eligible for conservative selection even without source
regions, including when loading saved graphs. Resolution is batched per module and cached;
unfamiliar symbol contexts produce an explicit conservative fallback.
Compiler ownership alone does not prove a product role or runtime isolation.
For recovered modules, the adapter joins the active build manifest's compiler
file list to its target GUID and Xcode PIF target metadata. Supported production
products (including local package libraries, frameworks and app extensions) gain
`recoveredRole` evidence. Test products, contradictory host/module settings,
unknown product types, ambiguous records, and missing metadata remain unproved.
The role and compiler import inventory must agree in both revisions before an
existing declared UI/runtime boundary can narrow uncertainty. This does not create
a runtime contract or UI feature mapping. Hosted tests still require their host
and imports inside their own declared boundary; direct dependencies always win.
`unresolvedProductRoles` and `unresolved_product_role` explain unavailable roles.

Conflicting module/list claims, missing or inactive inputs, unsupported response
files, and modules containing only generated build inputs produce explicit
ownership diagnostics and conservative selection, whether DerivedData is inside
or outside the checkout. Mixed modules retain their repository snapshots and list
unverified generated/external inputs in `unsupportedSourceInputs`.
Semantic changes in those modules produce an `unsupported_source_ownership`
fallback; unrelated resolved test-method edits remain eligible for narrowing.

Validated Xcode auxiliary-file sources (including package resource accessors) and
Xcode `actool` Swift asset symbols instead appear in `generatedSourceBoundaries`.
The boundary records the owning module, stable logical path, exact source digest,
compiler/generator settings and repository resource/build-input fingerprint.
Explicit generated `#filePath` values remain semantic; source literals are never
rewritten to normalize build directories. Equal evidence in both revisions avoids
a full-suite fallback solely because an unchanged generated source exists.
Changed content, resource membership/content, package manifests, bundle identity,
generator/compiler settings, or one-sided evidence produces
`generated_input_changed` and selects the full inventory. Resource changes still
use a conservative fallback; this feature does not infer resource consumers.
Arbitrary shell generators and external inputs remain unsupported.

Preserve `DerivedData/Build/Intermediates.noindex/XCBuildData` (including the active
manifest and `PIFCache/target`) alongside the complete build log when importing
artifacts. Discovery cache keys fingerprint this metadata; module fragments do not
cache product roles or generated-source equivalence. When retaining new products
on a revision-cache hit, the new build's evidence is rechecked before reusing its
analysis. Put analysis outputs outside the source tree: generated-input validation
conservatively fingerprints repository non-Swift files and package manifests.
An `ignoredDocumentation` pattern present in both revisions also applies to these
fingerprints when the active build evidence proves the Markdown file is outside
build inputs. Markdown resources, directory inputs, and files referenced by build
commands remain protected. Standard `copypng` and `xcstringstool` tasks are
recognized at their exact locations in the active compiler's Xcode installation.
External Metal tools must match `xcrun --toolchain com.apple.dt.toolchain.Metal
--find metal` (or `metallib`) using that Xcode and a clean environment. A matching
executable basename elsewhere is insufficient. These tools' declared inputs and
arguments still participate in the Markdown checks. Metal compilation also
requires its emitted makefile dependency list; included Markdown is protected,
and missing or unsupported dependency evidence keeps the conservative fallback.
Dependency files are fingerprinted alongside the active build metadata.
Xcode's default `-MMD` omits system headers, including repository files found
through `-isystem` or marked with `#pragma clang system_header`. Tool-managed
builds and `Scripts/capture-build.py` add
`MTL_COMPILER_FLAGS='$(inherited) -Xclang -sys-header-deps'` to include them while
preserving project Metal flags. When importing your own build, use the same
setting for both `build-for-testing` and `-showBuildSettings`, as in the example
above. Merely adding `-MD` alongside Xcode's `-MMD` is insufficient. Imports with
incomplete or opaque dependency flags retain a diagnostic and conservative
selection; they are not recompiled to recover missing Metal evidence.
Spaced and joined VFS-overlay options are unsupported. Dependency paths must
resolve to readable regular files; missing paths, directories, and dangling links
block exclusions. Markdown paths containing literal backslashes or newlines also
remain conservative because Metal's dependency output cannot reliably preserve
those spellings, even when a different file exists at the rewritten path.
Unknown shell tools prevent this exclusion because they may consume undeclared
inputs. Each boundary's `documentationBlockers` records the exact command/input;
selection emits `documentation_exclusion_blocked` when a changed Markdown file
cannot be excluded. Graphs without `documentationEvidenceVersion: 3`, including
earlier graphs with per-file exclusions or opaque fingerprints, cannot establish
safe exclusions; regenerate both revisions to obtain the complete evidence.
Proven reference-only `.pbxproj` edits accompanying pure file moves are also
excluded from the repository fingerprint comparison. Generated content, generator
settings and resource paths/content still participate in comparison.
The `buildEvidence` analysis event reports ownership/provenance processing time.
These checks work with both compiler replay and sealed build-time SIL capture;
ordinary `build-for-testing` still does not retain SIL automatically.
Entirely external packages, including `DerivedData/SourcePackages/checkouts`,
are not treated as repository source boundaries.
Regenerate saved graphs to acquire this ownership metadata; supplying old graphs
cannot recover missing snapshots from SIL alone.

Requires macOS, Swift 6+, Xcode test enumeration (Xcode 15+), and a configured scheme/destination. The adapter preserves project signing settings. Compiler-driver output and SIL are version-sensitive; extraction failures and multiple distinct compiler invocations for one module produce fallback diagnostics. The default workflow uses temporary DerivedData and rebuilds both revisions, which can cost more than a small suite; the existing-build workflow above reuses captured graphs and products. Selected runs retain `.xcresult` bundles under `.build/test-impact-results` beside the project/workspace. Validation covers Xcode 26.6 and 27.0 on an iOS 26.2 simulator. macOS UI execution, physical devices, and other Apple platforms are not yet validated for fine-grained selection.

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

The [Tests workflow](.github/workflows/tests.yml) runs the full Swift package
test suite, capture-script unit tests, and release-installation regressions on pull requests, pushes to `main`,
merge-queue entries, and manual dispatches. It uses a GitHub-hosted macOS 26
runner with Xcode 26.6, including for fork PRs. New commits cancel superseded
test runs for the same PR or ref. The check is named `Unit tests (macOS)`;
it can be selected as a required status check in repository branch rules.

See [issue #39 validation](Documentation/Issue39Validation.md) for fresh
real-project graphs, source-location policy and cache comparisons, measured time
and memory, and execution of the single selected UI test. The report also records
remaining conservative selections and limits on CI rollout evidence.

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

Discovery-cache regressions can be checked without executing test bodies:

```sh
python3 Scripts/xcode_discovery_cache_integration_test.py \
  --tool .build/release/swift-test-impact \
  --destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

This builds the fixture, checks that different `.xctestrun` files retain their own
test inventories, verifies warm-cache reuse, and checks that inactive source lists
do not alter source ownership or block analysis. It also verifies cache invalidation
when a gitignored mapping file is created, changed, or removed.

Compiler ownership omitted by scheme settings has a real Xcode integration check:

```sh
python3 Scripts/xcode_transitive_ownership_integration_test.py \
  --tool .build/release/swift-test-impact \
  --destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  --output /tmp/transitive-ownership.json
```

It generates the `XcodeTransitive` fixture from `XcodeUITests`, adding a local
package and two embedded extensions without adding them to the scheme. It checks
base/head snapshots, a source compiled into multiple modules, isolated production
edits, mixed documentation and test edits, warm/fresh parity, and selected execution
from verified retained products. This fixture does not replace the consumer's
full-run comparison and performance gate before CI adoption.

Capture reuse has a fast regression and an Xcode integration check:

```sh
python3 Scripts/capture_build_test.py
python3 Scripts/xcode_capture_session_integration_test.py \
  --tool .build/release/swift-test-impact \
  --destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

These check primary coverage across batch changes, bounded active captures after
repeated clean builds, stale inactive lists, rejection of a new session against
existing build products, and seal invalidation after a failed build.

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

- Expand [build-time SIL capture](#build-time-sil-capture-opt-in) validation across compiler versions and consumer projects.
- Extend precise declaration mapping to more language constructs and SwiftPM.
- Improve dispatch, initializer, callback, and test-argument modeling.
- Expand compiler-version, Swift Testing, external inheritance, and resource modeling coverage.
- Collect optional per-test coverage during ordinary selected runs.

References: [Swift compiler](https://www.swift.org/documentation/swift-compiler/), [SIL format](https://github.com/swiftlang/swift/blob/main/docs/SIL/SIL.md), [IndexStoreDB](https://github.com/swiftlang/indexstore-db).

## License

Copyright (c) 2026 Zachary Gorak.

Licensed under the **PolyForm Noncommercial License 1.0.0** (`PolyForm-Noncommercial-1.0.0`). See [LICENSE](LICENSE) for the complete terms.

This project is source-available. You may use and modify it for the purposes permitted by the license, including noncommercial purposes and the uses explicitly permitted for the organizations listed in the license. Forking and redistribution are allowed under the license's distribution and notice requirements. Commercial use outside those permissions requires a separate license from the copyright holder.

Versions previously released under AGPL-3.0-only remain available under that license; this change does not revoke permissions already granted for those versions.

### Select without any baseline artifacts

Use `--head-only` when CI cannot retain a baseline graph. This is an explicit
alternative to the cache-only policy below. It compares native Swift syntax at
both Git revisions, builds **only the head** with supplementary SIL, enumerates
that build's enabled tests, and retains its exact products. No persistent cache,
baseline producer, saved graph, or baseline compilation is required.

```sh
swift-test-impact select \
  --project MyApp.xcodeproj --scheme MyApp --test-plan AllTests \
  --destination 'platform=iOS Simulator,id=SIMULATOR_UUID' \
  --base origin/main --head HEAD --merge-base --head-only \
  --build-time-sil /absolute/path/to/SwiftTestSelection/Scripts/capture-build.py \
  --retain-build /absolute/new/job-directory/head-build \
  --format json --output impact.json

swift-test-impact run \
  --project MyApp.xcodeproj --scheme MyApp --test-plan AllTests \
  --destination 'platform=iOS Simulator,id=SIMULATOR_UUID' \
  --head-graph /absolute/new/job-directory/head-build/head-graph.json \
  --report impact.json
```

`select` is report-only unless `--run` is requested. `--merge-base` resolves the
actual common ancestor of the explicit revisions, including stale and stacked
branches. Without it, `--base` is the exact comparison revision. Both inputs must
exist in local Git history; fetch enough history before running. `--head-only`
requires build-time capture and retained products (`--retain-build` or `--run`),
and cannot be combined with saved graphs or `--cached-base-policy`. Optional
`--analysis-cache`/`--cache-context` can reuse head/module analysis, but never
cause baseline lookup or compilation in this mode.

The supported-change model is deliberately narrower than two-graph analysis:

| Change/evidence | Head-only behavior |
| --- | --- |
| Surviving ordinary function body, unchanged header | Trace head compiler dependencies to tests; deleting lines inside a body is supported |
| Edited test, helper, setup/teardown or inherited method | Select bound tests and dependent consumers; unresolved identities broaden explicitly |
| Added or edited private test helper with verified isolation | Select its compiled test consumers; unrelated opaque runtime dependencies do not broaden this helper |
| Other added/deleted/renamed/moved declaration, overload/signature/default-argument/dispatch change | Full enabled head inventory: old compiler edges are unavailable |
| Global/initializer, resource, configuration, mapping or unowned source change | Full enabled head inventory |
| Macros, opaque return types, unrecognized build scripts or unresolved ownership | Explained conservative fallback |
| Production change and app-hosted/unknown test host | Retain the affected host's tests; base source imports do not prove isolation |
| Hostless tests | Use head dependencies, retaining tests with opaque runtime uncertainty; two-graph runtime-boundary exemptions are unavailable |
| UI feature change | Use declared source/symbol/fixture mappings and `dependsOn`; missing boundaries, selectors or runtime contracts broaden UI selection |

New tests are included through the structural-change fallback; deleted tests are
absent from the head inventory. UI mappings remain user-declared contracts, not
measured coverage. Ordinary bodies with attributes other than `@MainActor` or an
opaque result type (including one nested in an optional, tuple or generic type)
are conservatively unsupported. This also applies to attributes
on enclosing types: an attached macro can synthesize other declarations from a
changed body. Test-entry selection retains the existing test-independence assumption.
Declared UI feature mappings narrow runtime uncertainty only when all changed
bodies belong to production code, proven test entries, or isolated private/SDK helpers.
Other mixed helper or lifecycle edits retain their runtime fallbacks even when a
mapped app feature also changes.

Private helper isolation is automatic and deliberately bounded. It supports a
synchronous `private func` in a final test class, with an unambiguous source-defined
inheritance chain ending at XCTestCase. Both source revisions must prove that all
references are direct calls from bound test entries or unchanged private helpers
in the same class. Each intermediate helper must pass the same source and compiler
checks, and the chain must terminate at bound test entries. Direct private callees
also require a supported transitive effect body, including when invoked inside
a newly added assertion. Unsupported, recursive, ambiguous or missing callee
effect evidence selects the full inventory with `head_only_helper_callee_effects`;
SDK mutations such as `UserDefaults.set` cannot be treated as harmless merely
because SIL represents them as Objective-C dispatch. Cycles, escaping
references, and changed or deleted intermediate helpers retain fallback. Added
helpers also require their name to be absent from the base module, so introducing
an overload or changing an existing name's resolution cannot silently pass.
The head graph must confirm the callers, complete test/lifecycle bindings, and
test-only ownership. The proof does not depend on UI feature mappings.

The supported helper bodies use ordinary String/Bool/Int/Double or XCUIApplication/
XCUIElement parameters, local `let` values, member queries, XCTest assertions, and
NSPredicate construction, and direct calls to private helpers. Local screenshot
attachments may be created with `XCTAttachment(screenshot:)`, assigned a `name`
and `lifetime`, and submitted with XCTest's `add`. The proof tracks fresh local
attachments and rejects shadowed attachment APIs; it does not exempt other shared
state. Private helper files must use plain imports from `XCTest`, `Foundation`,
`Swift`, or `UIKit` before SDK-named effects are trusted. Unknown, attributed,
or declaration-scoped imports retain `head_only_helper_callee_effects` fallback;
an external type named `XCTAttachment` cannot acquire XCTest's effect contract.
Untrusted re-exports and project modules shadowing these SDKs also prevent
isolation. Attachment constructors and member bindings are also audited at base
and head, including deleted source files, inherited members, aliases, and
construction inside assertions or downstream private helpers. A removed project
overload cannot acquire the SDK effect contract merely because the head graph
now calls the SDK. Protocol requirements without implementations and unrelated
concrete initializers do not replace that call; protocol default implementations
and unresolved bindings retain `head_only_helper_callee_effects`. Property overrides
are checked against the declaring class's ancestry at each revision: a proven
unrelated class does not invalidate the attachment contract. Missing, ambiguous,
aliased, or cyclic ancestry remains conservative.

Private helper effects also validate external callees, including references whose
SIL bodies are absent from the saved graph. Selection batches these symbols through
`xcrun swift-demangle --expand --tree-only` and caches results within each helper
traversal. Only recognized SDK declaration owners (and known Clang-imported XCTest/Foundation
types) receive the SDK contract. Unknown owners, unavailable demangling,
and external extensions exposed through another file's import retain
`head_only_helper_callee_effects`. Dynamic calls also require complete SIL method
signatures and matching source argument labels; a method name alone cannot
establish its implementation. Unknown calls, overloads, method values that lose
binding information, and incomplete evidence retain the diagnostic fallback.
Supported navigation actions must remain standalone statements preserved from
the base; hiding an action inside an added assertion does not establish isolation.
SDK member bindings are audited at both revisions even when a helper creates no
attachment. Nested aliases and inherited nested types cannot be resolved to an
unrelated module-level namesake.

Receiver audits also pair method and subscript labels with the compiled signature,
including every use of a method name in a source body. Captured SIL
file/line/UTF-8-column locations pair supported SDK method uses with their exact
source argument labels. Valid mixed query overloads and unrelated variables with
names such as `screenshot` no longer conflict just because they occur in one body.
All uses of each signature must match, including calls on the same line. Missing
call locations retain the broader whole-body check; method values remain unknown.
A `#sourceLocation` directive anywhere in the module disables the receiver proof:
presumed locations can point into a different, apparently clean source file.
Snapshots without physical-location evidence require source-proof regeneration.
Unknown source imports are named in receiver-type diagnostics; an import alone
does not establish a safe external implementation. Method values, foreign
overloads, unproven enum arguments, and dynamic or forwarded class metatypes
retain fallback. Captured structs and enums may participate through their checked
implementations; local SDK namesakes cannot establish an SDK signature. A reference to an SDK constructor does not prove that it was
called with the SDK class: the captured metatype must also be established.
Implicit static-method metatype inputs are ignored only when SIL proves that
they are unused outside debug instructions; forwarding or copying them retains
the origin check.
Clang-imported class thunks require an explicit SDK symbol contract because
Objective-C categories share the same imported class owner.

Older graphs without dynamic-call or receiver-type evidence require regeneration from the existing
build artifacts and sealed SIL capture. Source-proof refresh alone is insufficient;
reparsing valid saved SIL requires no application rebuild or test execution.
Helpers cannot capture `self` or free project variables, take
inout/function-valued/default arguments, or contain closures or macros. Known
global/shared-state and raw-pointer effects in project callees also
prevent isolation. Attachment handling never waives compiler-observed state
checks, including in assertion autoclosures. A failed helper proof that encounters
shared state selects the full inventory with `head_only_helper_shared_state`,
because shared objects can affect tests beyond the compiled caller paths.
Calls wrapped in other expressions (including operators,
subscripts and string interpolation) or used as matching patterns are not treated
as direct calls: they may create escaping autoclosures, including through custom
`~=` operators in guard/while/for/catch patterns. Stored proof versions must match
the current proof analysis; older or unknown versions select the full inventory
with `head_only_helper_proof_version` and require a fresh head capture. For an existing helper, all old statements must
remain unchanged and in order; only standalone XCTest assertions may be added.
Removing/replacing/reordering statements or changing local bindings/control flow
retains runtime fallback because head edges cannot prove the effects of old calls.
This supports adding the sharing assertion in #55 while preserving uncertainty
for other body rewrites. Escaped references, Objective-C exposure, lifecycle callers,
ambiguous classes/extensions, unsupported body syntax, missing bindings, and old
captures without the new syntax evidence retain the existing explained fallback.
As with test-entry selection, tests must be independent: this is a proof of the
helper's callers, not a general effect system for SDK implementations or a proof
that separately executed tests cannot communicate through external state.

Head-only selection also recognizes a bounded read-only waiting contract for
internal Swift methods in `XCUIElement` extensions whose file imports only the
trusted `XCTest`, `Foundation`, or `Swift` modules. Project SDK module shadows and
untrusted re-exports retain fallback. Both revisions must use only
supported element queries (`exists`, `value`, `isEnabled`, `isHittable`,
`isSelected`), primitive parameters, local predicates/expectations, and
`XCTWaiter.wait`, or bounded `waitForExistence`/`waitForNonExistence` calls. A local `NSPredicate` callback may capture `self` and primitive
parameters for those queries; predicates and method references cannot escape or
be stored in shared state. The method name and file path are unrestricted. This
supports replacing a value predicate with an existence-and-value predicate.
See the [real-project validation](Documentation/Issue58Validation.md) for the
current conservative result, the superseded 125-consumer experiment, and reproduction commands.

The proof follows direct helper callers, including source-defined XCTest base
classes and nonescaping local functions, to bound test entries. The head compiler
graph must confirm those paths and contain no unaccounted-for callers. Both source
revisions are checked across all captured source files, including callers outside a
requested file scope and files captured by another target at head, so removed calls
and target-membership changes cannot hide old dependencies. This reads
base source from Git; it does not build the base revision. Base Swift files absent
from the head inventory are also inspected. References to the helper or its caller
chain in those files retain an explicit fallback because their old module ownership
cannot be established from the head. Unrelated base-only files do not alone force
fallback. Overloads with different
argument labels can be separated when the helper has no default/variadic arguments;
ambiguous overloads remain conservative.

Calls wrapped in XCTest assertions or Boolean negation require plain imports
from `XCTest`, `Foundation`, `Swift`, or `UIKit` in the caller file at both
revisions. UIKit is allowed for caller UI types; the helper body still uses the
three-module query contract above. Unknown, attributed, or declaration-scoped
imports can introduce escaping overloads with the same names, so these wrappers
retain a conservative fallback with an unresolved-import diagnostic. Direct
helper calls do not require this wrapper-specific import proof; independent
receiver-origin checks still require trusted imports wherever nominal SDK types
or overloads are established. Project modules
shadowing any trusted module also retain fallback.

Project SDK-name shadowing/subclasses, dynamic exposure, lifecycle use, escaping
references, unsupported effects, missing bindings, and missing/version-mismatched
proof evidence select the full inventory with `head_only_sdk_helper_boundary`.
That diagnostic names the blocking evidence. Successful selections carry a
`dependency` explanation identifying the verified SDK-helper boundary. As with
other test-only precision, this relies on test independence and the documented
SDK query contract, not measured coverage or a general SDK effect analysis.

A mixed review still processes every other change normally; isolated helpers do
not suppress production, configuration, graph, or build-evidence fallbacks. Scoped
queries can use the same single captured head graph to separate those policies.
Private-helper effect evidence records the exact checked declarations. Both source
revisions must have unambiguous private callee bindings, and every project callee
reached in the head compiler graph must belong to a checked declaration. An inherited
overload or an unchecked project extension retains `head_only_helper_callee_effects`
fallback. SDK callee effects also require unambiguous overload candidates at both revisions,
including declarations removed from the head inventory. Queried SDK member names
are audited across both revisions regardless of their declared owner, including
inherited and type-aliased project members. Backticked identifiers are normalized
when auditing fresh and saved source evidence, including declaration and call
argument labels. Equivalent saved reference keys are merged so callers and escape
warnings cannot disappear. Unresolved owners and protocol implementations
remain conservative. Concrete project types cannot be ancestors of the trusted SDK
classes; their same-named members and free functions do not replace SDK member
calls. The compiler effect walk also rejects project callees outside the checked
helper and its callbacks. Private proof
version 9 and SDK proof version 5 reject older saved evidence. Private version 9
records all SDK member bindings across the checked callee bodies and validates
argument labels and method references. It also audits subscript bindings at both
revisions and requires overload labels to agree with the compiler signature.
Labeled subscripts and ambiguous mixed query overloads retain conservative
fallback: the saved SIL does not identify which source call produced each method
reference, so a valid call cannot justify another unproven call. Version-8 and
older private proofs require
regeneration. Both helper contracts also check the compiled consumer and lifecycle
closure for opaque factories that could supply an SDK subclass with effectful
overrides. Missing native or dynamic producer evidence retains a diagnostic and
conservative selection. Assertion-only helpers also require this audit because
opaque caller or lifecycle code can register XCTest callbacks. A `Void` or scalar return does not prove that an opaque call cannot
supply receivers. The analyzer requires a captured implementation or an explicit
SDK contract, rather than inferring safety from return-type names or callback
syntax. This covers returned structs/enums, thrown errors, callbacks, output
pointers and mutations of reachable state. Unknown producers retain fallback even
when a completion only asserts its input is nil. Diagnostics identify the missing
producer or storage declaration; they are uncertainty, not proven impact.

XCTest callbacks are a separate effect boundary: assertions and waits can invoke
project failure-recording methods or observers through the framework binary,
without a caller edge in SIL. Both helper contracts inspect base/head source
inventories, including base-only files, for recording/execution hooks, other
XCTest subclass overrides outside the bound lifecycle, and observer registration
or conformance. Unproven callback effects retain conservative selection with an
explicit diagnostic. Ordinary lifecycle overrides remain supported when their
captured implementations pass the caller audit. Missing source evidence declines
the proof; existing evidence can be refreshed without rebuilding the application.

The analysis scope is Swift source and compiler evidence for Swift, including
Swift methods exposed through Objective-C dispatch (`@objc`, imported SDK calls,
and compiler-generated thunks). These are handled automatically when their
implementations or built-in SDK behavior can be established. Handwritten
Objective-C/C/C++ implementations are not analyzed. A call into an unavailable
implementation remains an explicit uncertainty; rewriting that implementation
in Swift requires a fresh build-time SIL capture before it can be analyzed.
No user-authored isolation declarations are required or used to waive this boundary.

Receiver-origin trust uses explicit SDK declaration contracts, not blanket trust
of a module. Reflective factories such as Swift's `_typeByName`, unknown decoding
APIs, erased Objective-C bridging, and casts to receiver classes or metatypes
retain fallback. Casts to proven builtin value types remain supported. Generic SDK operations
also require captured call substitutions: a builtin collection can supply known
witnesses, while an arbitrary collection or value-protocol implementation cannot.
The contract is specific to the operation’s protocols and nested type arguments;
a builtin name alone does not prove its conformance. Retroactive conformances
on builtin types (such as `Optional: CustomStringConvertible`) retain fallback.
Printing and assertion failure messages also require known formatting witnesses.
Consequently, generic integer/optional equality assertions can retain fallback
even when their equality implementation is builtin; ordinary Boolean assertions
and supported concrete string/floating-point assertions remain eligible.
All uses and captured fragments must satisfy the contract. Missing generic-call
evidence in older graphs requires regeneration from retained artifacts and sealed
SIL; it is never interpreted as proof that no receiver can be produced.

Consumer and lifecycle storage accesses are also checked. Unknown fields and
globals retain fallback. Narrow source proofs support immutable stored string
literals and instance Boolean storage inferred from `true` or `false`, without
type annotations, wrappers or observers. The Boolean proof also rejects custom
literal defaults, shadowed type names and enclosing macros; it establishes only
that the storage cannot carry receivers or callbacks, not that its users are pure.
Those users and their explicit calls still undergo the ordinary audit. Exact SDK
gesture-velocity, keyboard-key and content-size-category constants are supported. The graph records field/global
identities; old graphs missing that evidence must be regenerated from saved
artifacts and sealed SIL. Module-fragment cache version 13 invalidates older
fragments. This needs no baseline build and does not execute application tests.

Signature evidence must cover the caller
closure as well as the changed helper. When upgrading old graphs, regenerate from saved build artifacts
and sealed SIL for the needed dependency modules too. The analysis caches both
successful and failed producer checks within one immutable graph. SDK version 5 requires
assertion names to be free of lexical shadowing, including parameter, generic,
and closure bindings, and verifies caller imports before trusting assertion or
negation wrappers. SDK version 3 and 4 captures fall back with a recapture diagnostic;
regenerate the graph from valid build artifacts (and sealed SIL when available)
to restore precision without another baseline build. Caller
proofs for both private and SDK helpers use a memoized work queue rather than
recursive stack frames. The private callee-effect analysis also uses an iterative
work queue with cycle detection and shared-callee reuse.
Local-function source analysis uses the file's identifier index, caches reference
classifications and caller resolutions, and traverses local relationships
iteratively. Name and signature lookups share that work; cycles, escapes, and
ambiguous local declarations still retain fallback.

Dependency explanations identify the verified private-helper proof. No baseline
build, additional SIL extraction, or user-maintained helper mapping is required.

Native Swift tokens preserve strings, regex literals, operators and directives.
With `sourceLocationPolicy: "diagnosticLineColumn"` agreed at both revisions,
comment/whitespace line and column shifts are ignored while file identity remains
semantic. The default semantic policy conservatively considers call-site locations
because location defaults can affect behavior without changing tokens. Markdown
is ignored only when both revisions opt in through `ignoredDocumentation` and the
fresh build proves the file is not an input; unknown tasks block that proof.

JSON reports identify `analysisMode: "head-only-git-syntax"`, resolved revisions,
exact method identifiers, dependency/mapping/fallback reasons, and timed phases.
`baseSourceSyntax` reads Git blobs; it is not base compiler extraction. Every
fallback uses the same retained head build. Capture failures prevent publication; malformed reports or modified graphs/products
fail verification. A valid empty selection executes no tests. `--full-suite`
explicitly selects all enabled head tests, still with one build. After execution,
the job's retained directory can be removed; nothing must survive to the next job.
Changes outside Git, such as an SDK/toolchain update, script environment or unlocked
external dependency, have no historical evidence in this mode. Keep those inputs
stable for a source comparison, or request `--full-suite`.

Validate selection against targeted and full controls before making it a CI gate.
Run `Scripts/xcode_head_only_test.py --tool /path/to/release/swift-test-impact
--destination 'platform=iOS Simulator,id=UUID' --output measurements.json --execute`
on an idle runner to measure build/analysis phases, execution, elapsed time, sampled
peak workspace disk, and exact executable-build counts. Local fixture and consumer
results, including validation limits, are recorded in
[the head-only validation report](Documentation/Issue49Validation.md).

### Require a cached baseline for one-build PR selection

Use `--cached-base-policy require` with `--analysis-cache` and `--cache-context`
to require a compatible cached baseline. With `--merge-base`, the tool resolves
and checks the **actual common ancestor**, including stale or stacked branches.
It exports that revision and resolves locked build settings before the head
build; it never builds, enumerates or extracts the base on this path. The normal
cache identity, checksum and ownership checks still apply. Package resolution
and settings inspection can perform I/O, so this is not an offline lookup.

```sh
swift-test-impact select \
  --project App.xcodeproj --scheme App --test-plan AllTests \
  --configuration Debug --destination "$DESTINATION" \
  --base origin/main --head HEAD --merge-base \
  --analysis-cache "$CACHE" --cache-context "$BUILD_INPUT_DIGEST" \
  --cached-base-policy require \
  --build-time-sil "$SWIFT_TEST_SELECTION/Scripts/capture-build.py" \
  --retain-build "$NEW_BUNDLE" --format json --output "$REPORT"
```

On a cache hit, this builds the head once, captures its SIL, and retains the exact
products for `verify-build` and `run`. A missing, evicted, corrupt or incompatible
base stops **before creating the head bundle or building anything**, exits with
status **3**, and writes a final JSON error line to stderr:

```json
{"code":"cached_base_unavailable","revision":"RESOLVED_BASE_SHA","reason":"No entry matching analyzer, toolchain, settings and input identity (absent, evicted or incompatible)"}
```

No selection report is published on that failure. Other failures (for example an
unowned cache directory, ambiguous merge base or head build failure) remain
errors, not permission to run all tests. Always check the exit status and use a
fresh report path; an old file is not evidence that this invocation succeeded.

To explicitly choose full coverage on a baseline miss, use
`--cached-base-policy full-suite`. It checks the baseline first, builds the head
at most once, selects every enabled test in the chosen plan, and retains those
same verified products. The report includes `cached_base_unavailable`, the
resolved base and reason, `fullSuite` explanations, and a `cachedBaseFallback`
phase event. A hit still performs affected-test selection. Neither policy treats
a missing or malformed saved report as a request for full execution. Without
`--run`, both successful modes only produce a report and retained artifacts.

Publish main's baseline from its **ordinary executable build**, using the same
pinned analyzer/helper, toolchain, destination, build settings and external input
context as PR jobs:

```sh
REV=$(git rev-parse HEAD)
swift-test-impact select \
  --project App.xcodeproj --scheme App --test-plan AllTests \
  --configuration Debug --destination "$DESTINATION" \
  --base "$REV" --head "$REV" --full-suite \
  --analysis-cache "$CACHE" --cache-context "$BUILD_INPUT_DIGEST" \
  --cached-base-policy require \
  --build-time-sil "$SWIFT_TEST_SELECTION/Scripts/capture-build.py" \
  --retain-build "$NEW_BUNDLE" --format json --output "$REPORT"
swift-test-impact run \
  --project App.xcodeproj --scheme App --test-plan AllTests \
  --configuration Debug --destination "$DESTINATION" \
  --report "$REPORT" --head-graph "$NEW_BUNDLE/head-graph.json"
```

Explicit `--full-suite` skips baseline lookup with either cache-only policy.
The same-revision producer builds once, publishes its reusable graph, and runs
all tests from that build. It replaces a standalone build-for-testing step; do
not run an extra build just to warm the cache. Preserve the cache across jobs and
allow enough disk space to retain older actual merge bases, not only main's tip.
Entries larger than the cache budget are not published; publication/eviction
messages remain visible. The original default policy is unchanged and may build
both revisions on a miss.

Validate exact build counts, stale/stacked merge bases, misses, retained product
identity, and selected/full execution with:

```sh
python3 Scripts/xcode_cached_base_policy_test.py \
  --tool /path/to/release/swift-test-impact \
  --destination "$DESTINATION" --output /tmp/cached-base-validation.json
```

### Persist Xcode analysis across comparisons

```sh
swift-test-impact select --project App.xcodeproj --scheme App \
  --destination 'platform=iOS Simulator,id=SIMULATOR_UUID' --test-plan AllTests \
  --base origin/main --head HEAD --merge-base \
  --analysis-cache "$HOME/Library/Caches/SwiftTestSelection/App" \
  --cache-context YOUR_EXTERNAL_INPUT_DIGEST --format json --output impact.json
```

Caching requires an explicit committed head. The actual review merge base and
head each get an independently validated entry containing their compiler graph,
source snapshots, mapping policies, and complete enabled test inventory. Warm
entries do not build, enumerate tests, or extract SIL. Xcode still resolves build
settings with locked package versions before lookup. New revisions receive fresh
builds and test discovery, while [compatible module fragments](#reusing-module-fragments-on-a-changed-revision)
can be reused across revisions to skip their compiler replay and parsing.

The key includes repository identity, exact revision, graph/cache schema, the
analyzer executable's SHA-256 (so changing upstream versions invalidates it),
Xcode/Swift versions, installed SDKs and simulator runtimes, exact destination,
container, scheme, plan, configuration, mapping path, and resolved build settings.
Workspace paths in settings normalize verified aliases of that exact export,
including `/tmp` and `/private/tmp` and the caller's symlinked retained parent.
External paths, neighboring directories and semantic flags remain in the identity.
Run the retained-build integration script with `--workspace-alias` to exercise warm
reuse through a symlinked parent containing spaces.
Tracked dependency locks are part of the revision, and Xcode uses
`-onlyUsePackageVersionsFromResolvedFile`. **`--cache-context` must be a stable
fingerprint of any inputs not represented there:** build-script environment,
untracked generated inputs, external local packages, or mutable external tools.
If these cannot be identified reliably, omit caching. Never put secrets in this
argument. Keep the destination stable across CI jobs: a different simulator UUID
currently invalidates the entry, even for equivalent hardware/runtime.

Use a dedicated local directory (network filesystems without working `flock`
locks are unsupported). A process lock serializes reads, publication and pruning;
completed entries are published by directory rename and verified by checksum.
Corrupt entries are removed and rebuilt by default; cache-only baseline policies
report the miss instead. Interrupted staging is removed by the
next holder. A base analysis failure remains an explicit full-selection fallback;
a head failure stops the command. `--cache-max-bytes` bounds persisted entries
(default 5 GiB), evicting least recently used entries. Temporary builds can need
additional disk space; they are removed at exit or on the next cache invocation
following interruption. Do not delete an active cache directory or its lock file.

Reports contain `analysisEvents` with per-revision cache status and elapsed
settings, graph-load, build, enumeration, extraction, publication, and selection
times. Standard error reports cache miss/invalidation/eviction reasons. The cache
contains analysis only; `--run` on this path still uses the ordinary execution
build until an execution artifact is explicitly supplied.

Reproduce the release-build cache checks and machine-readable measurements:

```sh
swift build -c release
python3 Scripts/xcode_cache_integration_test.py \
  --destination 'platform=iOS Simulator,id=SIMULATOR_UUID' \
  --output cache-measurements.json
```

This checks warm reuse, a new head against a warm base, actual merge-base lookup,
corruption recovery, concurrent readers, and selection equivalence to fresh
analysis. Fixture measurements are not evidence that ChainOfCustody meets its
separate end-to-end CI adoption gate.

Run `python3 Scripts/xcode_cli_path_test.py --tool .build/release/swift-test-impact`
to check executable fingerprinting for absolute, relative, PATH/symlink, and
launcher-supplied names. This CLI regression uses mocked Xcode commands and
does not build an app or execute tests.

### Keep the analyzed head build for execution

```sh
swift-test-impact select --project App.xcodeproj --scheme App \
  --destination 'platform=iOS Simulator,id=SIMULATOR_UUID' --test-plan AllTests \
  --base origin/main --head HEAD --merge-base \
  --retain-build /absolute/path/to/new-head-bundle \
  --format json --output impact.json

swift-test-impact run --project App.xcodeproj --scheme App \
  --destination 'platform=iOS Simulator,id=SIMULATOR_UUID' --test-plan AllTests \
  --report impact.json --head-graph /absolute/path/to/new-head-bundle/head-graph.json
```

The head is built once for analysis and execution. Selection exits with a
caller-owned bundle containing `source/`, `DerivedData/` (including the complete
`Build/Products` tree and `.xctestrun`), `build.log`, `build-settings.json`,
`head-graph.json`, and `complete.json`. The report's `buildArtifactPath` and
`buildArtifactID` identify that exact head. Completion is published last; existing
or partially created bundle directories are rejected. Use a distinct path per
job. Keep the bundle until execution has finished, then explicitly remove it.
Cancellation can leave an incomplete bundle, which must be removed explicitly.
Build stdout and stderr stream directly to `build.log` before compilation starts.
The CLI prints its path; the complete log and settings survive failed builds,
later analysis failures, and cancellation. An incomplete bundle remains ineligible
for execution. Check this with `python3 Scripts/retained_failure_log_test.py --tool .build/release/swift-test-impact`.
Cache eviction never removes these caller-owned products.

`--retain-build` can accompany the analysis cache options. On a warm head graph,
analysis is reused and products are built once for this execution. Cold heads
build once and capture their analysis from that build. Base products remain
disposable and are never handed to the runner. Retention without an analysis
cache uses a disposable uncached analysis directory. `select --head REV --run`
automatically retains its head build for that invocation and removes it afterward;
use an explicit `--retain-build` to preserve it after execution too. Worktree
selection without an explicit head retains the existing execution behavior.

Saved `run` checks the report/head identity, build context and toolchain, known
exact test identifiers, and the entire products manifest before issuing
`test-without-building`. Missing or changed products fail explicitly. Empty
selections issue no Xcode command. To relocate products, copy the **whole**
`Build/Products` directory intact and pass `--test-products NEW_PRODUCTS_PATH`.
Moving the complete bundle without that override fails because the recorded
product path no longer exists. Source exports should remain available until
execution completes for tests that access source-relative fixtures.

For existing CI runners, replace `run` with `verify-build` using the same options.
It returns JSON containing the validated `xctestrun`, head/artifact identity,
`shouldRun`, `selectedTests`, and exact `onlyTestingArguments`, without executing
tests. Skip execution when `shouldRun` is false. Otherwise pass that `.xctestrun`
and the selected identifiers to your existing `test-without-building` invocation;
keep its worker limits, snapshot serialization, skip policy, logs, xcresults, and
requested-versus-executed verification. Do not issue another build. Repeat
verification immediately before each execution group, and do not modify products
between verification and execution. The bundle completion metadata also records
the analysis input identity (repository/revision, analyzer, toolchain/SDK,
build-settings hash, and external-input digest).

```sh
python3 Scripts/xcode_retained_build_integration_test.py \
  --destination 'platform=iOS Simulator,id=SIMULATOR_UUID' \
  --output retained-build-measurements.json
```

The smoke test counts build commands, exits selection, removes its graph cache,
and executes one unit and one UI method from the saved head. It rejects a wrong
revision, missing report, and altered products and verifies that empty selections
execute nothing. ChainOfCustody integration and its full CI performance acceptance
remain tracked in [ChainOfCustody #298](https://github.com/twodayslate/ChainOfCustody/issues/298).

Run `python3 Scripts/xcode_saved_graph_cli_test.py --tool .build/release/swift-test-impact`
to check that saved-graph selection, with and without `--run`, rejects incomplete
or checksum-mismatched retained bundles on either side of the comparison. It also
checks that manual captures and completed bundles remain selectable without
products. This regression invokes no real Xcode commands or test bodies.

### Bounded Xcode extraction

`--extraction-workers N` bounds concurrent compiler/parser jobs, dependency scans,
source parsing and product hashing during fresh Xcode
analysis, including capture from existing builds. The default is **1**; values
from 1 through 8 are accepted. Start with 2 only after measuring your runner's
memory. This setting does not change the normal executable build or test execution.
Saved-graph selection needs no extraction workers.

Fragments merge in original compiler-invocation order, preserving ownership and
cross-module dispatch. At most N jobs/results are in flight, so an early slow
module cannot accumulate every later parsed module in memory. Each job owns a
unique temporary SIL file, removed on success or failure. Worker failures remain
explicit conservative graph diagnostics.

Library clients can call `analysis.extractionCancellation.cancel()`. Cancellation
is cooperative: queued jobs skip work, running compiler/parser jobs drain and
clean up, and the result carries a full-selection diagnostic with no partial
function graph. A hard process kill cannot run cleanup; the enclosing analysis
scratch directory remains subject to its existing lifecycle.

See `Scripts/benchmark_xcode_extraction.py` and the opt-in
`xcodeExtractionBenchmark` test for repeated release measurements with compiler
children included in sampled process-tree RSS. RSS sums double-count shared pages;
they are not physical-footprint peaks. Larger worker counts are not assumed to
scale linearly.

### Reusing module fragments on a changed revision

`--analysis-cache` also reuses compatible parsed module fragments after a new
revision's normal build and test discovery. A fragment hit skips that module's
SIL compiler replay and parser. Inventory, source ownership, UI mappings,
lifecycle binding and cross-module dispatch resolution are reconstructed from
the current revision. Whole-revision hits retain their existing behavior.

Module keys include ordered source/generated inputs and their resolved paths, compiler arguments, the
transitive project import closure, imported Swift/Clang inputs, compiler and
bundled plugin bytes, analyzer/schema/settings/toolchain/SDK identity and
`--cache-context`. Known root aliases and supported header-map destination
paths are normalized; source bytes are never rewritten. Swift symlink metadata
is retained, so retargeting a source link invalidates affected fragments even
when the destination bytes match; SIL source locations can still change.
Non-Swift repository files invalidate all fragments conservatively, including
mapping files that could also be compiler or script inputs. Module availability probes also track the queried project-module inputs and the
complete project-module name inventory; unrecognized probes invalidate more broadly.

A fresh Swift dependency scan hashes SDK headers, module maps, Swift interfaces,
prebuilt candidates, resolved macro binaries and compiler options. Generated
module output paths are represented by their module identities; their input
bytes are preserved. This permits reuse across independent build directories.
When scanning is unavailable or unsupported, exact imported-artifact hashes
provide a conservative fallback that may miss after relocation. Bridging-header
targets currently use this fallback because Swift 6.4's standalone scanner
crashed resolving an overlay through a bridging PCH in the consumer fixture.

The initial implementation requires an unambiguous explicit SwiftDriver import
map next to each file list. Missing metadata, custom compiler plugins without a
complete resource-input contract, unsupported responses, and ambiguous target or
architecture invocations bypass fragment caching. Modules containing
`#sourceLocation(file:line:)` directives and their transitive importers also
bypass reuse, with an explicit progress message: their presumed source paths
can refer to another checkout or an untracked symlink even with identical
source bytes. Unrelated modules remain cacheable. Comments, string literals,
and reset-only `#sourceLocation()` directives do not trigger this bypass.
External context must cover
external dependency/module availability and other compiler-visible inputs not
represented by Git, settings or the import inventory. Never reuse a context
value after those inputs change.

Fragments use the existing exclusive cache lock, checksummed atomic publication,
corruption recovery and shared disk budget. They contain no test inventory or
execution products. Source/import identities are checked again before accepting
or publishing fragments. Newly extracted fragments are staged on disk until
that final validation; changed inputs produce an explicit conservative
extraction diagnostic. Progress reports per-module hits, misses/bypasses,
validation timing, and avoided compiler/parser work.

Release measurements, fresh-extraction parity checks and reproduction commands
are in [the module cache benchmark](Documentation/Benchmarks/ModuleCache.md).

With multiple workers, completed extraction fragments are staged on disk and
merged in compiler-inventory order. Single-worker extraction avoids this extra I/O. Workers immediately take another module, even when an earlier module is
slow. This bounds transient parsed-module memory by worker count and preserves
ownership and diagnostic ordering. Extra staging I/O is the tradeoff; start with
1–2 workers on memory-constrained CI runners and measure your project.

See [release measurements and validation](Documentation/Benchmarks/FastSelection.md).

### Independent selection scopes for execution tiers

Head-only selection accepts `--selection-scopes /absolute/path/scopes.json`:

```json
{"version":1,"scopes":[{"name":"regression-support","paths":["AppUITests/Helpers.swift"],"excludedTestEntries":[]}]}
```

Each scope queries the **same captured head graph** against Git base syntax for
only those changed paths. It adds no build, SIL extraction, or baseline graph.
The primary report still describes the complete review diff. Additional results
appear in `selectionScopes`, each with its request, ordinary report diagnostics,
resolved revisions, and the same retained build identity and graph path. The public
`XcodeAnalysis.run(scoped.report)` API verifies and reuses those retained products,
just as it does for the primary report. Paths must belong to
the actual review diff; an empty scope selects no tests from changes.

A consumer can run Base tests from the full report and regression tests from a
helper/fixture scope. Scope-local uncertainty remains conservative, including
structural edits and opaque runtime calls. Whole-review fallback from an unrelated
production change is not injected into a scope. These results describe selection
policy, not proof that omitted changes cannot affect deferred regression tests.

`excludedTestEntries` lists added or edited test entries the consumer executes separately.
Their bodies do not become change roots in a helper scope when compiler evidence
proves they are independent entries. Entries consumed by other tests remain roots.
Exclusions apply to supported surviving bodies after checking both source
revisions. A newly added, ordinary zero-argument XCTest method may also be omitted
as a change root when it belongs to an existing final test class with a proven
XCTestCase inheritance chain, its name has no other references or declarations in
the head module and is absent from the base module, and compiler consumers are
limited to separately executed entries. This uses the same test-independence
contract as surviving entries. The primary report still includes new tests;
exclusion only changes the scoped roots, so a new test can still be selected as a
consumer of a changed helper. Deletions, renames, ambiguous names, nonfinal classes,
and macro/attribute uncertainty retain their structural fallbacks.
Missing test roots or unresolved lifecycle bindings prevent independence from being
proven, so those entries remain change roots and unresolved tests stay selected.
Only provide entries your policy already executes. This does not exclude helpers,
lifecycle methods, resources, or global build/graph uncertainty. Validate scope
identity and candidates against the primary report, and use `verify-build` before
executing retained products. Missing scopes must not be treated as empty coverage.
