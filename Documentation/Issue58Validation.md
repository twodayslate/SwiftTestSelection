# Issue #58: SDK extension helper precision

The release analyzer was validated against the historical ChainOfCustody #299
`waitForValue(_:timeout:)` edit. The scope contains only
`ChainOfCustodyUITests/XCUIElement+Waiting.swift`, with the consumer's two
independently executed edited-entry exclusions. Those entries remain selected
because they also consume the changed helper.

The final public CLI run selected **125 of 2,000 tests**, all UI tests, with
**zero scope diagnostics**. Its selected set exactly matches all 125 consumers
reachable in the historical compiler graph; none were lost or added. The
fallback-only `NoteLinksUITests/testBlockContextMenuSharesContent()` is excluded.
All explanations have kind `dependency` and identify the SDK-helper proof.

One head build captured supplementary SIL for all ten modules, with no compiler
replay or extraction diagnostics. No base build or baseline graph was supplied.
Build, capture and selection took **383.90 seconds**; the additional scoped query
took **42.24 seconds**. Both the primary and scoped reports passed `verify-build`
against the retained products. This run overlapped release tests and another
project build on the same host; it is not a controlled performance comparison.
The expanded cross-target base audit is included in the scope timing. The primary report still selects the full inventory
for other changes in the review; scoped helper precision does not waive those
fallbacks. This is selection/build-compatibility evidence, not a full-versus-selected
execution comparison: no application test bodies were executed.

The [machine-readable result](Issue58Validation.json) records the complete selected
set and original/normalized revisions. The normalized fixture removes the UI target's `selectedTests` filter and adds
the consumer mapping contract (`sourceLocationPolicy: diagnosticLineColumn` and
`runtimeDependencyPolicy: declared`). It does not alter the historical Swift
source diff. Environment: Xcode 27.0, iPhone 17 Pro
simulator, iOS 26.2. These measurements apply to that environment, not the original
historical runner. The issue's 40 Base + 113 Regression = 153 execution target is a
consumer policy calculation; the analyzer's scoped result is the 125 consumers.

Reproduce using a clean checkout containing the normalized fixture revisions and
this scope file:

```json
{
  "version": 1,
  "scopes": [{
    "name": "regression-support",
    "paths": ["ChainOfCustodyUITests/XCUIElement+Waiting.swift"],
    "excludedTestEntries": [
      "ChainOfCustodyUITests/CalendarDetentTransitionUITests/testCancelledTimelinePreviewPreservesCollapsedUntimedPanel()",
      "ChainOfCustodyUITests/CalendarDetentTransitionUITests/testCancelledTimelinePreviewPreservesUntimedCategoryAndScrollPosition()"
    ]
  }]
}
```

```sh
swift-test-impact select --project ChainOfCustody.xcodeproj \
  --scheme ChainOfCustody --test-plan ChainOfCustody \
  --destination "platform=iOS Simulator,id=$SIMULATOR_UUID" \
  --base 40c62f971f0aef63c902a14805cf4d821e6784fb \
  --head 50a773442d7df21ac8ce3c7d0fa61bf0548303ed \
  --head-only --build-time-sil "$SWIFT_TEST_SELECTION/Scripts/capture-build.py" \
  --retain-build "$NEW_BUNDLE" --selection-scopes scopes.json \
  --format json --output impact.json

jq '.selectionScopes[0].report' impact.json > helper-scope.json
swift-test-impact verify-build --project ChainOfCustody.xcodeproj \
  --scheme ChainOfCustody --test-plan ChainOfCustody \
  --destination "platform=iOS Simulator,id=$SIMULATOR_UUID" \
  --report helper-scope.json --head-graph "$NEW_BUNDLE/head-graph.json"
```

