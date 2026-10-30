---
name: ui-inline-mappings
description: Create, improve, explain, or audit SwiftTestSelection UI feature mappings using captured compiler graphs and deterministic validation. Use for mapping maintenance, not per-change LLM test selection.
---

Use the user's existing SwiftTestSelection CLI and captured build configuration.
Read its `--help`, the repository's [mapping schema](https://github.com/twodayslate/SwiftTestSelection#ui-feature-mappings),
[inline mapping documentation](https://github.com/twodayslate/SwiftTestSelection/blob/main/Documentation/InlineUIMappings.md),
and [maintenance commands](https://github.com/twodayslate/SwiftTestSelection/blob/main/Documentation/MappingMaintenance.md).
Prefer the matching local checkout's versions of these documents. Do not invent syntax from newer documentation when the installed tool does not support it.

Run `mapping-review --graph HEAD_GRAPH --output AUDIT.json` first. This reuses
analysis without building or running tests. Keep the complete JSON inventory
available; present counts and representative matches in the explanation. A graph
belongs to a revision, test plan, destination and configuration: disclose mismatches
and request the missing capture if it cannot answer the user's question. Do not
start expensive collection or coverage runs just to maintain mappings.

## Create or improve

Read existing mappings, enabled test identifiers, compiler roots, relevant production
and test code, helper behavior, and launch inputs. Prefer maintainable suite selectors.
Names suggest where to investigate; they do not prove dependency completeness.
Associate shared startup dependencies intentionally and preserve fixtures, explicit
feature dependencies, and runtime policies. Never automatically enable a declared
runtime-completeness contract.

Limit updates to the requested features and affected entries: renamed/moved files
or symbols, added/deleted suites, and changed helper relationships. Preserve unrelated
configuration. Generate a separate candidate file or reviewable patch; validate it
with `mapping-review --graph HEAD_GRAPH --mappings CANDIDATE`. Every symbol/path
must resolve independently, even when another entry in the same feature matches.
For inline proposals use `inline-proposal`; verify its source digest before applying
the insertion. Unsupported ancestry needs fresh compiler evidence or an explicit JSON
rule, not disabled strict validation.

When representative base/head graphs and changes are available, add
`--base-graph BASE_GRAPH --changes CHANGES.json`. Inspect added/removed methods
and suites, counts, and new fallbacks before applying a narrowing. Explain its
tradeoff and unresolved evidence. If no comparison was supplied, say that the
preview is absent; do not substitute fabricated compiler evidence.

Coverage is optional. If the user supplies an ordinary-run coverage proposal, read
[coverage proposal documentation](https://github.com/twodayslate/SwiftTestSelection/blob/main/Documentation/UICoverageMappings.md).
Keep measured observations/provenance separate from source-inferred associations
and explicit user declarations. Unobserved coverage is not proof of no dependency. Do not infer AND conditions from co-execution. Preserve class defaults and inherited rules when migrating comments; removing equivalent central rules must be part of the requested migration.

## Explain

Resolve each feature's sources, symbols, fixtures, selectors and `dependsOn` using
`mapping-review`. Report exact matched methods/counts and representative compiled
roots, and link the full JSON. For a real diff, inspect `preview.before`/`after`:
explanations contain compiler paths, explicit mappings and fallback reasons;
condition decisions show true, false and unresolved AND/OR operands. Explain that
other rules can independently select the same suite. A dependency path establishes
a compiled relationship, not measured behavioral coverage.

## Audit (read-only)

Separate `errors` and graph diagnostics from maintenance `suggestions`. Report
partially stale features, unmatched paths/selectors, missing feature/fixture
references, unmapped UI suites, and unresolved build evidence. Broad or overlapping
rules may be intentional shared coverage. A successful audit validates structure
and resolution, not whether tests exercise all declared behavior. Audit/explain
requests do not authorize edits, recurring automation, test execution or external
messages.

## Typical maintenance decisions

- Renamed symbol: resolve the new compiled identifier, replace only the stale entry,
  preserve siblings, then validate and preview the same representative diff.
- New suite: inspect its launch inputs and helpers, add a suite-level association,
  and check the entire enabled inventory for remaining unmapped methods.
- Broad rule: show its actual inventory fraction and alternative boundaries;
  preview any narrowing and disclose what evidence remains unproven.
- Shared dependency: retain deliberate overlap (for example authentication plus
  checkout) and explain both selection paths.
- Coverage-assisted proposal: review the measured positive evidence alongside
  source/graph evidence; preserve its provenance and do not require coverage for
  any of the other workflows.
