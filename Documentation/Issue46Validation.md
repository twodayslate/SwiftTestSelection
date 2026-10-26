# Issue #46: standard Xcode tasks and documentation precision

The fix recognizes `copypng` and `xcstringstool` at their exact locations in the
active compiler's Xcode installation. External `metal`/`metallib` executables must
match a clean-environment lookup using that Xcode and the explicit Apple Metal
toolchain identifier. A matching basename or arbitrary path underneath Developer
is insufficient.

Metal compilation also requires the emitted `-MT dependencies` makefile rule
and compiler arguments that include system headers in that rule. Xcode's default
`-MMD` alone is insufficient. Tool-managed builds and the capture helper add
`MTL_COMPILER_FLAGS='$(inherited) -Xclang -sys-header-deps'`; imported builds
without complete evidence keep conservative selection. Graphs captured before
`documentationEvidenceVersion: 3` must be regenerated before excluding docs.
Its transitive inputs participate in documentation exclusions, and the dependency
file is fingerprinted with the active build metadata. Missing or unsupported
Metal dependency evidence remains conservative. Unknown scripts and direct,
directory, argument, or included Markdown inputs are covered by regression tests.
The graph records `documentationBlockers`, and selection emits
`documentation_exclusion_blocked` with the responsible task/input.

## Release tests

The initial implementation passed **213 tests** with both Xcode 26.6 and Xcode 27.0. The Xcode 27 run also
uses `IMPACT_METAL_DEVELOPER=/Applications/Xcode-27.0.0.app/Contents/Developer` to
exercise the installed external Apple Metal toolchain. The deterministic task
matrix covers four executables across eight scenarios, including unavailable
Metal resolution and executables from another location/Xcode. Additional tests
cover Metal includes, missing/malformed dependency files, dependency-file mutation,
escaped paths, scalar/list manifest dependency formats, archive compatibility and
fallback diagnostics. The real retained manifest is replayed as an additional
check that all three generated boundaries and recovered production roles survive.

## Consumer reproduction

The results below describe the initial implementation at `5cadc20`. Post-review
validation with complete system-header dependencies is recorded separately below.

ChainOfCustody's normalized historical #293 pair from the issue:

- Base: `9a15c166a12f494ce84d9a90dcd082b4942b70ea`
- Mixed head: `b4a7751934d5c185e750ae1850586c249d1277f5`
- Xcode 27.0, Debug, iPhone 17 Pro simulator, iOS 26.2.
- Full combined plan and the same mapping/location policies in both revisions.
- Nine `copypng`, two `xcstringstool`, and two external Metal tasks in the fresh manifest.

The validation uses a fresh clone and fresh capture/cache directories. Its
method-only counterpart restores `AGENTS.md` to the base version while preserving
the exact Swift change. The counterpart reuses the validated base graph and
builds its new head. Both selections use `--build-time-sil`, `--merge-base`, and
`--retain-build`; `verify-build` checks the completed products. Selected execution
uses the original mixed head's retained graph and products.

```sh
swift-test-impact select --project ChainOfCustody.xcodeproj \
  --scheme ChainOfCustody --test-plan ChainOfCustody --configuration Debug \
  --destination "$DESTINATION" --base "$BASE" --head "$HEAD" --merge-base \
  --build-time-sil "$TOOL/Scripts/capture-build.py" \
  --analysis-cache "$CACHE" --cache-context issue46-locked-historical-inputs-v1 \
  --retain-build "$BUNDLE" --format json --output "$REPORT"

swift-test-impact verify-build --project ChainOfCustody.xcodeproj \
  --scheme ChainOfCustody --test-plan ChainOfCustody --configuration Debug \
  --destination "$DESTINATION" --report "$REPORT" --head-graph "$BUNDLE/head-graph.json"
```

The final mixed capture selects exactly:

```text
-only-testing:ChainOfCustodyUITests/PairingNotesMediaUITests/testBackButtonDismissesMediaPreviewToItsListBlock()
```

It selects **1 / 1,972**, ignores only `AGENTS.md`, and reports **zero selection
and extraction diagnostics**. All 20 base/head module extractions use captured
SIL. The three generated boundaries (`ChainOfCustody`, `ChainOfCustodyCore`, and
`MessagesExtension`) each retain their full input evidence and prove 27 Markdown
files, including `AGENTS.md`, outside build inputs. Recovered roles remain
resolved and `unsupportedSourceInputs` is empty.

The method-only counterpart also selects the same **1 / 1,972**, with no ignored
changes or diagnostics and the same complete generated/role evidence. Its new
head builds with SIL capture; nine module fragments and the base graph are
reused, while the UI module consumes its captured SIL.

The original mixed head then executes through `run --report … --head-graph …`.
The `.xcresult` confirms the exact requested method: **1 passed, 0 failed,
0 skipped** (136.02 seconds in the test body; 175.44 seconds for execution and
verification). Both retained completion manifests and `verify-build` checks pass.

