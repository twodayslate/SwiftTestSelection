# Issue #58: nonthrowing predicate callback evidence

A callback loaded from `[() -> Bool]` was treated as an opaque throwing XCTest
input producer. In the historical `waitForAllConditions(_:timeout:)` body,
`conditions.allSatisfy { $0() }` lowers to an indirect `apply` whose formal type
is `@callee_guaranteed () -> @out Bool`. That invocation cannot propagate a Swift
error into XCTest's catch-and-format path.

The parser now records a separate error-flow proof for these direct-result and
indirect-result Boolean predicate signatures, including their noescape forms.
This evidence only discharges the indirect invocation's error-propagation check.
The original indirect-call uncertainty and all compiler dependencies remain.
Throw instructions, throwing callback inputs, unknown/mixed signatures, generic
conformances, receiver origins, shared storage and helper effects still undergo
their existing checks. In particular, a nonthrowing predicate containing an
XCTest assertion over a throwing producer must retain conservative selection.

JSON and compact graph archives preserve the new optional evidence. Missing
legacy evidence cannot grant the exemption, and merged fragments retain every
unproven invocation. Module-fragment cache version 16 requires fresh extraction.
Existing sealed SIL can be reparsed without a baseline build or compiler replay.
Diagnostics include the unsupported invocation or explain that indirect-call
error evidence is missing.

The focused fixture uses the original immediate-value-to-predicate helper edit,
transitive consumers, and an unrelated test with opaque SDK dependencies. Its
new positive case wraps a local array of Boolean predicates in an XCTest input.
The existing stored/escaping helper references, stored predicates, dynamic
exposure, shared mutation, lifecycle, incomplete binding and removed-base-caller
negative cases remain part of the same compiled regression.

## Retained consumer results

Both the original historical #299 sources and the controlled Swift-only touch
helper variant pass the new predicate error-flow check. Their scoped selections
still retain all 2,000 candidates, including all 403 UI tests and all 125 known
helper consumers. `NoteLinksUITests/testBlockContextMenuSharesContent()` has a
conservative explanation and no dependency explanation for the changed helper.

The first remaining diagnostic is `Unproven generic receiver contract` for
`XCTAssertEqual` with substitutions `Optional<String>; String`. Equality alone
does not prove assertion failure formatting: runtime description selection can
invoke additional conformances. The existing conformance regressions demonstrate
that builtin nominal names do not establish all invoked witnesses. This change
does not add that missing proof or waive the other receiver boundaries.

The issue's proposed 153-UI-test execution target is therefore **not achieved**.
Issue #58 remains open. The selector continues to distinguish genuine dependency
paths from conservative runtime uncertainty. The captured source and compiler
reference edges were checked unchanged before refreshing the new optional field.
No new application build, baseline build or compiler replay was needed.

## Validation

The Xcode 26.6 release suite reported **355 tests passed** in **72.289 seconds**,
excluding compilation. The opt-in retained replay was skipped in that run and
passed separately across both original and Swift-only cases. Both scope reports
passed `verify-build` against their retained products. Capture-helper tests passed
six cases; distribution tests passed five with one platform-specific skip.

The [machine-readable record](Issue58PredicateCallbacks.json) includes revisions,
input/output hashes, remaining diagnostics and replay timings. These timings
include source refresh and sealed-SIL parsing and share a machine with other
work; they are not controlled benchmarks. No application tests were executed.

## Reproduction

`retainedHeadOnlyPrecisionReplay` accepts `IMPACT_PRECISION_REPLAY` pointing to an
array of the configurations documented in `PrecisionTickets60-62.md`. Set
`refreshIndirectErrorEvidence` to true to verify manifest, source and SIL hashes
and reparse the retained UI module. Set `retainedCapture` when the input graph is
a previously refreshed archive outside the retained bundle. The replay requires
unchanged source declaration keys/fingerprints, compiler reference edges and
previous error effects before adding the new field. `fallbackOnlyTests` asserts
that a conservatively retained test has no dependency explanation.

This validation reuses retained application products. It does not execute
application test bodies or establish full-run equivalence.

## More specific remaining-effect diagnostics

The receiver checker now separates supported equality from unproven assertion
failure formatting. For `XCTAssertEqual` on `Optional<String>`, `XCTWaiter.Result`
and similar values, it reports the containing compiler function/source location
and the runtime formatting protocols whose absence/effects are not proven.
`TextOutputStreamable`, `CustomStringConvertible`, `CustomDebugStringConvertible`
and `CustomReflectable` can introduce additional code beyond Equatable. Existing
compiled retroactive-conformance controls demonstrate why accepting nominal SDK
names alone would be unsound. The diagnostic does not establish a new dependency
edge or remove a known consumer. The 153-test target remains unproven.
