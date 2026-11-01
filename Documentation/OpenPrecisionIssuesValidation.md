# Remaining helper precision issues (#58, #61, #83)

Based on main `363f9a6269ea8d10e20de9f40a78230d822f12ff`.

## Changes

Exact reviewed formatting contracts now support the four scalar XCTest relational
assertions (`>`, `>=`, `<`, `<=`), including the SDK `CGFloat` comparison reported
in #58. The overload, producer, substitutions, helper, source revisions, SDK,
toolchain and captured build evidence remain bound. This closes the contract
expressiveness gap; it does not automatically grant the formatting guarantee.
Containers, project comparison witnesses, ambiguous type identities, unrelated
assertion overloads and unknown compiler metadata remain unsupported.

Private-helper reports now enumerate all incomplete declaration inventories in
`helperDeclarationInventories`, with every attribute/macro spelling, physical
line/column, possible declaration/effect and the required evidence. The separate
`helperDeclarationAudits` field ties those inventories to helper identities and
SDK member/operator names under audit. Both revisions and unowned historical
sources remain visible even when an earlier proof fails. Old archives request
refreshed metadata explicitly. This implements #83's actionable-evidence outcome;
it does not authenticate arbitrary SwiftUI attributes or infer module isolation
from source imports.

#61's extension entries, repeated plain headers and scrolling-helper body were
already supported on main. Their remaining formatting and declaration-inventory
boundaries use these same reports. No dependency, callback, historical caller,
shared-state or lifecycle uncertainty is removed by the diagnostic changes.

## Automated validation

Compiled fixtures cover every relational overload, SDK `CGFloat` frame producers,
exact before/after selected IDs, retained positive callers, source/build/toolchain
invalidation, overload/substitution mismatches, missing compiler/receiver data,
unknown witnesses, historical formatting conformances and aliases, escaping
method references, lifecycle changes and independent state effects.

Inventory fixtures include SwiftUI wrappers/builders, unsupported actor import
contexts, inactive macros, trusted compiler attributes/literals, legacy archives,
removed/unowned sources and 1,041 incomplete source inventories without truncation.
Native compiler-plugin regressions retain fallback for generated operators,
globals and members, with their actual historical dependency edges verified.

## Consumer reproduction

Each comparison uses a fresh head-only capture with Xcode 27.1 and iOS 26.2, the
existing normalized Swift-only base/head revisions, the complete plan, strict UI
mappings and its original independent `regression-support` scope. No source edit,
base compiler build, saved base graph or historical application test execution is
required. Captured products are verified for the raw and scoped reports.

Run the analyzer from the matching consumer checkout, substituting the exact
recorded revisions and paths:

```sh
swift-test-impact select \
  --project ChainOfCustody.xcodeproj --scheme ChainOfCustody \
  --test-plan ChainOfCustody --configuration Debug \
  --destination 'platform=iOS Simulator,id=SIMULATOR_UUID' \
  --base BASE --head HEAD --head-only --strict-mappings \
  --build-time-sil /path/to/SwiftTestSelection/Scripts/capture-build.py \
  --retain-build /path/to/new-retained --selection-scopes scopes.json \
  --format json --output impact.json

swift-test-impact verify-build \
  --project ChainOfCustody.xcodeproj --scheme ChainOfCustody \
  --test-plan ChainOfCustody --configuration Debug \
  --destination 'platform=iOS Simulator,id=SIMULATOR_UUID' \
  --strict-mappings --report impact.json \
  --head-graph /path/to/new-retained/head-graph.json
```

The opt-in `retainedHelperFormattingReview` fixture can compare existing reviewed
declarations against the same captured head and verify exact selected-ID previews.
A declaration discharge is local to its boundary, not proof of whole-helper
isolation. Hypothetical declaration experiments must remain separate from reviewed
consumer policy. The conditional 52/153/46 UI targets are not acceptance overrides.
