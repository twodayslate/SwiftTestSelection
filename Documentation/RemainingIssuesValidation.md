# Remaining issue validation

Baseline: `fd229885633d59148b367fac473f73f82eeaf8dd` (merged #99).

## Ignored documentation and runtime boundaries (#100)

The full Git comparison remains authoritative, including when the selection scope
contains only a subset of changed paths. A Markdown file no longer invalidates a
hostless boundary when both revisions have the same documentation policy and the
captured build evidence authenticates that exact file as a non-build input.
Missing or stale evidence, changed policy, target-owned documents, build resources,
and other configuration files retain fallback.

Native syntax also permits comment-only changes inside a closed module when unit
identities, fingerprints, caller locations and inline policies are unchanged.
This retains semantic file identity and source-location checks. It does not infer
comment-only status from a text diff. The compiled four-module fixture covers the
mixed diff, filtered scope, exact selected IDs, and invalid evidence controls.
Its build seals are test doubles; it is not a consumer execution claim.

## Fresh extraction without cache reuse (#102)

Omitting `--analysis-cache` now disables graph lookup/publication and module
fragment reuse/publication explicitly. Complete sealed captures no longer prepare
cross-build module identities, scan dependencies again for cache keys, stage
fragments, or encode a graph just to reject it against a one-byte cache budget.

`freshInputValidation` and `freshInputRecheck` fingerprint the current source lists,
compiler, explicit imported-module maps and bytes, SDK plugins and explicit file
operands. Capture seals independently validate captured SIL, the exported tree and
retained executable products. Missing fresh input evidence remains a diagnostic;
changed inputs fail extraction. Cancellation is checked before publication.
Compiler replay retains the existing dependency-scan mutation checks in a mode
that exposes no reusable fragment identities. Explicit persistent caches retain
their existing lookup, mutation checks, publication and budget behavior.

## Geometry helpers and remaining precision boundaries (#101)

Private helpers now accept `CGRect` and `CoreGraphics.CGRect` value parameters and
explicit `CoreGraphics` imports. Compiled controls check exact caller selection
and retain fallback for historical aliases, SDK member replacements, mutation,
callback escape and application factories. Unsupported callback diagnostics name
the receiving call and source line, along with the missing lifetime/effect proof.

This does not establish the complete #380/#383 consumer reductions. #380 also
needs a proof for the callback passed to `waitForAllConditions` and the removed
historical `replyDestination` caller. #383 needs application-factory, launch-state
and renamed/removed helper evidence. Their hostless Swift Testing targets have
independent trait/parameter iteration and declaration-inventory boundaries.

## Issues that still need external or historical evidence

| Issue | Remaining requirement |
| --- | --- |
| #58 | Actual throwing-callback bindings and error-formatting witnesses in the transitive consumer closure; the known caller count alone cannot exclude other tests. |
| #61 | Reviewed Optional/String assertion formatting and remaining declaration/binding evidence for the historical comparisons. Extension entries and bounded scrolling helpers are already supported. |
| #83 | Authenticated historical macro/attribute declarations or reviewed source-scoped contracts. Per-construct inventory diagnostics and supported SDK identity contracts already exist; arbitrary expansions cannot be treated as complete. |
| #91 | Actual UI-runner validation on Xcode 27.3. This machine has Xcode 27.0–27.2. Existing fixtures cover compiler discovery, mixed frameworks, exact identifiers, argument providers and trait uncertainty, but do not establish 27.3 runtime behavior. |
| #101 | The independent callback, factory, historical-caller and Swift Testing boundaries above. |

These issues are not closed by substituting conservative fallback for a proven
precision improvement. Prior exact consumer evidence is in
[OpenPrecisionIssuesValidation.md](OpenPrecisionIssuesValidation.md) and
[OpenIssuesFollowup.md](OpenIssuesFollowup.md).
