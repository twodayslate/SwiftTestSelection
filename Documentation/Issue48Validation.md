# Issue #48: cache-only baseline policy

Source revision `5e11df8` adds `--cached-base-policy require|full-suite`.
Both use the existing cache identity and payload checks and resolve the actual
merge base before any head build. Neither builds the baseline. Explicit
`--full-suite` permits a one-build baseline producer without requiring an older
cache entry. The default policy remains unchanged.

## Validation

The release CLI was built with Xcode 27.0 (27A266a), then copied to a fixed path
so rebuilding the package tests could not change its cache identity mid-run.
All **219 release tests** passed, including real Metal regressions. After
strengthening the missing-cache API assertion, both focused cache-policy tests
passed again. All six Python capture-helper tests passed. Invalid policy values,
missing cache arguments, and policy use in graph mode were rejected by the CLI.

`Scripts/xcode_cached_base_policy_test.py` uses the real Xcode fixture, compiler,
SIL capture helper, simulator enumeration, graph caches, and retained products.
An xcodebuild wrapper records every invocation; the harness distinguishes
settings-only calls from executable builds and asserts exact build counts.
It checks that every executable build writes to the intended head bundle and
that no base enumeration or extraction events occur.

| Case | Executable builds | Result |
| --- | ---: | --- |
| Empty cache, require | 0 | Exit 3, resolved base and reason; no head bundle/report |
| Same-revision full-suite producer | 1 | Reusable baseline, captured SIL, retained products |
| Wrong external context or revision | 0 | Explicit miss before head build |
| Corrupt or evicted baseline | 0 | Explicit miss before head build |
| Advanced target branch, cached actual merge base | 1 | Only edited unit method selected |
| Stacked PR, cached child revision as merge base | 1 | Only edited UI method selected |
| Execute selected unit method | 0 | Verified same retained products; 1 passed |
| Explicit full-coverage miss policy | 1 | All 9 enabled fixture tests selected |
| Execute full fallback | 0 | Verified same retained products; 9 passed |
| Malformed saved report | 0 | Rejected without execution |

Supplemental real CLI probes used Release instead of Debug, a different
destination string, and Xcode 26.6 instead of 27.0. Each returned exit 3 with zero
builds and no head bundle. An unowned cache directory and invalid container path
failed with exit 1 and zero builds. Configuration/destination probes are also
included in the regression harness. Unit tests independently vary all cache
identity fields (including runtime, settings/pins, analyzer and capture identity)
and verify corruption reasons.

The full UI execution was slow because XCTest repeatedly timed out after about
120 seconds while synchronizing with its crash-reporting daemon after passing
test bodies. The final result bundle confirms **9 passed, 0 failed, 0 skipped**;
the targeted unit result confirms **1 passed, 0 failed, 0 skipped**. These timings
are not a performance benchmark. No ChainOfCustody build or full suite was run
for this issue; the executable-build count and product identity checks use the
repository's nine-test fixture.

## Reproduction and evidence

```sh
swift build -c release
python3 Scripts/xcode_cached_base_policy_test.py \
  --tool /path/to/release/swift-test-impact \
  --destination 'platform=iOS Simulator,id=SIMULATOR_UUID' \
  --output /tmp/issue48-integration.json --keep-work
```

[Machine-readable evidence](Issue48Validation.json) includes the analyzer hash,
revisions, per-phase events, miss reasons, exact selections, retained artifact
identities, build counts and result-bundle counts. Local logs and artifacts were
preserved under `/tmp/issue48-*` and the `impact-cached-base-lobpjg0w` temporary
fixture directory. README examples show the producer and retained PR workflows.
