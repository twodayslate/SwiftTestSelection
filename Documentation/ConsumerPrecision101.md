# Consumer precision for #101

## Recheck at 0e7ae80

The complete policies for #380 and #383 still select every UI test. Fresh captures reproduced every Base UI, Regression UI and non-UI identifier from the earlier capture. Each comparison built the head once, consumed all ten build-time SIL modules, and verified its retained products. The two #380 historical callers and the #383 read-receipt relaunch test passed on those products with zero skips. The complete policies save zero test executions. [Download the exact selections, independent controls, build hashes and focused execution results](ConsumerPrecision101Recheck.json.gz).

| Comparison | Base UI | Regression UI | Non-UI | Scoped UI with a positive reason | Scoped UI selected only by fallback |
| --- | ---: | ---: | ---: | ---: | ---: |
| #380 | 47 | 313 | 1,848 | 1 | 359 |
| #383 | 47 | 316 | 1,853 | 43 | 320 |

Each row below replays one path against the same retained graph and the same independently executed test entries as its original regression-support request. The complete multi-file requests determine the final policies above.

| Comparison | Path in scope | UI selected | UI with a positive reason | Reason for broader UI selection |
| --- | --- | ---: | ---: | --- |
| #380 | `NoteCommentsUITests.swift` | 360 | 1 | Waiting callback effects |
| #380 | `NoteConversionUITests.swift` | 360 | 0 | Deleted helper and historical caller bindings |
| #383 | `NoteURLUITestFixture.swift` | 42 | 42 | None |
| #383 | `NoteConversionUITests.swift` | 363 | 2 | Renamed declarations and the application-launching helper |
| #383 | `PairingNotesUITests.swift` | 363 | 1 | Removed and added test signatures |

For #380, each file independently retains all 360 UI tests. A macOS 27.2.1 control using the original `waitForAllConditions` helper and a five-second timeout observed two predicate calls on completion, six on timeout and two when an outer waiter interrupted the inner wait. No further call occurred during 1.5 seconds of observation after completion or timeout, or two seconds after interruption. An exclusion still needs evidence that XCTest has finished invoking the captured predicate on every exit path, as well as evidence for the removed helper's historical bindings.

For #383, the fresh graph binds the app fixture to physical compiler locations. Its 42 UI consumers can be selected independently. Each changed UI test file still retains all 363 UI tests on its own. The passing relaunch test observes persisted read receipts across two app launches. A proof covering the renamed tests must account for that shared state. The complete diff also edits `ChainOfCustodyCore/Data/AppStore.swift`, inside the declared hostless Core boundary.

## Earlier capture at 9f16d30

Both comparisons use the original application and test edits with ChainOfCustody's normalized CI overlays. Each runs the consumer's selector and retained-product verification on a fresh iOS 26.2 simulator build using Xcode 27.2. The consumer installer points to the local release executable and its capture helper. The primary query and the independent regression-support query share the head build. The selection replay stops after product verification. Focused execution results are recorded separately below.

[Download the full identifier sets and capture hashes](ConsumerPrecision101.json.gz). The JSON includes the original and normalized revision pairs, scoped requests, raw primary and scoped selections, fallback-only candidates, runtime decisions, possible historical callers, and the final Base UI, Regression UI and non-UI lists. The comparison baseline is the consumer's capture at 529ed44.

| Comparison | Base UI | Regression UI | Final UI | Final non-UI | Scoped positive / fallback-only UI | Unresolved-test diagnostics before → after |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| #380 | 47 | 313 | 360 | 1,848 | 1 / 359 | 1,618 → 1,406 |
| #383 | 47 | 316 | 363 | 1,853 | 43 / 320 | 1,623 → 1,411 |

The exact final execution IDs match the prior pin for both comparisons. This change saves zero test executions on the two complete policies. Four #380 entries and one #383 entry formerly counted as positive regression-support candidates already run independently and remain in the final UI sets. #383's scoped structural fallbacks decrease from seven to five. Scoping suite witnesses to their owners reduces #383’s scoped runtime-uncertainty diagnostics from 1,853 in the first PR capture to 1,834. Those tests were already covered by other fallback decisions.

Each capture consumed all ten build-time SIL modules with zero global compiler diagnostics. The strict UI mappings cover every enabled UI method. Both retained-product checks passed. In the evidence file, diagnostics with multiple tests refer to an exact list in `diagnosticTestSets` to keep the archive compact.

**Focused execution.** Using the verified products with `test-without-building`, both #380 historical caller tests passed. On #383, `PairingNoteActivityUITests/testOpeningEmptyNoteReadsCreationAndPersistsWithoutVisitingActivity()` passed, including its second launch. All three requested methods executed with zero skips. The full historical suites were not timed or rerun.

## #380

All three historical references to the removed private helper `replyDestination(_:in:)` map to two surviving compiled methods in `NoteConvertedBlockUITests`. They are `testConverterCommentsCombineSourceResultAndConverter()` and `testCopiedConverterIncludesOriginalConversations()`. Two uses occur inside chained expressions. The owner mapping preserves those methods as possible consumers. Historical overload binding and the effects of the removed query still need independent evidence.

The historical `waitForAllConditions` takes an array of closures. A compiler control using the original `TestSupport/ConditionWaiter.swift` rejected forwarding a nonescaping predicate as `[predicate]` and accepted the same code with `@escaping`. The implementation captures that array in an `NSPredicate` and supplies it to an `XCTNSPredicateExpectation`. The Xcode 27.2 simulator SDK header declares that the expectation copies its predicate and stops evaluating it after fulfillment. A proof for this helper must account for callback invocation through XCTest on completion, timeout and interruption. A synchronous return type alone cannot establish that lifetime.

## #383

Two newly named XCTest entries can use the independent execution policy. Removed callers with different declaration keys have no verified successor. The `testAddBlockButtonShrinksAndExpandsWithScrollAndTap` entry also changes its throwing signature. Matching solely by method name would discard the historical binding question.

The application helper sets `COC_UI_TEST_CONVERSION_UNREAD` and launches the app. The fixture in `ChainOfCustody/App/NoteURLUITestFixture.swift` seeds activity and comment read receipts. Both view-history implementations default to `UserDefaults.standard`. Launch can reset that state through `AppNavigationPreferences.reset()`, and `PairingNoteActivityUITests` explicitly disables this reset for a relaunch that checks persistence. The in-memory UI-test cache alone cannot isolate this state. A scoped effect proof must retain these fixture readers and writers, including relaunches.

## Swift Testing

The suite factory remains a discovery root for every Swift Testing entry in its module. Its runtime witnesses become roots for tests bound to that suite or a nested suite. In both captures, `CacheRecoveryTests/localCacheCloudRecoveryMarkerMergesAndClearsByRequestID()` reaches `IsolatedCloudPersistence.scopeProvider` and `IsolatedCloudPersistence.provideScope` through its conformance witnesses. The unrelated `CheckComposerPreferencesTests/legacyMessageDraftWithoutCheckPreferencesStillConfirms()` retains the `NoteMediaDownloadTests` discovery factory and has no path to either callback. Unresolved trait callbacks, generic argument iteration and the app-hosted target retain their existing fallback coverage.
