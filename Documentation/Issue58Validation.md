# Issue #58: SDK extension helper precision

## Current status: conservative fallback required

The earlier 125-test results below are **historical and superseded**. Review
found that signature-only and callback-only receiver proofs could miss opaque
producers and shared-storage injection. They must not be used as evidence that
this historical revision is safe to gate on a 125-test selection.

The current analyzer requires captured producer implementations or explicit SDK
contracts, audits shared receiver storage, and reports a concrete blocker when
that evidence is missing. All 125 known consumers remain selected. The retained
#58 case falls back to its complete 2,000-test inventory; narrowing still needs
stronger evidence. #55's immutable literal fixture state is still supported, but
the conformance fix exposes a separate assertion-formatting boundary in its
caller chain: `XCTAssertEqual<XCTWaiter.Result>`. Error-flow auditing now finds
an earlier opaque callback boundary as well. That fixture retains
its complete 1,972-test inventory, including the 12 previously selected tests.
The previous 12-test precision result is superseded, not preserved by this fix.
An executed Xcode 26.6 XCTest probe confirmed that a failed generic integer
assertion invokes a retroactive `TextOutputStreamable` witness. Restoring narrow
selection requires proving formatting behavior as well as equality; nominal type
names alone cannot waive that obligation.

The query-overload blocker from PR #57 is now resolved using exact SIL
file/line/UTF-8-column evidence paired with source argument labels. Mixed
`matching(identifier:)` and `matching(_:)` calls, including multiple calls on one
line and calls inside assertion closures, can be verified independently. The
same position evidence now disambiguates other supported SDK method calls from
unrelated source names (for example, a `screenshot` Boolean parameter). Crossed
label/type overloads, method values and missing locations retain conservative
checks. A source-location directive anywhere in a module prevents its receiver
proof, including when it points into a different clean file. Older snapshots
without physical-location evidence must refresh that source evidence. Fragment
cache version 14 captures the expanded method-site evidence; older saved graphs
decline proofs that need missing evidence.

The retained #55 and #58 replays now first report unproven XCTest error
formatting in a closure within `waitForAllConditions(_:timeout:)`. That
producer has an indirect callback, so its error behavior is not established by
the captured evidence. The earlier generic assertion-formatting and unsupported
`SnapshotTesting` import boundaries remain separate missing proofs; clearing the
first diagnostic does not establish the complete caller chain.

The retained source inventory contains the seven consuming-project Swift modules,
not the SnapshotTesting source module. The implementation now supports more
concrete Swift string/character operations, builtin numeric assertions and
formatting, standard collection searches, `XCTUnwrap`, typed keyboard/content-size
constants, and inferred Boolean instance storage. Generic substitutions and
explicit callbacks are still checked: custom conformances, erased descriptions,
mutating callbacks, wrappers, observers, macros and unknown storage retain fallback.

The conformance review found that builtin nominal names did not prove the
protocol witnesses actually invoked by an SDK operation. The analyzer now checks
operation-specific scalar conformances, nested conditional equality/hashability,
and bridging requirements. Runtime printing and assertion failure formatting
also need known witnesses. `Optional: CustomStringConvertible`,
`Optional: Comparable`, and `Int: TextOutputStreamable` can be retroactive Swift
conformances, so these paths cannot inherit trust from `Optional` or `Int` alone.
Seven compiled cases cover these conformances, optional bridging, assertion
formatting, and an ordinary builtin description control. Unsupported combinations
retain both the helper caller and the potentially affected reader with an
explicit diagnostic. This can increase conservative selections for ordinary
generic integer or optional assertions until their formatting is proven.

The error-formatting review also demonstrated that `XCTUnwrap` invokes a thrown
Swift error's `description`, even when the caller uses `try?`. An executed
Xcode 26.6 probe confirmed that call. Capture now records Swift error propagation
and opaque throwing callback inputs, and receiver proofs audit explicit input
producers before trusting XCTest's catch-and-format behavior. This applies to
unwrap, equality/accuracy/comparison, Boolean, and nil assertions. Ordinary
nonthrowing controls remain eligible. Old graphs without this evidence decline
the proof until regenerated from sealed SIL; fragment cache version 14 forces
refresh of old fragments. The audit can conservatively include other explicit
producers in the same body because callback argument roles are not captured.

