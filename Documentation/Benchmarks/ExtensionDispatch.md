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

Review-fix validation: all 124 release tests passed, including the compiled
override regression and the missing-implementation/super-call checks.
