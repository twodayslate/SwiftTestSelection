# Open-ticket validation

This change fixes imported-body evidence merging (#77), compiler-backed inline
ancestry (#75), repeated inline lookup costs (#76), and mapping maintenance (#67).
For #58 and #61 it reports the exact remaining runtime formatting boundary and
replays the historical scopes; their focused execution targets remain unproven.
The changes do not infer isolation from absent compiler edges.

## Compiler evidence and inline mappings

Imported functions retain the union of compiler references, dynamic declarations,
state accesses, receiver origins, generic calls, error effects and uncertainty.
Definition/display ownership is chosen deterministically. Contributing modules
are recorded separately, including the modules emitting each witness declaration;
an empty stub cannot invalidate or supply witness ownership. Missing/conflicting
imported witness ownership retains runtime uncertainty. Optional missing proof
stays missing through merges and compact archive round-trips.

Compiled regression fixtures preserve callback reachability across unrelated
comment changes and both fragment orders. Other tests cover repeated merges,
legacy missing fields, stub-only provenance and conflicting external ownership.
The real `Array.append` symbol `$sSa6appendyyxnF` retains its five direct callees,
storage-field access and contributing-module provenance in both consumer captures.

The UIKit ancestry regression builds an actual iOS Simulator Swift module with a
base and subclass in separate files, extracts exact compiler USRs from that built
module, and binds real SIL. It tests strict validation, empty/production selections,
JSON parity, compact archives and missing/wrong/stale identities, aliases,
re-exports and incomplete source inventories. Existing unknown-import/shadowing
regressions remain enabled. Extraction fingerprints the module and supplementary
source information before/after and only opens relevant modules when compiler
import maps are complete.

Two fresh ChainOfCustody captures use one build-for-testing with supplementary SIL
each, no base build and no compiler replay. JSON and fully inline policies each
cover 409 UI methods (2,055 total enabled methods). Strict validation and retained
no-op product verification pass. A separate diagnostic re-extraction validates
sealed manifests, source exports, SIL, toolchain and product hashes, applies the
final parser/merge, and writes new comparison graphs without modifying retained
artifacts. No application test bodies execute.

`mappingComparisonReplay` compares canonical per-method production roots and the
entire selected inventory over empty, documentation, production, mixed and helper
body edits, alternating capture order across three rounds. Timing results and
selected-ID digests are recorded in [the validation record](OpenTicketsValidation.json).
Hypothetical body edits exercise the ordinary head-only selector; these probes do
not establish full-run equivalence.

## Repeated query cost

The five-directive graph from #76 has 2,055 tests. Seven release in-memory samples,
excluding graph decode and discarding the first two, measure resolver, strict
validation and audit time. The original issue reports about 5.23 seconds for
strict validation; the new result is about 0.59 seconds, with resolution itself
about 0.21 seconds. Six samples of each five-directive query probe take about
1.2 seconds, compared with the issue’s roughly six seconds. Indexes are per invocation, so separate queries cannot reuse
stale source or compiler evidence. Guards for aliases, inheritance, unknown
exports and shadowing remain active. This is local operation timing on a shared
machine, not a measured CI wall-time improvement.

The fully inline migration has more rules than the five-directive benchmark and
still has greater query overhead than central JSON. Its repeated timing is
reported separately rather than treating the sparse benchmark as a complete
migration performance result.

## Mapping maintenance

`mapping-review` reuses captured graphs for deterministic audits and same-graph
before/after policy previews. Tests repair a partially stale rule, map a new suite,
preserve fixtures/runtime policy, identify broad/overlapping rules, show narrowing
and widening, and retain unresolved condition decisions/fallbacks. The CLI contract
checks read-only behavior and rejects output that would overwrite an input.
The reusable skill was validated with the skill-creator validator.

## Remaining helper precision

Four historical scope replays preserve the known helper consumers and now report
the containing compiler function, source location and unproven XCTest assertion
formatting protocols. Optional equality does not establish absence/effects of
`TextOutputStreamable`, `CustomStringConvertible`, `CustomDebugStringConvertible`
or `CustomReflectable` conformances. Compiled conformance controls remain active.

- #58 retains all 125 known consumers and conservative selection of 403 UI tests;
  the fallback-only NoteLinks case remains explicit. The 153-UI execution target
  is not established.
- #61 retains 384/397 UI tests in the two historical comparisons, with one
  declaration fallback each. The 46-UI execution target is not established.

See [the predicate replay](Issue58PredicateCallbacks.md) and
[the extension-helper replay](Issue61Validation.md). These are capability limits,
not proof that unrelated tests depend on the changed helper.

## Final checks

The release suite passed **514 tests** in **359.527 seconds** (excluding build).
Capture-helper tests passed six cases; distribution tests passed five with one
platform-specific skip. Coverage, inline-mapping and mapping-maintenance CLI
contracts passed. The final sealed replay and the three-round whole-inventory
comparison also passed.

## Reproduction

```sh
swift test -c release --jobs 3 --no-parallel
python3 Scripts/capture_build_test.py
python3 Scripts/release_distribution_test.py
SWIFT_TEST_IMPACT="$PWD/.build/release/swift-test-impact" python3 Scripts/coverage_cli_test.py
python3 Scripts/inline_mapping_cli_test.py --tool .build/release/swift-test-impact
python3 Scripts/mapping_maintenance_cli_test.py --tool .build/release/swift-test-impact
```

Opt-in tests take JSON configuration paths in `IMPACT_SEALED_MERGE_REPLAY`,
`IMPACT_MAPPING_COMPARISON`, `IMPACT_INLINE_BENCHMARK` and
`IMPACT_PRECISION_REPLAY`. The benchmark variable names a captured graph directly;
`IMPACT_INLINE_BENCHMARK_OUTPUT` sets its result path. Replay structures are defined
in their test files. Select the matching Xcode with `DEVELOPER_DIR` for sealed
capture validation. Local retained paths and hashes are in the validation record;
the large consumer bundles are not checked into this repository.
