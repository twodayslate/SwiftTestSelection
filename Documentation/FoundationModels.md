# Experimental Foundation Models UI reachability

Normal Xcode selection can use Apple's on-device Foundation Models to supplement
compiler and mapping results. Enable it with `select --ai`; it is off by default,
and `--no-ai` explicitly disables it. AI never removes a test selected by the
normal selector. `--run` executes the combined selection through the existing
execution path. No separate AI selection command or dataset preparation is needed.

```sh
swift-test-impact select --project App.xcodeproj --scheme App \
  --destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  --base main --head HEAD --ai --confidence-threshold 75 --format json \
  --output impact.json
```

AI currently requires Xcode mode and an explicit committed `--head`. It reuses the
head graph from fresh, cached, retained-build, or saved/head-only analysis without
another build. Changed production declarations are paired automatically with
previously unselected enabled UI tests. Semantic fingerprints avoid evaluating
comment-only edits. Removed declarations and non-function changes continue through
the ordinary selection rules. Full-suite selection and empty comparisons make no
model requests. Additional `selectionScopes` remain deterministic queries; AI
supplements the full comparison used for execution.

A score **at or above 75%** adds the test by default; override this using
`--confidence-threshold 0…100`. Any qualifying function pair adds its test, without
averaging. Unknown predictions, unavailable models, unresolved source, and model
failures retain the affected candidate UI tests. A configurable `--ai-max-pairs`
(default 100) bounds inference work; candidates with unevaluated pairs are retained.
The normal report's `aiSelection` records baseline selection, additions, unknowns,
notes, evaluated pairs, confidence scores, and prompt metadata. Build provenance,
normal explanations, and the original selection remain intact.

`--prompt-template` and `--instructions-template` also work directly on
`select --ai`. Disabling AI does not load template files or probe the model.
The chosen threshold is a preference for supplementing selection, not a claim
that the model's probabilities are calibrated.

The `ai status`, `ai prepare`, `ai render`, and `ai evaluate` commands remain as
model diagnostics, prompt-inspection, and benchmark helpers. There is no
`ai select` subcommand.

The function's source and the test are useful inputs, but a callee tree alone
usually misses the key question: which screen, gesture, fixture or callback
**reaches** the function? Preparation includes same-file callers/callees and
setup/teardown helpers. An optional revision-matched saved Xcode graph adds
one-hop compiler callers/callees and their source. Missing and bounded context is
explicit. Neither source names nor compiler edges prove runtime execution across
the app/UI-test process boundary.

## Requirements and commands

