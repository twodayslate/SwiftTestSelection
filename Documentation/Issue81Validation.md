# Issue #81 validation: reviewed formatting boundaries

The implementation supports exact, reviewed XCTest equality failure-formatting
boundaries. The compiled fixture narrows from three tests to its two known
consumers. Adding a compiler dependency from the third test keeps all three.
The real-app reviews below discharge their covered formatting diagnostics, but
**do not establish the conditional 52/153 UI targets**: independent uncertainties
remain, and both selections stay broad.

See [the schema and trust model](HelperFormattingContracts.md). The checked-in
[review declarations](Issue81Evidence/) are validation inputs for these exact
captures, not a recommended blanket consumer policy. They are not installed in
the consumer repository.

## Real captures and review

| Consumer | Run | Scope UI before → after | Known helper callers retained |
| --- | --- | ---: | ---: |
| #293 | 40058859478 | 394 → 394 | 12 / 12 |
| #299 | 40159996488 | 403 → 403 | 125 / 125 |

The scope is `regression-support`, with the original independently executed test
entries excluded as change roots. Total scope inventories are 1,972 and 2,000.
The consumer's separate Base/edited-test policy is not changed. Its union with
these scope selections is still 394/403 UI tests. Returning #299 to the old
41-test total would discard known consumers and is not supported.

