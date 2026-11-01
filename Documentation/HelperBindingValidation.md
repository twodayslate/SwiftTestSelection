# Helper binding review validation (#58 and #83)

Based on main `3d03903`. This change implements scoped review support for SDK
synthesis identities and source-local dependency imports. It does not establish
arbitrary macro expansion or imported-function purity, and does not close either
precision issue. See [the contract schema](HelperBindingContracts.md) for the
trust boundary and [the machine-readable results](HelperBindingValidation.json)
for exact positive dependencies, selection differences, and remaining boundaries.

## PR #85 review fixes

Saved head-only selection now supports a separate `--helper-binding-reviews`
JSON array. A compiled regression commits the reviewed policy after the code
revision, then exercises the public CLI against that earlier immutable capture:
two selected tests narrow to the one known consumer without an Xcode project or
a rebuild. The original graph remains byte-for-byte unchanged. Stale reviews
retain fallback; mismatched revisions and missing/stale build audits are rejected.
Both full and scoped reports retain the original script-input uncertainty and
record the full applied declarations. Retained publication preserves the audit's
documentation allowances and uncertainty alongside its raw-log/settings digests.

Input evidence version 2 recursively expands compiler response files before
validating plugin arguments. Tests cover direct/nested hidden flags, both flag
spellings, quoted response paths, missing/cyclic files, standard plugin roots,
response-file sealing, and ambiguous working directories. Version 1 evidence is
rejected rather than silently inheriting the stronger validation.

After these fixes, all **550 serial release tests passed in 369.791 seconds**.
The focused run passed 52 tests. The original standalone response-file probe now
rejects the hidden custom plugin. Python capture/distribution tests and coverage,
inline-mapping and mapping-maintenance CLI checks also passed (one existing
distribution platform skip).

The consumer measurements below were produced at `fb147a2`, before these review
fixes. They document observed selections; their version 1 seals and hypothetical
policies cannot authorize reviews with the current analyzer. A fresh capture is
required for current policy adoption. The fixes do not establish the remaining
macro or snapshot-callback effect proofs.

## Compiled regressions

A reviewed SwiftUI `@State` declaration in an unrelated app source allows a
private XCTest helper to narrow from two tests to its one compiler-bound caller.
A separately compiled dependency import, reviewed at both revisions, allows an
SDK helper to narrow from two tests to its one caller. Both preserve raw source
uncertainty and report precisely which identity review was used.

Negative cases retain fallback for an imported function call, a historical
`UserDefaults` write, source aliases at head/base/unowned revisions, arbitrary
macros, reexports, unsupported identities, stale inputs/products/import maps,
missing inventories, duplicate reviews and missing guarantees. Identical bytes
cannot borrow a head review for the base or an unowned historical source.
Missing raw operator metadata stays conservative. Archive round trips preserve
binding digests; changing statement order changes them.

Capture tests cover actual explicit import-map and dependency bytes, custom
plugin rejection, unknown map fields, missing binaries, and the one-build
retained-artifact publication path. Capture errors disable review support and
remain visible in the report. The replay exposed excessive hashing of unrelated
macro inventories; candidate filtering and bounded Foundation temporary-object
lifetimes fixed that without changing the digest or authorization rules.

## Consumer evidence

Two fresh head-only builds used Xcode 27.1, the complete consumer test plan,
strict mappings and the original normalized `regression-support` comparisons.
Each captured all ten SIL modules and sealed ten compiler import inventories
covering 517 dependency/compiler input files. There was no base build, compiler
replay, consumer policy/pin edit or execution of consumer test bodies.

The first #293 analysis was interrupted by excessive temporary memory use after
its build and graph capture completed. After fixing the hashing path, the same
retained source, raw logs/settings, SIL and products were used to refresh binding
metadata and rerun selection. The final one-build publication path has a direct
regression test. All consumer evidence comes from those two completed builds.

The existing six #293 formatting reviews and one #299 formatting review matched
the fresh source/build context exactly. Additional synthesis, comparison and
import grants in the experiment are explicitly **hypothetical**, not approved
consumer policy. No generated identity inventory is promoted to a review.

| Comparison / policy | Selected total / UI | Known positive consumers | Review result |
| --- | --- | --- | --- |
| #293, existing six formatting reviews | 1,972 / 394 | 12 / 12 | Four discharged, two unused; 513 raw incomplete inventories |
| #293, plus 219 hypothetical SDK identity reviews | 1,972 / 394 | 12 / 12 | 213 discharged, six rejected for `SwiftUI.State` namesakes; 300 inventories remain incomplete |
| #299, existing one formatting review | 2,000 / 403 | 125 / 125 | One discharged; another assertion-formatting boundary remains |
| #299, 131 hypothetical comparison reviews | 2,000 / 403 | 125 / 125 | 22 discharged, 109 unused; `import SnapshotTesting` blocks receiver identity |
| #299, plus two hypothetical source import reviews | 2,000 / 403 | 125 / 125 | Both discharged; `SnapshotTesting.assertSnapshot` error formatting from its throwing callback remains unproven |

Every scenario adds/removes **zero selected identifiers** relative to its raw
capture, and preserves all known compiler dependency explanations. The #293 raw
inventory retains all 513 sources and 27,190 construct locations even when
individual reviews discharge boundaries. Six source reviews fail because a
project alias/namesake can shadow `SwiftUI.State`; the validator does not waive
those failures. Arbitrary Testing/Observation macro inventories remain outside
this contract. The #299 import review supplies no effect guarantee for the
subsequently encountered snapshot assertion callback.
The final #299 import-review report also retains its complete raw inventory:
528 incomplete sources and 27,642 construct locations.

These results do not demonstrate the conditional 153/52 UI targets. Both issues
remain open, and the hypothetical grants must not be copied into consumer policy.
Raw and scenario products pass strict `verify-build` authentication.

The full serial release suite passed **549 tests in 383.991 seconds** with Xcode
26.6. All eight focused tests passed after the final capture/report guards. Python
capture-helper and distribution tests pass (one existing platform skip), as do
coverage, inline-mapping and mapping-maintenance CLI checks.

## Reproduction

`retainedHelperBindingReview` is opt-in through `IMPACT_BINDING_REPLAY`, a JSON
array of records containing `graph`, `root`, `report`, and `output` paths, plus
optional `formatting` and `bindings` JSON policy files. It checks retained source
fingerprints, logs, settings and products, refreshes typed input evidence from
the completed build, and runs the original report scopes. It never invents a
review or launches a compiler. Each scenario emits a scoped report and graph for
`swift-test-impact verify-build --strict-mappings` with the original project,
scheme, plan, configuration and simulator destination.

Local captures and scenario policies for this run are retained under
`/tmp/helper-binding-validation`. The JSON summary is durable evidence of exact
selected-ID differences and positive consumers; it is not a replacement for the
retained build inputs needed to authenticate a review.
