# Consumer precision for #101

Both comparisons use the original application and test edits with ChainOfCustody's normalized CI overlays. Each runs the consumer's selector and retained-product verification on a fresh iOS 26.2 simulator build using Xcode 27.2. The consumer installer points to the local release executable and its capture helper. The primary query and the independent regression-support query share the head build. The selection replay stops after product verification. Focused execution results are recorded separately below.

[Download the full identifier sets and capture hashes](ConsumerPrecision101.json.gz). The JSON includes the original and normalized revision pairs, scoped requests, raw primary and scoped selections, fallback-only candidates, runtime decisions, possible historical callers, and the final Base UI, Regression UI and non-UI lists. The comparison baseline is the consumer's capture at 529ed44.

| Comparison | Base UI | Regression UI | Final UI | Final non-UI | Scoped positive / fallback-only UI | Unresolved-test diagnostics before → after |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| #380 | 47 | 313 | 360 | 1,848 | 1 / 359 | 1,618 → 1,406 |
| #383 | 47 | 316 | 363 | 1,853 | 43 / 320 | 1,623 → 1,411 |

The exact final execution IDs match the prior pin for both comparisons. This change saves zero test executions on the two complete policies. Four #380 entries and one #383 entry formerly counted as positive regression-support candidates already run independently and remain in the final UI sets. #383's scoped structural fallbacks decrease from seven to five. Adding known witness paths also exposes opaque runtime paths for 88 additional #383 non-UI tests already retained by fallback.

Each capture consumed all ten build-time SIL modules with zero global compiler diagnostics. The strict UI mappings cover every enabled UI method. Both retained-product checks passed. In the evidence file, diagnostics with multiple tests refer to an exact list in `diagnosticTestSets` to keep the archive compact.

**Focused execution.** Using the verified products with `test-without-building`, both #380 historical caller tests passed. On #383, `PairingNoteActivityUITests/testOpeningEmptyNoteReadsCreationAndPersistsWithoutVisitingActivity()` passed, including its second launch. All three requested methods executed with zero skips. The full historical suites were not timed or rerun.

## #380

All three historical references to the removed private helper `replyDestination(_:in:)` map to two surviving compiled methods in `NoteConvertedBlockUITests`. They are `testConverterCommentsCombineSourceResultAndConverter()` and `testCopiedConverterIncludesOriginalConversations()`. Two uses occur inside chained expressions. The owner mapping preserves those methods as possible consumers. Historical overload binding and the effects of the removed query still need independent evidence.

The historical `waitForAllConditions` takes an array of closures. A compiler control using the original `TestSupport/ConditionWaiter.swift` rejected forwarding a nonescaping predicate as `[predicate]` and accepted the same code with `@escaping`. The implementation captures that array in an `NSPredicate` and supplies it to an `XCTNSPredicateExpectation`. The Xcode 27.2 simulator SDK header declares that the expectation copies its predicate and stops evaluating it after fulfillment. A proof for this helper must account for callback invocation through XCTest on completion, timeout and interruption. A synchronous return type alone cannot establish that lifetime.

## #383

Two newly named XCTest entries can use the independent execution policy. Removed callers with different declaration keys have no verified successor. The `testAddBlockButtonShrinksAndExpandsWithScrollAndTap` entry also changes its throwing signature. Matching solely by method name would discard the historical binding question.

The application helper sets `COC_UI_TEST_CONVERSION_UNREAD` and launches the app. The fixture in `ChainOfCustody/App/NoteURLUITestFixture.swift` seeds activity and comment read receipts. Both view-history implementations default to `UserDefaults.standard`. Launch can reset that state through `AppNavigationPreferences.reset()`, and `PairingNoteActivityUITests` explicitly disables this reset for a relaunch that checks persistence. The in-memory UI-test cache alone cannot isolate this state. A scoped effect proof must retain these fixture readers and writers, including relaunches.

## Swift Testing

The factory-type proof binds the literal metatype passed to the SDK and the compiler owner of the test method. Project witness tables add positive paths from a factory's concrete existential payloads to matching runtime trait methods. Unresolved trait/scoping callbacks and generic argument iteration still require coverage. For the named `CacheRecoveryTests/localCacheCloudRecoveryMarkerMergesAndClearsByRequestID()` entry, both captures contain three-symbol paths from a suite factory through a conformance witness to `IsolatedCloudPersistence.scopeProvider` and `IsolatedCloudPersistence.provideScope`. These concrete paths do not establish completeness for other runtime conformances. The app-hosted target retains its own runtime fallback.
