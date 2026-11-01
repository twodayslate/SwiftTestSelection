# Remaining helper precision issues (#58, #61, #83)

Based on main `363f9a6269ea8d10e20de9f40a78230d822f12ff`.

## Changes

Exact reviewed formatting contracts now support the four scalar XCTest relational
assertions (`>`, `>=`, `<`, `<=`), including the SDK `CGFloat` comparison reported
in #58. The overload, producer, substitutions, helper, source revisions, SDK,
toolchain and captured build evidence remain bound. This closes the contract
expressiveness gap; it does not automatically grant the formatting guarantee.
Containers, project comparison witnesses, ambiguous type identities, unrelated
assertion overloads and unknown compiler metadata remain unsupported.

Private-helper reports now enumerate all incomplete declaration inventories in
`helperDeclarationInventories`, with every attribute/macro spelling, physical
line/column, possible declaration/effect and the required evidence. The separate
`helperDeclarationAudits` field ties those inventories to helper identities and
SDK member/operator names under audit. Both revisions and unowned historical
sources remain visible even when an earlier proof fails. Old archives request
refreshed metadata explicitly. This implements #83's actionable-evidence outcome;
it does not authenticate arbitrary SwiftUI attributes or infer module isolation
from source imports.

#61's extension entries, repeated plain headers and scrolling-helper body were
already supported on main. Their remaining formatting and declaration-inventory
boundaries use these same reports. No dependency, callback, historical caller,
shared-state or lifecycle uncertainty is removed by the diagnostic changes.

## Automated validation

Compiled fixtures cover every relational overload, SDK `CGFloat` frame producers,
exact before/after selected IDs, retained positive callers, source/build/toolchain
invalidation, overload/substitution mismatches, missing compiler/receiver data,
unknown witnesses, historical formatting conformances and aliases, escaping
method references, lifecycle changes and independent state effects.

Inventory fixtures include SwiftUI wrappers/builders, unsupported actor import
contexts, inactive macros, trusted compiler attributes/literals, legacy archives,
removed/unowned sources and 1,041 incomplete source inventories without truncation.
Native compiler-plugin regressions retain fallback for generated operators,
globals and members, with their actual historical dependency edges verified.

The full serial release suite passed all **539 tests** in 442.787 seconds with
Xcode 26.6. Python capture-helper and distribution tests passed (one documented
platform skip), as did coverage, inline-mapping and mapping-maintenance CLI checks.

## Consumer reproduction

Each comparison uses a fresh head-only capture with Xcode 27.1 and iOS 26.2, the
existing normalized Swift-only base/head revisions, the complete plan, strict UI
mappings and its original independent `regression-support` scope. No source edit,
base compiler build, saved base graph or historical application test execution is
required. Captured products are verified for the raw and scoped reports.

Run the analyzer from the matching consumer checkout, substituting the exact
recorded revisions and paths:

```sh
swift-test-impact select \
  --project ChainOfCustody.xcodeproj --scheme ChainOfCustody \
  --test-plan ChainOfCustody --configuration Debug \
  --destination 'platform=iOS Simulator,id=SIMULATOR_UUID' \
  --base BASE --head HEAD --head-only --strict-mappings \
  --build-time-sil /path/to/SwiftTestSelection/Scripts/capture-build.py \
  --retain-build /path/to/new-retained --selection-scopes scopes.json \
  --format json --output impact.json

swift-test-impact verify-build \
  --project ChainOfCustody.xcodeproj --scheme ChainOfCustody \
  --test-plan ChainOfCustody --configuration Debug \
  --destination 'platform=iOS Simulator,id=SIMULATOR_UUID' \
  --strict-mappings --report impact.json \
  --head-graph /path/to/new-retained/head-graph.json
```

The opt-in `retainedHelperFormattingReview` fixture can compare existing reviewed
declarations against the same captured head and verify exact selected-ID previews.
A declaration discharge is local to its boundary, not proof of whole-helper
isolation. Hypothetical declaration experiments must remain separate from reviewed
consumer policy. The conditional 52/153/46 UI targets are not acceptance overrides.

## Declaration evidence from the fresh #293 capture

The capture reproduces 352 head sources, with exactly the same 257 incomplete
inventories as the earlier report: 123 app, 48 snapshot-test, 43 unit-test,
36 core, three share-extension, two messages-extension and two UI-test sources.
The independent scope now lists all 513 head/base inventories and 27,190
individual construct locations, including inactive branches and repeated uses.
The affected helper is `NoteLinksUITests.assertShareOptions`, whose audit
includes `buttons`, `exists`, `subscript` and `waitUntilExists` bindings.

