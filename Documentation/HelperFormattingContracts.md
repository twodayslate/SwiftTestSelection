# Reviewed helper formatting contracts

`helperFormattingContracts` is an opt-in, review-scoped addition to the existing
mapping file. Version 1 supports the runtime failure formatting of an exact generic
`XCTest.XCTAssertEqual` call whose equality witness is already supported, or an
exact scalar `XCTAssertGreaterThan`, `XCTAssertGreaterThanOrEqual`,
`XCTAssertLessThan`, or `XCTAssertLessThanOrEqual` call whose SDK comparison witness
is supported. Examples include equality on `XCTWaiter.Result` or
`Optional<String>`, and relational comparisons on `CGFloat` or `Int`. It is
available in head-only helper analysis. A relational declaration does not authorize
an equality/accuracy overload, a different producer, a container or a project
`Comparable` witness. SDK scalar identity still requires the ordinary source,
import, alias and compiler binding checks.

This is a maintainer assertion, not proof that an arbitrary implementation is
pure. The analyzer still proves helper accessibility, nonescaping callers,
base/head source bindings, callback restrictions, SDK receiver origins, and
lifecycle and state checks. It preserves compiler dependencies and feature
mappings. There is no consumer allowlist, wildcard symbol, general isolation
switch, or observed-coverage prerequisite.

## Review and authoring

1. Run the ordinary head-only selection with the captured head build. Keep
   `--build-time-sil`, `--strict-mappings`, `--retain-build`, and retained-product
   verification. Declarations require captured build-input provenance.
2. Inspect `formattingBoundaries` and the associated diagnostic's `fallback`.
   `helperContractReviewContext` provides exact source digests, the actual base
   revision, captured toolchain and candidate helper symbols. These are binding
   facts, **not generated completeness assertions**.
3. Review the producer's exact assertion overload and concrete substitutions,
   both source revisions, and the formatting/reflection behavior of all relevant
   runtime conformances, including external dependencies. Establish that formatting
   cannot mutate shared state/resources, register or escape callbacks, or produce
   test/SDK receivers through results, errors, callbacks or mutations. A statement
   that the call is normally successful is insufficient: failure paths matter.
   The guarantee concerns formatting the compared values; ordinary XCTest failure
   recording and evaluation of assertion expressions keep their existing checks.
4. Write a declaration with the following fields in the existing mapping JSON's
   `helperFormattingContracts` array. Copy identities exactly; do not abbreviate
   or glob them. Include a rationale describing the review evidence.
5. Rerun selection. Inspect `helperContractDecisions`, `helperContractPreview`,
   and **all remaining diagnostics**. The preview compares exact selected IDs
   with and without these declarations using the same immutable head graph,
   comparison and independent selection scope. It performs no additional build.

| Field | Meaning |
| --- | --- |
| `version` | `1` |
| `id` | Unique review identifier |
| `helper` | Exact source-unit key of the changed helper |
| `helperSymbol` | Exact compiled function ID resolving inside that helper |
| `producer` | Exact source-unit key enclosing the assertion |
| `producerSymbol` | Exact compiled caller/closure ID containing the generic call |
| `assertionSymbol` | Exact mangled XCTest overload |
| `substitutions` | Exact captured generic substitutions, e.g. `Optional<String>` |
| `baseRevision` | Exact resolved base revision from the selection report |
| `baseSources` | Report's semantic digest of owned and unowned historical sources |
| `headSources` | Report's semantic digest of captured head sources |
| `toolchain` | Exact captured toolchain string, including newlines |
| `buildContext` | Report's fingerprint of captured scheme, configuration, SDK, architecture, destination, runtimes, effective build settings and ordered compiler invocations |
| `guarantees` | All three strings below, each exactly once |
| `rationale` | Nonempty explanation of the human review |

The required guarantees are:

```json
[
  "formatting-has-no-shared-state-or-resource-effects",
  "formatting-does-not-register-or-escape-callbacks",
  "formatting-does-not-inject-test-or-sdk-receivers"
]
```

