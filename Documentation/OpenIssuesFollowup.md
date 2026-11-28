# Open issue follow-up

Based on `614c746c40a8d1d902df9e27a40f8c43e19545ae`. Issue status is kept separate
from implementation progress; no consumer count is used as permission to remove
uncertainty.

## Diagnostic defaults (#96)

Private helpers accept bare `#file`, `#fileID`, and `#filePath` defaults for
`StaticString`, and `#line` for `UInt` (including `Swift.`-qualified types).
Those parameters may be forwarded directly to known XCTest `file:` and `line:`
arguments only. Native syntax checks reject storing, returning, escaping,
shadowing, control-flow use and forwarding to unknown callees. Existing compiler
binding, receiver, callback and historical effect checks still apply. The
versioned helper proof requires a fresh capture for this support.

`sourceLocationPolicy: diagnosticLineColumn` retains caller file identity. This
change does not broaden it to `diagnostic`, replace defaults, or remove assertions.
The compiled regression exercises default and explicit arguments and checks exact
caller selection while an unrelated opaque test remains unselected.

The actual #380 helper also takes `CGRect` and calls a project waiting helper
with a closure. These are independent effect boundaries. Removal of
`replyDestination(_:in:)` is another independent structural boundary. Supporting
diagnostic defaults alone does **not** establish a focused selection for the full
consumer comparison. Unsupported parameter types now name the exact parameter
and type instead of blaming an unrelated nested variable.

## Removed/renamed helpers and local functions (#95)

`headOnlyDeclarationChanges` records each added, removed or ambiguous source key,
base/head regions, possible historical source references (including unsupported
uses and missing inventories), and missing ownership/caller/effect proof. A
matching name or body is never treated as a verified rename. These references
are source observations, not reconstructed compiler edges, and retain the
existing structural fallback.

Proof version 31 supports zero-argument, synchronous, void local functions called
directly as statements. They can capture already-bound immutable values and call
previously validated local functions. Their bodies undergo the same SDK binding,
state and compiler-effect checks as the enclosing helper. Forward references,
recursion, escaped values, autoclosure-wrapped calls, mutation, shadowing and
unsupported signatures remain conservative. Historical statement preservation
includes each complete local declaration, so changing a local body cannot borrow
the unchanged-body proof. A compiled SDK-element capture/action fixture narrows to
the actual consumer and keeps an unrelated opaque test unselected; changing the
old local action restores fallback. Unsupported local cases retain their named
source location and missing proof. Application construction/factory references
are diagnosed before a later local function, because that separate effect needs
initialization and mutable application-state evidence.

## Hostless non-UI boundaries (#97)

Head-only validation supports a closed, unchanged runtime module universe when:

- Both revisions declare the identical nonempty contract for a hostless target.
- The captured compiler import, host, test/lifecycle and explicit-reference
  inventories validate that contract.
- Captured dependency inputs, effective build settings and the head-only build
  audit match the retained artifact and contain no build uncertainty.
- The full Git comparison matches the resolved base and captured head. All
  boundary sources have identical bytes; Swift membership is unchanged; no
  build/resource/policy input changed; other source edits preserve declarations
  and supported function headers.
- Historical ownership is complete. Macro/attribute expansions and generated
  inputs inside the boundary are not accepted without historical build evidence.

The independent regression scope cannot conceal a full-review build change or
substitute a stale merge base. Only opaque-runtime fallback can be excluded;
explicit dependencies, app-hosted uncertainty and other structural fallbacks
remain. Dynamic loading, IPC, app-owned files/preferences and shared state are
covered by the explicit closed-runtime assertion, not inferred from imports.
This is not automatic proof that a user's runtime assertion is truthful.

A compiled four-module fixture builds only head modules and reads the base from
Git, including an actual merge-base resolution. It checks unrelated UUID/callback
effects, a separate app-hosted target, missing/stale evidence, changed contracts,
direct cross-boundary edges, imports, lifecycle and unowned source failures.
Build seals in this unit fixture are explicitly test doubles; it is not a fresh
consumer capture or a product-verification claim.

## Swift Testing UI tests (#91)

