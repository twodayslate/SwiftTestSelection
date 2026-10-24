# SIL extraction performance

The parser reads SIL in 64 KiB chunks, compiles eight immutable parsing regexes
once per process, caches up to 4,096 normalized source paths, and drains
Foundation temporary objects after each chunk. The in-memory API drains every
512 lines and no longer constructs an array of every line. Both Xcode and
SwiftPM analysis use the file API.

Transient input storage scales with the longest line. Retained functions,
dependency edges, source regions, and per-function value tracking still scale
with the graph. Streaming does not impose a fixed memory ceiling on arbitrary
projects or discard graph information to save memory.

## Regression benchmark

On macOS with Swift 6 or later:

```sh
python3 Scripts/benchmark_sil.py --output /tmp/sil-benchmark.json
```

This compiles the production parser sources with `swiftc -O`, generates 8 MiB
and 128 MiB inputs with a constant graph, verifies retained dependencies and
locations, and measures each input in a fresh process with `/usr/bin/time -l`.
It fails above 256 MiB peak RSS/physical footprint or 64 MiB growth between
sizes. Sizes and budgets are configurable using `--sizes-mib`,
`--max-peak-mib`, and `--max-growth-mib`. A 300-second per-input timeout catches
severe throughput regressions. These defaults are regression budgets for the
synthetic input, not memory promises for a real project.

Instrumented temporary copies count actual regex constructor calls and fail
immediately if more than eight are compiled. The shipped library has no counter
or benchmark mode. The regular test suite additionally covers chunk boundaries,
UTF-8, CRLF, oversized lines, final lines without a newline, invalid encoding,
file errors, dispatch tables, and function-value dependency flow.

## Investigation on October 24, 2026

Environment: macOS 26.6.1, Xcode 26.6 (`17F113`), Apple Swift 6.3.3. Measurements
were made on a shared development machine, so elapsed times include contention.
MB below denotes decimal bytes; MiB denotes 1,048,576 bytes.

A 10 MiB synthetic input with one retained function reproduced growth in the
original `f5790bd` parser, without risking a repeat of the reported 53.1 GB run:

| Parser, optimized build | Parsing time | Peak physical footprint | Maximum RSS |
| --- | ---: | ---: | ---: |
| Original | 12.43 s | 2,882,914,824 bytes | 763,232,256 bytes |
| Original with only a per-line autorelease pool | 14.81 s | 29,819,336 bytes | 34,373,632 bytes |
| Streaming, precompiled regexes, path cache, bounded pools | 2.21 s | 2,703,816 bytes | 7,176,192 bytes |

A `heap -s` snapshot after the original parse found 5,509,168 live allocations
(2,823,562,368 bytes), including 211,834 `NSRegularExpression` objects, 211,834 ICU
regex patterns, 211,834 ICU matchers, and 741,424 ICU Unicode sets. `vmmap -summary`
showed a 2.7 GiB physical footprint with most memory compressed. The retained
Swift graph contained one dictionary entry. Draining pools alone removed most
of this growth, supporting temporary-object accumulation as the dominant cause
in this reproducer. This does not attribute every byte of the user's interrupted
53.1 GB project run to the same cause.

The larger regression benchmark, which also exercises dispatch and value flow:

| Input | Parsing time | Regex compilations | Peak physical footprint | Maximum RSS |
| --- | ---: | ---: | ---: | ---: |
| 8 MiB | 5.36 s | 8 | 2,818,504 bytes | 7,274,496 bytes |
| 128 MiB | 74.14 s | 8 | 2,900,424 bytes | 7,225,344 bytes |

## ChainOfCustody combined-plan measurement

An isolated checkout of `twodayslate/ChainOfCustody` at
`20a264ccfab2fafa70b3aed1fe3fd0db6ab14761` had only the UI target's `selectedTests`
restriction removed from `ChainOfCustody.xctestplan`. A second revision changed
one assertion-message string in one UI test. Both were built and enumerated on
an iPhone 17 Pro simulator running iOS 26.2. No test bodies were executed.
The app's normal checkout and CI configuration were not modified.