The same complete declaration object can instead be placed on a single native
Swift comment line:

```swift
// swift-test-helper-formatting: { ...complete declaration object... }
```

The abbreviated example is deliberately not a valid declaration. Line, doc and
block comments are read through SwiftSyntax trivia. Text inside string literals
is not a directive. The declaration's explicit identities determine its scope;
its placement does not infer a type, overload, suite or consumer list. Each distinct
compiled producer/overload/substitution boundary requires a separate declaration.
If that producer invokes the same overload with the same substitutions multiple
times, the declaration covers all those occurrences; version 1 does not bind an
individual instruction offset. Duplicate IDs, including a
copy in both central and comment form, are rejected.

## Revision and invalidation rules

Declarations apply to a **particular review comparison**, not indefinitely to a
suite. A new head declaration may cover an explicitly reviewed base/head pair,
including a newly added private helper, only if the ordinary historical source
and caller checks also succeed. It never supplies a missing historical edge.
Base compiler graphs, base builds and historical test execution are not used.

The base revision and both semantic source digests must match. The digest binds
module/file ownership keys, declaration signatures, bodies, imports and
conformances across the complete source inventory. A change to any of these,
including callbacks or apparently unrelated declarations, requires a new review
and new digests. Unknown/unowned historical source is included in the base digest
and still undergoes the existing binding checks. Comparison type aliases and
project namesakes are rejected in the producer's module at both revisions and in
unowned historical sources. A head SDK substitution and a fresh source digest do
not prove the historical comparison witness. SDK helpers also audit historical
caller bodies and transitive producers outside the requested diff. Replacing or
removing an old comparison or effect cannot be justified by a formatting review
of the head assertion. Both helper paths also require unshadowed reserved names
in head, base and unowned historical sources, including implicit literal types
such as `IntegerLiteralType`. Unchanged literal syntax does not prove an unchanged
comparison type, and missing binding metadata cannot grant isolation.
Rename/deletion, ambiguous source
ownership, an absent compiled overload or missing generic substitutions cannot
be repaired by a formatting assertion. Toolchain, SDK, architecture, build-context and simulator-runtime changes invalidate declarations;
consumer policies requiring full toolchain coverage remain in force.

Build-input evidence is captured with the head artifact. It includes normalized
build settings and the ordered Swift compiler arguments, expanding response files
and source-file lists. Only known source/DerivedData roots and irrelevant log
progress are normalized; compiler flags remain semantic. For validated build-time
SIL captures, the exact frontend-wrapper path is also normalized, including its
appearance inside settings flags. The wrapper contents and sealed capture-helper
identity remain bound, so moving the capture does not invalidate a declaration
but changing the capture helper does. Unrelated frontend paths remain semantic. Equivalent captures can
therefore retain the review binding even when paths or log timestamps differ.
The derived evidence must match the artifact's raw settings/log digests. Missing,
stale or legacy evidence (including build-input evidence v1) invalidates declarations; an empty digest cannot bless an
incomplete capture. Retained captures can be refreshed from their authenticated
original files without invoking the compiler. This is separate from reviewing
new guarantees and does not automatically authorize a declaration.

Ordinary prose comments and permitted Markdown edits remain nonsemantic.
Directive adoption, removal or editing participates in selection: affected helpers
become change roots even if their Swift bodies did not change. A central mapping
edit gets this treatment only when every other mapping field is unchanged.
Changes to feature ownership, fixtures, dependencies or runtime policy retain
normal conservative handling. Independent scopes only acquire directive change
roots when the directive's file is in that scope; all applicable contracts still
validate against their own complete base/head source evidence.

Use a freshly captured source snapshot when adopting comment syntax. The analysis
cache identity changed for this feature. Old saved graphs cannot discover comments
that their parser did not preserve. Unsupported two-graph mode does not apply
these contracts; directive edits there select conservatively.

## What validation can and cannot establish

