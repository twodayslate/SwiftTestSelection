# Precision tickets #60–62 validation

Follow-up: [issue #61 validation](Issue61Validation.md) records the control-flow support, remaining `Optional<String>` formatting boundary, and historical policy replay for the two #291 comparisons. The measurements below describe the earlier implementation.

This PR fixes the SDK gesture-velocity identity rejection (#60), recognizes bodyless Swift protocol initializers (#62), and supports independent XCTest entries and bounded private helpers in plain extensions (#61). It does **not** restore the proposed focused real-app selections. The remaining blockers below stay conservative; #58 remains open, and #61 still needs a control-flow effect proof for its real scrolling helper.

## Implementation boundaries

- `XCUIGestureVelocity` requires trusted imports and no project type or alias shadow. Only its exact importer-synthesized equality witness is contracted, alongside the existing immutable SDK constants. Generic raw-representable operations, unrelated conformances and formatting remain unproven.
- A bodyless Swift protocol initializer is explicitly distinguished from an implementation, including `@objc` selector annotations. SDK-owner declarations, aliases, default implementations and missing evidence retain fallback. Diagnostics name the rejected owner/member and source location, including when the rejection occurs in a transitive SDK helper.
- Multiple plain extension headers are containers rather than ambiguous callables. Their owner must resolve uniquely to the same existing final XCTest hierarchy at both revisions. Added methods still enter the primary selection; only an explicit separate-execution scope can omit independent entries. Attributes, conformances, conditions, aliases and incomplete bindings remain conservative.
- Private helper callers may span their class and plain extensions in one file. Primitive literal defaults include their compiler-generated thunks in the effect check. Escapes, lifecycle callers, shared effects, competing overloads and effectful defaults remain unsupported. Nested local declarations in control flow report the exact source line requiring further evidence.

Private-helper proof version is 10; the module-fragment cache is version 15. Legacy initializer/extension metadata does not grant the new exemptions. Unsupported syntax prevents an added helper from establishing isolation; it does not by itself force a full run for a surviving body with an unchanged header. Those bodies retain ordinary dependency selection and runtime uncertainty fallbacks.

## Fresh consumer captures

The capture and replay measurements below were recorded at PR commit `8114257`, before the surviving-helper diagnostic refinement. A separate compiled regression checks that refinement with both complete and opaque dependency graphs.

Each comparison used one fresh head `build-for-testing` with supplementary SIL, all ten modules, a complete normalized test plan and UI mapping, and the original scope/excluded-entry policy. No base compilation or compiler replay occurred. #301, #293 and #299 include the consumer’s Swift touch-helper rewrite identically on both review sides. The two #291 comparisons retain the original historical sources. Handwritten Objective-C is not analyzed.

The capture executable includes the declaration/metatype fixes. The final release selector then re-queries those same retained graphs with the completed equality contract and diagnostics. The opt-in replay refreshes source proofs, checks identical source keys and semantic fingerprints, and leaves compiler edges, inventory and products untouched. Both initial reports and final scoped reports pass `verify-build`. Exact revisions, artifact hashes, metrics and remaining messages are in [the machine-readable record](PrecisionTickets60-62.json).

| Consumer / historical run | Scope UI selected | Known consumers retained | Declaration fallbacks | Remaining blocker |
| --- | ---: | ---: | ---: | --- |
| #301 / 40340806833 | 403 (full inventory) | 2 | 1 | XCTest formatting of `XCTWaiter.Result` |
| #293 / 40058859478 | 394 (full inventory) | 12 | 0 | Indirect callback error formatting in `waitForAllConditions` |
| #299 / 40159996488 | 403 (full inventory) | 125 | 0 | Indirect callback error formatting in `waitForAllConditions` |
| #291 / 40031610717 | 384 (full inventory) | 1 | 0 | Nested loop-local value in `revealInboxFilter` |
| #291 / 40035642452 | 397 (full inventory) | 1 | 0 | Nested loop-local value in `revealInboxFilter` |

The #301 scope retains both genuine navigation-helper callers; the 43-UI target is not achieved. The Swift-only #293 scope retains all 12 sharing-helper consumers; the 52-UI policy target is not achieved. #299 retains all 125 waiting-helper consumers; its 153-UI candidate target is not achieved. Both #291 scopes remove all six former declaration-change diagnostics, retain the scrolling-helper caller, and report the loop-local limitation explicitly; their 46-UI targets are not achieved. These are scope results, not a rerun of the consumer’s tier-policy implementation.

## Release measurements

Capture wall time includes build, enumeration, graph extraction and selection; verification is separate. RSS and footprint are the byte counts reported by macOS `/usr/bin/time -l` for the capture command. Final-query time includes source-proof refresh and scope analysis. These measurements share a development machine with package validation and are not an isolated performance comparison.

| Historical run | Capture seconds | Maximum RSS (MiB) | Peak footprint (MiB) | Final query seconds |
| --- | ---: | ---: | ---: | ---: |
| 40340806833 | 353.49 | 2423.5 | 1923.0 | 20.42 |
| 40058859478 | 368.34 | 2398.6 | 1863.5 | 20.68 |
| 40159996488 | 344.72 | 2466.8 | 1779.9 | 21.64 |
| 40031610717 | 252.03 | 2398.3 | 1849.9 | 8.59 |
| 40035642452 | 258.08 | 2505.0 | 1868.9 | 8.69 |

## Tests and reproduction

The release suite reported 351 passing tests; the opt-in retained-capture replay was skipped in that run and passed separately across all five cases. Seven focused functions also passed under Xcode 26.6, matching CI’s toolchain. The new fixtures cover the real velocity equality loop, project/foreign/escaped namesakes, aliases and comparison overloads; Swift and `@objc` protocol requirements versus default implementations at both revisions; extension entries/helpers, default thunks, escaping references, lifecycle/shared effects, overloads, missing bindings and unsupported headers. Six capture-helper tests passed; five distribution tests passed with one platform-specific skip.

Reproduce a capture using the normalized revisions and `scope` object in the JSON record:

```sh
swift-test-impact select --project ChainOfCustody.xcodeproj \
  --scheme ChainOfCustody --test-plan ChainOfCustody --configuration Debug \
  --destination "$DESTINATION" --base "$BASE" --head "$HEAD" --head-only \
  --build-time-sil /path/to/SwiftTestSelection/Scripts/capture-build.py \
  --retain-build "$NEW_BUNDLE" --selection-scopes scopes.json \
  --format json --output impact.json
```

`scopes.json` has the form `{"version":1,"scopes":[SCOPE_FROM_RECORD]}`. Preserve the original normalization/Swift overlay on both sides. The optional `retainedHeadOnlyPrecisionReplay` test accepts `IMPACT_PRECISION_REPLAY` pointing to an array of replay configurations: `graph`, Git `root`, original `report`, fresh `output` directory, `knownConsumers`, `obsoleteBlockers`, `expectedBlocker`, and `declarationFallbacks`. It performs no application build or test execution.

No application test bodies or full-suite equivalence runs were executed for this PR. Keep the conservative fallbacks and full-run validation requirement before adopting focused selection as a CI gate.