Both graph operations completed with 1,969 tests: 1,119 unit tests, 457 snapshot
tests, and all 393 UI tests. The base graph contained 124,506 functions, no
extraction/source-parser diagnostics, and no unbound test entry points.

| Release graph run | Elapsed wall time | Analyzer peak physical footprint | `time -l` maximum RSS |
| --- | ---: | ---: | ---: |
| Parser fix, before dispatch-prefix index | 852.39 s (14m 12s) | 1,162,642,824 bytes | 1,746,075,648 bytes |
| Parser fix and dispatch-prefix index, one-method edit | 671.02 s (11m 11s) | 1,161,168,288 bytes | 1,629,585,408 bytes |

These are complete single-revision operations, including build, enumeration,
compiler replay, graph binding, and writing approximately 315 MiB of JSON.
`proc_pid_rusage` independently confirmed the analyzer lifetime peak footprint.
The command's maximum RSS can include compiler children; it is not an aggregate
process-tree budget. Cache state and machine contention differed, so the wall
time difference is not a controlled measurement of the dispatch index alone.

The final release run's per-module parsing measurements:

| Module | SIL size (MiB) | Functions | Parse time | Analyzer footprint after parse (MiB) |
| --- | ---: | ---: | ---: | ---: |
| SnapshotTesting | 20.5 | 2,262 | 3.23 s | 119.7 |
| CloudKitSyncMonitor | 1.5 | 248 | 0.22 s | 119.9 |
| ChainOfCustodyCore | 245.3 | 23,868 | 38.70 s | 142.7 |
| SimpleCommon | 4.3 | 634 | 0.63 s | 152.8 |
| ChainOfCustodyTests | 493.1 | 45,960 | 72.88 s | 211.6 |
| ShareExtension | 6.6 | 742 | 1.01 s | 225.1 |
| MessagesExtension | 22.9 | 1,612 | 3.80 s | 226.1 |
| ChainOfCustody | 321.2 | 28,075 | 48.87 s | 255.3 |
| ChainOfCustodySnapshotTests | 168.3 | 16,211 | 25.01 s | 298.4 |
| ChainOfCustodyUITests | 105.2 | 10,072 | 16.32 s | 308.9 |

SIL sizes differ from the original report; debug source paths and build inputs
contribute to file size. Binding finished in 106.85 seconds at 370.5 MiB. JSON
serialization accounts for the larger end-to-end peak and remains a possible
future optimization. The index preserves the old dispatch-prefix predicate;
existing method/lifecycle binding still performs repeated scans.

Validation also compared old/new parser results on complete-function excerpts
from five real modules (including a roughly 6.7 MiB test function), with matching
names, regions, dependencies, dispatch data, and uncertainty flags. All 48 package
tests and the eight SwiftPM integration checks passed.

## Individual-method validation before the precision fix

The changed method was:

```text
ChainOfCustodyUITests/CalendarPermissionUITests/testHolderCanCreateEventWhenEventsAreFilteredOut()
```

Only its assertion-message string changed. The two independently built graph
outputs were compared using `GitChanges.read` and `XcodeFineSelector.select`, the
same selection engine called by the CLI. Reusing the saved base graph avoided
another baseline build. Both graph builds used the same isolated source directory;
this was a library-engine validation, not an additional `select --head` export run.

Expected: one `-only-testing:` identifier. Actual: **1,969 of 1,969 tests selected**.
The selection comparison itself took 110.70 seconds and peaked at 1,640,269,504
bytes of physical footprint. The report exposed two distinct issues:

- 481 imported symbols changed their recorded module attribution as compiler
  invocation order changed. For example, the same `_finalizeUninitializedArray`
  symbol was attributed to CloudKitSyncMonitor in one graph and SnapshotTesting
  in the other. At `30b1042`, edge comparison used this attribution, so unchanged
  declarations appeared affected. The report assigned dependency reasons to 1,967 tests.
- 1,788 tests also received `unresolved_dependency` fallbacks for reachable global
  state, opaque calls, or unresolved dispatch. Holding the compiler graph constant
  while changing only the source snapshot isolated this policy: one test had a
  dependency reason, but fallbacks still expanded the selection to 1,788 tests.
  Missing UI mappings produced diagnostics for the apparent production changes.

