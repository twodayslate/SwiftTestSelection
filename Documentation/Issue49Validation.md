# Issue #49: head-only selection without historical artifacts

Implementation: `e9477cb`. `--head-only` has its own native source comparison and
supported-change model. It never substitutes the head for a base compiler graph
or invokes the two-graph selector with a missing baseline. The committed source
at the actual merge base supplies syntax and policy only. Compiler dependencies,
ownership, test inventory and executable products come from one head capture.

The mode is independent of `--cached-base-policy` (#48). It needs no persistent
cache, baseline producer, saved graph/SIL or historical products. Structural and
uncertain changes explicitly broaden selection; they never cause a base build.

## Automated regression coverage

- All **232 release Swift tests passed**, including the existing selection,
  capture/product verification, module-cache and generated-input tests.
- All **six Python capture-helper tests passed**.
- Head-only regressions cover edited methods, deleted body lines, shared helpers,
  lifecycle consumers, additions/deletions/renames, signatures/defaults,
  inheritance, conditional compilation, global state, unsafe attributes and
  enclosing macros, empty/comment-only Swift files, raw strings/regex/operators,
  file-location semantics, hostless/app-hosted tests, opaque runtime fallbacks,
  UI boundaries and shared feature dependencies, unresolved mappings/build inputs,
  actual Git blob reads and early API rejection of invalid modes.

`Scripts/xcode_head_only_test.py` creates a fresh fixture Git repository and
separate retained directories. An xcodebuild wrapper counts executable builds
separately from settings inspection. The script asserts one head build per
selection, zero base build/enumeration/extraction, correct actual merge bases,
complete enabled head inventories and exact retained xctestrun reuse.

| Fresh fixture case | Selection | Builds |
| --- | --- | ---: |
| Edited unit method, advanced target branch | 1/9 | 1 |
| Same method plus opted-in Markdown and comments | Same 1/9 | 1 |
| Stacked PR relative to its actual parent | Edited UI method, 1/9 | 1 |
| Production body edit | 8/9, including hosted-unit and unmapped-UI fallbacks | 1 |
| Added test | Full enabled inventory, 10/10 | 1 |
| Comment-only edit | 0/9 | 1 |

The initial fixture run passed selected-method, mixed-method, production and
full-fallback execution (1, 1, 8 and 10 tests respectively), all with **zero
additional builds**. Empty execution launched no tests. The final CLI repeated every selection/execution case. Corrected graph/product
corruption probes ran separately against its completed full-fallback bundle;
malformed-report rejection was also checked. Capture failures are tested before publication
using the separate retained-capture failure harness (20 scenarios, including
five head-only cases). Execution trusts the sealed graph and verified products;
it does not reread unused SIL input metadata after publication. The evidence JSON distinguishes both runs and
records their analyzer hashes.

## Consumer validation and limits

Consumer: ChainOfCustody, actual base
`9a15c166a12f494ce84d9a90dcd082b4942b70ea` and method-only head
`855afd0056811ed7ba86574b1394b30ea473bebf`. The enabled inventory contains 1,972 tests.
Each successful fresh selection asserts one executable head build and no baseline
compiler work. The method-only selection chose exactly:

```
ChainOfCustodyUITests/PairingNotesMediaUITests/testBackButtonDismissesMediaPreviewToItsListBlock()
```

The selected method passed using its exact retained products, with zero rebuilds.
The method selection took 414.66 seconds and execution took 302.13 seconds on this
host. XCTest logs show roughly 19 seconds in the test body, with substantial runner
startup/teardown overhead. These are local observations, not a promised speedup.

A simultaneous mixed-diff enumeration lost its XCTest runner/testmanagerd
connection. It failed closed: no report or completed bundle was published. Keep
this failed attempt in the evidence; it is not a successful selection. Subsequent
consumer attempts are serialized after the full hostless-target control.

The hostless control requested all 1,119 identifiers in `ChainOfCustodyTests`,
using the method capture without rebuilding. It returned exit 65: the result
bundle reported **811 passed and one timed-out test**,
`PairingNoteLinkTests/timeoutAndCancellationDoNotWaitForUnresponsiveSync(cancel:)`.
It is not a passing full-suite control (812 results, not all 1,119 requested
identifiers). Test execution had ended, but Xcode then spent over six minutes
collecting simulator diagnostics; only that `simctl diagnose` child was stopped
to allow the result bundle to finish. The recorded elapsed time includes this
failed diagnostic collection. No simulator/test runner was killed to turn a
failure into a pass.

An independent two-graph diagnostic used the earlier compiled base graph and the
fresh head. It selected 1,972/1,972 because generated-build evidence differed for
ChainOfCustody, ChainOfCustodyCore and MessagesExtension. No evidence was rewritten
to force parity. This comparison is diagnostic, not a correctness oracle or a
matched-environment precision benchmark. Head-only mode compares Git source under
the head build environment; external toolchain/environment changes require an
explicit full run.

The first method capture binary preceded the final conservative enclosing-macro
checks. Final native source metadata and selection replayed against that same
sealed compiler capture selected the identical method, with no diagnostics.
The mixed retry and production capture used the final CLI, whose hash matches
the final fixture matrix. Production replay also matched its fresh selection.

The mixed retry (`b4a7751934d5c185e750ae1850586c249d1277f5`) selected the same
**1/1,972** method, ignored `AGENTS.md`, and passed exact retained execution.
The production probe changed only `distance * 0.55` to `distance * 0.5501` inside
`NoteInspectorDetentInteraction.rubberBandedOffset` in
`ChainOfCustody/Features/Notes/NoteInspectorDetent.swift`. Its local validation
head was `ba92d14c1a3d1cee1154dd7b51589b17647def56`.

Production selection was **1,697/1,972**: 1,060 unit tests, 459 snapshot tests and
178 UI tests. Its 1,506 per-test opaque-runtime diagnostics and one app-host target
fallback explain the breadth. No base-source import contract was used to exempt
those tests. The related mapped UI test
`PairingNotesMediaUITests/testDownwardSwipesStopAtDetentAndCanInterruptItsSnap()`
was included and passed on the exact retained production products, without a
rebuild. This was a one-test production probe, not execution of all 1,697 tests.

| Fresh consumer case | Head build | Enumeration | Extraction | Git syntax + selection | Analysis elapsed | Retained execution |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Method only | 160.64 s | 129.16 s | 87.71 s | 0.85 s | 414.66 s | 302.13 s, 1 passed |
| Method + Markdown retry | 198.90 s | 121.27 s | 100.26 s | 0.93 s | 484.17 s | 113.54 s, 1 passed |
| Production body | 137.27 s | 71.57 s | 84.58 s | 0.62 s | 328.96 s | 146.92 s, 1-test probe passed |

Each row performed **one executable head build**, zero base build/enumeration/
extraction, and zero execution rebuilds. The measured analysis-plus-execution
command sums were 716.80, 597.70 and 475.88 seconds respectively; these exclude
idle gaps between validation commands. Analysis maximum RSS reported by
`/usr/bin/time -l` was 2.23, 1.90 and 2.33 GiB. Retained bundles occupied about
3.17, 3.20 and 3.18 GiB. Sampled workspace peaks rose from 3.27 to 12.61 GiB as
all captures, failed attempts and result bundles accumulated; that is not the
storage requirement of one isolated CI job.

The production two-graph diagnostic likewise selected 1,972/1,972, including
mismatched generated-input evidence and runtime fallbacks. The raw diagnostic
category counts and example reasons are preserved in the evidence JSON.

## Measurement and reproduction

Release CLI built with Xcode 27.0. Fixture execution uses Xcode 26.6 / iOS 26.2;
consumer execution uses Xcode 27.0 / iOS 27.0. Each case starts with a fresh build
and capture directory and no persistent analysis cache. This shared local host
was **not a clean, idle CI runner**; concurrent activity and simulator startup
make elapsed-time comparisons unsuitable as benchmarks.

The harness records build, extraction, syntax/selection and other phase timings,
execution elapsed time, process maximum RSS and sampled peak workspace disk bytes.
Workspace disk includes retained cases accumulated during that harness run; it
excludes shared Xcode installations, simulator runtimes and global package caches.
One-second disk samples are a lower bound on an instantaneous peak. Consumer
controls are separate from each selection's one-build count. The full consumer
UI/snapshot suite is not claimed as passed; validate it on the intended runner
before using selection as a CI gate.

```sh
swift build -c release
python3 Scripts/xcode_head_only_test.py \
  --tool /path/to/release/swift-test-impact \
  --destination 'platform=iOS Simulator,id=SIMULATOR_UUID' \
  --output /tmp/head-only-measurements.json --execute --keep-work
```

An optional `headOnlyTwoGraphDiagnosticReplay` test accepts
`IMPACT_HEAD_ONLY_COMPARISON=/path/to/config.json`. Required JSON keys are `root`,
`base`, `head`, `baseGraph`, `headGraph`, `output`; optional `headOnlyReport` also
refreshes source metadata and verifies final head-only selection against the
original report. This is a validation tool, not a baseline prerequisite.

[Machine-readable measurements](Issue49Validation.json) record observed outcomes,
phase timings, revisions, build counts and scope of the controls.
