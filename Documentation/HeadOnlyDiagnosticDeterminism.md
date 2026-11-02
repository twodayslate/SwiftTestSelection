# Head-only declaration diagnostic reproducibility

[Issue #89](https://github.com/twodayslate/SwiftTestSelection/issues/89) exposed
dictionary-order dependence in fallback labels for declarations sharing a key
across files. An import removed from one file can share its key with surviving
imports in other changed files. Selecting the first grouped unit made the
diagnostic message, `firstBoundary`, explanations and deduplicated full-run
reasons vary between processes. Selected tests did not change.

The fallback now names the complete sorted set of affected paths. Its regions
are sorted by path, start line and end line, preserving repeated base/head
regions. Single-file labels retain their existing text. Grouping, fingerprints,
selection rules and isolation proofs are unchanged.

## Regression checks

```sh
swift test -c release --filter 'headOnly|HeadOnly|bindingIdentity|bindingDigest'
python3 Scripts/check-head-only-diagnostic-determinism.py
```

The 31 targeted tests passed. The new fixture removes one of three identical
imports while changing a test helper. It varies dictionary insertion order 12
times and checks exact messages, `firstBoundary`, full-run reasons, fallback
explanations and every affected region. All five tests remain selected in the
full comparison, with three positive helper dependencies retained. The
independent helper scope selects only those three consumers; the import-only
scope reports only its own changed file.

The script launches five fresh test processes with Swift hash randomization
enabled. The complete encoded full/helper/import reports were byte-identical
across all processes. It requires a previously built release test binary and
fails if the test does not produce its reports. CI runs the same check with
`--configuration debug` after building its normal test binary.

## Consumer replay

The saved #293 capture from the consumer's `9477981` study uses base
`143c0be82c134d0d07345c29b42136af3d850a7b` and head
`82b91d0c474b287215ff272e5e1afcea12dd2c21`. Reproduction uses the public saved
selection command recorded in that study's
`40058859478/timing-comparison/current-command.json`, replacing only the analyzer
executable and output path. It retains the original formatting declarations,
graph, Git comparison, strict mappings and independent scope file; no
hypothetical binding policy is added.

Two fresh processes produced identical complete reports after normalizing
unordered array encoding. Diagnostics, explanations, full-run reasons and
selected IDs also matched exactly without array normalization. Relative to the
preserved `9477981` report, only the intended declaration labels and region
ordering changed. The full and scoped selections retain 1,972 tests / 394 UI,
all positive dependency paths, all 12 known scoped helper consumers and all raw
uncertainty. The independent scope is equivalent in every report field; the
original graph's SHA-256 is unchanged.

This is a selection replay over preserved compiler evidence, not a fresh app
build or test-body execution. Removed retained products prevent repeating
product verification. The macro/declaration and callback/error-formatting
precision requirements in #83 and #58 remain separate from this diagnostic fix.
