# Scoped helper binding reviews

Scoped helper binding reviews can discharge two identity gates:

* Declaration inventories containing supported SDK property wrappers, result
  builders or global actors. Each construct needs its exact source location,
  resolved SDK identity, and review evidence.
* Unsupported imports in one source file reached from one changed helper. The
  review covers that source's exact written and compiler-observed bindings,
  including transitive dependency exports, host modules and historical identity.

This is an explicit **reviewed declaration**, not compiler-proven isolation or
observed test coverage. It is not a package import allowlist. An unchanged
`Package.resolved` file alone does not establish the review. Inspect the actual
captured dependency sources/products, SDK declarations and module exports, and
account for the base bindings. If those inputs do not establish a binding, leave
it unreviewed. Do not copy the review-context inventory into an approved policy.

## Authoring and invalidation

A helper fallback report supplies `helperBindingReviewContext`. It contains the
base/head source digests, exact source/compiler binding digests for each source
revision, captured input digest, build context, supported construct identities,
and required guarantees. Its `helperSymbols` supplies the exact helper source/compiler
identities. Only sources eligible for this review appear as candidates; unsupported
macros remain in the complete raw declaration inventory.

Use the saved-capture workflow to author reviews without a self-referential Git
commit or a new build:

1. Capture the exact code revision with the usual `select --head-only --head`
   command, `--build-time-sil`, and `--retain-build`. Keep the report and graph.
2. Inspect `helperBindingReviewContext` and perform the identity review described
   above. Save the reviewed records as a JSON **array** in a separate file, such
   as `reviews/helper-bindings.json`. The file may be committed after the code
   revision; `headRevision` continues to identify the captured code revision.
3. Re-select the saved capture, using the original project, scheme, destination,
   configuration, plan, mapping path and exact base/head revisions:

   ```sh
   swift-test-impact select --project App.xcodeproj --scheme App \
     --destination 'platform=iOS Simulator,id=SIMULATOR_ID' \
     --head-only --base BASE_SHA --head CAPTURED_HEAD_SHA \
     --head-graph /path/to/retained/head-graph.json \
     --helper-binding-reviews reviews/helper-bindings.json \
     --strict-mappings --format json --output reviewed-report.json
   ```

   `--selection-scopes` also works with this saved capture. No compiler, build,
   discovery or test execution is needed. The original graph stays unchanged.
4. Inspect the decisions, exact selection preview and remaining diagnostics.
   Verify or execute with the original graph and products using `verify-build`
   or `run`. The report retains the full applied records in
   `appliedHelperBindingReviews`, including their guarantees and evidence.

The overlay replaces only the capture's binding review array; it cannot alter UI
mappings, compiler edges or source snapshots. `helperBindingContracts` remains
the internal mapping representation, but committing a record into the captured
head itself cannot satisfy its own `headRevision`. Use the separate policy file.
Saved selection requires the persisted head-only build audit; old captures must
be refreshed, and script/generated-input uncertainty is never discarded.

Each review record has these fields (all are required):

| Field | Meaning |
| --- | --- |
| `version`, `id` | Version 1 and a unique review ID |
| `helper`, `helperSymbol` | One exact helper source key and compiler symbol |
| `revision`, `sourceKey` | `head` or `base`, and an owned `Module:path` key |
| `baseRevision`, `headRevision` | Exact compared Git revisions |
| `baseSources`, `headSources` | Complete source/ownership digests |
| `buildContext`, `capturedInputs` | Effective compiler settings and captured compiler input/product bytes |
| `bindings` | Exact source/compiler observations for this source revision |
| `constructs` | Every inventory issue, each with `issue`, resolved `identity`, and `evidence`; empty for import-only review |
| `imports` | Exact unsupported import declarations being reviewed; empty for synthesis-only review |
| `guarantees`, `evidence` | All required identity/export/host/historical guarantees and concrete review evidence |

Use separate records for base and head, even when source bytes are unchanged.
A review cannot authorize an unowned historical source. Changed source,
ownership, compiler observations, package source bytes, retained dependency
products, effective settings, toolchain, SDK/runtime or review revisions invalidate
the applicable declaration. Captured input seals include the completed build's explicit transitive import maps,
Swift/Clang module bytes, module maps, compiler and standard plugin bytes, source
input digests and retained products. Unknown import-map fields, missing binaries
and custom plugin resource paths leave the evidence unavailable, with the reason
in `captureFailure`. Compiler response files are recursively expanded before
plugin checks; missing, cyclic or excessively nested response files fail closed.
Their bytes are included in the input seal. No additional compiler invocation is needed.

Captured input seals include paths and build metadata;
a new capture generally requires a new review. Legacy captures lack the necessary
input and conditional reference inventories and cannot opt in. Input evidence
version 1 predates response-file validation and is rejected; version 2 requires
a fresh capture and review.

Raw completeness/import flags are never changed. Reports keep the raw declaration
inventories and expose `helperBindingDecisions` (`invalid`, `valid-unused`, or
`discharged`). Discharge means the specific identity boundary was used, not that
all helper isolation checks succeeded. `helperContractPreview` compares exact
selected identifiers with all reviewed helper declarations disabled.

## Boundaries that remain conservative

Arbitrary attached/freestanding macros, custom wrappers/builders/actors,
reexports, scoped imports, missing metadata and unowned historical declarations
are unsupported. SDK namesakes, source aliases, operators, overrides and lifecycle
declarations still pass through the existing binding audits. A synthesis review
does not mark a declaration body safe: synthesized accessors/callbacks reached by
the helper still need compiler effect proof. An import review grants no effect
contract to any imported function, factory, callback, formatting witness or state
access. Changed or removed historical callers remain conservative.

This supports part of #58/#83 without claiming the conditional 153/52 UI targets.
The real-app inventories contain Testing/Observation and other macro expansions;
SDK wrapper reviews cannot establish those expansion boundaries.
See [validation results](HelperBindingValidation.md) for compiled regressions,
fresh consumer captures, exact selection differences and remaining blockers.