`AppView.swift` now identifies `@MainActor` at line 123, `@Environment` at line
213, `@AppStorage` at line 214, the individual `@State`/`@ViewBuilder` uses and
four `#Preview` expressions. The UI-target blockers are now explicit:

- `CalendarSnapshotUITests.swift:5:1`: `@MainActor` under an unsupported import
  context, requiring authenticated actor/attribute and export identity.
- `TouchEventSynthesis.swift:50:26`, `51:26`, `53:28` and `67:36`: `#selector`
  expressions, represented by SwiftSyntax's macro-expression nodes and outside
  the currently supported compiler-literal inventory. Their compiler identity and
  referenced declaration/effect boundary remain unproven by this source audit.

These diagnostics do not assert that SDK wrappers, actors or selector expressions
actually synthesize colliding globals. They identify the missing proof and retain
uncertainty until authenticated evidence can distinguish compiler/SDK constructs
from project expansion and historical binding effects.

## Fresh capture results

| Consumer comparison | Scoped selected / UI | Known helper consumers retained | Added IDs | Removed IDs |
| --- | ---: | ---: | ---: | ---: |
| #293 / 40058859478 | 1,972 / 394 | 12 | 0 | 0 |
| #299 / 40159996488 | 2,000 / 403 | 125 | 0 | 0 |
| #291 / 40031610717 | 1,961 / 384 | 1 | 0 | 0 |
| #291 / 40035642452 | 1,981 / 397 | 1 | 0 | 0 |

Every capture consumed ten SIL modules from exactly one head build, with zero
extraction diagnostics and no base compiler work/replay. Raw and independent
scoped reports passed strict mapping and retained-product verification. No
historical application test bodies executed. All exact selected-ID sets match
the corresponding prior normalized comparisons. The #293/#299 source-unit
fingerprints and declaration-completeness bits also match their previous captures.

For #291, the sole known consumer is independently verified by reverse traversal
from `revealInboxFilter`, its default thunk and named closures in each fresh
compiler graph. The declaration fallback occurs before a changed helper root is
accepted, so these scoped reports do not label that path as a positive dependency
explanation. The known test nevertheless remains selected. Both comparisons retain
one declaration diagnostic and an `Optional<String>` formatting boundary; the new
inventory fields expose the other missing source proofs before that first effect
check can be discharged. The proposed 46-UI result remains unproven.

Existing reviewed declarations matched both fresh source/build fingerprints
without rebinding. #293 discharged four of six declarations; two stayed
valid-unused. Its remaining blocker is the complete declaration inventory above.
#299 discharged its one reviewed declaration and exposed another equality
producer. All selected IDs stayed unchanged, and each reviewed scope passed
retained-product verification.

A separately labeled **hypothetical** diagnostic experiment reused the prior 106
equality declarations for #299. Eight discharged and 98 remained valid-unused;
none was invalid. The next boundary is now a structured, reviewable
`XCTAssertGreaterThanOrEqual` / `CGFloat` formatting entry in
`SharingPeopleUITests.testRolesLeadSharingDetailsAndOwnerCanChangeRole()` at line
81. Its exact assertion symbol, producer and substitutions are available for a
future per-producer review. That experiment also retains all selected IDs and
passes product verification. It is not a safety review, consumer policy, or
permission to remove uncertainty. No new consumer guarantees were authored.

The native reviewed-declaration replay passed in 149.066 seconds over the same
fresh builds, with no compiler work. Detailed revisions, exact empty ID
differences, selected-ID digests, known consumer identifiers, remaining diagnostics,
and contract decisions are in [the validation JSON](OpenPrecisionIssuesValidation.json).
The complete untruncated source inventories and helper audits are preserved as
compressed JSON for [#293](OpenPrecisionEvidence/40058859478-inventories.json.gz)
and both #291 comparisons
([40031610717](OpenPrecisionEvidence/40031610717-inventories.json.gz),
[40035642452](OpenPrecisionEvidence/40035642452-inventories.json.gz)).
Use `gzip -dc FILE.json.gz` to inspect them. Full local reports, captured graphs,
products, command lines, logs and verification outputs are retained under
`/tmp/open-precision-validation/`.