An exploratory audit now passes the receiver-origin check for **0 of the 125**
known consumers. This is not a partial test selection or a full isolation proof.
The JSON records the first remaining blocker for each other consumer; later
blockers may be hidden by that first failure. The actual selector still retains
the complete inventory.

Handwritten Objective-C implementations are outside the tool's analysis scope.
The consumer plans to rewrite those helpers in Swift; validating the replacement
requires a fresh build-time SIL capture. Swift-to-Objective-C lowering remains
within scope and is handled automatically where the captured implementation or
built-in SDK behavior can establish the proof. No user-audited isolation waiver
has been introduced. The rewrite alone does not resolve missing third-party
Swift evidence, erased-value provenance or protocol-dispatch proofs.

**#58 remains open.** The overload fix is covered by compiled positive and negative
regressions, but does not establish the real fixture's 125-test precision target.
Unconditionally trusting imports, opaque Objective-C bodies, or unmodeled SDK
symbols would recreate the unsafe assumptions withdrawn in PR #57. The complete
inventory remains selected, including all 125 known consumers.

All **343 package tests** and one additional retained replay test passed in
Xcode 27.0 release (**344 total**, **97.050 seconds**, excluding compilation).
Xcode 26.6 focused runs passed the compiled overload/source-remapping regressions,
Swift value and collection controls, and Boolean-storage controls. Capture-helper
checks passed six tests; release-distribution checks passed five with one
platform-specific skip.
The earlier replay assertion requiring #55's 12-test precision failed, exposing
the now-documented formatting boundary. Final replay assertions verify the full
inventories and retention of all previously identified consumers. #55 scope
analysis took **18.30 seconds**; #58 took
**19.13 seconds**. Both reports passed `verify-build`.
The final replay refreshed source proofs and reparsed the sealed UI-module SIL,
checking unchanged declaration keys, fingerprints, compiler-reference edges and
dynamic declarations. Original completed bundles and products were unchanged.
No new application build, baseline build, or application test bodies were executed.
These are local replay measurements, not controlled end-to-end benchmarks.

The machine-readable file separates `currentValidation`, `previousCallbackValidation`,
`previousQueryValidation`, and `historicalValidation`. Selection and `verify-build`
do not establish full-run equivalence.

### Receiver identity and imported overload review

Receiver-origin checks now pair every source method/subscript use with its SIL
signature. They reject unknown labels and method values, including mixtures with
valid SDK calls. This closes foreign `element` and labeled-subscript overloads
whose printed SIL types match an SDK operation.

SIL capture also retains literal, input, and dynamic metatypes and enum
constructors. An SDK allocator reference alone no longer proves that its runtime
class is the SDK class. Imported subclasses, forwarded metatypes, aliases, and
foreign enum arguments with an SDK-like printed name retain conservative
selection. Known SDK literals require trusted source imports and unshadowed
nominal identities. Clang-imported class thunks use exact SDK symbol contracts;
the shared `__C` class owner cannot authenticate an Objective-C category.

The compiled factory regression has 76 cases spanning private and SDK-extension
helpers, with positive ordinary SDK construction controls. Compact archives retain
the new optional evidence independently of older fields. Captured value-type
declarations preserve ordinary struct/enum producers without accepting SDK
namesakes. Synthesized initializers and enum accessors audit all overlapping declarations,
and static-method metatype inputs are omitted only when every matching input is
unused outside debug instructions. Nested signatures and forwarded values retain
their evidence. Missing evidence retains
an explicit recapture diagnostic, and module-fragment cache version 14 invalidates
older fragments. Regenerating from valid sealed SIL does not execute test bodies
or require a new baseline build.

### Explicit SDK origin contracts

Native SDK module ownership no longer establishes receiver safety. Every trusted
primitive has an explicit symbol contract. Reflective factories, custom collection
witnesses, erased Objective-C bridging, and bridge-capable casts to SDK receivers
or metatypes retain fallback. Generic operations require captured substitutions
for every use; aliases and shadowing, including backtick-escaped identifiers,
cannot authenticate builtin types. Unknown legacy evidence and mixed fragments
retain fallback.

Standard collection traversal can forward stored project values without invoking
their protocols; their producers and callback bodies remain in the graph. Range
bounds and value-protocol operations require closed builtin types. Array storage
allocation/finalization and continuation-handle wrapping have narrow contracts
that do not manufacture elements or resume continuations.