[Apple's Xcode 27.3 release notes](https://developer.apple.com/documentation/xcode-release-notes/xcode-27_3-release-notes)
confirm Swift Testing with XCUIAutomation. Discovery retains Xcode's exact IDs,
including top-level functions and nested suites. Compiler binding now handles
nested suite components and static test methods; execution keeps the original
`-only-testing:` identifier. Exact compiler references from Swift Testing's test
factories now bind argument providers and test traits alongside each test body.
All captured suite factories in the same module are included conservatively;
this can overselect dependencies from unrelated suite traits. Factory matching
requires a single matching factory, current native syntax metadata, complete
generated references and enough suite factories. Missing/ambiguous factories,
missing argument thunks and legacy metadata retain discovery fallback. Even when
these roots are bound, trait-bearing factories and generic argument iteration
retain explicit runtime TestTrait/TestScoping uncertainty. A bounded SIL proof
now exempts nonparameterized SDK factories whose trait array is a literal empty
allocation and whose returned Test does not escape or get mutated. Top-level
functions cannot inherit suite traits; member entries additionally require a
local compiler declaration owner and all captured suite factories to prove empty
traits. Extensions of imported suites retain fallback for unseen inherited
traits. Unsupported SIL and old captures
retain fallback. A compiled custom TestTrait
control demonstrates that its `prepare(for:)` callback is not reached through
the constructor graph. Source attribute spelling alone never proves a macro
identity/effect, and factory binding alone cannot authorize exclusions.
The compiled fixture verifies argument and test/suite-trait dependency paths,
mixed XCTest/Swift Testing entries, and these negative controls.

The compiled fixture imports Testing and XCUIAutomation, checks instance/static,
nested/top-level and parameterized bindings and exact execution arguments. It
does not execute UI tests. Installed Xcode 27.2 cannot establish Xcode 27.3 UI
runner behavior. Swift Testing macros/traits remain outside the head-only helper
isolation proof, and inline XCTest-specific mapping syntax is not extended here;
JSON mappings can use enumerated IDs. Full 27.3 runner validation remains open.

The mixed-runner integration test builds one head containing a Swift Testing UI method and an XCTest UI method in the same file. It compares that head to three Git revisions. Editing both methods must select both, and editing either method alone must select only that method. Each single-edit comparison reuses the retained graph and verifies the same build artifact. The test checks both compiled entries, the Swift Testing factory registration, strict UI mappings and both execution filters. Each filter must execute its named method once with zero failures or skips. Run the mixed UI case with Xcode 27.3 or later and a compatible simulator destination.

```sh
swift build -c release
python3 Scripts/xcode_swift_testing_ui_test.py --destination 'platform=iOS Simulator,id=<UDID>' --output /tmp/swift-testing-ui.json
```

The same command accepts three controls on Xcode 27.2. Use `--control xctest-ui` for two methods in one XCTest UI suite, or `--control hostless-swift-testing-unit` for a Swift Testing unit in a platform test process alongside an XCTest UI method. Both controls require exact single-method selection. With `--control swift-testing-unit`, the application hosts the unit bundle. In this control the XCTest-only edit must identify only the UI method as a positive dependency and also retain the unit test with a discovery fallback. The JSON records both lists for each edit.

The hostless control disables code coverage in its test plan. With coverage enabled, LLVM links a startup initializer into the test image and discovery remains open. With coverage disabled, a retained build under `/private/tmp` also exposed a path comparison defect. Foundation reported the executable under `/tmp`, and the selector discarded its factory inventory. The selector now resolves both paths before checking the bundle layout and requires the bundle to be inside the products directory. Rebuild an older graph to capture this evidence.

Switching frameworks does not reveal dependencies across the app/test process
boundary. There is no measured precision or speed benefit from dropping XCTest;
keep both frameworks and improve the evidence they share.

## Work already present on main (#58, #61, #83, #87)

The cross-file private-namesake fix and context-sensitive cache for #87 are already
present; the existing two-file SwiftUI compiler control and accessibility,
alias, extension and historical-visibility negatives remain regression coverage.
See [the prior validation](HelperBindingCacheValidation.md).

Added XCTest entries in plain extensions, repeated extension headers, bounded
scrolling bodies, SDK query/predicate helpers, scoped formatting contracts, and
actionable per-source declaration inventories are also already present.
[The prior consumer evidence](OpenPrecisionIssuesValidation.md) preserves all
known positive consumers and names the remaining boundaries. No hypothetical
identity/formatting review is converted into approved policy by this follow-up.
Arbitrary macro expansions, unknown callback effects and unresolved formatting
producers still need evidence; #58/#61's conditional reduced counts remain
unproven. Compiler `@unchecked` conformance modifiers and `#selector`/`#keyPath`
lookups now retain their written declarations without being labeled expansion
macros. Their runtime/body effects are not exempted. A real compiler fixture and
custom-macro/namesake controls cover this distinction. Arbitrary Testing and
Observation expansion inventories remain explicit.

Callback/error-formatting diagnostics name the producer, the inspecting caller
and its physical source location when available. They explicitly request the
actual throwing-callback binding and error-formatting witnesses; an import review
or snapshot recording mode supplies neither. Exact Optional/String formatting
reviews remain available through the existing scoped contract API, without an
automatic formatting exemption.

## Profiling (#98)

Analysis events now separate head source reading/parsing, compiler binding,
helper review validation/context/preview and dependency-index construction.
`parentPhase` identifies inclusive nested intervals. Analyzer CPU and process peak
RSS are emitted for timed selection phases; compiler children are excluded from
that CPU metric. Graph dimensions, source read/parse counts and digest/index
computation counts are recorded. Do not add nested intervals or peak values.

One immutable dependency index is reused across primary selection, independent
scopes and review previews. Cache validation includes function evidence and test
roots; decisions, candidates, exclusions and uncertainty are recomputed per scope.
Head-only selection reuses native syntax only for Git-proven byte-identical
regular files with the current parser version and matching parsed-byte Git blob
identities (SHA-1 or SHA-256), and shares the full comparison
within the invocation. Legacy captures reparse base syntax. Changed sources
outside a filtered scope still use their base bytes. This source-only reuse does
not grant runtime or build-input exemptions and adds no persistent cache. Symlinks,
archive substitutions and missing byte identities cannot authenticate reuse.

`Scripts/profile_selection.py CONFIG --output NEW_DIRECTORY` runs three serial
repetitions of a configured installed-tool selection and verification. `CONFIG`
contains `cwd`, `selection` and `verification` argv arrays, and a `report` path.
Use `{run}` for fresh output/retained paths. It preserves commands, stdout/stderr,
Darwin resource measurements, load, toolchain, analysis events and exact primary
and scope selections/decision statuses. Failures stop the run and remain visible.
The selection command can be the complete consumer wrapper. In that case set
`toolExecutable` to the installed analyzer, `consumerPhases` to the wrapper's
inclusive timing JSON, and `policyReport` to its final execution policy. Raw IDs,
diagnostic messages, positive consumers, contract outcomes, each scope and final
policy IDs are compared. A policy change or failed primary/scope verification
fails the run and preserves evidence. Work outside the supplied commands remains
unmeasured. Three harness tests cover successful wrapper measurement, policy-only
changes despite identical raw IDs, and selection/scope-verification failures.

The 5.6–5.8 minute consumer remainder cannot be attributed to index construction
or declared removable without matching end-to-end repetitions. Synthetic cache
parity checks establish correctness, not consumer performance or break-even.

## Validation

The initial guarded release suite passed 599 tests on Xcode 27.2 / Apple Swift 6.4.2.
The subsequent release suite passed 602 tests serially. Focused compiled checks
after the final discovery-runtime safeguard passed, including a custom trait
whose runtime callback is deliberately not treated as factory-reachable.
Five fresh processes produced identical complete primary/helper/import-scope
diagnostic reports. Coverage, inline-mapping, mapping-maintenance and strict-map
CLI checks passed against the release executable. Capture-wrapper checks passed
six tests; release-distribution checks passed with one platform-specific skip.

Real consumer replay uses the complete ChainOfCustody scheme/plan, strict mappings,
actual merge bases and original independent regression-support scope/exclusions.
Each invocation performs one head build with captured SIL and separately verifies
the primary and scope reports against the retained products. These are capture
and verification checks, not execution of the consumer's app test suite.

### Initial guarded comparisons and remaining boundaries

This preserved series uses helper proof version 30 and source parser version 2.
It predates the bounded-local-function support, compiler-construct handling and
Swift Testing discovery roots described above (proof 31 / parser 3). It is not
relabeled as a capture of the current sources. In particular, the old #383 local
function diagnostic below predates the more precise application-factory blocker.

The normalized #380 comparison is
`b565980275d3b64e5c4f26103a5a3b5677a20e2f` →
`ae3ea9575d543aac2b755b12d06cf938daa21d03`; #383 is
`1a905c7996552dc72d6f0db961fdb3a8bf1e3790` →
`6367bb4075185b8a33a7e275e9d7dfe433ecb771`.

| Initial guarded replay | Total selected | UI selected | Positive UI | Fallback-only UI |
| --- | ---: | ---: | ---: | ---: |
| #380 primary | 2,208 | 360 | 5 | 355 |
| #380 regression-support | 2,208 | 360 | 5 | 355 |
| #383 primary | 2,216 | 363 | 119 | 244 |
| #383 regression-support | 2,216 | 363 | 44 | 319 |

#380 names `baseline: CGRect` at `NoteCommentsUITests.swift:244` as the next
unsupported helper parameter. Its removed `replyDestination` retains a separate
structured declaration/caller record and structural fallback. #383 names local
function `closeViewer` at `NoteConversionUITests.swift:348` and the missing
historical capture, mutation, recursion and nonescaping caller evidence.
Its scope has seven structural records. The parameterized-test uncertainty
prevents entry exclusions here too: the historical scope's 42 positive UI tests
remain, with two additional positives and two additional structural fallbacks.
These results do not establish safe reduced UI inventories.

Both captured mappings contain the Core runtime contract. #380 emits no runtime
decision in this comparison; its other selection paths already retain the
inventory. #383 records `unproven` for `ChainOfCustodyTests`, with missing
test-entry/lifecycle evidence; per-test diagnostics name the argument-generation
and trait evidence that is unavailable. The fixture's successful hostless
narrowing must not be relabeled as successful consumer narrowing.

All seven initial captures (three main, three guarded #380, one guarded #383) have
one build event, ten captured-module consumption events, no compiler-replay event,
zero graph extraction diagnostics, and successful primary
and scope retained-product verification. The earlier exploratory captures are
excluded. Exact selected IDs, per-target counts, commands, raw-report digests,
source/executable identities and individual measurements are preserved in
[the validation ledger](OpenIssuesValidation.json). Full captures and logs remain
under `/tmp/swift-open-issues-validation/` on the validation machine.

### Initial guarded upstream timing

Three installed-release runs per binary used the same #380 input, complete plan,
destination and independent scope on the same runner. No regression build/test
jobs ran concurrently with these measurements. The main binary is the baseline
commit above; the initial guarded implementation is identified by the ledger's source and executable digests. Build/extraction variance is substantial; the ranges overlap.

| Seconds | Main median (range) | Initial guarded median (range) |
| --- | ---: | ---: |
| Base source read/parse | 46.23 (45.29–47.80) | 1.71 (1.60–1.73) |
| Selection plus primary/scope verification | 372.20 (350.78–406.78) | 351.61 (301.80–354.70) |
| Above total minus each run's build interval | 267.48 (247.48–270.10) | 229.48 (206.51–248.19) |

Base Git blob reads fell from 432 to eight, and base parses from 444 to seven.
The initial guarded runs each record 874 authenticated syntax reuses across the two queries
and one dependency-index construction. The #380 graphs have identical dimensions:
442 source snapshots, 20,413 source units, 143,477 functions, 547,817 edges and
2,208 tests. Exported Swift sources occupy approximately 10.76 MB; graph JSON is
approximately 500 MB and captured SIL 1.76 GB across 500 primary files.

Selection process-family CPU medians were 914.78 seconds on main and 895.89 on the
initial guarded binary, including compiler children. `/usr/bin/time` selection peak RSS
ranges were 3.19–3.36 GiB and 3.12–3.30 GiB respectively; these are high-water
measurements, not aggregate simultaneous memory or attributable cache savings.
Per-phase analyzer-only CPU and memory observations are also retained in the
ledger where available. Inclusive phase intervals and peaks must not be added.

Remaining work is dominated by extraction (initial guarded median 142.22 seconds), test
enumeration (24.67), and head source read/parse, with roughly five seconds each
for graph publication and retention. Primary selection rose from 0.89 to 1.70
seconds with the additional evidence/diagnostics; independent scopes fell from
1.28 to 0.39 seconds. Existing diagnostic categories and all prior positive
dependencies remain. Exact selected IDs, mapping/condition records and helper
contract decisions match main; the additional parameterized-test diagnostics and
retained entry roots are the deliberate behavior difference described above.

The observed total median reduction is 20.59 seconds (5.5%); the per-run non-build
median reduction is 38.01 seconds (14.2%). These three-sample local distributions
do not guarantee a CI speedup. This workload still spends about 3.8 minutes on
measured non-build work, before external consumer orchestration, and does not
reduce executed-test candidates. Break-even therefore still requires sufficient
test-execution savings plus allowance for unmeasured orchestration and any
capture-related build difference. The historical cohort's net cost has not been
recalculated or claimed solved.

## Remaining external validation

The exact normalized historical objects for #58/#61/#83 are absent from the local
consumer repository. Fetching each recorded head from GitHub returns `not our ref`:

| Consumer run | Normalized head |
| --- | --- |
| #293 / 40058859478 | `82b91d0c474b287215ff272e5e1afcea12dd2c21` |
| #299 / 40159996488 | `de7249daf287e676d59a48a28a597e7112f92eca` |
| #291 / 40031610717 | `17d634a66a045db0437016977e1c27d60876a901` |
| #291 / 40035642452 | `ffead14c366b9581e0da2626fcdc294aad97b7e9` |

The preserved `/tmp/open-precision-validation/` and
`swift-test-selection-9fc8140-2026-11-01` bundles are also unavailable on this
machine. Their committed validation ledgers remain historical evidence, not fresh
executions of this change. Repeating these exact cases requires the preserved
Git objects/source comparison and captured graphs plus any actually reviewed
scoped declarations. Reconstructing a new normalization would need separate
provenance and would not reproduce those exact recorded objects.

#58 still needs actual throwing-callback binding and error-formatting evidence;
#61 retains its `Optional<String>` formatting/declaration boundary; #83 retains
arbitrary macro expansion and historical declaration uncertainty. The new
compiler-construct handling and actionable diagnostics do not supply those
missing proofs or establish the conditional 153/46/52-UI targets.

Xcode 27.3 is not installed. The Swift Testing compiler/binding fixtures pass on
27.2, but the new UI runner behavior in #91 remains unvalidated. Neither its
framework-only precision nor a speed benefit is established.

## Complete consumer workflow measurements (#98)

The final proof-31/parser-3 implementation was measured through the historical
consumer's actual `select-tests.py` entry point, including native comment parsing,
independent scope preparation, normalization, policy application and retained
product/policy verification. Only tool installation was replaced with resolution
of an explicitly installed binary; warm compiler/version checks still run.
The consumer checkout and policy are unchanged.

Three serial control/candidate pairs use the exact #380 comparison above on the
same Xcode 27.2 / Swift 6.4.2 runner and a dedicated iOS 26.2 simulator. The control
has all the final correctness changes, with only authenticated head-syntax reuse
and invocation-local dependency-index reuse disabled. This isolates these two
optimizations from the new diagnostic and discovery behavior. Binary/source
hashes, wrapper source, configurations, load, commands and individual measurements
are in [the complete workflow ledger](ConsumerWorkflowValidation.json).

| Measurement | Reuse disabled, median (range) | Reuse enabled, median (range) |
| --- | ---: | ---: |
| Complete consumer step, seconds | 321.68 (321.47–350.11) | 275.17 (275.06–277.33) |
| Step minus each run's build, seconds | 231.94 (230.71–246.76) | 185.59 (185.10–185.84) |
| Head build, seconds | 90.96 (89.53–103.36) | 89.96 (89.33–91.75) |
| Base source syntax, seconds | 46.81 (46.76–46.92) | 1.66 (1.61–1.70) |
| Process-family CPU, seconds | 858.36 (858.28–874.57) | 831.91 (830.04–835.77) |
| Peak RSS, GiB | 2.573 (2.564–2.582) | 2.672 (2.632–2.691) |

The median complete-step reduction is **46.51 seconds (14.5%)**; the per-run
non-build median reduction is **46.35 seconds (20.0%)**. These are three-sample
local observations, not a CI speed guarantee. The first control had a longer
build and enumeration interval. Memory did not improve: the reported RSS is a
process-family high-water measurement, not aggregate concurrent memory or an
attributable cache allocation.

All six exact primary/scope selections, diagnostic messages and affected IDs,
positive-consumer sets, mapping/contract/runtime decisions and final consumer
policies match. The full signature evidence is preserved in
[compressed policy JSON](OpenIssuesEvidence/consumer-380-policy.json.gz).
Every run verifies raw and scoped retained products in addition to the consumer's
normal final-policy verification. The extra experiment-only raw/scope commands
cost medians of 8.38/8.52 seconds and are **excluded** from the complete-step
numbers above; adding them would not represent the normal CI step.

The optimization consistently changes base blob reads from 432 to eight, parses
from 444 to seven, authenticated head-syntax reuses from zero to 874, and index
constructions from two to one. Every graph has 442 snapshots, 20,413 source units,
143,477 functions, 547,817 edges and 2,208 tests. Exported Swift sources are
10.76 MB across 431 files; graph JSON is approximately 510.7 MB; each capture
contains 500 primary SIL files totaling approximately 1.83–1.84 GB.

The remaining candidate medians are 128.67 seconds for extraction, 13.58 for head
source reading/parsing, 5.16 for enumeration, 5.22 for graph publication, 4.73 for
retention, 1.70 for primary selection and 0.45 for the independent scope. The
extraction interval contains its per-module consumption intervals; they must not
be added again. This input does not produce review-context/preview work, so it
does not calibrate those instrumented paths.

Consumer scope preparation is 0.42 seconds, within the retained-selection call.
Other consumer orchestration outside retained selection and verification is
1.21 seconds; native retained-product/policy verification is 5.08 seconds. These
measurements put the remaining dominant cost in upstream extraction, rather than
consumer policy preparation. They do not justify removing any verification.

The raw and final consumer policies still include all 2,208 tests: 360 UI and
1,848 non-UI, with 47 Base and 313 Regression UI entries. This input therefore
has no demonstrated test-execution saving. Break-even still requires saving
approximately **185.6 seconds of execution**, plus any capture-related build
premium over a normal build. That premium was not measured here. The historical
19-comparison cohort has not been rerun or declared cost-effective.

An earlier control attempt failed during simulator runner launch and is excluded,
with its logs retained. A pre-final pilot is also excluded. Neither failure nor
old-proof measurements have been relabeled as successful current executions.

Three subsequent saved-head selections use the same retained #380 graph and
produce exactly the fresh raw primary/scope policy. Their graph read/decode/
validation interval has a 3.20-second median (3.15–3.43); complete saved selection
has an 8.58-second median (8.44–9.05), before the separately verified products.
These use the same graph decoder as retained verification, with no build or
compiler replay. They are standalone probes, not additional components to add
to the CI-step measurements.

## Final real comparisons and closure status

All seven final fresh captures (six #380 benchmark runs and one #383 replay)
have one head build, ten consumed SIL modules, zero graph/dependency extraction
diagnostics, no compiler replay/base build, and successful raw/scope retained
product and consumer-policy verification. No application test bodies executed.
The three saved-graph probes also pass primary/scope product verification.

| Final proof-31 replay | Total selected | UI selected | Positive UI | Fallback-only UI |
| --- | ---: | ---: | ---: | ---: |
| #380 primary | 2,208 | 360 | 5 | 355 |
| #380 regression-support | 2,208 | 360 | 5 | 355 |
| #383 primary | 2,216 | 363 | 119 | 244 |
| #383 regression-support | 2,216 | 363 | 44 | 319 |

Both comparisons have zero added/removed selected IDs and zero added/removed
positive-consumer IDs relative to the initial guarded captures. #380 retains
26 primary/one scoped structural records and the separate `baseline: CGRect`
boundary. #383 retains 78 primary/seven scoped structural records. Its helper
diagnostic now names the `XCUIApplication` factory at
`NoteConversionUITests.swift:324`, within the helper starting at line 323, and
requests receiver-initialization/mutable-application-state evidence. It no longer
blames the supported shape of the later local function.

The pre-review capture at commit `80dbee4` reports runtime discovery
uncertainty beyond parameterized entries: 1,618 entries in #380 and 1,623 in #383.
Factory bindings provide additional roots, but do not authenticate trait/scoping
callbacks or generic iteration. These diagnostics are identical between the
performance control and candidate. They do not remove positive dependencies or
change the selected IDs above. In #383, the Core decision names
`CacheRecoveryTests/localCacheCloudRecoveryMarkerMergesAndClearsByRequestID()`
and the unproven runtime callbacks, instead of a generic missing-root message.
The consumer Core boundary remains `unproven`.

PR #99 review follow-up removes the unconditional runtime diagnostic for proven
trait-free entries. Compiled regressions cover top-level and suite-member tests,
both selectors, custom traits, inherited traits, parameterized entries, and
missing compiler proof. The full Git comparison is also now deferred until a
caller/runtime-boundary audit actually needs it; an unaudited retained source
read with 200 unrelated changed files exercises this path. The consumer timings,
policy artifacts, and source hashes above remain historical evidence for
`80dbee4`, not a rerun of these review fixes.

The isolated 200-file reproducer's retained-artifact read fell from 15.495/15.453
seconds before the review fix to 0.201/0.294 seconds afterward. The corresponding
reads without a retained artifact took 0.214/0.216 seconds afterward. This measures
only source loading, not an end-to-end consumer workflow or test execution.
The initial review fixes at `da8fd81` passed all 604 tests with
`swift test -c release --jobs 3 --no-parallel` on Xcode 27.2 (358.040 seconds).

The subsequent archive review found that compact SIL fragments dropped the
factory proof before binding. The compact format now preserves this optional
evidence for both SIL modules and Xcode graphs. Regression coverage loads a
compiled module through the module cache before binding and compares actual
one-worker and two-worker extraction: both must exclude the unrelated trait-free
test. Archives written without the field remain readable with unproven evidence.
After the archive fix, all 605 release tests passed on Xcode 27.2 in 374.958
seconds, including the compiled worker-parity and module-cache regressions.

The final #383 exact policy is preserved in
[compressed JSON](OpenIssuesEvidence/consumer-383-policy.json.gz), with its
commands, driver, complete timing and comparison evidence in
[the workflow ledger](ConsumerWorkflowValidation.json). Use `gzip -dc` to read
the policy artifacts; the ledger records their compressed and uncompressed
SHA-256 digests. Full products and graphs retain their original absolute paths
under `/tmp/swift-open-issues-validation/`.

The table records the disposition at #99. The subsequent
[historical helper analysis](HistoricalHelperResolution.md) reconciles the four
archived comparisons and updates the conclusions for #58, #61 and #83.

| Issue | Disposition | Evidence or remaining requirement |
| --- | --- | --- |
| #87 | Ready to close; already fixed on main | Existing cross-file private-name fix and regression coverage retained. |
| #96 | Ready to close | Diagnostic defaults and restricted forwarding have compiled positive/negative coverage; real helper's independent `CGRect`/deletion boundaries remain explicit. |
| #95 | Ready to close for the requested supported/diagnostic outcome | Bounded local calls are implemented; structural evidence is explicit; both exact real comparisons and consumer policies verified. Rename/deletion isolation is not inferred. |
| #97 | Ready to close for the documented supported subset | Authenticated unchanged hostless boundary passes compiled controls; unsupported consumer runtime evidence remains named and conservative. |
| #98 | Ready to close as a profiling/optimization investigation | Three full-flow pairs, exact policy parity, CPU/memory/phase evidence, fresh/saved checks and remaining break-even costs published. |
| #58 | Keep open | Concrete callback/error-formatting blocker is improved; exact historical replay and scoped evidence are still unavailable. No focused 153-UI proof. |
| #61 | Keep open | Extension/scrolling support is present; historical replay and the remaining Optional formatting/declaration evidence are unavailable. No 46-UI proof. |
| #83 | Keep open pending historical revalidation | Compiler constructs and actionable inventories are supported; exact fresh #293 replay with its reviewed declarations is unavailable. Arbitrary expansion isolation remains unproven. |
| #91 | Keep open pending Xcode 27.3 validation | Compiler discovery/ID/argument/trait roots are covered; UI runner execution and runtime trait/iteration completeness are not established. |