The [#293 selection evidence](Issue81Evidence/coc-293-selection.json) and
[#299 selection evidence](Issue81Evidence/coc-299-selection.json) record exact before/after selected IDs, added and
removed IDs, known caller IDs, positive dependency paths, declarations discharged
or unused, and remaining diagnostic reasons. Empty removal lists are intentional.
These results are declaration-dependent audits, not execution coverage or a CI
speed measurement.

### #293

The six declarations bind `assertShareOptions(in:)` to specific
`XCTAssertEqual<XCTWaiter.Result>` producers. Review covered the wait results
compared with `.completed` in `testNoteToolbarSharesLink`, the two context-menu
share tests, `disablePrivacyVeil`, `assertLinkShareSheet`, and the unchanged
inherited `restorePortraitOrientation` helper. The latter declaration covers only
formatting the enum value; it does not authorize lifecycle or orientation effects.

Four declarations are discharged before the independent inventory gate stops
analysis; two remain valid but unused. The remaining helper diagnostic identifies
incomplete base/head declaration inventories, including macros or unsupported
attributes; the first reported file is head `ChainOfCustody/App/AppView.swift`. Formatting declarations cannot supply macro expansion or ownership
evidence. Per-test runtime uncertainty consequently remains as well. Affected source identities are retained in the evidence rather than attributing the broad selection to
missing feature mappings.

### #299

One deliberately limited declaration covers the exact
`TabBarBadgeUITests.testCalendarBadgeMirrorsInboxAndCanBeDisabledIndependently`
producer's `XCTAssertEqual<Optional<String>>` formatting while analyzing
`XCUIElement.waitForValue(_:timeout:)`. Its three relevant assertions cast
`XCUIElement.value` to `String?`; formatting receives nil or a string, not the
original accessibility object.

That declaration is discharged. The next uncovered formatting boundary is in
`TabBarBadgeUITests.testNotesBadgeCanBeDisabledAndPreferencesSurviveRelaunch`,
line 53 of the captured file. Runtime fallback remains, and all 125 independently
recorded helper consumers still have positive compiler reasons. This is a real
example of one declaration not authorizing a different producer. The first
unresolved boundary does not imply that reviewing it would be sufficient to reach
153 tests; the traversal can reveal further independent blockers.

### Trust accepted for this validation

The review inspected the relevant base/head source diff, the captured XCTest
header defining `XCTWaiterResult` as an integer enum, the generic equality
assertion signature, and the captured package sources. Project sources at both
revisions have no formatting/reflection conformances for these types. The
SnapshotTesting/IssueReporting string and optional extensions use their own
snapshot-description/placeholder protocols, not replacement XCTest formatting
witnesses.

The declarations explicitly trust the captured Apple runtime's built-in formatting
and reflection of these concrete values to avoid shared/resource effects,
callback registration/escape, and test/SDK receiver injection. This is a reviewed
assumption, **not binary purity established by the compiler**. Normal assertion
failure recording and evaluation of expressions retain their existing checks.
No declaration is inferred from suite membership, absent edges or passing tests.

## Capture provenance and reproduction

The retained captures under `/tmp/precision-60-62-validation/<run>/retained` use
one prior head build each with build-time SIL. They contain the previously
documented identical Swift-touch bridge overlay at base and head; they are not
new captures of the original unmodified PR commits. Exact comparison revisions,
artifact IDs and fingerprints are in the evidence. The toolchain reports Xcode
27.0 / Swift 6.4, from `Xcode-27.0.0.app`. Verification with Xcode 27.1
was rejected for a toolchain mismatch before using the matching installation.

This validation performs zero new app builds, zero base builds/compiler graph
loads/replays, and no test execution or historical coverage lookup. Missing Git
subtrees in the old scratch repositories were restored through alternate object
databases containing the exact content-addressed objects. Base source is read
from the actual recorded comparison revision.

The opt-in `retainedHelperFormattingReview` fixture reparses captured source
bytes, requiring identical source-unit identities and fingerprints. For these
older captures it also verifies the sealed manifests/source/SIL hashes, reparses
the UI module's sealed SIL, requires unchanged compiler references and existing
error effects, and refreshes only indirect-call error metadata (9,901 / 10,144
functions). It neither changes dependency edges nor invokes a compiler. It writes
a separate `reviewed-head-graph.stigraph`; the original capture remains intact.
The replay also authenticates the original settings/log digests before deriving
normalized effective-build evidence. The declarations were rebound to that
stronger fingerprint with unchanged guarantees, source digests and captured
inputs. The separate graph is needed because strict mapping validation correctly rejects
the old archive's missing inline-source metadata.

A replay configuration is an array with `graph`, `root`, `report`, `output`,
optional `contracts` (one of the declaration JSON files), and
`refreshIndirectErrorEvidence: true` and `refreshFormattingBuildEvidence: true`. `report` is the original captured impact
report containing `selectionScopes`. Omitting `contracts` produces the baseline;
each declared run also computes an exact no-declaration preview internally.

```sh
IMPACT_FORMATTING_REPLAY=/path/to/replay.json \
  swift test -c release --jobs 3 --no-parallel --filter retainedHelperFormattingReview

DEVELOPER_DIR=/Applications/Xcode-27.0.0.app/Contents/Developer \
  /path/to/swift-test-impact verify-build \
  --project ChainOfCustody.xcodeproj --scheme ChainOfCustody \
  --test-plan ChainOfCustody --configuration Debug \
  --destination 'platform=iOS Simulator,id=F76CB8AE-1D41-4CAC-AFA3-97CA767EF5FD' \
  --strict-mappings --report /path/to/output/regression-support.json \
  --head-graph /path/to/output/reviewed-head-graph.stigraph
```

Run verification from the matching captured consumer checkout. It checks strict
mapping resolution, the report/artifact binding, exact retained product manifest,
toolchain, simulator runtimes and test plan without building or executing tests.

## Automated checks

- Full serial suite: 526 tests passed (512.211 seconds).
- Focused helper/receiver/cache checks: 44 tests passed.
- Directive/inline mapping checks: 44 tests passed, including a declaration in a
  separate comment-only Swift file.
- Final contract and independent-scope checks: 16 tests passed (7.062 seconds),
  including the named incomplete-inventory fallback.
- Release build passed. The native real-capture replay passed in 99.725 seconds.
  Strict retained-product verification results are recorded alongside the exact
  selected IDs.

Negative cases cover stale source/revision/toolchain/build-context identities,
ambiguous/duplicate/missing bindings, unknown overloads/substitutions, incomplete
compiler evidence, removed historical callers, escaping callbacks, shared state,
lifecycle changes, project formatting conformances, declaration changes, and
incomplete source inventories. Mixed production/helper changes retain mapping and
compiler reasons. Separate helper scopes, central/comment equivalence, policy
adoption/removal, and inert prose/Markdown are also checked.

## PR #82 review fixes

Aliased formatting conformances now invalidate declarations before either private
or SDK helper isolation can use them. A compiled SDK regression includes a
state-mutating `Optional` conformance spelled through an alias and an unrelated
test reading that state. Qualified, nested, namespace, chained and escaped aliases
are exercised at head, base and in unowned historical source. Unrelated nominal
conformance controls retain valid declarations.

Build declarations now bind normalized effective settings and ordered compiler
invocations. Captured raw settings/log digests authenticate that derived evidence.
Changed flags, response-file arguments, stale derived metadata, missing artifact
metadata and missing conformance inventories retain conservative selection.
Equivalent captures with relocated source/DerivedData roots and changed log
progress preserve the fingerprint, avoiding an authoring cycle when adding a
review comment. New capture paths save this evidence; old caches are invalidated.

The focused review-fix run passed 28 tests (19.478 seconds), including parameterized
alias/build-input cases and retained-artifact checks. The refreshed release replay
passed in 101.805 seconds. Both before/after reports passed strict mapping and
retained-product verification for each consumer capture. The selections and all
known consumers remain unchanged; the evidence files now record the authenticated
build-input binding. No additional app build, base compiler replay or consumer
test execution was used.

The updated full serial suite executed 531 tests in 530.227 seconds. Its only
failures were two cases of the existing cached/uncached parity test comparing a
scoped diagnostic with an unscoped reference. All diagnostic fields matched
except the intentional `selectionScope` label. The test now supplies the same
expected scope to its reference; production selection was unchanged.
The final focused rerun passed 13 tests in 20.730 seconds, including all three
scenarios of that corrected parity test and the formatting/build-input regressions.

## Retained-capture relocation

Build-input evidence v2 normalizes the exact frontend wrapper identified by a
validated SIL capture, including its path inside `OTHER_SWIFT_FLAGS` when more
flags follow. The fingerprint still includes the frontend bytes and sealed helper
identity. Unsealed/unrelated frontend paths remain semantic, and v1 evidence is
rejected until refreshed. Both production capture paths pass the validated SIL
metadata through to this binding.

The focused helper/capture checks passed 29 tests in 21.166 seconds; the two
existing workspace-normalization tests also passed. The new regression compares
separate retained directory layouts, alias paths, changed frontend contents,
changed helper identities and missing metadata. Both original real captures
passed seal/product/helper verification, and rewriting their paths through a
relocated directory alias produced identical fingerprints. Their declarations
were rebound to v2 without changing the reviewed guarantees.

The release replay passed in 98.366 seconds. Both before/after reports for each
capture passed strict mapping and retained-product verification. Exact selected
IDs, declaration decisions and all 12/125 known consumers were unchanged. The
evidence files now include the frontend digest and sealed helper identity. No
new consumer app build, base compiler replay or consumer test execution was used.
