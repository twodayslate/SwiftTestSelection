# Helper binding cache and visibility validation

This follow-up addresses #86's repeated authoring-context work and #87's
inaccessible cross-file namesakes. It does not establish the macro expansion or
throwing callback/error-formatting evidence still requested by #83 and #58.

## Correctness checks

The focused release tests cover exact digest equality against the uncached
implementation, archive round trips, source metadata changes, changed compiler
observations, different source modules, repeated queries, scope exclusions,
changed comparison revisions, stale build/input records, helper-scoped grants,
and saved CLI overlays. Public context, raw inventories and policy decisions
remain query-specific. Internal previews only consume selected identifiers and
no longer create unused authoring context.

The visibility tests include an actual two-file SwiftUI compiler control for a
private nested `State` in another file. They also cover private enclosing types,
private/fileprivate aliases, accessible names, same-file nested names, extension
access defaults, explicit public extension members, conditional duplicate names,
missing capture metadata and an accessible historical declaration. Same-file
lexical/inheritance resolution remains conservative; this is not a general Swift
name resolver.

## Consumer replay protocol

Use the preserved fresh captures from the consumer's
`swift-test-selection-9fc8140-2026-11-01` study, with the original Git repositories,
exact base/head comparisons, formatting-control graphs, mapping/build settings,
and regression-support scope files. Compare release executables built using the
same local toolchain. Run saved head-only selection serially for each executable
and capture wall/CPU time and peak memory with `/usr/bin/time -l`.

The benchmark applies the existing formatting-control declarations; it does not
adopt hypothetical binding policies. Compare full/scoped selected IDs exactly,
and compare the remaining JSON evidence after normalizing Set-encoded array
order. This includes positive dependency reasons, contract decisions, authoring
fingerprints, raw inventories, remaining diagnostics and previews.

The original captures had ten SIL modules, zero compiler replay and recorded
product verification. This replay performs no build or test-body execution.
The retained products have been removed, so product verification cannot be
repeated; original graph bytes and artifact identities are preserved.

## Reproducing the digest workload

`Scripts/HelperBindingDigestBenchmark.swift` compares the unchanged uncached
digest algorithm with the invocation-local cache on one saved graph/report and
its Git comparison. It checks every computed digest for exact equality and
prints primary/scope/preview-sized passes and computation/hit counts. These are
digest workload timings, not complete selector-phase timings; actual internal
previews now skip authoring context entirely.

After `swift test -c release --filter bindingDigestCacheRequiresExactSourceAndCompilerEvidence`
(enabling the internal test interface), link the script against the TestImpact and
SwiftSyntax object files from the executable's `Objects.LinkFileList`, excluding
`SwiftTestImpactCLI.build` objects. For the standard arm64 SwiftPM layout:

```sh
rg -v '/SwiftTestImpactCLI.build/' \
  .build/arm64-apple-macosx/release/swift-test-impact.product/Objects.LinkFileList \
  > /tmp/helper-binding-objects.rsp
xcrun swiftc -O -I .build/arm64-apple-macosx/release/Modules \
  -I .build/checkouts/swift-syntax/Sources/_SwiftSyntaxCShims/include \
  Scripts/HelperBindingDigestBenchmark.swift @/tmp/helper-binding-objects.rsp \
  -o /tmp/helper-binding-benchmark
/usr/bin/time -l /tmp/helper-binding-benchmark GRAPH REPORT GIT_ROOT
```

## Measured results (2026-11-01)

A serial, single-pair release comparison on the same host used the merged #85
code as baseline (the local `81c3d69` executable, identical source tree to
`9fc8140`). Both executables used the local Xcode 26.6 toolchain; the preserved
app capture was produced with Xcode 27.1. An earlier baseline run overlapping a
package build was excluded from these timing results. These are observations,
not statistical estimates or fresh app-build timings.

| Preserved consumer capture | Baseline wall | Updated wall | Baseline CPU user | Updated CPU user | Baseline peak RSS | Updated peak RSS |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| #293 / 40058859478 | 111.25 s | 73.56 s | 81.71 s | 44.09 s | 1,534 MB | 1,484 MB |
| #299 / 40159996488 | 113.17 s | 80.77 s | 76.71 s | 44.46 s | 1,442 MB | 1,446 MB |

Saved selection, including Git reads/parsing, the primary query, its independent
scope and report serialization, was approximately 34% / 29% faster. Peak RSS was
roughly unchanged or lower. Darwin's separate peak-footprint values were
1,429 → 1,403 MB and 1,365 → 1,364 MB, respectively (decimal MB throughout).

The isolated #293 digest workload had 263 source/revision candidates:

| Context-sized pass | Original digest algorithm | Shared cache |
| --- | ---: | ---: |
| Primary | 8.580 s | 3.998 s |
| Independent scope | 8.610 s | 0.013 s |
| Preview-sized repeat | 8.638 s | 0.012 s |

All digest outputs matched exactly. Only 134 distinct snapshots and 14,103
compiler nodes were hashed across the three cached passes; later passes added
no computations. The actual selector does not execute the final preview-sized
context pass at all. This microbenchmark isolates digest generation and does
not claim those rows measure complete selection phases.

The full/scoped #293 reports retained all 1,972 selected IDs; the #299 reports
retained all 2,000. Every report field matched the baseline after normalizing
unordered collection encoding, including the 12 / 125 known positive dependency
explanations, review fingerprints, formatting decisions, previews, raw inventories
and uncertainty. Public authoring evidence was not dropped to obtain the speedup.
This equality describes that observed pair, not a guarantee of repeatability:
the subsequent fresh-capture consumer check at `9477981` reproduced unstable
full-diff declaration fallback labels for #293, including between executions of
the same binary ([#89](https://github.com/twodayslate/SwiftTestSelection/issues/89)).
Selected IDs, positive dependencies and the independent scope were unchanged.
See [diagnostic reproducibility validation](HeadOnlyDiagnosticDeterminism.md)
for the correction and repeated-process checks.

## Exact private-State diagnostic

The preserved #293 formatting-control graph and its 219 hypothetical binding
records were replayed in the independent regression-support scope. The whole PR
has unrelated source uncertainty, so it is not substituted for this scope.

For this diagnostic only, the head source of
`ChainOfCustodyCore/Data/PairingNoteDocumentStore.swift` was read from the exact
captured Git revision and parsed with the updated parser. All 37 unit keys and
fingerprints matched the capture. Only the new file-restricted-name metadata was
supplied in memory; compiler evidence and every existing source field were
preserved. Historical source metadata came from the normal Git syntax path.
The saved graph's byte digest remained unchanged.

Before: 213 valid records and six invalid `SwiftUI.State` namesake rejections.
After: all 219 records were valid and discharged in the scope. Selected IDs
remained exactly 1,972 total / 394 UI, and all 12 known positive dependency
explanations survived. Other macro/effect uncertainty still prevents narrowing.
These records are hypothetical diagnostic declarations, not approved or adopted
consumer policy. Normal adoption requires a capture with the new visibility
metadata; older graphs remain conservative.

All 552 serial release tests passed in 363.526 seconds. The eight focused binding
review/build-evidence tests also passed, including the two new cache/visibility
regressions. `git diff --check` passed.
