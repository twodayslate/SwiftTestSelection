# Change-aware runtime uncertainty: issue #29

The Notes label-only case reported in [#29](https://github.com/twodayslate/SwiftTestSelection/issues/29)
selects **471 of 2,000 tests**, down from 1,500, with an explicit, validated
hostless module contract. Imported conformance ownership remains conservative
where SDK runtime effects are unknown.
The default without that contract remains conservative: the updated compiler
graph selects 1,548 tests. No Foundation/global/callback blanket exemption is used.

| Target | Reported baseline | Fresh compiler, no contract | With validated contract |
| --- | ---: | ---: | ---: |
| ChainOfCustodyTests | 1,040 | 1,077 | 0 |
| ChainOfCustodySnapshotTests | 436 | 447 | 447 |
| ChainOfCustodyUITests | 24 | 24 | 24 |
| Total | 1,500 | 1,548 | 471 |

[Machine-readable evidence](Issue29Validation.json) includes every omitted and
retained identifier, grouped by reason, both boundary decisions, revisions,
process memory, phase timings, repeated-report parity and execution results.
Relative to the reported baseline, 1,040 core identifiers are omitted and 11 snapshot identifiers are conservatively added.

## Why the exclusions are justified

`ChainOfCustodyTests` is hostless. Its compiler import closure contains only
`ChainOfCustodyTests` and `ChainOfCustodyCore` among project modules. The reviewed
contract declares that these tests do not load, communicate with, or depend on
application code or application-owned shared state. This assertion about opaque
runtime behavior is an explicit integration obligation, not something imports or
successful tests alone prove. The app-only label edit lies outside that closure.

The compiler graph also contains broad dispatch candidates from other modules,
including `Collection` extensions and generated protocol witness thunks. A
candidate is not an explicit compiler reference. Fresh graphs retain that
provenance; validation follows in-boundary candidates and rejects explicit
cross-boundary references, including escaped callbacks. Known Swift nominal
module prefixes identify generated witness thunks without debug locations.
Unknown provenance retains fallback. Direct/candidate dependency selections
still win even when a separate uncertainty fallback can be bounded.

The snapshot target is hosted by `ChainOfCustody`. Its runtime closure includes
the app, so this core-only contract cannot exclude its uncertainty. Its remaining
447 candidates are reported as conservative fallbacks, not proven Notes
relationships. The 24 UI methods come from the existing notes-navigation mapping.
All 1,040 omitted baseline IDs belong to the hostless core target and require the
validated boundary. Imported conformance declarations remove unsupported project
witness candidates, but **ownership does not prove the implementation body or
runtime effects**. SDK equality can invoke project overrides or type-erased
conformances. Such calls retain uncertainty, including SDK helpers without source
debug locations. This safety correction adds 11 snapshot candidates missed by the
old report. It supersedes the unsafe preliminary 432-test result; no SDK ownership
marker alone suppresses fallback.

## Scope and provenance

Validation starts at consumer `c93e363d46cbb068c16426cdb6646a40344e0cb7`, exactly the
source revision in the issue. Two disposable validation commits add the contract
and then replace `"A to Z"` with `"Alphabetical"` in
`NoteListSortDirection.title(for:)`:

- Policy-only base: `d18d6f1e7a69c64f0cbbcafe9e9f3a6d203968b1`.
- Label-only head: `c9316d1e69f1e30017cdaa39063bb76dfbaec8bc`.

These are local validation commits, not changes pushed to the consumer branch.
Both revisions have fresh compiler graphs from matching builds. The final base
graph was recaptured from the same built products after adding edge provenance;
the preliminary capture is recorded separately. The capture and selection binary
hashes are recorded because validation refined generated-thunk handling and SDK
runtime uncertainty after capture. Those refinements change selection validation,
not the captured graph format or ownership evidence.
The head's sealed products passed `verify-build`; test execution never rebuilt or
substituted products. All original app/test assertions and the complete plan
remain intact. This is a post-adoption focused-case experiment, not a claim that
the migration PR's broader diff selects 471 tests.

Machine: Apple M5, macOS 26.6.1, Xcode 27 / Swift 6.4, iPhone 17 Pro Simulator on
iOS 26.2. Extraction used one worker; test commands allowed two workers and kept
the snapshot target's serial-host configuration.

## Checks

- 151 package release tests pass with Xcode 26.6 and Xcode 27. A preliminary
  rerun used an inherited SDK path and failed two existing compiler fixtures;
  setting each toolchain’s matching SDKROOT restored both complete passes.
- `Fixtures/RuntimeBoundary` compiles and executes independent XCTest branches
  before/after a label edit. The other branch contains UUID/Date equality,
  shared state, an escaped callback, a project override, a project conformance,
  an imported-class extension, generic dispatch to generated witnesses, and
  inherited setup. Changing those dependencies retains their affected tests.
- Missing/changed contracts, missing imports/hosts, incomplete graphs, unknown
  ownership, unbound entries, explicit cross-boundary references and legacy edge
  provenance cannot silently narrow selection. Existing missing-implementation
  and unknown-ancestry regressions continue to pass.
- The actual committed diff and the independent source replay select identical
  IDs. Mixed allowed documentation also selects 471; a single UI method-body
  replay selects one; an empty diff selects none.
- A real CLI merge-base comparison preserves the selection. Stale/missing graph
  controls fail without writing a report. Stacked shared/infrastructure changes
  retain conservative coverage in the fixture.
- Three complete saved-graph reports compare equal, including explanations and
  diagnostics, at 4.84–5.29 seconds. The final saved-graph selection measured
  10.28 seconds and 1.48 GB peak process footprint. These runs overlapped local
  validation; they are not isolated performance benchmarks.
- Full non-UI execution passed all 1,597 requested IDs with zero failures/skips
  and no missing IDs, in 235.30 seconds. All 24 selected UI methods passed with
  zero missing IDs in 1,770.12 seconds. All 447 final selected snapshot methods
  passed with zero failures/skips and no missing IDs in 184.86 seconds. The JSON
  records the preliminary 408-test snapshot run separately; it is not the final
  selection. Parameterized subcases were executed as part of their method IDs.

The selected non-UI run took 50.44 seconds less than the full non-UI run in this
local comparison. Build, extraction, installation/cache costs and the 24-method UI
run are separate; fewer selected tests does not by itself establish lower total
CI time.

The fresh head build took 142.21 seconds, enumeration 45.23 seconds and extraction
312.62 seconds. These are local phase measurements with concurrent work, **not a
CI speedup claim**. Tool installation and CI cache restore/save costs were not
measured as a completed workflow here. Consumer
[#298](https://github.com/twodayslate/ChainOfCustody/issues/298) still requires its
20-PR baseline, repeated representative cold/warm end-to-end comparisons, an
overhead budget and required CI. Consumer
[#297](https://github.com/twodayslate/ChainOfCustody/pull/297) must remain draft until
that gate passes.

## Reproduce

Use a disposable consumer checkout at the original revision and build the release
analyzer with a matching Xcode toolchain. Add this top-level field to the existing
`.swift-test-selection.json`, preserving its UI mappings and documentation policy:

```json
"testRuntimeBoundaries": [{
  "target": "ChainOfCustodyTests",
  "modules": ["ChainOfCustodyTests", "ChainOfCustodyCore"],
  "rationale": "Hostless core tests do not load or communicate with application code or depend on app-owned shared state; validate against full runs before CI adoption."
}]
```

Commit the policy, record `BASE`, then capture its retained graph. In these commands,
`TOOL` is the absolute release executable, `DESTINATION` is a dedicated installed
Simulator UUID destination, and `BASE_BUNDLE` / `HEAD_BUNDLE` are new absolute paths:

```sh
"$TOOL" select --project ChainOfCustody.xcodeproj --scheme ChainOfCustody \
  --test-plan ChainOfCustody --configuration Debug --destination "$DESTINATION" \
  --base "$BASE" --head "$BASE" --retain-build "$BASE_BUNDLE" \
  --format json --output base-empty.json
```

Commit only the exact label replacement, record `HEAD`, and repeat that command
with head/head and `HEAD_BUNDLE`. Then compare the actual revisions:

```sh
"$TOOL" select --project ChainOfCustody.xcodeproj --scheme ChainOfCustody \
  --test-plan ChainOfCustody --configuration Debug --destination "$DESTINATION" \
  --base "$BASE" --head "$HEAD" \
  --base-graph "$BASE_BUNDLE/head-graph.json" \
  --head-graph "$HEAD_BUNDLE/head-graph.json" --format json --output impact.json

"$TOOL" verify-build --project ChainOfCustody.xcodeproj --scheme ChainOfCustody \
  --test-plan ChainOfCustody --configuration Debug --destination "$DESTINATION" \
  --report impact.json --head-graph "$HEAD_BUNDLE/head-graph.json"
```

Execute the verified `.xctestrun` with the report's exact `-only-testing:` arguments.
For the full non-UI comparison, use `-only-testing:ChainOfCustodyTests` and
`-only-testing:ChainOfCustodySnapshotTests`. Preserve result bundles, request IDs,
exit statuses and elapsed times; use `xcresulttool get test-results tests` and the
consumer's `verify-selected-tests.py` to require every requested ID. A zero exit
with zero matching tests is not a pass.

For controlled source replay, write a JSON config containing `graph` (base graph),
`headGraph` (optional actual head graph), `log`, `settings`, `root` (base exported
source directory), and a new `output` directory. Run:

```sh
IMPACT_BOUNDARY_REPLAY=/absolute/replay-config.json \
  swift test -c release --filter runtimeBoundarySourceReplay
```

Omitting `headGraph` performs the exact source-snapshot label replacement instead
of claiming a fresh head build. `legacy: "true"` checks that legacy graphs lacking
edge provenance retain explicit fallback. This probe also emits mixed-documentation,
empty and test-method controls. It never executes consumer test bodies.
