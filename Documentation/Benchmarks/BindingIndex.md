# Xcode test binding index benchmark

Measured 2026-10-24 on an Apple M5, 32 GiB RAM, macOS 26.6.1, Xcode 26.6 / Swift 6.3.3. Release build, saved ChainOfCustody graph: 124,506 functions and 1,969 tests. Input fingerprint and raw measurements are in [BindingIndex.json](BindingIndex.json).

| Implementation | Run 1 | Run 2 | Run 3 |
| --- | ---: | ---: | ---: |
| Original full scans | 115.473 s | 115.134 s | 118.980 s |
| Indexed entries and class lifecycle | 0.216 s | 0.202 s | 0.206 s |

The benchmark decodes once, then binds a fresh copy of the same graph for each iteration. Decoding, semantic comparisons and output are outside the timed intervals. The reference implementation is frozen in the test target; both implementations run in the same release executable. Other local Xcode prototype builds overlapped portions of this run, so these are local measurements, not controlled CI throughput guarantees.

Every iteration compares all function fields, dependency edges, uncertainties, test roots, and global/per-test diagnostics against the reference. Identical selector inputs preserve downstream selections. The full suite also covers method edits, shared helpers, inherited lifecycle, mappings and conservative fallbacks. Added parity coverage includes free functions, duplicate names/symbols, empty-region imported declarations, static hooks, initializers/deinitializers, property initializers, inherited methods, parameterized names and unresolved parents.

Current analyzer footprint after the three reference iterations was 501.0, 526.7 and 531.9 MiB; indexed iterations were 538.2 MiB each. Process peak was 970.1 MiB throughout, including graph decoding. This is not an isolated allocation peak for binding: the original/reference graph remains resident for parity verification. The index adds bounded graph-sized storage instead of repeated per-test scans.

Reproduce with a saved graph (not checked in because it contains consumer source):

```sh
IMPACT_BINDING_GRAPH=/absolute/path/graph.json \
IMPACT_BINDING_RESULTS=/tmp/binding.json \
swift test -c release --filter bindingBenchmarkOnSavedGraph
```

The benchmark is opt-in; normal test runs execute the small semantic parity fixture without requiring consumer artifacts.