Reason categories overlap; these counts must not be added. Both independently
built graphs still had zero extraction/source-parser diagnostics and zero unbound
test entry points. Successful extraction is therefore not sufficient evidence of
selection precision.

The performance change alone preserved the conservative fallback policy and did
not pass the individual-method acceptance case. The separate precision fix below
addresses the two causes identified by this measurement.
No full-suite accuracy comparison or test-body execution was performed, and no
application CI configuration was changed.

## Precision fix: replaying the real graphs

The updated selector compares dependency symbols by compiler ID, independent of
which importing module emitted their SIL. Only source-owned definitions participate
in implementation-edge comparisons. Private symbols whose IDs change after a file
move can pair by a unique module/name match on both sides; different overload IDs
remain distinct.

When every changed declaration on both sides resolves unambiguously to a discovered
test entry point, selection follows the compiled paths to those entries without
expanding for unrelated runtime uncertainty. Explicit callers and inherited test
entries remain selected. Helpers, lifecycle/state changes, production changes,
ambiguous line locations, and mixed edits retain conservative runtime fallbacks.
Unbound tests, unknown inheritance, and extraction diagnostics also retain their
fallbacks. This policy assumes independent tests; reflective cross-test calls and
order-dependent side effects require full-suite validation.

Replaying the same independently compiled base/head graphs now selects **1 of
1,969 tests**, with the exact argument:

```text
-only-testing:ChainOfCustodyUITests/CalendarPermissionUITests/testHolderCanCreateEventWhenEventsAreFilteredOut()
```

The report has dependency explanations for both revisions, no selection diagnostics,
and no full-run reasons. It still explicitly reports all 393 UI tests as unmapped
in `uiMappingCoverage`; test-entry edits do not require app-feature mappings.
Production changes continue to require those mappings or conservative fallback.

The comparison uses the release library with `GitChanges.read` and
`XcodeFineSelector.select`, against saved graphs from the completed extraction runs.
The final release replay, including JSON decoding and report writing, took **94.54
seconds** with **1,595,803,352 bytes peak physical footprint** and 1,410,514,944 bytes
maximum RSS (`/usr/bin/time -l`). These are graph-comparison measurements, not a
new compiler-extraction run.

It does not rebuild the app or execute its test bodies. No application CI settings
were changed. This verifies the reported one-method precision case, not general
selection accuracy against a full ChainOfCustody run.

Validation also passed all 59 package tests, eight SwiftPM integration checks, and
the full Xcode acceptance script on the iOS 26.2 simulator. The Xcode checks include
actual execution of one selected method while a deliberately failing neighbor is
skipped, additions/deletions, helper/lifecycle/inheritance propagation, production
mappings, trivia and file moves, missing mappings, explicit-head/merge-base
execution, workspace discovery, and a healthy full run of all nine fixture tests.
The package regressions specifically cover imported-symbol drift, serialized
imported bodies, overload identity, private-symbol moves, runtime uncertainty,
explicit callers of tests, inherited entries, and unresolved or ambiguous inputs.

## Measuring a project

```sh
swift build -c release
/usr/bin/time -l .build/release/swift-test-impact graph \
  --project /path/to/App.xcodeproj --scheme App --test-plan AllTests \
  --destination 'platform=iOS Simulator,id=SIMULATOR_UUID' \
  --format json --output /tmp/app-graph.json 2>/tmp/app-graph-measurements.log
```

Each Xcode module reports compiler-replay time, SIL parsing time, SIL bytes,
function count, current analyzer physical footprint, and the analyzer's lifetime
peak footprint. Progress goes to stderr, leaving JSON output clean. The memory
figures on these progress lines describe the analyzer process, not concurrent
compiler/Xcode children or aggregate machine usage. Compiler build memory must
be budgeted separately. RSS can understate memory pressure when macOS compresses
pages; report physical footprint as well.

Graph completion alone does not establish selection accuracy. Review diagnostics,
verify individual-method edits using both revisions, and compare selections with
full test runs before enabling a CI gate. App-to-XCUITest feature mappings remain
necessary for production changes crossing the process boundary.
