<!-- SPDX-FileCopyrightText: 2026 Zachary Gorak -->
<!-- SPDX-License-Identifier: AGPL-3.0-only -->

# Indexed selection, compact artifacts and sealed capture

Measured on Apple M5 / 32 GiB, macOS 26.6.1, release Swift 6.3.3 (Xcode 26.6).
The consumer is the saved ChainOfCustody graph used in the build-time capture
investigation: 124,013 functions and 2,000 enumerated tests. These measurements
exclude Xcode builds, enumeration and compiler extraction. The probe changes one
source-unit fingerprint at a time in a copy of the same graph. It measures the
selector, not the behavior of executing modified production code.

`ReferenceXcodeFineSelector` freezes the implementation from `1990736`. Each of
three scenarios runs both selectors three times, requiring byte-identical sorted
JSON reports (selected IDs, diagnostics, full-run reasons and explanations).
Raw measurements are in [FastSelection.json](FastSelection.json). Local fixture
builds and test development overlapped portions of the run; these are local
measurements, not controlled CI guarantees or estimates of whole-pipeline speedup.

| Changed boundary | Selected | Before median | Indexed median | Speedup |
| --- | ---: | ---: | ---: | ---: |
| `SharingPeopleUITests.swift` | 1 | 70.83 s | 2.35 s | 30.2× |
| `SharingPeopleUITestView.swift` | 1819 | 91.44 s | 1.78 s | 51.3× |
| `NoteCommentsTests.swift` | 1 | 70.32 s | 2.30 s | 30.6× |

The combined reference/indexed benchmark process peaked at 990.7 MiB RSS.
This peak includes loading the 318.5 MiB JSON input and both algorithms; it is
not a separate memory attribution for either selector. A separate indexed-only
process running the same nine selections peaked at 992.5 MiB RSS, including
JSON loading and the resident graph.

Reproduce with a saved consumer graph from the investigation:

```bash
swift test -c release --filter selectionBenchmark
/usr/bin/time -l env \
  IMPACT_SELECTION_BENCHMARK=/path/to/consumer-graph.json \
  IMPACT_SELECTION_OUTPUT=/tmp/selection.json \
  swift test -c release --skip-build --filter selectionBenchmark
```

Set `IMPACT_SELECTION_ENGINE=indexed` for a separate indexed-only process memory
measurement. `IMPACT_ARCHIVE_BENCHMARK` and `IMPACT_ARCHIVE_OUTPUT` similarly enable
`compactArchiveBenchmark`, reporting byte sizes, encoding/decoding time and the
process peak footprint. Archive decoding constructs the public graph representation;
the selector constructs its dense adjacency/source indexes once per revision.

## Compact archive result

A single release measurement of this same graph reduced storage from 318.5 MiB
JSON to 116.1 MiB binary (**63.5% smaller**). In-memory decoding took 1.32 seconds
for JSON and 0.65 seconds for binary; binary encoding took 0.98 seconds. Integer
records use a contiguous little-endian buffer, avoiding boxed-integer decoding.
These decode timings exclude reading bytes from disk. The archive benchmark holds
the original and decoded graphs and both data buffers simultaneously; its process
peak was 1,396 MiB physical footprint, not a standalone decoder memory estimate.

## Capture and precision validation

- Xcode 27 / Swift 6.4 fixture build: supplementary SIL for all three modules,
  nine enumerated tests, and no compiler replay for complete captures.
- Reanalysis of that exact build: discovery cache hit; no enumeration, extraction
  or binding. Product/source/capture validation still runs on every hit.
- A committed edit to `SharingUITests.testShareSheet()` followed by incremental
  build: fresh UI-module capture, explicit replay of the other two modules, and
  exactly `CheckoutUITests/SharingUITests/testShareSheet()` selected. No selection
  fallbacks or diagnostics. Base and head graphs used binary interchange.
- The real captured `ChainOfCustodyApp.init()` fragment now resolves equality to
  the single `UIApplication.State` conformance instead of all 17 equality
  conformances in that fragment. The previous whole-graph merge expanded that
  declaration to still more modules. Unknown concrete tables and generic forms
  keep conservative candidate/fallback behavior.
- Real compiler integration on Swift 6.3.3 verifies identical object machine code
  with/without supplementary SIL, successful fixture execution, unchanged output
  maps, literal file-list paths, whole-module and per-primary capture.

These checks do not establish full-suite selection accuracy for the consumer or
universal equivalence between normal-build SIL and whole-module replay. Keep the
capture mode opt-in and validate against full runs before enabling a CI gate.
Incremental reuse deliberately favors correctness: after a source-tree change,
unchanged modules without fresh capture may replay even if their old files remain.
