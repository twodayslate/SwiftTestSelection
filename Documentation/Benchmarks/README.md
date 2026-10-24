# Xcode analysis cache measurements

`xcode-cache.json` records the release-build acceptance run of
`Scripts/xcode_cache_integration_test.py` on the bundled `Fixtures/XcodeUITests`
project: one app, a unit-test target, and a UI-test target, with nine enabled tests
including inherited UI methods. The diff edits one UI method. The script asserts
that cached and fresh selections match, a warm lookup performs zero builds,
a new head reuses the merge base, corrupt entries rebuild, and concurrent callers
receive complete results.

The file records hardware, toolchain, destination, fixture revisions, per-phase
analysis events, wall time and `/usr/bin/time -l` maximum resident set size in
bytes. That memory statistic is not the simultaneous aggregate memory of every
Xcode/compiler/simulator process. Tool compilation is outside the timed region.

These are local functional/performance measurements, not a controlled CI speedup
study. Other development builds were active on the host. The final cache run used
a newly created iOS 26.2 simulator, so its cold discovery includes initial simulator
setup; do not attribute the entire cold/warm difference to the graph cache.
Use build/enumeration/extraction counts to establish which work was reused.

Reproduce with the commands in the repository README. The separate
[ChainOfCustody adoption gate](https://github.com/twodayslate/ChainOfCustody/issues/298)
still requires representative real PRs, repeated cold/warm runs, total CI execution
costs, and coverage-equivalent comparisons before rollout.

## Retained build execution

`retained-build.json` records the companion release smoke check from
`Scripts/xcode_retained_build_integration_test.py`. It selects an edited unit
method and an edited UI method, builds the head once, exits selection, removes
the graph cache, and executes exactly those two methods from the retained build.
It also checks warm graph reuse with one new product build, wrong-revision and
modified-product rejection, empty selections, and automatic `select --head --run`
cleanup. Its timings describe this fixture only. The committed runtime-compatibility
regression additionally rejects saved graph pairs from different simulator runtime
inventories; this is covered by unit tests rather than changing installed runtimes.
