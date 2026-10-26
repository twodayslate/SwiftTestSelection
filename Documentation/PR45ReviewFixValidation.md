# PR #45 review fixes

The review fixes preserve the original capture seal through delayed publication,
apply ignored-documentation policy to generated-input comparisons only with
per-file build evidence, include helper stderr in failures, and retain diagnostic
files outside disposable cache work.

## Automated regressions

All 205 package tests pass in release mode with Xcode 26.6 and Xcode 27.0.
They cover changed, added and removed products; changed logs/settings; publication
without a capture seal; documentation-only and mixed changes; added/deleted docs;
one-sided policies; legacy opaque graphs; resource/directory/relative-path inputs;
unknown shell tools; and generator changes. Original tests remain enabled.

The Python capture helper's six tests pass. The CLI failure matrix passes all 15
cases: helper setup failure, explicit helper failure, source mutation,
missing products and process-group cancellation, each with a retained bundle,
an explicit analysis cache and an ephemeral analysis cache. It checks the
reported diagnostic directory after exit, combined helper stderr, source-export
manifest and available build log/settings, plus absence of executable completion.

```sh
python3 Scripts/capture_build_test.py
python3 Scripts/xcode_capture_retained_failure_test.py --tool "$RELEASE_TOOL"
```

## Fresh Xcode fixture

The build-only regression uses the resource-bearing local package, app, extension,
hosted tests, hostless tests and UI tests in `Fixtures/XcodeGeneratedInputs`.
It runs with Xcode 27.0 on the iPhone 17 Pro iOS 26.2 simulator, using a release
analyzer built with Xcode 26.6. Both the standalone Markdown file and bundled
Markdown resource match `ignoredDocumentation` patterns in both revisions.

```sh
python3 Scripts/xcode_capture_review_regression_test.py \
  --tool "$RELEASE_TOOL" --capture-helper Scripts/capture-build.py \
  --destination "$DESTINATION" --output "$RESULTS_JSON"
```

The expected selections are zero of 15 tests for standalone documentation,
exactly `CoreTests/ValueTests/testValue()` for one method edit mixed with
documentation, and all 15 tests for the bundled Markdown resource edit. The last
case must include `generated_input_changed`, despite its ignore pattern. The
retained documentation build passes `verify-build`; successful temporary capture
directories are removed in cached and ephemeral modes.

Measured results are in [PR45ReviewFixValidation.json](PR45ReviewFixValidation.json).
Elapsed time includes revision builds, enumeration, analysis and, for the retained
case, product verification. Maximum RSS is `/usr/bin/time -l`'s measurement for the
selection command; it is not the sum of analyzer, compiler and simulator memory.
Other validation ran on the host, so these are observations, not isolated benchmarks.

No fixture test bodies or consumer suites were executed for these review fixes.
The earlier selected/full fixture execution evidence and consumer rollout limits
remain recorded separately in [Issues41-44Validation.md](Issues41-44Validation.md).

| Change | Selected | Elapsed seconds | Maximum RSS MiB |
| --- | ---: | ---: | ---: |
| documentation | 0/15 | 61.544 | 601.7 |
| mixed | 1/15 | 30.831 | 598.2 |
| resource | 15/15 | 56.920 | 607.2 |
