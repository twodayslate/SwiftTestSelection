# UI mappings from attributed coverage

Coverage is optional **authoring evidence**. `coverage import` proposes additive
file-to-suite relationships; `coverage apply` explicitly writes them. Neither
`graph` nor `select` reads coverage or requires a previous test run. An observation
is positive evidence, not a declaration of complete runtime dependencies.

## Build, plan, collect, review

1. Make a clean coverage-enabled `xcodebuild build-for-testing` build with
   `-enableCodeCoverage YES`. Capture its unfiltered build log, build settings,
   xctestrun and compiler graph using the existing-build `graph` command described
   in the README. Enable coverage for the **app**, not only its UI runner.
2. Plan exact suites from that graph's enabled test inventory:

   ```sh
   swift-test-impact coverage plan --graph head-graph.json \
     --suite CheckoutUITests/SharingUITests \
     --suite CheckoutUITests/NotesUITests \
     --app-target ImpactDemo --output coverage-plan.json
   ```

   The JSON contains revision, source/build identity, toolchain, configuration,
   destination, runtime fingerprint, enabled inventory, expected tests, and one
   `test-without-building` execution per suite. It reuses the same captured build.
   `--suite` and `--app-target` may be repeated. No test bodies run while planning.
   The app target name must match the graph's production target name. Standard
   `.app` and `.framework` report suffixes are recognized; custom product names
   require an explicitly normalized export and are otherwise diagnosed.
3. Optionally collect with the supplied Xcode adapter. Without `--run`, this prints
   the plan. With `--run`, it verifies the source revision, toolchain, runtime inventory and product
   hashes, creates a **new** output directory, and executes the suites:

   ```sh
   python3 Scripts/collect-ui-coverage.py --plan coverage-plan.json \
     --source-root /absolute/path/to/repository \
     --output-directory /absolute/path/to/new-collection --run
   ```

   Each suite gets its own xcresult, log, actual test results and app coverage
   export. A checkpoint records incomplete collection before starting each run.
   `measurements.json` reports collection time, execution count and artifact size.
4. Import existing exports without running tests:

   ```sh
   swift-test-impact coverage import --graph head-graph.json \
     --artifact new-collection/coverage-artifact.json \
     --mappings .swift-test-selection.json --output proposal.json
   ```

   Omit `--mappings` for a new file (the graph's saved mappings are preserved when
   present). Inspect `additions`, `mappings`, `evidence`, `diagnostics`,
   `unmappedSuites`, and `provenance`. `additions` is the reviewable additive diff.
   Provenance stays in the proposal, outside the selection configuration.
5. Apply explicitly, reading the current mapping again:

   ```sh
   swift-test-impact coverage apply --graph head-graph.json \
     --artifact new-collection/coverage-artifact.json \
     --mappings .swift-test-selection.json --output applied-proposal.json
   ```

   Apply refuses error diagnostics or failed proposal validation. Existing
   features, fixture references, dependencies and policy settings are retained.
   It never enables `runtimeDependencyPolicy: declared`, prunes an unobserved
   association, or rewrites an existing feature. Reapplying the same observations
   adds nothing. Commit/review the resulting mapping like any authored mapping.

## Portable artifact contract and library API

`UICoverageMappings.plan(graph:suites:appTargets:)` and
`UICoverageMappings.propose(graph:artifact:existing:)` are reusable library
operations. The CLI uses these same functions. Input models and results are
`Codable` and `Sendable`; clients can decode raw exports without invoking Xcode.
Graphs must have compiler dependencies, repository source snapshots, enabled tests
and captured build provenance. Import works with JSON or binary graph archives.

An artifact has `schemaVersion: 1` and a `sessions` array. Each session has:

| Field | Evidence |
| --- | --- |
| `id` | Unique collection session ID |
| `identity` | Exact `identity` object from the compatible collection plan |
| `sourceRoot` | Absolute repository root used when building; paths normalize against this root even on another machine |
| `enabledTests` | Complete enabled graph inventory, including non-UI tests |
| `selectedSuites` | Intended UI selectors, each `Target/Class` |
| `appTargets` | Explicit production targets being measured |
| `resultBundle` | Original xcresult reference for audit |
| `status` | `complete`, `incomplete`, `failed`, or `crashed` |
| `testResults` | Raw `xcresulttool get test-results tests --path RESULT` JSON |
| `coverage` | Raw `xccov view --report --json RESULT` JSON |

