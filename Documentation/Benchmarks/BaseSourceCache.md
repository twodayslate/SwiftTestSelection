# Invocation-local base syntax reuse (#79)

Head-only selection now shares Git blob bytes, the base path listing, and native
source snapshots across the primary report and additional scopes. The cache is
owned by one invocation and bound to its repository and resolved base commit.
Snapshot keys additionally include module and logical path; parser identity is
fixed by the running executable. Different owners and renamed files never share
a snapshot merely because their bytes match. Unknown ownership uses its own
empty-module key. Selection needs no persistent source cache or base compiler
graph and performs no additional build. Scopes use the captured head graph in
memory. This change does not expand reuse of captured head syntax.

Only immutable inputs are shared. Every query constructs its own changed-path
set, caller audit, unknown-ownership evidence, mapping policy and diagnostics.
Failed reads are memoized as unavailable evidence, not empty source. Historical
callers outside a scope still participate in the audit. A primary report's
unrelated addition or deletion diagnostics are never copied into a scope.

## Verification

`ReferenceHeadOnlySources.swift` freezes the previous loader as an independent
oracle. Tests compare exact selected identifiers and the complete diagnostic
objects, including messages and affected identifiers. Fixtures cover overlapping
and empty scopes, independently executed entries, unrelated additions/deletions,
changed and removed historical callers outside the scope, base-only sources,
multiple module owners, renames and file identity, mapping changes, unavailable
revisions, missing blobs, invalid UTF-8, and unowned read failures. Revision tests
also cover moving symbolic refs and a stacked comparison whose merge base differs
from the base tip. Counters assert that repeated queries perform no additional
Git blob reads, path listings, or native parses for already requested evidence.

Run the normal suite using the repository's CI settings:

```sh
swift test --jobs 3 --no-parallel
```

## Reproduction

The opt-in release benchmark consumes a JSON array with `name`, `root`, `graph`,
`report`, `output`, and `repetitions` fields. `graph` is the fresh retained
`head-graph.json`; `report` is its complete primary report with selection scopes.
The repository must still contain both report revisions. Each repetition runs
the old independent loader and the shared cache, alternating their order, and
asserts exact primary and scoped identifiers against the report and complete
diagnostics against the uncached loader on the same in-memory graph.
It uses identical captured compiler evidence without rebuilding or replaying the
compiler. Graph decoding and Git diff construction occur outside measured totals.

```sh
IMPACT_BASE_SOURCE_BENCHMARK=/absolute/path/cases.json \
  swift test -c release --jobs 3 --no-parallel \
  --filter baseSourceCacheRealAppBenchmark
```

For fresh end-to-end capture, use the issue's normalized revisions, complete-plan
and strict-map overlays, and regression-support scope without modifying the Swift
review edits:

```sh
swift-test-impact select --project ChainOfCustody.xcodeproj \
  --scheme ChainOfCustody --test-plan ChainOfCustody --configuration Debug \
  --destination "$DESTINATION" --strict-mappings \
  --base "$BASE" --head "$HEAD" --merge-base --head-only \
  --build-time-sil /same-checkout/Scripts/capture-build.py \
  --selection-scopes /absolute/path/scopes.json \
  --retain-build /new/retained-directory --format json --output impact.json
```

`baseSourceSyntax` and `selection` measure primary loading and selection;
`scopeSourceSyntax` and `scopeSelection` measure those phases per scope.
`selectionScopes` remains their inclusive aggregate. `baseSourceCache` has zero
duration and reports cumulative `blobReads`, `blobHits`, `treeReads`, `treeHits`,
`parses`, and `parseHits`. Blob reads count attempted Git shows, including mapping
content and missing files. Tree reads count listings; the cache separately pins
the revision once. A parse hit returns the snapshot without requesting its blob,
so it does not also increment blob hits.

## Measurements (2026-10-31)

[Machine-readable results](BaseSourceCache.json) record both normalized revision
pairs from #79, every run, counts, per-query timings, retained build identities,
and SHA-256 digests of the matching identifier and diagnostic arrays.
All 518 tests passed with the CI settings; the focused release checks also passed.
All four captures used identical analyzer and capture-helper bytes.
The release analyzer was built with Xcode 26.6; fresh consumer captures used
Xcode 27.1 and the iOS 26.2 simulator. Each retained capture consumed ten modules
from exactly one head build, used strict complete mappings, and performed no base
compilation or compiler replay. Primary, regression-support, and the previously
audited consumer-policy execution requests all passed retained-product verification.
No application tests were executed for these timing measurements.

Two paired repetitions per case use the same freshly captured graph, alternating
cached/uncached order. Every query compares exact identifiers and full diagnostic
objects against the uncached loader on that same in-memory graph. The table
reports mean wall times in seconds. Totals cover
primary plus scoped source loading and selection, including the parity assertions;
they exclude graph decoding, diff construction, builds, and product verification.
Replay and CLI timings have different execution contexts; compare the paired
rows within this table rather than substituting them for CLI phase durations.

| Case | Loader | Git blob reads | Native parses | Primary loading | Scope loading | Primary selection | Scope selection | Total |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| #293 | Previous loader | 709 | 706 | 15.271 | 15.246 | 1.765 | 2.098 | 34.476 |
| #293 | Shared cache | 353 | 353 | 15.144 | 0.001 | 1.737 | 2.078 | 19.030 |
| #299 | Previous loader | 726 | 724 | 15.455 | 15.441 | 2.779 | 3.097 | 36.824 |
| #299 | Shared cache | 360 | 362 | 15.467 | 0.001 | 2.845 | 3.089 | 21.432 |

Fresh end-to-end totals below include export, build, enumeration, extraction,
retention, source loading and selection; product verification is separate. These
are repeated observations on a shared development machine, not an isolated
before/after build benchmark. The first captures overlapped the unit suite and
release test compilation. Do not attribute changes in build time to this cache.

| Case | Run 1 | Run 2 | Exact primary/scoped identifiers |
| --- | ---: | ---: | --- |
| #293 | 355.63 s | 334.37 s | Match |
| #299 | 346.25 s | 336.71 s | Match |

The second #293 capture reproduced an existing diagnostic nondeterminism: one
ambiguous-declaration fallback named `NoteBlockCollectionCoordinator.swift`
instead of `NoteSharing.swift`. Its code, affected tests, and total diagnostic
count were unchanged. The selector chooses the first declaration from an
unordered source dictionary. This optimization leaves that behavior unchanged;
the JSON records the exact cross-capture delta. Cached-versus-uncached assertions
use the same graph and compare complete messages without suppressing this
category. The second #293 total was recovered from command/report timestamps
after the coordinator stopped to investigate that diagnostic difference.

The optimization removes repeated source work; it does not change selection
precision or resolve the broad helper selections tracked in #58/#61. Historical
phase values from the issue are retained in the JSON for context, not used as
a controlled before/after comparison.
