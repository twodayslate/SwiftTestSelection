---
name: ui-inline-mappings
description: Create, improve, explain, audit, or migrate SwiftTestSelection inline XCTest UI dependency mappings using compiler-backed audit and source proposal tools. Use for mapping maintenance, not per-test LLM selection.
---

Use the repository's deterministic mapping tools. Locate the SwiftTestSelection
checkout and read `Documentation/InlineUIMappings.md` for maintained syntax,
composition, command usage and supported evidence. Read its reviewed migration
section before moving file rules into comments. Use the user's selected build,
test plan and configuration; a declaration name alone is not an executable identity.

For **audit or explanation**, keep source and configuration unchanged. Run
`swift-test-impact inline-audit --graph GRAPH` and inspect each rule's enabled tests,
resolved symbols, unresolved entries and binding diagnostics. For a real diff, use
`select --format json` with the normal Xcode comparison options. Explain the rule's
source location and compiler path or condition operands, including false/unresolved
operands and any independently selecting rules or fallbacks. The audit covers only
the active inventory, not every disabled test or configuration.

For **create or improve**, use the audit plus relevant production/test code and
helpers to establish boundaries. Preserve class defaults, shared startup/service
relationships, existing file rules and global policies. Produce a reviewable source
insertion with `inline-proposal`; do not hand-invent selector strings or unsupported
payload keys. A renamed symbol needs validation of every old entry even if another
entry still resolves. A new suite needs its own enabled-inventory binding. Treat a
broad shared rule as a review tradeoff, not automatically a mistake to remove.

Coverage is optional positive evidence. If given a validated version-1 coverage
proposal, use `inline-proposal --coverage-proposal FILE --target TARGET` with its
exact source module and suite. Preserve the original proposal/provenance and other
suites' shared associations. Do not infer AND conditions from co-execution, prune
unobserved dependencies, or collect coverage solely because this skill is loaded.

Apply source edits when the user's maintenance request authorizes them, checking the
proposal's source digest against the current file first. Keep the change additive
unless the requested migration explicitly includes removing equivalent file rules.
Recapture/reuse compatible compiler evidence, run strict validation, and compare
selection before/after for representative diffs. Report added/removed tests and new
fallbacks. If no representative diff was supplied, disclose that limitation rather
than presenting schema validity as a completeness proof. Do not silently enable a
declared runtime-completeness contract.

No mapping file is required for inline-only dependencies, but a file may still hold
shared feature dependencies, fixtures and global policies. Preserve those semantics
through migration. Head-only policy edits remain conservatively broad because old
compiler bindings are unavailable; do not describe that fallback as precise coverage.