Keep test-result and coverage exports from the **same** result bundle. The adapter
exports them together; externally produced manifests assert this relationship and
must supply accurate build provenance. This format is an evidence record, not a
cryptographic attestation of a test run. A coverage percentage or an intended
`-only-testing` argument is insufficient attribution evidence.

Every enabled method of an attributed suite must have a passed result. Every
`Test Case` node must have a nonempty, resolvable identifier and a nonempty result;
an incomplete node invalidates the session rather than disappearing from its
attribution. Unknown, failed, skipped and partial results do not generate candidates. Duplicate session
IDs are rejected. Revisions, source/build identities, toolchains, configurations,
destinations, runtime contexts, graph IDs and inventories must match the graph;
incompatible sessions are diagnosed and excluded, not merged.

The raw test report must include exactly one device with `deviceId`, `platform`
and `osVersion`. Its metadata is retained in proposal provenance. Reported values
are checked against explicit destination `platform`, `id`, `name`, `OS` and `arch`
constraints, and device/OS/build metadata must agree across accepted sessions.
`OS=latest` uses the reported version; a destination specifying only a device ID
does not independently establish its OS version, but session metadata must still
agree. Unsupported destination expressions and missing device evidence are errors.
Older hand-authored manifests that omitted `devices` need the original full
`xcresulttool` export; do not fill it from the intended destination.

A full-plan report without executed-test evidence is rejected. A report with
multiple complete UI suites can produce **coarse associations with all of those
suites**, explicitly labeled `coarseMultipleSuites`. It cannot identify which
suite exercised an individual function. Co-execution never produces an AND
condition.

## Boundaries, validation and diagnostics

Only positive function execution counts contribute evidence. Coverage functions
are resolved by normalized repository path and source line to candidate compiler
nodes. This is not exact symbol identity: overlapping functions and generated
adapters can share a line. Candidate IDs and ambiguity are recorded. Proposals
use readable **whole-file boundaries**, explicitly showing the expansion from
observed functions to all functions in each file. They use suite selectors.
Shared startup and service files remain associated with every observed suite.

External files and generated/unowned sources without a repository production
snapshot are diagnosed and excluded. Paths are normalized lexically against the
recorded build root, without basename guessing or dependence on the importing
machine's symlinks. The producer must preserve the compiler's build-root spelling (including symlink aliases such as `/var`); external
symlink paths are not automatically remapped. An unresolved function may still
support a compiler-owned file boundary; no exact symbol mapping is invented.

Proposals use `UIFeatureMappings.validate()` and the same `MappingIndex` and
`DependencyIndex` as selection to validate added sources and selectors. They also
run `XcodeTestGraph.validateMappingSymbols`, introduced by #69, on the complete
proposed configuration, including preserved user symbols. Strict failures are
returned in `mappingValidationDiagnostics` and block apply. Capture-time mapping
load failures also block apply unless an explicitly supplied valid mapping
replaces the captured mapping. User entries remain intact in the review proposal.
This implementation supports mapping schema v1 and emits no symbol patterns or
boolean expressions. Unsupported mapping versions are rejected rather than rewritten.

Diagnostic codes are stable machine-readable strings. `severity` is `info`,
`warning`, or `error`; `session` and `path` provide context when applicable.

| Codes | Meaning |
| --- | --- |
| `incompatible_artifact`, `missing_provenance` | Build identity/inventory differs or provenance is absent |
| `collection_incomplete`, `collection_failed`, `collection_crashed` | Run did not complete successfully |
| `missing_execution_evidence`, `suite_attribution_mismatch` | No attributable executed-test results, or intent differs from execution |
| `invalid_execution_evidence` | A test-case record has a missing or unresolved identifier/result; the entire session is excluded |
| `invalid_destination_evidence`, `incompatible_destination` | Result-bundle device evidence is missing, mixed, or contradicts the destination or another session |
| `unsuccessful_or_unknown_tests`, `partial_suite_execution` | Results cannot establish complete successful suite execution |
| `coverage_unavailable` | Coverage was not exported successfully |
| `invalid_app_targets` | Requested targets are absent or not production targets in the graph |
| `missing_app_instrumentation` | Requested app targets have no measurable coverage; runner-only reports do not qualify |
| `measured_empty` | Instrumented app coverage was measured successfully, with zero positive functions |
| `coarse_multi_suite_attribution` | Report supports only all-contributor associations |
| `external_source`, `generated_or_unowned_source`, `invalid_source_location` | Source cannot be safely mapped |
| `unresolved_compiler_identity`, `ambiguous_compiler_identity` | File boundary may be proposed, but no exact function identity is asserted |
| `shared_dependency`, `unmapped_suite` | Shared associations retained, or no usable observations for an enabled UI suite |
| `strict_mapping_validation_failed` | The complete proposal fails the shared strict symbol/file validator; structured details are in `mappingValidationDiagnostics` |
| `proposal_validation_failed` | An added source boundary or selector did not resolve |