The existing package deployment target stays macOS 13. The optional provider
needs an SDK containing Foundation Models, macOS 26+, supported Apple Silicon,
Apple Intelligence enabled, and the on-device model downloaded. Older SDKs compile
the unavailable-provider path. No API key or cloud model is used. The framework
uses [guided generation](https://developer.apple.com/documentation/foundationmodels/generating-swift-data-structures-with-guided-generation)
for `confidencePercent` (an integer from 0 through 100, or `null`) plus a short
explanation. The percentage estimates the probability that the test executes the
function; it is not confidence in a categorical answer. This self-reported score
is uncalibrated until evaluated against authentic execution labels. `null` means
insufficient evidence or a provider failure, never 0% probability.

```sh
swift build
.build/debug/swift-test-impact ai status

python3 Scripts/prepare_chain_of_custody_ai.py \
  --repository /path/to/ChainOfCustody \
  --cli .build/debug/swift-test-impact \
  --output .build/ai-chain-of-custody

.build/debug/swift-test-impact ai evaluate \
  --dataset .build/ai-chain-of-custody/dataset.json \
  --confidence-threshold 75 --output .build/ai-chain-of-custody/report.json

```

`evaluate` saves a report even if the model is unavailable. Exit 0 means the
requests completed (a model may still answer `null`); exit 2 means one or more
requests failed or the model was unavailable; exit 1 means invalid arguments,
inputs or another command failure. Inspect per-row errors and answer rate.
Model failures, invalid percentages, and over-budget input become `null`, never 0%.

For standalone experiments, `ai evaluate` accepts the same confidence threshold
(default 75) and records per-pair metrics and hypothetical threshold decisions.
Those experiment datasets cover only supplied pairs and are not a full test
inventory. Normal `select --ai` constructs its own candidates from the comparison
and merges the result into the compiler/mapping report. Benchmark reports remain
`advisoryOnly: true`; the normal report records how the AI supplement was applied.

To prepare your own pairs, write a JSON array of case specifications:

```json
[
  {
    "id": "save-note",
    "revision": "FULL_COMMIT_SHA",
    "function": {"path": "App/Notes.swift", "line": 42},
    "test": {"path": "AppUITests/NotesTests.swift", "line": 18},
    "testIdentifier": "AppUITests/NotesTests/testSave()",
    "expected": true,
    "evidenceKind": "sourceReview",
    "evidence": "Review rationale, or a reference to isolated execution evidence"
  }
]
```

Use a line within the complete function/declaration and no-argument XCTest method.
Preparation checks the method and suite name, resolves the revision to its full
commit SHA, and reads source using Git objects. Working-tree edits never enter the
input. For an unlabeled experiment, omit `expected` and use `unlabeled` evidence.

```sh
.build/debug/swift-test-impact ai prepare \
  --repository /path/to/App --cases cases.json \
  --graph saved-head-graph.json --mappings .swift-test-selection.json --output dataset.json
```

`--graph` is optional. If supplied, it must carry the exact revision, a matching
UI test inventory, and compiler nodes for both declarations. Prepare different
revisions separately when using graphs. Context is bounded to one hop, 32 graph
nodes and 64 edges. Syntax-only preparation does not build the app and cannot
recover cross-file fixture implementations or inherited test lifecycle methods.
The entire function and test remain intact. Optional context is dropped explicitly
to fit a 12,000-byte input budget; this is a byte heuristic, not a token guarantee.
An oversized subject or a model context-window error is recorded as an abstention.
This is not the full transitive graph in either direction. Declaration extraction
starts after leading trivia, so preceding `///` and `/** ... */` documentation is
not included. Comments inside the extracted declaration are preserved. Inline
`swift-test-selection:` mapping directives are extracted separately as described below.

### Custom Stencil prompts

`ai render` and `ai evaluate` accept `--prompt-template FILE` and
`--instructions-template FILE`. Both files are UTF-8 Stencil templates, read once
at command start. Either option may be omitted to keep that built-in component.
The default pair renders the existing `ui-reachability-v3` instructions and source
JSON exactly. Stencil is pinned to
[0.15.1](https://github.com/stencilproject/Stencil/releases/tag/0.15.1); its variables,
loops, conditions, and filters fit this task without changing template syntax.
It builds with this package's Swift 6 toolchain.

Start with the supplied [input template](Prompts/UIReachability.stencil) and
[instructions template](Prompts/UIReachabilityInstructions.stencil):

```sh
# Inspect exact instructions and input for each pair without invoking the model.
.build/debug/swift-test-impact ai render \
  --dataset .build/ai-chain-of-custody-mappings/dataset.json \
  --prompt-template Documentation/Prompts/UIReachability.stencil \
  --instructions-template Documentation/Prompts/UIReachabilityInstructions.stencil \
  --output prompts.json

.build/debug/swift-test-impact ai evaluate \
  --dataset .build/ai-chain-of-custody-mappings/dataset.json \
  --prompt-template Documentation/Prompts/UIReachability.stencil \
  --instructions-template Documentation/Prompts/UIReachabilityInstructions.stencil \
  --confidence-threshold 75 --output custom-report.json
```

Both templates receive the same context:

| Variable | Contents |
| --- | --- |
| `function`, `test` | `name`, `scope`, `source`, `calls`, and `region` (`path`, `startLine`, `endLine`) |
| `context` | Array of related source fragments with the same fields |
| `revision`, `testIdentifier`, `contextKind` | Snapshot identity and preparation mode |
| `compilerEdges`, `mappings`, `limitations` | Available graph/mapping evidence and its limitations |
| `input` | Entire model-input object, including all fields above |
| `inputJSON` | Stable JSON representation of that object |
| `defaultInstructions` | Built-in instructions, for extending rather than rewriting them |
| `outputContract` | Description of the fixed percentage/reason response schema |

For example:

```stencil
Target: {{ function.region.path }}:{{ function.region.startLine }}
{{ function.source|required }}
Test: {{ testIdentifier }}
{{ test.source|required }}
{% if mappings %}Declared mappings: {{ mappings|json }}{% endif %}
{% for fragment in context %}
{{ fragment.name }}: {{ fragment.source }}
{% endfor %}
```

`json` serializes any value as JSON, including `null` for absent optional evidence.
`required` raises an error for missing or empty values; otherwise Stencil's normal
missing-variable behavior is to render an empty string. Standard filters such as
`default`, `join`, and `uppercase` are available. Templates are self-contained:
there is no filesystem loader for `include`/`extends`. Inserted Swift source is
literal data, not rendered a second time, and is not HTML-escaped.

Expected labels, review rationale, case IDs, environment variables, and selection
thresholds are not exposed to either template. The guided response schema remains
`confidencePercent` plus `reason`; changing the prompt does not change that schema.
Custom templates choose which input fields appear. The supplied example preserves
both complete subjects, bounded source context, graph evidence, and mapping context.

All cases are rendered before inference starts. Syntax errors, unknown filters,
failed `required` checks, or empty rendered text fail with exit 1 before any model
request. The source JSON still has a 12,000-byte budget; rendered instructions are
limited to 4,000 bytes and the rendered input to 12,028 bytes. Over-budget cases
become error/unknown rows during evaluation (exit 2, retained for selection);
`ai render` fails rather than emitting a partial preview. No prompt is silently
truncated. These byte limits remain heuristics, not token-window guarantees.

Reports store both template sources, engine/context versions, a configuration
SHA-256 digest, and each pair's exact rendered-prompt digest. Custom configurations
use `custom-stencil-v1:<digest>` as their prompt version. Each rendered pair is
passed directly to the provider without re-rendering, so its recorded digest
identifies the actual instructions/input used even with dynamic template tags.
The normal report's `aiSelection.evaluation` preserves these templates and hashes.
Changing templates requires a fresh evaluation. Saved normal reports already
contain the combined selection and can use the existing `run --report` workflow
without invoking the model again.

### Mapping evidence

Preparation automatically reads `.swift-test-selection.json` from each case's
immutable Git revision. `--mappings REPO_PATH` selects a different committed file;
an explicitly requested file must exist at every case's revision. Malformed JSON,
invalid mapping schemas, and symlink mappings fail preparation. Today's working
copy and graph-embedded JSON mappings are not substituted for historical rules.
If the default file is absent, the input records that absence rather than treating
it as evidence that the function does not execute.

The prompt receives relevant rules with origin, location, test/fixture selectors,
source and symbol patterns, `dependsOn`, and complete `when` expressions. Relevance
includes rules matching the test or target function, plus their connected
`dependsOn` declarations. Source-pattern matches are reported explicitly; symbol
matches require compiler identity from a revision-matched graph. Conditional
`when` expressions remain unevaluated because a source snapshot is not a base/head
change comparison. `runtimeDependencyPolicy` is retained as policy context.

Inline comment mappings use the existing parser. Without a compiler graph, only
annotations on the selected method and its enclosing class/extension are supplied
as **unverified syntax candidates**, with conditional-compilation status. Inherited
and cross-file rules are not inferred. With a matching graph, the existing inline
resolver supplies compiler-bound rules and relevant resolution diagnostics.
Neither candidate annotations nor resolved selection contracts prove per-function
runtime execution, and broad file rules do not imply that every function executes.

Mapping context is capped at 16 whole rules, prioritizing rules matching both the
test and function. The overall 12,000-byte budget still applies: optional source
context is removed before mapping rules; omitted rules are counted in
`mappings.omittedRuleCount`. Omission can leave dependency context incomplete and
is explicitly disclosed. Complete subject function/test declarations are preserved.
The prompt asks the model to cite mapping evidence when explaining its percentage;
it does not convert mappings to fixed percentages or override the normal selector.

The library exposes `UIReachabilityPreparation`, `FoundationModelUIReachability`,
and `UIReachabilityEvaluation`. The evaluator accepts an injected async predictor
for testing or other providers; the command uses only Apple's on-device model.

## Evaluation contract

The built-in prompt is `ui-reachability-v3`, and new reports use schema version 2.
Custom Stencil prompts carry their own digest-based version.
Predictions replace the version 1 `verdict` enum with nullable `confidencePercent`.
Historical version 1 JSON artifacts below are preserved in their original format.
Each pair uses a fresh model session with greedy sampling, a 256-token response
cap, and a versioned prompt. Labels and evidence rationale are never passed to the
model. Reports include input/dataset SHA-256 digests, OS, provider, availability,
prompt version, per-pair elapsed time, answers, and errors. The model itself is
system-managed; identical inputs are not a reproducibility guarantee across OS or
model updates. Prompt changes require a prompt-version bump and fresh evaluation.

Metrics are separated by label provenance:

- `execution`: actual per-test function execution evidence for that exact revision,
  configuration, fixture and device. A negative requires complete instrumentation
  of a successful isolated run; an absent coverage record is not a negative.
- `sourceReview`: a reviewed expectation, not measured execution.
- `historicalAssociation`: co-change or regression association, not measured execution.
- `unlabeled`: excluded from accuracy metrics.

The evaluator validates the schema, not the truth of user-supplied labels. Reports
include the raw percentages, answer rate, Brier score (mean squared probability
error; lower is better), and a confusion matrix at the configured threshold
(`confidencePercent >= positiveThresholdPercent` is positive; default 75).
The same threshold controls the report's experimental `selection`. Historical
reports retain their recorded 50% threshold. In normal selection, threshold
results are additive to the deterministic baseline. Brier score excludes abstentions and errors,
so inspect `scoredCount` and answer rate alongside it. Scores against source-review
labels measure agreement with those labels, not execution calibration. Precision,
recall, and accuracy are threshold-dependent; unknown positives count against recall.
`retainUnknownRecall` models
the hypothetical policy of retaining unknowns; it can be 100% when **no predictions
succeeded**, so it is not model accuracy. Undefined rates encode as `null`.

Before using AI to narrow selection, collect isolated per-method coverage or
function-entry traces at historical commits, freeze labels before prediction, and
split by revision/feature so near-identical pairs cannot leak across prompt tuning
and evaluation. Compare against existing selection, always-run, and simple name
matching. Prioritize false negatives and positive-case recall over aggregate
accuracy; record test reduction, latency, refusals, errors and abstentions.

## Chain of Custody pilot, November 17, 2026

The reproducible script and checked-in [case manifest](Benchmarks/FoundationModels/ChainOfCustodyCases.json) select 12 pairs from three immutable historical revisions:
PR #355 (unread activity), #361 (scroll-driven Add Block minimization), and #365
(activity filtering/mark-all-read). Six reviewed related pairs are balanced by six
comparisons against a check-settings journey. This is a small convenience sample
concentrated in Notes, with repeated functions/tests; it is not a representative
historical benchmark or a held-out validation set. Labels are all `sourceReview`.

The initial [attempt report](Benchmarks/FoundationModels/ChainOfCustodyPilot.json)
records `appleIntelligenceNotEnabled`: 0/12 answered, 12 unavailable errors, and
`accuracyAmongAnswered: null`. No app UI tests or coverage collection ran for this
experiment. The existing historical selection reports do not supply per-test
function execution ground truth.

The first attempt to enable the model was blocked by macOS UI automation permissions.
On retry, Apple Intelligence was enabled through System Settings on macOS 26.6.1
(build 25G76). The framework progressed from `appleIntelligenceNotEnabled` to
`modelNotReady` and then `available`. No macOS 27 update was needed. Actual
function-level historical accuracy still requires the execution labels described above.

### Enabled-model run

The [enabled-model report](Benchmarks/FoundationModels/ChainOfCustodyPilotEnabled.json)
uses the same frozen 12 pairs and `ui-reachability-v1` prompt, on macOS 26.6.1.
It measures **agreement with source-review labels**, not measured execution accuracy.

| Result | Count |
| --- | ---: |
| Related pair predicted likely | 5 |
| Unrelated comparison predicted likely | 6 |
| Pair predicted unlikely | 0 |
| Unknown due to response decoding failure | 1 |
| Correct among answered pairs | 5/11 (45.5%) |
| Correct among all submitted pairs | 5/12 (41.7%) |
| Positive recall, counting the unknown as not predicted | 5/6 (83.3%) |

All 11 valid responses said `likely`. Several explanations invented direct calls
or claimed the app function and test were in the same file, contrary to the input.
For example, `pr365-markAllRead-comparison` claimed the check-settings test called
`NoteActivityView.markRead`; its supplied test source contains no such call.
One response exhausted its 256-token output budget before completing the structured
JSON and was correctly reported as unknown with a decoding error. The 12 requests
took about 79.4 seconds in total (median 6.1 seconds per pair), including the first
request after enabling the model.

This version offers no useful test reduction on the pilot. Retaining `likely` and
`unknown` keeps all 12 pairs, exactly as an always-run policy would. The latter has
50% agreement on this artificially balanced sample without any model cost. The
absence of false-negative predictions here does not establish safety: there were
no negative predictions at all, and no execution labels.

Recommendation: keep this as an advisory experiment, not a selection filter.
Before expanding it, test shorter grounded prompts with explicit evidence routes,
a bounded explanation schema, and authentic per-test execution labels. Evaluate
those changes on different revisions/features; do not tune to these 12 labels and
present the resulting score as independent validation.

### macOS 27 update check

On November 17, 2026 at approximately 11:55 AM Eastern, the host was confirmed to
be running macOS 27.2.1 (26B131). System Settings reported that Apple Intelligence
& Siri assets were downloading. The framework continued to return `modelNotReady`
through a five-minute readiness check while the Mac was connected to AC power.
The model was available on a later check. Apple's `fm models` command identified
the available system model as `AFM 3 Core Advanced`, and the package's framework
availability check returned `available`.

### macOS 27 enabled-model comparison

The [post-upgrade report](Benchmarks/FoundationModels/ChainOfCustodyPilotMacOS27.json)
completed on November 17, 2026 at approximately 1:11 PM Eastern on macOS 27.2.1
(26B131). It uses the same executable and `ui-reachability-v1` prompt. Dataset and
all per-pair input digests match the earlier enabled-model report. The model name
above comes from the contemporaneous CLI readiness check; the report records the
framework provider and OS, not a separately verified model artifact version.

| Result | macOS 26 run | macOS 27 run |
| --- | ---: | ---: |
| True positives | 5 | 1 |
| False positives | 6 | 1 |
| True negatives | 0 | 4 |
| False negatives | 0 | 5 |
| Unknown | 1 (decoding error) | 1 (model abstention) |
| Agreement among answered pairs | 5/11 (45.5%) | 5/11 (45.5%) |
| Agreement among all submitted pairs | 5/12 (41.7%) | 5/12 (41.7%) |
| Positive recall | 5/6 (83.3%) | 1/6 (16.7%) |
| Total inference time | 79.4 seconds | 77.9 seconds |

All 12 post-upgrade requests completed without provider errors; one answered
`unknown`. Median time was 6.4 seconds per pair. These remain **source-review
agreement metrics**, not execution accuracy, and a single run does not establish
repeatability. Several explanations incorrectly treat the absence of a direct
function call from the UI test as evidence against execution, even when describing
UI gestures that could trigger the callback. Keeping only `likely` and `unknown`
would retain 3/12 pairs while dropping five of the six reviewed positives. This
prompt remains unsuitable for filtering tests; the update did not improve overall
agreement and substantially reduced positive recall on this pilot.

### Percentage-output run

The [confidence report](Benchmarks/FoundationModels/ChainOfCustodyPilotConfidence.json)
uses `ui-reachability-v2` and report schema 2 on the same macOS 27 host. Dataset
and per-pair input digests match the preceding run. Only the output contract and
its prompt instructions changed; no graph or documentation context was added.
All 12 requests returned valid percentages without errors or abstentions, taking
70.5 seconds total (median 5.8 seconds). Scores were:

| Function / historical change | Related pair | Check-settings comparison |
| --- | ---: | ---: |
| scrollViewWillBeginDragging / #361 | 20% | 0% |
| scrollViewDidScroll / #361 | 50% | 0% |
| isUnread / #355 | 25% | 25% |
| markBlockRead / #355 | 25% | 25% |
| markAllRead / #365 | 45% | 25% |
| activityIndex / #365 | 45% | 25% |

At the report's 50% threshold, agreement with source-review labels is 7/12
(58.3%), with one true positive, six true negatives, five false negatives, and
no false positives. Positive recall remains 1/6 (16.7%). Brier score is 0.2392,
compared with 0.25 for predicting 50% on every pair. These are uncalibrated scores
on the same exploratory sample, not held-out execution accuracy or evidence of
safe test exclusion. The new output makes thresholds and probability error
inspectable; it does not resolve the missing runtime/context evidence.

### Mapping-context validation

Prompt `ui-reachability-v3` adds mapping-aware instructions and historical mapping
context. Repreparing the original 12 pairs found no default JSON mapping file at
any of their three revisions and no inline directives in the selected test files.
Consequently, that pilot cannot measure an improvement attributable to mappings.
No current mapping was applied retroactively, and no new historical accuracy score
is claimed for this version.

A separate [synthetic two-input smoke dataset](Benchmarks/FoundationModels/MappingSmokeDataset.json)
compares identical function/test source with mapping context withheld versus supplied.
The supplied context contains a class-level inline source rule and a JSON rule
associating the test with `App.swift`. Both cases are unlabeled: this is an integration
check, not execution ground truth or a historical benchmark. The
[on-device smoke report](Benchmarks/FoundationModels/MappingSmokeReport.json) returned
50% without the mappings and 75% with them, without errors, in 7.2 seconds total.
This shows that the score can respond to mapping context; it does not establish
calibration or improved accuracy. The explanation still assumed a button-to-function
callback link not established by the supplied code, so the percentage is not proof
of a runtime route. Mapping-only and mapping-assisted comparisons still need a
held-out dataset with contemporaneous mappings and isolated execution labels.

## Implementation validation

All 46 targeted tests passed after integrating AI into normal selection, including
30 AI tests and existing saved-build, retained-build, head-only, and cache checks.
The CLI validation script also passed.

Normal selection integration checks preservation of the deterministic baseline,
75/74 threshold behavior, unknown/model-error retention, budget limits, unresolved
methods, cancellation, comment-only edits, and full-suite short-circuiting. The
saved-build selection test also exercises the AI wrapper and verifies build identity
and selected IDs remain intact. CLI checks cover --ai/--no-ai, invalid tuning,
the explicit-head requirement, disabled-template loading, and removal of ai select.
Mapping-path regressions cover equivalent relative spellings, absent optional
defaults, and historical lookup independent of working-tree symlinks.
These are controlled integration tests, not historical runtime accuracy evidence.

Stencil integration passed all 23 focused AI tests plus the CLI validation script.
Checks cover unchanged default text, literal Swift source, loops/conditions/filters,
label isolation, errors in later cases failing before inference, size abstentions,
and exact template/rendered-prompt metadata. The examples render all 12 historical
inputs within budget. A live on-device check using the custom example templates
also completed; its rendered-prompt digest matched the render-only preview. This
is an integration check, not a new historical accuracy claim.

All 17 focused AI tests and the CLI validation script passed after threshold
selection was added. Selection is checked at 0/74/75/76/100, with custom metrics thresholds,
unknown/error retention, multi-pair deduplication, revision isolation, rejection of
stale/duplicate/incomplete reports, and invalid arguments before model invocation.
The earlier standalone-selection CLI was removed when AI became an opt-in flag
on normal selection. Library-level threshold checks remain for benchmark metrics.

After mapping integration, all 14 focused AI tests and the CLI validation script
passed. Added checks cover historical JSON versus dirty working copies, fixture
selector expansion, cyclic dependency closure, class/method annotation scope,
condition preservation, compiler-bound inline rules and symbol identity, missing
custom paths, invalid/symlink mappings, input overwrite protection, and explicit
budget omissions. The two-case live synthetic smoke evaluation exited 0.

After the percentage-output change, all nine focused AI tests and the CLI
validation script passed. Tests cover 0/100 bounds, the 49/50 threshold boundary,
invalid scores becoming abstentions, explicit JSON nulls, Brier score, and provider
errors not contributing a probability. The CLI's unavailable-model check was
skipped because the real model was available; the injected-error tests passed.
The live percentage-output evaluation completed all 12 requests with exit 0.

Validated with Xcode 27.2 / Swift 6.4.2 on Apple Silicon macOS 26:

- Package build passed; Foundation Models is weak-linked (`LC_LOAD_WEAK_DYLIB`).
  Runtime execution on macOS 13 and compilation with an older SDK were not tested.
- The initial `swift test --filter ai` run passed 100 matching tests. The final
  focused `swift test --filter '^TestImpactTests.ai'` run passed all seven new tests.
- `python3 Scripts/ai_cli_test.py` passed argument validation, immutable revision
  preparation, duplicate case rejection, symlink/input overwrite protection, and
  unavailable-provider report/exit-status checks. It does not require inference.
- The 12 historical inputs were prepared and evaluated through the real CLI.
  The initial run exited 2 with unavailable-model errors. The enabled-model retry
  produced 11 predictions and one decoding error, preserving every row and exiting
  2 to signal the partial failure. Both reports are retained above.
- The existing `Scripts/integration_test.py` fails before graph extraction because
  the installed SwiftPM build system produces `out/Products/Debug` without the
  expected `description.json`. The same failure was reproduced on an untouched
  export of upstream `bee44895d15be8abb2c6d8b2a47d46428a018b0e`; it is not introduced
  by the AI command. That broader integration check is not claimed as passing.