| Selection case | Elapsed | Command maximum RSS | Selected |
| --- | ---: | ---: | ---: |
| mixed | 484.39 s | 2503.7 MiB | 1 / 1,972 |
| method-only | 190.34 s | 2539.1 MiB | 1 / 1,972 |

These are release-build observations under Xcode 27.0 (27A266a), including
builds, enumeration and retained publication. `/usr/bin/time -l` command
measurements are not isolated analyzer benchmarks or simultaneous process-tree
memory sums. Build-evidence processing took 1.08 and 1.20 seconds for the fresh
mixed head/base.

[Machine-readable evidence](Issue46Validation.json) records revisions, commands,
provenance assertions, resource measurements and the executed test node. Local
logs, captures, reports, products and the result bundle are preserved under
`/tmp/issue46-validation-final`. The full 1,972-test consumer suite was not run;
this verifies the reported selection regression and its exact retained execution.


## Post-review: complete Metal system-header dependencies

At analyzer source revision `4cd9ea9`, tool-managed builds and the capture helper
request system-header dependencies without changing shader code generation.
Imports using plain `-MMD`, opaque argument forwarding, or older saved exclusion
evidence remain conservative. The README's existing-build example supplies the
same Metal setting to the build and settings capture.

All **215 release tests pass on Xcode 26.6 and 27.0**, with the installed Metal
integration enabled on both. Six real-compiler cases cover `-isystem` and nested
includes of a `#pragma clang system_header` header under `-MMD`, `-MD`, and
`-MMD -Xclang -sys-header-deps`. Each case changes the included Markdown, checks
that the compiled Metal product changes, and verifies the selector includes the
test instead of ignoring that input. Separate cases cover ambiguous dependency
flags and legacy/unknown documentation evidence versions. The six Python
capture-helper tests also pass.

A fresh consumer capture under `/tmp/pr47-system-header-validation` repeats the
same historical mixed comparison and a newly created method-only counterpart.
Both select the same **1 / 1,972** with **zero diagnostics** and all three generated
boundaries at evidence version 2. Both retained builds pass `verify-build`, and
both have empty unresolved-role and unsupported-input inventories. The actual
Metal compiler commands contain `-Xclang -sys-header-deps` alongside Xcode's
`-MMD`; their emitted dependency files include Metal system headers.

All 20 mixed-comparison module extractions use captured SIL. The method-only
head reuses nine parsed modules, parses its captured UI module, and reuses the
validated base graph. The exact selected UI test executes from the original
mixed head's retained products: **1 passed, 0 failed, 0 skipped**, confirmed in
`.xcresult` (139.01 seconds in the test body; 177.67 seconds including verification
and execution).

| Selection case | Elapsed | Command maximum RSS | Selected |
| --- | ---: | ---: | ---: |
| mixed | 592.07 s | 2565.8 MiB | 1 / 1,972 |
| method-only | 225.56 s | 2580.2 MiB | 1 / 1,972 |

These are complete-command observations, not isolated performance benchmarks;
package validation overlapped part of the mixed capture. The JSON companion's
`postReviewValidation` records the exact analyzer digest, revisions, commands,
versioned boundaries, Metal dependency checks, and result-bundle test node. The
full consumer suite was not executed.


## Follow-up review: overlays and dependency path identity

At analyzer source revision `66c4a1a`, both spaced and joined VFS-overlay options
are rejected. Every parsed Metal dependency must resolve to a readable regular
file. Missing paths, directories, and dangling links keep conservative selection.
Markdown paths containing literal backslashes or newlines cannot be excluded:
Metal can rewrite their spelling, including to the name of a different existing
file. Documentation evidence is now version 3, so earlier exclusions require
recapture.

All **217 release tests pass on Xcode 26.6 and 27.0** with installed Metal tests
enabled. Four real-compiler cases exercise spaced/joined overlays and backslash
paths with and without an existing slash-spelled collision. Each changes the
compiled shader product and verifies selection includes the test, excludes no
changed documentation, and reports `documentation_exclusion_blocked`. Deterministic
tests cover invalid dependency paths, joined flag forms, and version-2 archives.

The same release suites replay the retained mixed build under Xcode 27 and the
retained method-only build under Xcode 26 using `IMPACT_BUILD_EVIDENCE_REPLAY`
and `IMPACT_EXPECT_IGNORED_DOCUMENTATION=AGENTS.md`. Recovery preserves all three
generated boundaries, with no unresolved roles or unsupported inputs. Their
version-3 documentation lists exactly match the previously validated lists.
A documentation-only selection against each recovered graph ignores `AGENTS.md`,
selects no tests, and reports no diagnostics.

These are metadata replays of `/tmp/pr47-system-header-validation/{mixed,method-only}/retained`,
not new consumer builds or UI executions; the preceding fresh-build and exact UI
execution evidence remains recorded above. Existing graph archives were not
modified. The JSON companion's `dependencyPathValidation` records the new source
and binary identities, test counts, and replay assertions.