Import emits diagnostic-bearing proposals even if some sessions are unusable, so
agents can explain or repair the collection. Any error diagnostic makes
`validationPassed` false and blocks apply.
CLI input/decoding failures emit JSON on stderr with `code: coverage_command_failed`
and exit 1. An invalid artifact is never reported as a successful empty collection.

## Prototype and reproducible acceptance run

`Fixtures/XcodeCoverage` is separate from the historical selector regression
fixture. Its menu opens independent Sharing and Notes screens. Each suite taps its
own screen, asserts the app-rendered title, then terminates the app to flush
coverage. Each screen calls its own production function and the shared
`sharedTitle` service. The fixture supports UIKit and AppKit; the collection
adapter is intentionally version-sensitive.

```sh
swift build --jobs 3
python3 Scripts/xcode_coverage_integration_test.py \
  --destination 'platform=iOS Simulator,id=YOUR_SIMULATOR_ID'
```

The script builds once, captures the graph, executes two suites, checks isolated
screen associations and shared dependencies, imports, explicitly applies, and
checks idempotence. It retains logs, result bundles and measurements in the printed
temporary directory for review. Unit tests also verify malformed/aggregate,
partial/failed/incompatible, empty/uninstrumented and ambiguous inputs, preservation,
and ordinary graph selection after applying mappings without coverage inputs.

To repeat just import/apply validation against collected artifacts, without another
build or test execution, pass `--reuse-collection /path/to/printed-directory`.
`SWIFT_TEST_IMPACT` can point these acceptance scripts at a separately built CLI.

### Verified environment and measurements

Verified on 2026-10-28: Apple Silicon, macOS 26.6.1 (25G76), Xcode 26.6 (17F113),
Swift 6.3.3, Debug, iPhone 17 Pro simulator running iOS 26.5 (23F77). The final
collection used fresh fixture build products with a warm simulator and SDK/compiler
caches. Import was also exercised independently against the saved artifacts.

| Measurement | Result |
| --- | ---: |
| Coverage-enabled builds | 1 |
| Build-for-testing time | 9.91 s |
| Initial suite collection and export | 69.56 s |
| Suite executions | 2 (36.95 s and 32.61 s including export/fingerprinting) |
| Portable attributed artifact | 27,209 bytes |
| Two xcresult bundles | 576,800 bytes |
| CLI import and proposal generation | 0.39 s |
| Observations / proposed file boundaries | 10 / 4 |

The collection timing excludes the preceding build and graph capture/enumeration.
The acceptance script additionally records total initial setup/collection time for
new runs in `build-measurements.json`; `--reuse-collection` preserves that record
when available. Timings vary with simulator startup and machine load.

`App/Sharing.swift` maps only to Sharing, `App/Notes.swift` only to Notes, and both
`App/App.swift` and `App/Common.swift` map to both suites. Six line-location
ambiguities are reported explicitly; they produce file boundaries, never invented
exact symbols. Both UI tests passed, and the generated proposal passed validation,
explicit apply, and an idempotent re-import.

Only the Xcode 26.6 / iOS 26.5 simulator combination above is verified end to end.
Physical devices, other Xcode result schemas, macOS collection, custom product
names, app extensions and additional processes are not claimed as verified.
Xcode must actually flush app coverage into the result bundle; missing reports
remain errors. Coverage cannot prove unseen branches or complete runtime
relationships, and no narrowing policy is enabled automatically.
