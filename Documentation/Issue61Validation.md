# Issue #61: private extension helpers with scoped locals

Added XCTest entries and repeated plain extension headers were supported by #63. This change supports the scrolling-helper body, but **does not establish the proposed 46-UI real-app selection**. Replaying both original comparisons exposes a further caller boundary: XCTest failure formatting of `Optional<String>`. That boundary remains conservative.

## Implemented boundary

Immutable locals are checked in lexical order within each branch/loop. Their names and attachment provenance are discarded when that scope ends, and initializers are checked before their names become visible. Shadowing, pattern bindings, mutable locals, closure escapes and missing compiler evidence remain unsupported. The supported `for` form is an ignored element over a literal integer range. Explicit local annotations and cast types are limited to the built-in/XCTest value types already audited at both revisions; arbitrary aliases and compound types retain fallback. Default literal-type aliases are also audited, since an apparently primitive literal can invoke a project initializer at base.

The helper's callers, primitive default-argument thunk, assertion closures, transitive callees and receiver origins still require compiler evidence. Exact CoreGraphics rectangle operations and XCTest coordinate/drag signatures now have explicit contracts. Project overloads, SDK module collisions, ambiguous methods, shared/lifecycle effects and unknown external operations retain fallback. Changes to existing helper bodies must still preserve earlier statements and their control-flow context. Every allowed bare global participates in the reserved-name audit across head, base, and unowned base sources. This rejects historical rebinding of `max`, `CGRect`, and `CGVector` even when the project overload disappears before the head capture.

Private-helper proof version is 13 and the module-fragment cache is version 18. Older saved helper proofs cannot grant this isolation.

## Acceptance coverage

The five requested boundaries are covered: #63 supplies extension-entry and repeated-header support; this PR supplies the scoped helper body and exact unsupported-effect diagnostic, conservative fallback with compiled positive/negative fixtures, and both original scope-local capture replays. The third criterion explicitly permits identifying an unsupported effect. The remaining optional assertion-formatting boundary is documented below; the 46-UI optimization remains unproven.

## Historical comparisons and remaining effect

The replay reuses the two complete single-head-build SIL captures documented in [the prior validation](PrecisionTickets60-62.md). Each contains ten modules, a normalized complete test plan and complete UI mappings. No new application build, base compilation or compiler replay was performed. All current source proofs were regenerated from the retained source export; source keys and semantic fingerprints were checked unchanged. Compiler edges, inventory and products were untouched.

Each scope contains only `ChainOfCustodyUITests/NotificationUITests.swift` and excludes the same six independently executed entries recorded in the issue. The helper's former nested-local rejection is gone. Both scopes retain the known scrolling-helper caller and fall back on this exact generic call:

```
$s6XCTest14XCTAssertEqual___4file4lineyxyKXK_xyKXKSSyXKs12StaticStringVSutSQRzlF
substitutions: Optional<String>
```

The caller uses `XCTAssertEqual(comment.value as? String, "Read")`. Optional equality alone does not prove the failure-formatting path: a project can add `Optional: TextOutputStreamable`, whose witness can mutate shared state or replace an SDK implementation. A compiled negative fixture demonstrates that custom formatting body. No such harmful conformance is alleged in the consumer; the analyzer lacks a closed formatting proof and must keep fallback. This is a caller/receiver contract limitation, not evidence that the loop itself escapes.

The consumer's original version-2 tier policy was rerun with its 40-test Base configuration, original full-review candidate report, and refreshed scope result. The full production diff was not substituted for the scope-local proof.

| Historical run | Scope UI selection | Final Base + Regression UI | Remaining declaration fallbacks | Retained verification |
| --- | ---: | ---: | ---: | --- |
| 40031610717 | 384 | 40 + 344 = 384 | 1 | Passed |
| 40035642452 | 397 | 40 + 357 = 397 | 1 | Passed |

The one declaration fallback is the added helper whose complete caller chain remains unproven; the four added extension entries and repeated headers no longer trigger the original six fallbacks. The consumer verification recomputed the policy and checked the sealed graph, build identity, context and products. Scope reports also passed `verify-build` independently. Original/normalized revisions, capture hashes, exact scopes, selected counts and measurements are in [Issue61Validation.json](Issue61Validation.json). Application test bodies and full-suite equivalence were not executed.

## Tests and reproduction

After rebasing onto main (`d01af86`, including #69, #70, and #72), the release suite reported 390 passing tests, including both historical replays, all 20 compiled scrolling variants, three compiled global-binding cases with three scenarios each, and six compiled local-type cases with two source-ownership scenarios each. The capture-helper suite passed six tests; the distribution suite passed five with one platform-specific skip. Replay timing shares a machine with other builds and is not a comparative performance measurement.

`ExtensionHelperControlFlowTests` compiles the real scrolling body (using XCTest's native wait method in place of the consumer wrapper), including the default thunk. Without an unsupported caller effect it selects only its compiled caller. Negative variants cover shared state, escapes, lifecycle use, overloads, missing binding/dynamic metadata, stale proofs, shadowing, sibling-scope leakage, initializer reads, mutation, callbacks, nonliteral loop bounds, pattern bindings, SDK module collisions and optional assertion formatting. Existing extension-entry/header tests remain in the suite. Three compiled global-binding cases each check removed project overloads, unowned base sources, and head-only overloads for `max`, `CGRect`, and `CGVector`; each must retain the shared-state reader. The fixtures verify that the old compiler graph reaches the project overload. Six compiled local-type cases cover historical aliases in annotations and casts, default literal-type rebinding, and supported `Int`/`Swift.Int` annotations and casts. Both ordinary and unowned base files are checked; negative fixtures verify the historical edge to the state-mutating literal initializer.

```sh
swift test -c release --jobs 3 --no-parallel
python3 Scripts/capture_build_test.py
python3 Scripts/release_distribution_test.py
IMPACT_PRECISION_REPLAY=/path/to/replay.json swift test -c release --jobs 3 --filter retainedHeadOnlyPrecisionReplay
```

The opt-in replay retains the existing configuration fields. For these cases set `expectedBlocker` to `Optional<String>`, `declarationFallbacks` to 1, and `obsoleteBlockers` to include `Nested local declaration`. Set `expectedSelectedCount`/`expectedUICount` to 1961/384 and 1981/397 respectively. The known consumer is `ChainOfCustodyUITests/NotificationHubUITests/testFiltersAndBulkReadClearOnlyAffectVisibleSelection()`. The replay additionally supports `expectedSelected` for exact selections and a null `expectedBlocker` to require zero diagnostics.
