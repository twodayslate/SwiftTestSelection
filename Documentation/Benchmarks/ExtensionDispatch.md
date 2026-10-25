# Imported extension dispatch ownership

Issue #23 is reproduced by a local `extension XCTestCase` helper: treating the
extension header as a project type declaration incorrectly attributes unrelated
framework initializers to the project. New snapshots distinguish extensions and
record owned member names. Binding retains compiled implementations and diagnoses
missing project members without claiming ownership of the entire imported type.

The compiled regression imports XCTest, calls an Objective-C extension helper,
overrides setup, and binds five methods. An unrelated production edit selects no
tests; editing the helper selects its direct caller and the test whose setup calls
it; editing setup selects that class. Separate missing-member checks retain
conservative diagnostics for project callbacks and extension methods.

The review regression adds a project `isEqual` override reached through an
`NSObject` reference, with an intermediate project superclass and a qualified
`Foundation.NSObject` ancestor. Editing the override selects its caller and leaves
an unrelated test out. Snapshots record explicit overrides; the binder connects
base declarations to their available implementations and preserves uncertainty
when those implementations are missing. Super calls retain their ancestor target,
so framework initializers do not acquire subclass-override cycles.

The generic-superclass regression runs the same compiled fixture through both
`Parent` and `Fixture.Parent<[String: [Int]]>`. The source index parses nominal
type names and removes specialization arguments before walking ancestry. In both
cases an override edit selects only its caller, without an unresolved-dispatch
fallback. Trailing protocol conformances do not become superclass links.

Ancestry that cannot be resolved (including an unsupported type alias) retains an
explicit `incomplete override ancestry` diagnostic for matching member dispatches.
Known XCTest/NSObject ancestry and super calls keep their precise behavior. This
is conservative handling, not type-alias resolution.

Superclass lookup follows enclosing scopes before module-level names, so a
top-level `Parent` does not hide `Scope.Parent`. Alias declarations, including
aliases used as qualifiers, stop lookup conservatively rather than letting it
fall through to an unrelated class. Required initializer implementations are
recorded even without an `override` modifier. Compiled regressions verify a path
to the actual nested override and required initializer, then check that an edit
selects its caller and leaves an unrelated test out.

Nominal qualifiers also stop outward lookup when a nested member is absent from
the source index. A compiled fixture defines `Scope.Container: RealContainer`,
where `RealContainer.Parent: NSObject`, alongside an unrelated outer
`Container.Parent`. Editing the override in `Scope.Local: Container.Parent`
selects its caller with an explicit incomplete-ancestry fallback and excludes
an unrelated test. The index does not resolve inherited nested members; it must
not substitute the outer class and silently omit the affected test. Direct
nested superclass references retain their compiled dependency paths with both
unqualified and qualified spellings.

## Saved consumer comparison

Release validation on the existing ChainOfCustody graph (124,013 functions, 2,000
tests, source revision `1f0e37b69458200227c584d9a4563b5391948cdf`) reproduced issue
#23's NoteListSort display-label source replay. [Raw results](ExtensionDispatch.json)
record the selected-identifier differences and remaining diagnostic count. Every
source-unit key and fingerprint was checked against the available source export
before refreshing ownership metadata. The comparison removes only the stale
`XCTestCase.init` classification, then rebinds; other uncertainties are preserved.

| Result | Before | After |
| --- | ---: | ---: |
| Tests carrying the incorrect initializer fallback | 145 | 0 |
| Total selected tests | 1,440 | 1,442 |
| Added / omitted selected identifiers | — | 2 / 0 |

The override-aware review fix adds two conservative candidates:
`DomainTests/handoffRequiresAllNonSubmissionAssets()` and
`DomainTests/repairFillsIncompleteDivergentTagThumbnailAssets()` in
`ChainOfCustodyTests`. No selected identifier was omitted. Other runtime
uncertainty still selects the tests previously carrying the initializer diagnostic. This is evidence that the
specific diagnostic is fixed, not a claim of reduced suite size or full-run
behavioral validation. Older saved graphs keep conservative legacy ownership until
regenerated.

Reproduce with the corresponding saved graph and matching source export:

```sh
IMPACT_EXTENSION_GRAPH=/path/to/graph.json \
IMPACT_EXTENSION_SOURCE=/path/to/source \
IMPACT_EXTENSION_OUTPUT=/tmp/extension-results.json \
swift test -c release --filter consumerExtensionDispatchProbe
```

## Superclass and initializer validation

A separate saved-input check of `issue11-consumer-graph.json` at the same consumer
source revision selects **1,464 tests versus 1,445** in its saved baseline: 19
additional conservative candidates and no omissions. The incorrect XCTestCase
initializer classification remains absent (145 affected tests before, zero after).
The source fingerprints were verified before rebinding. These counts compare
against this saved baseline, not the previous PR head. Its SHA-256 and exact added identifiers are recorded
under `overrideResolutionValidation` in the raw results.

The ancestry fallback deliberately retains callers of matching dispatches when
an override's superclass chain cannot be established. This can add conservative
candidates; it does not claim complete type-alias or external-framework hierarchy
resolution. The compiled generic-superclass case has no such diagnostic and
selects only its caller. Full-suite behavioral validation remains separate.

Review-fix validation after rebasing onto `4e36974` (main): all 134 release tests passed, including both compiled
override cases, nested nominal-name parsing, unresolved ancestry, trailing
protocol conformances, missing-implementation/super-call checks, lexical
shadowing (including inherited nested members), required initializer dispatch, and the capture tests merged in #28.
