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
