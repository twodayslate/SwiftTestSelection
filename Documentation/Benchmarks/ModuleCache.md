# Module fragment reuse

The cache stores parsed functions and dispatch tables before test binding and
cross-module dispatch resolution. A hit avoids compiler replay and parsing for
that module. It does not avoid the new revision's executable build, test
enumeration, source analysis, binding or selection. Existing whole-revision hits
already bypass those stages and remain unchanged.

## Validation

The package regression matrix compares cached and fresh complete graphs,
selected identifiers, `-only-testing:` arguments, explanations and fallbacks
after method edits, additions, deletions, moves, shared API changes, policy
changes, external-context changes, stacked heads and unavailable bases.
Separate tests cover generated inputs, compiler settings, headers, external
modules, availability probes, corruption and mutation during extraction.

An independently built three-module Xcode fixture reused all three fragments
after moving both its source and DerivedData directories. Its complete function
graph matched fresh extraction, including every region, dependency, dynamic
declaration, resolved declaration and uncertainty. This is necessary evidence:
hashing generated PCM/Swift-module binaries alone missed across these builds.
The fixture's dependency-input inventory was also validated with Xcode 26.6
(Swift 6.3.3); all three modules used scanner inputs without a binary fallback.

A fresh dependency scan instead hashes compiler-reported headers, interfaces,
module maps, candidate binaries, macro binaries and compiler options. Only
generated output paths and context hashes are replaced by module identities;
source bytes are never rewritten. Known root symlink aliases are normalized,
as are destinations in supported Clang header maps. Header-map bucket order
and key spelling remain intact, and unsupported formats retain exact byte
identities. Scanner dependency-edge ordering is canonicalized; compiler argv
and source order are preserved. The header-map format follows
[Clang's definition](https://github.com/llvm/llvm-project/blob/main/clang/include/clang/Lex/HeaderMapTypes.h).
Unsupported scans retain exact binary hashes,
which may miss across build directories. The consumer's bridging-header UI-test
target uses this fallback: Swift 6.4's standalone scanner crashed resolving a
Foundation overlay through its bridging PCH. Normal SIL replay still succeeds.

## Measurement method

Release build on Apple M5, 32 GiB RAM, macOS 26.6.1, Xcode 27.0 / Swift 6.4.
Consumer baseline: ChainOfCustody `1f0e37b69458200227c584d9a4563b5391948cdf`,
ten Swift modules and the combined 2,000-test plan. The separate parser and
binding optimizations are not included in these cache timings.

The benchmark uses an exported temporary source tree. Each method-edit variant
wraps one existing string expression in `String(...)`; each shared-dependency
variant adds a public function to `ChainOfCustodyCore`. These are benchmark
variants, not reviewed commits or execution-authorizing artifacts. Each variant
is normally built for testing before analysis. No consumer test bodies run.
Build times are separate from extraction times, and executable-product
fingerprints are checked before and after every extraction.

Extraction time includes fragment lookup, compiler/parser misses, deterministic
merge, input validation and publication. The opt-in probe additionally performs
an initial identity inspection, so its runner wall time is higher. These are
component measurements, not total build-plus-selection latency. Some local
validation overlapped portions of these runs; these are not controlled CI measurements.

The repeated matrix preceded the final staging-recovery, scanner-schema,
working-directory, root-alias, header-map and scanner-edge-order changes.
It also used the generic SwiftPM helper identity in the benchmark harness;
the production CLI already fingerprints its actual executable. The harness
now fingerprints the test bundle containing the implementation. Final release
validation uses one fixed binary and a fresh cache after these changes.

## Repeated results

| Case | Extraction seconds | Separate build seconds | Module hits / misses |
| --- | ---: | ---: | ---: |
| Cold cache population | 416.59 | Already built | 0 / 10 |
| Identical head, runs 1 / 2 | 21.51 / 22.47 | Already built | 10 / 0 |
| Method edits, variants 1 / 2 | 199.10 / 201.79 | 13.93 / 9.80 | 9 / 1 |
| Fresh extraction of method variant 1 | 391.40 | Already built | Cache disabled |
| Shared-core edits, variants 1 / 2 | 382.58 / 399.27 | 102.74 / 23.01 | 4 / 6 |
| Fresh extraction of shared variant 1 | 384.45 | Already built | Cache disabled |
| Restored baseline | 21.78 | 103.28 | 10 / 0 |

Each changed variant also received a warm rerun (21.99–22.38 seconds), with all
ten modules reused and the same complete function graph. The method edit's
cached graph exactly matched its fresh comparison. Both shared variants had
the same graph, which also exactly matched fresh extraction. The restored
baseline reproduced the original 124,013-function graph; shared variants added
one function. All 248 product files/symlinks were unchanged by every extraction.

The isolated method edit avoided nine compiler/parser jobs and roughly halved
extraction time. Shared-core changes invalidated Core, the app, both extensions,
unit tests and snapshot tests: there was **no material speedup** in these runs.
Reuse is deliberately conservative when dependencies change. Identical-head
numbers isolate fragment loading; existing whole-revision hits already skip
this work and should remain preferable.

Three additional cache-disabled baseline runs are recorded with [the parallel
extraction experiment](https://github.com/twodayslate/SwiftTestSelection/blob/4254ed43095e87b5d7a8d06e2177ec4d62b4756c/Documentation/Benchmarks/ParallelExtraction.json).
Cold population includes validation and publication overhead that those runs
exclude. See [raw results and per-module progress](ModuleCache.json).

A one-second sample during the first shared-core extraction reported a
`982.0M` peak physical footprint for the analyzer at that point. It excludes
compiler children and any later peaks; it is not an aggregate whole-run memory
measurement.

## Final release relocation check

After the final safeguards, release commit `bae677a` passed all 94 package tests.
One fixed implementation populated a new empty cache from independently built
copy B, reused it from copy A, and revisited B. Both source and DerivedData roots
differ. The separate clean build of B took 115.94 seconds.

| Case | Extraction seconds | Runner wall seconds | Module hits / misses |
| --- | ---: | ---: | ---: |
| B, empty cache | 404.91 | 420.54 | 0 / 10 |
| A, relocated inputs | 39.33 | 54.59 | 9 / 1 |
| B, warm rerun | 21.47 | 37.03 | 10 / 0 |

Every run reproduced its own fresh 124,013-function graph exactly and preserved
all 248 executable-product files/symlinks. The bridging-header UI-test module
was the sole relocated miss; its exact binary fallback is intentional. The
cold run's progress samples reported an analyzer peak physical footprint of
1,070.0 MiB; this excludes compiler children and later serialization peaks.
These timings validate reuse after relocation, not a change to the existing
whole-revision cache hit path.

The builds list the first two modules in different orders. Imported/synthetic
symbol ownership therefore makes the merged A and B graph digests differ.
Each result is compared with fresh extraction of the **same build**, preserving
its original merge order. Separately, all ten raw fragments were compared field
by field across builds: no function or dispatch-table differences were found.
Do not sort module merges to force aggregate equality across different logs.

## Reproduce

Build the analyzer's release tests once, then prepare immutable successful Xcode
builds and full build logs for baseline and changed revisions. A config is a JSON
object of string values:

```json
{
  "root": "/build/source",
  "derived": "/build/DerivedData",
  "workspace": "/build",
  "log": "/build/build.log",
  "reference": "/build/reference-graph.json",
  "cache": "/cache/module-experiment",
  "context": "locked-external-inputs",
  "revision": "the-commit-or-benchmark-variant",
  "mode": "cached"
}
```

The reference graph supplies target ownership. Use a new cache for a cold run,
the same cache for compatible changed heads, and `mode: fresh` to disable
fragment reuse. `mode: identities` only inspects keys. Keep the analyzer binary,
external context, toolchain and inputs fixed across compared runs. An optional
`inspectInputs` directory records hashed identity components per module for
investigating misses; it does not contain source contents.

```sh
swift test -c release --scratch-path /tmp/impact-cache-build
python3 Scripts/benchmark_module_cache.py \
  --scratch-path /tmp/impact-cache-build \
  --output /tmp/impact-cache-results \
  cold.json identical-head.json changed-head.json shared-dependency.json
```

The runner never changes consumer files or builds/runs consumer products.
Prepare each input snapshot independently; repeat configurations and fresh
caches explicitly. Compare complete semantic digests with fresh extraction
before accepting timing improvements.