Compiled regression fixtures use a different method name (`checkValue`) and cover
transitive and inherited helpers, local functions, direct `try`/control-flow calls,
overloads, stored/escaping references and predicates, mutation, dynamic exposure,
lifecycle use, missing bindings, unknown consumers, SDK shadows/aliased subclasses,
unsupported base effects, untrusted imports/re-exports, SDK module shadows,
old/future evidence, and removed base callers outside
the requested file scope. An initial real-graph replay exposed repeated symbol
scanning while matching callers to tests; caching those symbols and indexing test
roots reduced that replay from 91.69 to 12.15 seconds with the same selection.

The PR #57 review fixes also inspect base Swift files absent from the head
inventory and require transitive effect evidence for private callees (proof
version 4). The full release suite passes 254 tests. Eight compiled regression
cases cover direct/transitive mutations, unsupported effects through an upstream
caller, recursion, a pure callee, deleted/out-of-target caller files, and an
unrelated base-only file. A fresh #55 capture still selects 12 of 1,972 tests with
zero scope diagnostics; its build/capture/selection took 259.18 seconds and its
scope took 2.55 seconds. Both primary and scope reports passed retained-product
verification.

The follow-up binding review adds exact declaration evidence (private proof
version 5), rejects inherited/global overload ambiguity at both source revisions,
and checks compiler callees against the proved effects. Read-only SDK waiting
wrappers use SDK proof version 3, including bounded existence/nonexistence waits.
The base audit now reads captured files across targets as well as base-only files,
so a target-membership change cannot conceal an old caller.

The Xcode 26.6 debug CI crash was reproduced as a worker-thread stack overflow in
`PrivateTestHelperIsolation`. Replacing recursive caller proofs with a memoized
work queue fixes the existing depth-25 diamond regression. All 257 tests pass in
both Xcode 26.6 debug and Xcode 27.0 release builds. The additional compiled cases
cover same-file/separate-file inherited overloads, base-only ambiguity, unproved
project effects, and a caller file moved to another target. Python capture tests
pass (6); distribution tests pass (6 run, one platform-dependent skip).

The SDK binding follow-up closes effect proofs over actual compiler targets and
checks competing overload candidates at both revisions. A project-defined
inherited `waitForExistence`/`waitForNonExistence` implementation cannot gain the
trusted SDK contract from its name; a removed overload cannot disappear from a
private helper's historical effect proof. Unknown base-file ownership is included
in this audit. These are selection-time checks over the existing version-5 private
and version-3 SDK metadata, so their evidence schemas do not change. Both new
compiled regressions pass, along with all 259 package tests in Xcode 26.6 debug
and Xcode 27.0 release builds.

The historical member-binding audit now covers queried SDK properties, methods,
and constructors through ancestor and aliased owners, including base-only source
files. Concrete project types are excluded only when every declaration candidate
at that revision is concrete; protocol and unresolved owners retain conservative
fallbacks. A compiled base/head regression verifies that removing a mutating
`NSObject.evaluate(with:)` overload cannot silently narrow a scoped predicate-helper
edit. SDK caller traversal now uses explicit enter/finish work items, preserving
cycle detection and reuse of shared callers without recursive stack growth.
Compiled regressions exercise 50- and 100-helper diamonds and cycles in debug and
release configurations.

All 264 package tests pass in Xcode 26.6 debug and Xcode 27.0 release builds.
Final retained-graph replays preserve the #55 set of 12 tests and the #58 set of
125 tests, with zero diagnostics. Their selection phases took 11.03 and 11.94
seconds respectively; both reports pass `verify-build`. These remain analysis
and retained-product checks, not application test execution.

The escaped-identifier follow-up normalizes SDK member, owner, alias, override,
and superclass names during selection, including raw names in saved captures.
The compiled historical-overload regression now covers both `evaluate` and its
backticked spelling and round-trips the head graph through JSON. Escaped owners
and members are also checked at head, base, and in base-only source inventories;
unrelated concrete owners retain their precision.

Private outbound callee-effect proofs now use iterative enter/finish work items.
The 200-helper source-parse regression no longer requires a recursive worker
stack. Cycles and unsupported effects still fail conservatively, shared callees
are reused, and attachment effects propagate to every ancestor. These changes
use existing capture metadata and do not require a schema version change.

