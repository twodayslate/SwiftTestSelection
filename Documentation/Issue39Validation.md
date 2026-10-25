# Generated compiler helper ownership: issue #39

[Issue #39](https://github.com/twodayslate/SwiftTestSelection/issues/39) is reproduced
against merged main with compiled ObjC async XCTest closures and global-actor
reabstraction adapters. A fresh consumer replay additionally exposed type-only
key-path equality/hash helpers. These normal compiler forms previously caused
entire module graphs to be discarded.

The fix resolves ObjC wrappers through their enclosing declaration. Known
type-only adapters retain separate graph identities per emitting module, without
assigning a declaration owner from parameter/result/actor types. Their incidental
conversion-site locations do not become shared source declarations. Bodies,
compiler references, dispatch declarations, and uncertainty remain available.
SIL key-path instructions now retain their embedded accessor and index-helper
references, with conservative key-path uncertainty. Unknown contexts still fail
conservatively, with immediate bounded diagnostics. Existing foreign-extension
and protocol-witness ownership guards are unchanged.

## Reproduction and source provenance

The release analyzer ran with Xcode 27.0 / Swift 6.4 and one extraction worker,
using the iPhone 17 Pro simulator on iOS 26.2. Both revisions of each comparison
were built and enumerated during this validation; the cache started empty for
the four-case sequence. Compatible module fragments produced during that sequence
could be reused after input validation, including between a pair's head and base.
No compiler graphs or fragments from earlier validation runs were supplied.

The complete test plan and mapping policy from consumer
`e349d75d808bc279d3ac6b18b3585e0ff7d2eb57` were applied identically to each pair.
For older #294/#278 revisions, mapping source paths/classes absent from either
side were removed identically, as recorded in the evidence. #293/#296 needed no
such pruning. All original Swift source remains byte-for-byte unchanged, and the
normalized comparisons have exactly the original changed paths. The normalized
SHAs are local audit commits, not upstream consumer commits.

#293 is the incremental fix between its failed and successful heads, not its
entire original PR diff: `1d47a36876f3e6043fdd1732e2aa1f50d6e8abc5` to
`49e130b2dab1f9125e836fa8969fd0815effb7be`. Its changes are the single UI method
and allowed `AGENTS.md` documentation. Both fresh graphs retain all seven project
modules, all 1,972 test entries, valid runtime inventory, and complete mappings
for the native 394-test UI inventory. Graph, source, test-entry, and runtime
inventory diagnostics are empty on both sides.

[Machine-readable evidence](Issue39Validation.json) records implementation and
binary hashes, original/normalized revisions, mapping adaptations and hashes,
module counts, generated adapters, selections, reasons by kind, policy outcomes,
phase times, memory, cache parity, and the executed test result.

## Fresh comparison results

The configured policy is `diagnostic`. Unit / snapshot / UI counts below are
selected method counts. Times include both builds, enumeration, extraction,
retained-head publication, and selection; they exclude the selected test execution.
RSS is the maximum resident set reported by `/usr/bin/time -l`.

| Historical comparison | Selected/total | Unit / snapshot / UI | Fresh comparison | Maximum RSS |
| --- | ---: | ---: | ---: | ---: |
| #293 | 1/1972 | 0 / 0 / 1 | 1112.82 s | 2.03 GiB |
| #296 | 2000/2000 | 1137 / 460 / 403 | 1086.52 s | 2.12 GiB |
| #294 | 1898/1969 | 1061 / 444 / 393 | 852.27 s | 2.02 GiB |
| #278 | 458/1935 | 0 / 439 / 19 | 879.94 s | 2.03 GiB |

#296 intentionally remains a full selection: its changed Core module also
compiles generated `resource_bundle_accessor.swift`, which has no repository
semantic boundary. The existing `unsupported_source_ownership` fallback is
retained. Other mapping/runtime uncertainty diagnostics remain explicit; this
fix does not suppress them to obtain a smaller selection.

These are local observations, not isolated benchmarks or a CI speedup claim.
The JSON also records peak process footprint separately from RSS. These are not
simultaneous totals for the analyzer, compiler subprocesses, and Simulator.

## Policy and cache controls

Every policy passes the consumer's unchanged complete-native-inventory and mapping
validator. Every edited UI method is included. Semantic mode intentionally retains
broader location-sensitive/conservative selections; this fix does not change the
location-policy contract or waive runtime uncertainty.

| Comparison | `semantic` | `diagnosticLineColumn` | `diagnostic` |
| --- | ---: | ---: | ---: |
| #293 | 1899 | 1 | 1 |
| #296 | 2000 | 2000 | 2000 |
| #294 | 1898 | 1898 | 1898 |
| #278 | 458 | 458 | 458 |

The saved-graph API replay compares selection IDs, exact execution arguments,
reasons, diagnostics, mapping coverage, full-run reasons, and runtime-boundary
decisions with the fresh report. With multiple reachable changed declarations, an
explicit mapping may choose a different valid witness path; the evidence flags
path equality separately and preserves both original reports. These controls do
not claim byte-identical explanation paths. A separate CLI replay hits both revision graph
cache entries, skips builds/enumeration/extraction, and preserves those same fields.
The four warm comparisons completed in 14.51–16.45 seconds each; all four also
matched the fresh report's explanation paths in these CLI runs.
The replay uses the cold run's shell `PATH` order: an initial attempt with a
different order correctly missed the settings identity and was stopped. No cache
identity was rewritten to force a hit.
Empty and allowed-documentation controls select no tests. Internal revision-cache
payloads are used through the analysis cache/API, not misrepresented as standalone
build-artifact captures for the artifact-selection CLI.

## Executed selection and regression checks

The verified retained #293 head products executed exactly:

```
-only-testing:ChainOfCustodyUITests/PairingNotesMediaUITests/testBackButtonDismissesMediaPreviewToItsListBlock()
```

The xcresult contains that exact method: one pass, zero failures, zero skips, and
no missing requested IDs. No rebuild or substitute products were used. The process
completed in 195.89 seconds, including runner startup and result processing.

All 186 package release tests pass with both Xcode 26.6 and Xcode 27. The compiled
regression covers async XCTest setup/test ObjC closures, global-actor adapters,
key-path equality/hash helpers and embedded edges, two emitting modules, captured
and replayed SIL, one/two extraction workers, and resolved-fragment cache round
trips. Existing unknown-context, foreign-extension, protocol-witness, selection,
and cache tests continue to pass.

The other historical cases validate selection, mapping coverage and artifact
verification; their selected bodies and full suites were not executed here.
Known historical failures and whether they were selected are recorded explicitly
in the JSON. In particular, #278 did not select its two historical media failures,
`testFullScreenPagerAndSafariTabBarStaySynchronized()` and
`testVideoAutoHideKeepsNavigationInFullDetails()`. Their relationship to that diff
has not been established by this validation. This is not a full-suite equivalence result or approval to enable a
CI selection gate; that broader consumer rollout validation remains separate.

## Repeat the comparison

In a disposable consumer checkout, recreate a normalized original base/head pair
with the identical complete plan/mappings above (and recorded historical-only
adaptations). Build the release analyzer with the chosen Xcode. Use a new cache
and retained directory; do not substitute old compiler graphs:

```sh
"$TOOL" select --project ChainOfCustody.xcodeproj --scheme ChainOfCustody \
  --test-plan ChainOfCustody --configuration Debug --destination "$DESTINATION" \
  --base "$BASE" --head "$HEAD" --merge-base \
  --analysis-cache "$CACHE" --cache-context issue39-fresh-historical-v1 \
  --retain-build "$RETAINED" --format json --output impact.json

"$TOOL" verify-build --project ChainOfCustody.xcodeproj --scheme ChainOfCustody \
  --test-plan ChainOfCustody --configuration Debug --destination "$DESTINATION" \
  --report impact.json --head-graph "$RETAINED/head-graph.json"
```

For #293, run the verified `.xctestrun` with the report's literal `onlyTestingArguments`
and inspect xcresult test-case identifiers, not only the process exit status.
Repeat the comparison without `--retain-build` to test revision-cache hits.
Local raw logs, reports, retained products, and the selected xcresult are under
`/tmp/issue39-final`; the committed evidence is the portable summary of those runs.