The only erased-bridge exemption is a compiler-proven unreachable `.some` block:
a fresh `Optional<Any>` stack slot is immediately initialized to `.none` and
switched, with exactly one predecessor. Mutation, aliases, multiple predecessors,
and mixed reachable bridge calls retain fallback. This preserves #55 without
trusting live erased bridges. JSON/compact archives retain the new evidence, and
cache version 14 requires older module fragments to be regenerated.

### XCTest callback effect review

The helper proof now checks source inventories at both revisions for XCTest
failure-recording and execution hooks, inherited/custom framework overrides,
and observation registration or conformance. Base-only and unowned source files
remain part of this check. Bound lifecycle hooks are audited through their
compiled roots. Assertion-only helpers now also audit opaque caller/lifecycle
implementations; imported setup code cannot acquire trust merely because the
helper uses no UI-element receiver.

Sixteen compiled cases cover both helper paths with direct, inherited and legacy
recording hooks, observers, removed hooks, opaque imported setup, missing compiler
evidence, and ordinary controls. Source tests cover escaped names, other framework
callbacks, aliases, unrelated declarations, and missing evidence at head, base,
and in unowned files. The runtime regression executes a small XCTest fixture:
the former one-test selection passes incorrectly, whereas the corrected selection
and the full fixture both detect the reader's failure. This is a synthetic
regression; consuming-application test bodies were not executed.

## Historical validation (superseded)

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


Private proof version 6 also validates imports before trusting SDK-named effects.
A scoped import of an external `XCTAttachment` can no longer hide an initializer
that writes shared state: the compiled regression selects both the helper caller
and the state consumer with an explicit callee-effect diagnostic. Unknown imports,
untrusted re-exports, and project SDK module shadows prevent isolation. Version-5
private captures with restored permissive flags fail with a recapture diagnostic.

Local-function reference proofs now share one file-local analysis. Identifier
lookups replace enclosing-token rescans, classifications and caller resolutions
are cached, and an iterative traversal rejects cycles and escapes. Declaration
identity distinguishes shadowed locals even when declarations share a line.
Regressions cover deep chains, shared callees, nested scopes, cycles, stored
references, attributed locals, untrusted imports, and bounded evaluation counts.

The same synthetic local-call-chain fixture improved as follows in Xcode 27
release builds (source parsing only, excluding compilation):

| Local functions | Source bytes | Before | After |
| --- | ---: | ---: | ---: |
| 40 | 1,513 | 0.1261 s | 0.0017 s |
| 100 | 3,733 | 1.8909 s | 0.0041 s |
| 200 | 7,633 | 16.1291 s | 0.0080 s |

The 200-function case takes 0.1394 seconds in Xcode 26.6 debug. These are local
microbenchmarks, not predictions of whole-project graph-generation speed.
All 276 package tests pass in Xcode 26.6 debug and Xcode 27.0 release builds.
After refreshing source proofs from retained exports and checking unchanged
keys/fingerprints, the release replays preserve the 12-test #55 and 125-test #58
sets with zero diagnostics. Refresh and encoding took 8.24 and 8.26 seconds;
selection took 11.20 and 12.04 seconds. Both reports pass `verify-build` against
retained products. No original completed bundles were modified, and no application
build, compiler extraction, or application test bodies were executed.


Private proof version 7 audits attachment constructor and member bindings at both
revisions before granting the SDK effect contract. The proof records member names
across checked private callees, including construction inside assertions without
attachment writes. Removed project initializers, attachment methods, and screenshot
overloads retain `head_only_helper_callee_effects`, including declarations in deleted
files and aliases or backticked owners. Already-proven SDK query helpers keep their
existing effect proof; unresolved overloads do not inherit that exemption. Compiler
shared-state diagnostics are preserved even when a historical binding is unproven.
Version-6 and older private evidence requires recapture, and missing member evidence
fails conservatively.

The compiled regression validates nine scenarios at both revisions: ordinary,
escaped, aliased, and deleted initializers; construction inside assertions and
transitive private helpers; screenshot and attachment member overloads; and an
unrelated concrete initializer (including a required override) that preserves
single-method selection. A separate regression distinguishes protocol requirements
from historical default implementations and checks SDK extensions in other modules.
The audit remains cross-module because Swift can expose extensions through imports
in another file. For every unsafe scenario the base compiler graph confirms the route from the test through
the project implementation to global state. The scoped head-only report must then
select both the caller and state consumer with an explicit diagnostic. JSON round
trips, missing attachment evidence, and stale version-6 captures are also checked.

