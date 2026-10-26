# Generated inputs, recovered roles and retained SIL capture

Issues [#41](https://github.com/twodayslate/SwiftTestSelection/issues/41),
[#42](https://github.com/twodayslate/SwiftTestSelection/issues/42),
[#43](https://github.com/twodayslate/SwiftTestSelection/issues/43) and
[#44](https://github.com/twodayslate/SwiftTestSelection/issues/44) are covered by
release tests, fresh Xcode comparisons and actual retained-product execution.
[Machine-readable measurements](Issues41-44Validation.json) distinguish fresh
builds, cached graphs, compiler replay and read-only capture validation.

## Contracts exercised

Generated resource accessors and asset-symbol sources require matching content,
active generator metadata, compiler settings and resource/build input seals.
Temporary build roots are normalized; literal source values such as `#filePath`
remain semantic. Changed, missing, conflicting and unsupported evidence stays
conservative. The active build manifest and PIF records are retained and checked
again before publishing the graph or reusing a cached graph with new products.

Recovered package/extension modules retain their `compiler-module` identity.
Production roles are separate evidence joined to the active compiler task and
PIF target. Unknown/test/host-bearing targets are not promoted. Runtime isolation
requires compatible roles and import inventories in both revisions, alongside
the existing declared boundary contract.

`--build-time-sil` captures during the retained API's normal build-for-testing,
using revision-bound source exports and locked package resolution. It includes
helper identity in the cache key and seals source, context, products and compiler
outputs. Both revision analyses must succeed before the retained completion
marker is published. Failure/cancellation tests check incomplete bundles and
preserved diagnostics. Missing or tampered captured files are failures;
unsupported trustworthy layouts replay the affected module explicitly.

## Xcode fixture

`Fixtures/XcodeGeneratedInputs` combines a resource-bearing local package,
hostless unit tests, hosted unit tests, embedded extensions and XCUITests. Its
package includes empty and platform-excluded primary files. The fixture uses
`diagnosticLineColumn` and explicit UI/non-UI runtime boundaries.

- A package-method edit selects 5 of 15 tests, without a generated-input fallback.
- An isolated extension edit selects 2 of 15: its mapped UI test and the hosted
  runtime-dependent test. The hostless Core tests are excluded under their
  validated contract.
- Warm base reuse, cached head analysis with a newly captured executable build,
  and independent fresh extraction preserve selection, diagnostics and boundary
  decisions. Generated-input and role evidence also agree.
- Independent ordinary replay builds produce the same selections and diagnostics.
  A cold identical-base/head capture builds once and selects no tests.
- Capture and replay extraction on the same verified fixture inputs agree on test
  bindings and reachability from all 15 tests to all 198 project functions.
- The exact selected tests and the complete fixture suite execute from the
  retained head products, without another build. Execution IDs are checked
  against the report and complete graph inventory.

Reproduce the combined capture/replay/cache/execution check:

```sh
swift build -c release
python3 Scripts/xcode_generated_inputs_integration_test.py \
  --tool "$PWD/.build/release/swift-test-impact" \
  --capture-helper "$PWD/Scripts/capture-build.py" \
  --destination "$DESTINATION" --output /tmp/generated-inputs-validation.json
python3 Scripts/xcode_capture_retained_failure_test.py \
  --tool "$PWD/.build/release/swift-test-impact"
```

The integration script prints its evidence directory. To independently compare
captured/replayed dependency reachability in that retained fixture:

```sh
IMPACT_RETAINED_CAPTURE_PARITY="$FIXTURE_EVIDENCE/extension" \
  swift test -c release --filter retainedCaptureMatchesReplayedProjectDependencies
```

This optional comparison is intended for the small fixture: it checks every
pair of a test and a project function, not a scalable graph benchmark.

## ChainOfCustody comparisons

Fresh base/head comparisons use Xcode 27.0, Debug, iPhone 17 Pro Simulator with
iOS 26.2, a release analyzer, and one extraction worker. Each historical pair
receives the same complete plan and mapping policy from consumer revision
`7e5638020d694235c97d9a4bfca40030b5ef1801`, using `diagnosticLineColumn`.
The original Swift sources are unchanged. Original and normalized local audit
SHAs are recorded in the JSON. For #294 only the mapping for the absent
`NoteMessageComposer.swift` is removed, identically on both sides.

| Historical comparison | Before | Selected / total | Unit / snapshot / UI | Fresh comparison | Maximum RSS |
| --- | ---: | ---: | ---: | ---: | ---: |
| #296 | 2000 | 1928 / 2000 | 1078 / 447 / 403 | 487.05 s | 2.49 GiB |
| #294 | 1898 | 837 / 1969 | 0 / 444 / 393 | 447.66 s | 2.47 GiB |

Both reports pass `verify-build`. No generated-input, source-ownership,
product-role, invalid-boundary or incomplete-graph fallback remains. Remaining
unmapped boundaries and opaque runtime dependencies remain visible. In
particular, the consumer policy has no ShareExtension UI mapping, and its hosted
snapshot target is outside the hostless Core runtime boundary. Smaller counts
are not a substitute for those missing contracts.

These fresh historical captures exercise per-module fallback: SnapshotTesting's
additional type-alias-only fragment used ordinary compiler replay. The final
reader also accepts that canonical layout. It was independently checked against
the original sealed real-app evidence from #44: all 10 modules parse from capture,
including CloudKitSyncMonitor and SnapshotTesting, with no extraction diagnostics
or compiler replay. That read-only probe retains 1,972 test bindings and 121,927
functions; it does not rebuild, enumerate anew, or execute the consumer's tests.

The historical run command is recorded in the JSON. Its essential form is:

```sh
swift-test-impact select --project ChainOfCustody.xcodeproj \
  --scheme ChainOfCustody --test-plan ChainOfCustody --configuration Debug \
  --destination "$DESTINATION" --base "$BASE" --head "$HEAD" --merge-base \
  --build-time-sil "$TOOL_CHECKOUT/Scripts/capture-build.py" \
  --analysis-cache "$CACHE" --cache-context historical-audit-locked-inputs-v1 \
  --retain-build "$NEW_BUNDLE" --format json --output "$REPORT"
```

Timings include builds, enumeration, extraction, retained publication and
selection. Other validation ran on the same host; these are observations, not
isolated benchmarks. RSS and physical footprint are recorded separately and do
not represent the simultaneous sum of the analyzer, compilers and Simulator.
The JSON aggregates individual analysis phases; worker times may overlap.

## Regression coverage and limits

All 202 package tests pass in release mode under Xcode 26.6 and Xcode 27.0.
Python capture inventory and frontend file-list regressions pass. Capture failure,
source mutation, missing-product and cancellation checks preserve incomplete
retained bundles and useful logs. Tests also cover context/helper mismatch,
missing/tampered output, malformed canonical fragments, mixed empty/real batches,
metadata ambiguity, changed generator inputs and source-location sensitivity.

The fixture's selected and full runs establish execution parity for that
fixture. The historical consumer comparisons establish graph/selection and
product-verification results only. Their selected bodies and complete consumer
suites were not run here. Full-suite equivalence and end-to-end CI performance
remain the consumer rollout gate; this validation does not enable that gate.
