# Mapping maintenance

The repository includes a reusable Codex skill for creating, improving, explaining,
and auditing UI mappings. AI reasoning happens during maintenance; ordinary test
selection remains deterministic and graph-based.

Install the skill from this checkout:

```sh
mkdir -p "${CODEX_HOME:-$HOME/.codex}/skills"
cp -R skills/ui-inline-mappings "${CODEX_HOME:-$HOME/.codex}/skills/"
```

Invoke `$ui-inline-mappings` with the requested task, captured graph paths, existing
configuration and any representative comparison. Coverage and previous test runs
are optional. The skill preserves unrelated rules and runtime policies.

## Deterministic review

```sh
swift-test-impact mapping-review --graph head-graph.json --output audit.json
swift-test-impact mapping-review --graph head-graph.json \
  --mappings proposed.json --base-graph base-graph.json \
  --changes changes.json --output review.json
```

These commands read existing captures; they neither build nor execute tests.
`--mappings` is a complete proposed central JSON configuration. Inline directives
remain part of the captured source evidence. The input files are never modified;
output cannot overwrite an input. Audit findings are JSON data (exit 0), including
`valid`, `errors`, graph diagnostics, full enabled inventory, per-rule compiled
root IDs and matched test IDs, unmatched entries/selectors, unmapped UI tests and
maintenance suggestions. Invalid command input or undecodable files fail normally.
Use the capture's dependency function dictionary to inspect any root's full name,
source regions and outgoing edges. Fixtures and explicit feature dependencies are
listed separately so shared policy is visible. Broad/overlapping rules are
suggestions, not structural failures.

`changes.json` is a JSON array of `FileChange` values (also available from the
library's `GitChanges` API), for example:

```json
[{"path":"App/Checkout.swift","oldRegions":[{"path":"App/Checkout.swift","startLine":12,"endLine":12}],"newRegions":[{"path":"App/Checkout.swift","startLine":12,"endLine":12}],"isPureMove":false,"requiresFallback":false}]
```

Supply actual matching base/head captures and diff regions. The preview evaluates
both central policies against the **same** compiled comparison, with each policy
applied at both revisions. It reports added/removed tests and suites, full before/
after selection reports (including counts, dependency/mapping explanations and
condition decisions), and new fallback diagnostics. Historical inline directives
remain attached to their respective source revisions. Without both a base graph
and changes, the output explicitly states that no representative preview ran.
This is a policy comparison, not a completeness or full-run-equivalence proof.

Strict symbol validation checks every entry independently. The maintenance audit
additionally checks source patterns and test selectors, including a stale symbol
in a feature whose other symbols still match. Structural schema validation checks
fixture references, feature dependencies and cycles. Suggestions for new suites
or narrower patterns still require source and behavior review.

Examples to exercise: repair a renamed symbol without changing a sibling rule;
map a newly discovered suite; inspect a rule covering most of the inventory;
retain an intentional authentication/checkout overlap; optionally review a
[coverage proposal](UICoverageMappings.md) and its original provenance.
