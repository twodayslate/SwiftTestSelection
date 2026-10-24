# Bounded module extraction

Six alternating release-mode runs on an Apple M5 with 32 GiB RAM, macOS
26.6.1, Xcode 27.0 / Swift 6.4. Consumer: ChainOfCustody revision
`1f0e37b69458200227c584d9a4563b5391948cdf`, combined 2,000-test plan,
ten Swift modules. Analyzer starts from `ee2fa9c` with this change;
the separate parser and binding optimizations are not included.

| Workers | Run | Extraction seconds | Runner wall seconds | Peak aggregate RSS GiB |
| --- | --- | ---: | ---: | ---: |
| 1 | 1 | 425.79 | 431.52 | 1.74 |
| 2 | 1 | 383.91 | 388.43 | 1.76 |
| 1 | 2 | 394.08 | 398.35 | 1.62 |
| 2 | 2 | 367.46 | 371.94 | 1.48 |
| 1 | 3 | 394.70 | 398.80 | 1.76 |
| 2 | 3 | 364.22 | 368.47 | 1.84 |

Median extraction: 394.70 seconds serial, 367.46 seconds with two workers
(6.9% less elapsed time). Keep **one worker as the default**. Two workers
offer a modest improvement here; this is not evidence for higher concurrency
or a safe memory limit on other projects. The ordered sliding window bounds
both running jobs and retained results, but can leave workers idle behind
a slow earlier module.

All six complete graphs had 124,013 functions and the same digest covering
every node field and dependency. No extraction diagnostics were emitted.
All 248 executable-product files/symlinks retained identical content/targets
through the runs. Unit tests additionally compare serial/concurrent graphs,
diagnostics and selected identifiers with duplicate definitions, cross-module
dispatch, failures, cancellation and temporary-output cleanup.

Memory is the sampled sum of RSS for the SwiftPM runner and its descendants,
including compiler children, at roughly 100 ms intervals. Shared pages are
counted repeatedly; this is **not physical footprint** and can miss short
peaks. Package tests/builds and small fixture builds overlapped portions of
these local measurements. This is not an isolated CI benchmark.

These measurements cover compiler replay, SIL parsing and graph merge.
They exclude the executable build, enumeration, source analysis, binding and
selection. No consumer test bodies ran. See [raw results](ParallelExtraction.json).

## Reproduce

Build unchanged consumer products for testing, retain the complete successful
build log and a reference graph providing source ownership. Create a JSON
configuration with absolute `root`, `derived`, `log`, and `reference` paths.

```sh
swift test -c release --scratch-path /tmp/impact-extraction-build
python3 Scripts/benchmark_xcode_extraction.py \
  --config /path/to/config.json \
  --scratch-path /tmp/impact-extraction-build \
  --output /tmp/impact-extraction-results
```

Use a new output directory and leave that scratch path and all consumer inputs
unchanged during the experiment. The script alternates three runs each with
one and two workers, fails on extraction diagnostics or graph divergence,
and includes runner startup in its separate wall-time measurement.
