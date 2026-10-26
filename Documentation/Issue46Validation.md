# Issue #46: standard Xcode tasks and documentation precision

The fix recognizes `copypng` and `xcstringstool` at their exact locations in the
active compiler's Xcode installation. External `metal`/`metallib` executables must
match a clean-environment lookup using that Xcode and the explicit Apple Metal
toolchain identifier. A matching basename or arbitrary path underneath Developer
is insufficient.

Metal compilation also requires the emitted `-MT dependencies` makefile rule.
Its transitive inputs participate in documentation exclusions, and the dependency
file is fingerprinted with the active build metadata. Missing or unsupported
Metal dependency evidence remains conservative. Unknown scripts and direct,
directory, argument, or included Markdown inputs are covered by regression tests.
The graph records `documentationBlockers`, and selection emits
`documentation_exclusion_blocked` with the responsible task/input.

## Release tests

All **213 tests** pass with both Xcode 26.6 and Xcode 27.0. The Xcode 27 run also
uses `IMPACT_METAL_DEVELOPER=/Applications/Xcode-27.0.0.app/Contents/Developer` to
exercise the installed external Apple Metal toolchain. The deterministic task
matrix covers four executables across eight scenarios, including unavailable
Metal resolution and executables from another location/Xcode. Additional tests
cover Metal includes, missing/malformed dependency files, dependency-file mutation,
escaped paths, scalar/list manifest dependency formats, archive compatibility and
fallback diagnostics. The real retained manifest is replayed as an additional
check that all three generated boundaries and recovered production roles survive.

## Consumer reproduction

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
