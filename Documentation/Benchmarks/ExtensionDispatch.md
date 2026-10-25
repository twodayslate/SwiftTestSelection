# Imported extension dispatch ownership

Issue #23 is reproduced by a local `extension XCTestCase` helper: treating the
extension header as a project type declaration incorrectly attributes unrelated
framework initializers to the project. New snapshots distinguish extensions and
record owned member names. Binding retains compiled implementations and diagnoses
missing project members without claiming ownership of the entire imported type.

The compiled regression imports XCTest, calls an Objective-C extension helper,
overrides setup, and binds three methods. An unrelated production edit selects no
tests; editing the helper selects its direct caller and the test whose setup calls
it; editing setup selects that class. Separate missing-member checks retain
conservative diagnostics for project callbacks and extension methods.

## Saved consumer comparison

Release validation on the existing ChainOfCustody graph (124,013 functions, 2,000
tests) reproduced issue #23's NoteListSort display-label source replay. Every
source-unit key and fingerprint was checked against the available source export
before refreshing ownership metadata. The comparison removes only the stale
`XCTestCase.init` classification, then rebinds; other uncertainties are preserved.

| Result | Before | After |
| --- | ---: | ---: |
| Tests carrying the incorrect initializer fallback | 145 | 0 |
| Total selected tests | 1,440 | 1,440 |
| Added or omitted selected identifiers | — | 0 |

Other runtime uncertainty still selects these tests. This is evidence that the
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