All 265 package tests pass in Xcode 26.6 debug and Xcode 27.0 release builds.
The additional retained-graph replay passes in release, preserving the 12-test
#55 set and the 125-test #58 set with zero diagnostics. Selection took 11.26 and
12.06 seconds respectively, and both resulting reports pass `verify-build`.
No application test bodies were executed by these replays.

Declaration signatures and call-reference signatures now share the same escaped
identifier normalization as SDK member audits. Saved reference maps merge all
semantically equivalent keys, preserving declaration lines, caller lines, escape
flags, and unsupported-reference locations. Already-canonical maps remain shared
through copy-on-write. Existing capture evidence remains usable without a schema
version change.

Compiled regressions cover historical overloads with escaped method names or
argument labels, including raw signatures restored from saved graph JSON. Caller
regressions verify fresh and saved mixed-spelling references, precise selection
when calls survive, and conservative fallback when an escaped base caller is
removed outside the requested scope.

All 267 package tests pass in Xcode 26.6 debug and Xcode 27.0 release builds.
The additional release replay preserves the #55/#58 selections of 12 and 125
tests with zero diagnostics. Scoped analysis took 11.31 and 12.07 seconds, and
both reports pass `verify-build` against the retained products. These checks
execute no application test bodies.

The assertion-binding review expands lexical shadow detection to function and
closure parameters, closure capture bindings, generic parameters, and associated
types. External argument labels do not count as local bindings. Compiled cases
cover callable assertion parameters (including backticked names) and a generic
constructor that stores an escaping callback; the later callback consumer is
retained through conservative selection.

SDK proof version 4 invalidates version-3 evidence that could incorrectly claim
these bindings were safe. The legacy-graph regression restores the old permissive
flags and verifies fallback with a recapture diagnostic. Existing version-3
retained graphs must have their source proof evidence regenerated before helper
precision can be relied on.

All 270 package tests pass in Xcode 26.6 debug and Xcode 27.0 release builds.
An additional release replay refreshed source proof evidence from each retained
source export, asserting identical declaration keys and source fingerprints
before reusing the original compiler graph and product evidence. Separate graph
files were written; the completed retained bundles were not modified. Refresh
and encoding took 8.08 seconds for #55 and 8.12 seconds for #58. Selection then
took 11.28 and 12.20 seconds, preserving the 12-test and 125-test sets with zero
diagnostics. Both refreshed reports pass `verify-build` against the retained
products. This was a source-proof refresh and analysis replay, not another
application build, compiler extraction, or execution of application test bodies.


SDK proof version 5 closes the imported-assertion escape: caller files must use
plain imports from XCTest, Foundation, Swift, or UIKit before an enclosing
assertion or Boolean negation is treated as nonescaping. Unknown, attributed,
and declaration-scoped imports retain an explicit unresolved-binding fallback.
The import check is computed once per file. Direct helper calls keep their
precision, and UIKit remains supported for caller UI types without expanding the
helper body's three-module query contract. Project module shadows are rejected.

Compiled regression cases cover ordinary imports, scoped imports, an external
re-export, nonescaping local-function traversal, and an import removed only at
head. Both revisions compile. Graph JSON round trips preserve the new evidence;
version-4 graphs with restored permissive reference flags require regeneration.
A direct-call control retains precise selection despite an unrelated import.

All 272 package tests pass in Xcode 26.6 debug and Xcode 27.0 release builds.
An additional release replay refreshes source proofs from the retained exports,
verifies identical declaration keys and source fingerprints, and preserves the
12-test #55 and 125-test #58 selections with zero diagnostics. Refresh and
encoding took 8.29 and 8.22 seconds; scoped analysis took 11.34 and 12.17 seconds.
Both resulting reports pass `verify-build` against retained products. The original
completed bundles were unchanged, with no additional application build, compiler
extraction, or application test execution.