All 278 package tests pass in Xcode 26.6 debug and Xcode 27.0 release builds.
The final retained-source refresh verifies unchanged keys and fingerprints before
reusing the compiler graph and product evidence. It preserves exactly 12 tests for
#55 and 125 for #58, with zero diagnostics. Refresh and encoding took
8.38 and 8.26 seconds; scoped selection took 11.71 and 12.25 seconds.
Both reports pass `verify-build`. The completed retained bundles were unchanged;
no additional application build, compiler extraction, or application test execution
was performed.


External helper callees now require compiler-resolved declaration ownership rather
than being skipped when they have no local SIL body. The compiled regression uses
an extension from a binary support module imported by a sibling file. An assertion
added to the private helper calls that extension and writes shared state; selection
now includes both the caller and state consumer with an explicit callee-effect
diagnostic. Ownership resolution is batched and cached per traversal, and unknown
symbols or unavailable/malformed demangling results fail conservatively. SDK
constructor thunks retain precision without treating every Clang-imported symbol
as trusted. No new source-proof version or capture format is introduced.

Attachment override checks now resolve class ancestry at each revision. An unused,
unrelated class overriding `name` no longer broadens a local attachment helper edit
to all tests. Tests cover both the compiled override/control cases and known SDK
ancestry, aliases, unresolved parents, nested declarations, cycles, ambiguous
classes, and missing evidence. All historical attachment checks remain active.

All 283 package tests pass in Xcode 26.6 debug and Xcode 27.0 release builds.
The release run also includes the retained replay test (284 tests total). Fresh
source-proof refreshes verify identical declaration keys and fingerprints before
reusing the original compiler graph and products in separate graph files. The
replays preserve exactly 12 tests for #55 and 125 for #58 with zero diagnostics,
and both reports pass `verify-build`. Refresh and encoding took 8.30 and
8.34 seconds; selection took 11.92 and 12.21 seconds. The original completed
bundles were unchanged. No application build, compiler extraction, or application
test bodies were executed.


The subsequent dynamic-dispatch and ancestry review closes cases that lack a
`function_ref`: foreign `@objc dynamic` calls, SDK-name overloads, differently
labeled overloads with identical formal types, escaped labels, and method values.
Private helper proof version 8 checks source call shapes and records every SDK
member used by checked private callees, including helpers without attachments.
Unknown dynamic calls or missing signature evidence retain an explicit fallback.
Supported navigation actions must be preserved standalone statements, rather than
new effects hidden in assertions. SDK helper compiler walks also validate external
and dynamic calls. The two compiler actor-check symbols and importer-synthesized
`XCTWaiter.Result` conformances have narrow explicit support.

Superclass lookup follows enclosing lexical scopes. Nested aliases, inherited
nested types, ambiguous classes, and unresolved ancestry cannot establish that an
override is unrelated to an SDK receiver. Compiled regressions include removal of
a state-writing screenshot override outside the selected helper scope, both with
and without an attachment and with an unrelated module-level namesake.

Graphs now retain complete SIL method references and formal signatures. JSON and
compact archives preserve missing versus empty evidence; merging fragments keeps
missing evidence conservative. The module-fragment cache schema advances to 8.
Older graphs remain readable, but source-proof refresh alone cannot restore this
precision: regenerate from valid build artifacts and sealed SIL with the current
analyzer. This does not require another application build.


Final validation passes all **289 package tests** with Xcode 26.6 in debug and
Xcode 27.0 in release; the release run also includes the retained replay test
(**290 tests total**). The capture helper's six tests pass, and release-distribution
checks pass five tests with one platform-specific skip.

The final retained replays select exactly **12 tests for #55** and **125 for #58**,
with zero diagnostics, and both reports pass `verify-build`. Each replay refreshes
source proofs with unchanged declaration keys/fingerprints and reparses the sealed
UI module SIL. Before adding signature evidence, it checks that compiler-reference
edges and dynamic declarations match the original graph. Original graph edges,
products, and completed bundles remain unchanged. No compiler invocation,
application build, or application test execution is involved.