Structural validation authenticates the declared source/compiler identities,
review revisions, substitutions and toolchain. It conservatively rejects project
conformances on the substituted types, including protocols that could inherit or
alias a formatting protocol; analyzing their effects is not supported by version 1.
It also rejects conformance extensions whose owner contains an unresolved type
alias, including qualified, nested, inherited or chained aliases at head or base.
A declaration such as `extension Maybe: CustomStringConvertible`, where `Maybe`
aliases `Optional`, cannot evade the contradiction check. Missing alias/conformance
inventories fail closed. Unused aliases and conformances on independently named,
unrelated nominal types remain supported. These checks do not prove a maintainer's
claims about arbitrary binary/runtime formatting implementations.

The declaration discharges only the missing formatting effect check. It does not
remove any dependency edge or bypass error formatting, thrown/escaping callbacks,
shared/global mutation, fixtures, lifecycle effects, unknown compiler evidence,
structural edits, ambiguous type identities, or historical caller bindings.
Discharging one boundary can reveal a second unresolved boundary; it can also
leave a full selection unchanged.

`helperContractDecisions` reports `invalid` with validation failures,
`valid-unused` when the exact boundary was not reached, or `discharged` with each
exact covered boundary. Discharge does not mean the whole helper proof passed.
`helperContractPreview` labels the selection as dependent on reviewed declarations,
separately from compiler evidence and observed coverage. Invalid declarations
never participate in narrowing; they remain visible in the report.

## Actionable fallbacks

Each Xcode selection diagnostic has structured `fallback` data: changed symbols
and source regions when available, selection scope, effect category, first
unresolved boundary, dependency path when available, applicable revisions,
resolution type and required evidence. Formatting diagnostics point to the exact
supported declaration; unsupported callback/state/lifecycle boundaries explicitly
say a formatting declaration cannot resolve them. Production feature ownership
is reported separately from helper effects.

`tests` retains all tests selected for that uncertainty. `uncertaintyOnlyTests`
separates tests with no positive reason; `overlappingPositiveTests` retains overlap
with compiler/mapping reasons. Broad fallback does not replace known dependency
explanations. Source/build failures without a resolved symbol retain the named
missing input in `firstBoundary`; the analyzer does not invent a source binding.

The preview is an audit of selection, not a CI speed measurement. Measure build,
selection, product verification and actual execution end to end before claiming
savings. Full runs remain useful for validating maintainer assumptions.

### Incomplete declaration inventories

`helperDeclarationInventories` lists **every** incomplete head, base and unowned
historical source inventory participating in a private-helper audit. Each entry
names the source key and revision, then every unsupported attribute/macro with
its physical line/column, possible synthesized declarations/effects, and required
evidence. `helperDeclarationAudits` identifies the affected helper keys, SDK
member/operator names, and protected lifecycle/global/member binding categories.
These are possible conflicts under the current whole-inventory audit, not claims
that a particular attribute actually creates a colliding declaration.

The list is preserved even when an earlier compiler, formatting, callback or
historical binding check stops the proof. Ordinary diagnostic messages stay
compact and point to these fields. Legacy snapshots without construct metadata
explicitly request refreshed source proofs instead of inventing a location or
attribute identity (line/column 1 denotes the whole-file missing-evidence entry).

SwiftUI wrapper/result-builder spellings and actors imported through unsupported
module contexts still require authenticated declaration/expansion and module
export/host evidence at both revisions. A head SIL source location does not prove
historical macro expansion or exclude generated globals, operators, SDK members,
aliases, conformances or lifecycle hooks. Neither feature mappings nor a formatting
contract supplies that evidence. The report does not discard other targets or
base-only files merely because their source imports appear unrelated.

See [open precision issue validation](OpenPrecisionIssuesValidation.md) for the
relational fixtures, complete-inventory diagnostics and fresh consumer captures.
See [issue #81 validation](Issue81Validation.md) for compiled negative fixtures,
reviewed real-app declarations, exact selection IDs, and remaining blockers.
