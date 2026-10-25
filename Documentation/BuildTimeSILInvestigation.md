# Capturing SIL during the normal Xcode build

This records the original investigation for #11. Opt-in integration is now available
through `Scripts/capture-build.py` and `graph --sil-capture`; see the
[current workflow](../README.md#build-time-sil-capture-opt-in) and
[validation results](Benchmarks/FastSelection.md). The measurements below describe
the prototype. Universal normal-build/replay equivalence remains unproven; keep
capture opt-in and validate against full runs before using it as a CI gate.

## What works

The installed Xcode 26.6 (Swift 6.3.3) and Xcode 27.0 (Swift 6.4) frontends advertise `-sil-output-path` as an additional compilation output. Normal object compilation can retain canonical SIL with source locations. The integration regression compiles a multi-file batch, links and executes it, and compares each object's machine-code section with a normal build. It covers direct calls, escaped function values, protocol dispatch, class dispatch, Objective-C dispatch, global state and an inherited setup method. Both tested toolchains produce identical object machine code and the expected executable result. Other toolchains are not certified by this probe.

The Xcode fixture built app, unit-test and UI-test targets with capture. Its nine enumerated test roots matched replay exactly. Selection matched for all 19 simulated function-body edits, including helpers, inherited lifecycle methods, unit tests and mapped app dependencies. These probes change source-unit fingerprints to compare selector inputs; they do not claim a full behavioral test-suite validation.

## Integration details that matter

- A bare `SWIFT_EXEC` Python filename fails integrated-driver name validation. Merely overriding the frontend path also changes where SwiftDriver discovers resources and `share/swift/features.json`; the first experiment lost ABI-descriptor output. The preparer creates an isolated wrapper layout with links to the selected toolchain's resources. It never modifies the installed toolchain.
- Every frontend job has an exclusive UUID directory. Primary inputs within a batch have separate SIL filenames. Targets and architectures cannot overwrite one another.
- `-sil-output-path` cannot be combined with an existing supplementary output map. The wrapper copies the map and adds `sil` entries, preserving original output destinations.
- Repeating `-sil-output-path` for multiple primaries can be accepted while overwriting the first output with the last primary's SIL. For batches without a map, the prototype moves the observed dependency/diagnostic/constant-value output arguments into an equivalent private per-input map before adding SIL. The regression specifically checks this case.
- Frontend `-filelist` and `-primary-filelist` inputs are expanded as literal newline-separated filenames, preserving spaces, quotes and backslashes. The manifest snapshots ordered sources and primaries relative to the compiler working directory. Source and list hashes are checked again when compilation finishes; later validation uses the snapshot even if temporary lists have been deleted. Missing fingerprints or per-primary outputs fail validation.
- Compiler queries and module-only jobs pass through. Capture adds no optimization, debug, language-version or code-generation flags. The validator only accepts `-Onone -g` captures. Optimized builds can remove or transform code that the existing replay deliberately retains and need separate investigation.
- An initial incomplete manifest is written before compilation; complete manifests record input hashes, output hashes, compiler arguments, elapsed time and compiler-child peak RSS. Missing outputs or changed inputs remain failures. A successful Xcode build alone is insufficient evidence of complete capture.

The resource-layout behavior follows [SwiftDriver's feature discovery](https://github.com/swiftlang/swift-driver/blob/main/Sources/SwiftDriver/Jobs/EmitSupportedFeaturesJob.swift) and [toolchain root lookup](https://github.com/swiftlang/swift-driver/blob/main/Sources/SwiftDriver/ExplicitModuleBuilds/ModuleDependencyScanning.swift). Swift's [compiler debugging documentation](https://github.com/swiftlang/swift/blob/main/docs/DebuggingTheCompiler.md#printing-the-intermediate-representations) describes additional SIL output; installed compiler help is used to check the spelling available on the actual toolchain.

## Reproduce the compiler regression

```sh
python3 Scripts/Experimental/test_capture.py
python3 Scripts/Experimental/test_validate_capture.py
python3 Scripts/Experimental/test_capture_filelists.py
DEVELOPER_DIR=/Applications/Xcode-27.0.0.app/Contents/Developer \
  python3 Scripts/Experimental/test_capture.py
DEVELOPER_DIR=/Applications/Xcode-27.0.0.app/Contents/Developer \
  python3 Scripts/Experimental/test_capture_filelists.py
```

For an isolated Xcode experiment, run `prepare_sil_capture.py --compiler /absolute/path/to/swiftc --output /new/session/path`. Apply the printed environment and append the printed flags to the existing `OTHER_SWIFT_FLAGS`, preserving `$(inherited)`. Capture an unfiltered successful full build-for-testing log. Run `validate_sil_capture.py --capture SESSION/capture --expected-build-log BUILD.log` before attempting a graph comparison. The directory must be new for each build; this prototype has no incremental fragment cache.

The opt-in release test `buildTimeCaptureProbe` reads a JSON configuration from `IMPACT_CAPTURE_PROBE`. Supply `root`, `capture`, `output` and `capturedGraph`. A `reference` path uses a saved XcodeTestGraph; alternatively supply `project`, `scheme`, `plan`, `destination`, `derived`, `log` and `settings` to enumerate the fixture and generate the replay reference. Optional `selectionPaths` is a `|`-separated list of path substrings, and `selectionLimit` limits simulated edits (default 20). `selectionLimitPerFile` distributes a small sample across files. Both limits must be positive. When using a build log captured through the wrapper, retain its `IMPACT_REAL_SWIFTC` environment so replay queries can pass through that wrapper. The reference must have nonempty functions and no extraction errors. The harness reports differences; a passing harness run means the experiment ran, not that its reported differences are acceptable for production.

## Completeness and provenance boundary

A fresh incremental capture does not include unchanged files. The validator compares fragments with the source inventory in an expected full build log and rejects missing, failed, altered or unsupported captures. Its regressions explicitly reject empty incremental captures, changed/missing source, modified SIL and optimized compilation. It does not treat an empty capture as an empty dependency graph.

The comparison harness explicitly strips executable artifact metadata from its experimental output. It cannot authorize execution through the supported saved-graph API.

This is not yet reviewed-head artifact provenance. A supported implementation must tie the fragment inventory and compiler identity to the exact revision and immutable object/test-product manifest already enforced by `XcodeBuildArtifact`. It must validate generated inputs, imported modules, compiler plugins, flags, SDK, architecture and external context before reusing any unchanged fragment. No products from another revision can be substituted. Missing or incompatible capture must produce an explicit diagnostic and fall back to replay or conservative full selection.

## Alternatives

The index store is a plausible source of symbol occurrences, relationships and locations. [IndexStoreDB](https://github.com/swiftlang/indexstore-db) provides indexed access, and the [index-store API](https://github.com/swiftlang/llvm-project/blob/next/clang/include/indexstore/indexstore.h) exposes reference/call/relationship roles. Those APIs alone do not establish equivalent treatment of SIL function-value conversions, indirect execution, global-state uncertainty or dispatch tables. That equivalence was not measured here, so there is no basis for replacing SIL with index-store references as part of this change.

A compiler/plugin integration could emit a compact dependency graph directly and reduce SIL I/O and parsing, but would introduce a separate compiler compatibility surface. Retaining textual SIL reuses the existing conservative parser and is the more concrete next implementation path. Per-module parsed-graph reuse (#8), parser optimization (#9), and indexed test binding (#7) remain relevant even if compiler replay is eliminated.

## Large consumer measurements

ChainOfCustody revision `1f0e37b69458200227c584d9a4563b5391948cdf`, Xcode 27.0 / Swift 6.4, iOS 26.2 simulator, Apple M5 with 32 GiB RAM, macOS 26.6.1. The clean capture completed with 79 frontend jobs, 414 SIL fragments, ten modules and 2,000 enumerated tests. Completeness validation passed against the full build inventory. No test bodies were needed to extract dependencies.

| Measurement | Normal build-for-testing | Build-for-testing plus SIL capture |
| --- | ---: | ---: |
| Elapsed | 125.09 s | 158.56 s |
| Sampled compiler/driver RSS sum peak | 4.69 GiB | 4.93 GiB |
| Additional retained SIL | — | 1,404,070,178 bytes (1.31 GiB) |

This is one local pair with warm SDK/package caches and selection validation overlapping both builds. It is not a controlled CI speedup measurement. `measure_build.py` samples processes whose command lines reference the isolated DerivedData; the RSS sum double-counts shared pages and excludes persistent Xcode services without that path. Actual average sample intervals were 0.38–0.48 seconds. The largest captured compiler job reported 2.17 GiB peak RSS. [Raw measurements](Benchmarks/BuildTimeSIL.json) preserve these limits.

Parsing all captured fragments took 51.97 seconds and binding took 0.23 seconds in a release validation build combining the independently checked #7 and #9 optimizations. A process sample during comparison reported 754.7 MiB physical footprint and 2.0 GiB peak; that peak includes retaining and comparing both full graphs and JSON serialization. Adding the measured build, parse and bind components gives about 211 seconds, **excluding** enumeration, completeness validation and selection. This is not an end-to-end latency measurement and must not be compared directly with the earlier 764.61-second capture or 374.43-second replay measurements from different conditions.

All 417 object `__TEXT.__text` sections matched a normal rebuild at the same source/DerivedData paths. A captured unit test and snapshot test passed. A selected UI test reached its assertions and teardown but the runner stalled; the normal-build control also stalled at teardown, including on a fresh simulator. UI execution remains inconclusive. Machine-code equality is not full product/provenance identity, and neither smoke tests nor synthetic edits replace full-suite validation.

The captured and replay graphs both contained 124,013 functions; no project function was missing and all 2,000 test-root sets matched. Nevertheless, 1,029 source-bearing functions differed: 829 had different dependency edges, 928 differed in dynamic dispatch/resolution/uncertainty fields, 15 had different region sets and eight generated thunks had different owning-module attribution (categories overlap). Fragment union preserves more region/edge information, while canonical SIL and whole-module replay expose different dispatch representations. These differences require deliberate handling, not an assumption of equivalence.

| Simulated function-body edit | Replay selection | Capture selection | Result |
| --- | ---: | ---: | --- |
| `SharingPeopleUITestView.swift:43` | 1,819 | 1,824 | Five additional tests; none omitted |
| `NoteCommentsTests.swift:8` | 1 | 1 | Exact identifier match |
| `SharingPeopleUITests.swift:6` | 1 | 1 | Exact identifier match |

Full-run reasons matched for these probes (none); ordinary per-test conservative diagnostics remain active. The production selection is already broad with replay, and capture broadens it further. Three comparisons took 560.24 seconds, separately from capture/parsing. This exposed repeated per-test dependency walks as another performance concern. The small fixture's 19 comparisons passed, but neither sample proves universal precision or absence of missed tests.

## Recommendation and implementation follow-ups

**Go for an opt-in production implementation after the following gaps are resolved; no-go for replacing replay by default now.** The compiler integration is feasible and normal object code was preserved, but graph counts alone do not prove dependency or selection equivalence.

1. Preserve dispatch precision across SIL stages. Normal-build fragments retain generic witness dispatch that whole-module replay simplifies. For example, `ChainOfCustodyApp.init()` gains `Equatable.==` dispatch, which the current parser resolves to hundreds of unrelated conformances. Investigate concrete type/substitution information before changing the supported extraction path. Keep uncertain dependencies conservative; do not delete edges simply to obtain a smaller selection.
2. Define a versioned capture manifest tied to the existing reviewed-head artifact identity. Bind compiler/toolchain, flags, SDK, architecture, generated sources, imported modules and plugins to the exact products; check them again when selecting/executing. The experimental output deliberately carries no execution provenance.
3. Support incremental completeness through validated fragments for every unchanged primary input. A missing/incompatible fragment must trigger an explicit replay/full-selection fallback. Handle response files, additional supplementary-output shapes, multi-architecture builds, failures and cancellation before supporting arbitrary projects.
4. Reduce repeated graph traversals while preserving selected identifiers, explanations and fallback behavior; validate with broad and narrow edits on the large graph.
5. Validate release-mode end-to-end cost and selections on repeated clean and incremental CI runs, including full test runs and reliable UI execution. The rollout acceptance stays in [ChainOfCustody #298](https://github.com/twodayslate/ChainOfCustody/issues/298); this investigation adds no independent mandatory gate.

The prototype intentionally leaves the supported compiler replay and conservative fallback behavior unchanged. Index-store replacement and compact compiler-emitted graphs remain separate investigations rather than prerequisites for trying additional SIL output.
