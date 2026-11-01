# Scoped helper binding reviews

`helperBindingContracts` in the mapping file can discharge two identity gates:

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

Each mapping entry has these fields (all are required):

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
in `captureFailure`. No additional compiler invocation is needed.

Captured input seals include paths and build metadata;
a new capture generally requires a new review. Legacy captures lack the necessary
input and conditional reference inventories and cannot opt in.

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