UI SIL reparse took 4.18/4.13 seconds for #55/#58; total source/signature refresh and
encoding took 12.30/12.30 seconds. Scoped selection took 11.57/12.32 seconds.


### Overload pairing, subscripts, and receiver origins

Private source proof version 9 pairs query argument labels with exact SIL formal
signatures. It rejects crossed label/type overloads and mixed call shapes that
cannot be disambiguated by the saved compiler evidence. Subscripts are included
in the historical binding audit; labeled external getters cannot inherit the SDK
identifier-getter contract. An unrelated labeled collection subscript does not
broaden selection.

Both helper contracts now inspect consumer and lifecycle dependencies for native
or dynamic factories that could supply imported subclasses with stateful SDK
method overrides. Known SDK declarations remain trusted primitives. Project-owned
bodies require complete saved compiler references and dynamic signatures; opaque
external producers retain an explicit conservative fallback. Origin checks are
cached separately from outgoing effect contracts. Exact compiler-generated async
completion adapters are supported across both validated toolchains.

Compiled regressions exercise these cases using a separate imported support
module, alongside ordinary SDK controls. Parser and archive tests cover stale or
missing evidence, malformed method names, transitive call shapes, and nested
return types. Existing selection regressions remain covered.

All **300 package tests pass** with Xcode 26.6 debug (164.922 seconds) and
Xcode 27.0 release. The release run includes the retained replay test, for
**301 tests total** in 119.038 seconds. Capture-helper checks pass six tests;
release-distribution checks pass five with one platform-specific skip.

The retained replays preserve exactly **12 tests for #55** and **125 for #58**,
with zero diagnostics; both final reports pass `verify-build`. All ten sealed SIL
modules were reparsed, checking original compiler-reference edges and dynamic
declarations before adding signature evidence. Source proofs retain unchanged
keys and fingerprints. This evidence refresh and encoding took 64.68/64.82
seconds for #55/#58. Final scoped selection reused those separately refreshed
graphs and took 12.00/12.87 seconds.

The original completed bundles and products remain unchanged. No compiler
invocation, application build, or application test bodies were executed. These
checks validate the selection regressions and retained-build compatibility;
full-run equivalence remains a consumer CI adoption check.


### Callback and output-channel receiver review

Opaque receiver checks now inspect callback arguments as well as return types.
A native or dynamic factory returning `Void` cannot bypass the audit by delivering
an SDK subclass through a callback, optional callback, or output pointer. Resolved
project implementations remain traversable; unavailable producer evidence is
conservative.

A narrow completion contract preserves the real gesture-helper case: the source
must pass one direct callback whose input is used only as the first argument of
`XCTAssertNil`/`XCTAssertNotNil` or directly interpolated into an `XCTFail` message.
Shorthand optional-error unwrapping is supported. Compiler edges must independently establish
trusted SDK assertion bindings. Storing, returning, casting or forwarding the
input, unknown imports, mixed calls, missing metadata and external assertion
bindings retain fallback. The optional evidence survives graph archives. Its
source scan visits each saved declaration once, including local functions that
share that source unit.
Explicit closures are matched through their ending line because multiline calls
and earlier capture locations can overlap implicit assertion autoclosures.
An exact UIKit renderer callback contract and XCTest expectation construction
remain supported without granting outgoing effect purity. No project-specific
function or type names are trusted.

All **305 package tests pass** with Xcode 26.6 debug (173.665 seconds) and
Xcode 27.0 release. The release run includes the retained replay test:
**306 tests total**, 141.284 seconds. Compiled controls cover direct, multiline,
local-function and error-reporting completions as well as all unsafe factory
variants. Source/archive tests cover missing evidence, external assertion bindings,
forwarded expressions and overlapping implicit autoclosure locations.

Retained replays select exactly **12 tests for #55** and **125 for #58**, with
zero diagnostics, and both final reports pass `verify-build`. Scoped selection
took 11.80/12.85 seconds. Source evidence was refreshed from the retained exports,
checking unchanged declaration keys and fingerprints. The previously validated
compiler signatures and products were reused. Original completed bundles remain
unchanged; no compiler invocation, application build, or application test bodies
were executed. Full-run equivalence remains a consumer CI adoption check.
