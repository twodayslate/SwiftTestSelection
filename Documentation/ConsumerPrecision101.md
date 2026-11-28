# Consumer precision for #101

## Original consumer policies

Fresh single-head builds at `2175b2a` and independent saved-graph replays produced the following complete policies. Each build consumed all ten captured SIL modules and verified the retained products. Every final test ID matched the earlier original comparison.

| Original comparison | Base UI | Regression UI | Non-UI | Scoped UI with a positive reason | Scoped UI selected only by fallback |
| --- | ---: | ---: | ---: | ---: | ---: |
| #380 | 47 | 313 | 1,848 | 1 | 359 |
| #383 | 47 | 316 | 1,853 | 43 | 320 |

For #383, the fixture file alone now selects its 42 positively identified UI consumers. This removes 321 candidates from that individual query. Each changed UI test file independently selects all 363 UI tests. For #380, each changed UI file independently selects all 360. The complete original policies therefore save zero executions. The remaining proofs concern the deleted helper’s historical callers and the effects of accessibility queries for #380, and renamed XCTest entries and persistent launch state for #383.

On the verified original #380 product, the reply-geometry test and both historical callers of the deleted helper executed and passed on iOS Simulator with zero skips.

The fresh Xcode blank-line fixtures ran through both head-only and two-graph selection. Both modes ignored the ordinary edit inside the returned dictionary and selected zero of nine tests. When a macro observed the blank line, both modes selected all nine, including `UnitTests/ProductionTests/testSharing()`. Retained-product verification passed in all four runs.

A separate fixture inserts one blank line before an unused `@MainActor` function following an unchanged `@Observable` class. Both fresh selection modes now ignore the edit, down from nine of nine tests. Fresh builds read the Swift compiler index for each primary source. A reference to Swift’s actor at the attribute position allows selection to exclude the attribute from macro, result-builder and caller-location comparisons. Single-head selection requires the full Git change to contain just that file, unchanged expansion inputs elsewhere in the file, and verified module declarations that exclude a historical macro namesake. The compiled control with a project-defined result builder named `MainActor` retains its location evidence.

[Download the complete primary and scoped IDs, positive and fallback-only sets, final Base and Regression lists, and simulator waiter traces under `sealedMacroDeclarations`](ConsumerPrecision101Recheck.json.gz).

## Macro lookup in the alternate #383 comparison

With a captured inventory of macro declarations, the complete alternate policy selects **91 UI tests and 1,853 non-UI tests**. All 47 Base UI IDs and 44 Regression UI IDs match the earlier 91-test control. This result covers the alternate Git head that retains the historical test names and forwards to them.

At capture time the analyzer invokes the recorded Swift frontend to print private interfaces from the compiled modules and reads the sealed Swift inputs. Saved-graph selection reads the resulting inventory without invoking the compiler. The saved-graph selector can use that evidence for ordinary imports when the full Git comparison also bounds historical lookup. In the two affected targets, the captured modules declare 53 and 49 distinct macro names respectively. Neither inventory contains `MainActor`. Replaying with the token scanner from `e9c050e` reads full identifiers, including escaped and multibyte names. Graphs captured with the earlier scanner use the conservative fallback until recaptured. A compiler test with a binary module that *does* export a macro named `MainActor` retains the generated declaration's consumer. An out-of-scope replacement of that binary also retains the consumer.

The older retained graph lacks this inventory. Replaying it selects 365 UI tests and 1,853 non-UI tests, including 318 Regression UI IDs. The 274 additional IDs enter through the Regression plan. Recapturing reevaluates the same Git revisions, selection scopes and consumer policy with compiler evidence for the two attributes.

## Earlier capture without the compiler macro inventory

Fresh single-head builds with `f3a7f4d` reproduced every primary, regression-support and final execution ID for the original #380 and #383 comparisons. Retained-product verification passed for both. #380 still schedules 360 UI and 1,848 non-UI tests. #383 still schedules 363 UI and 1,853 non-UI tests.

The independent #383 query for `ChainOfCustody/App/NoteURLUITestFixture.swift` broadened from 42 to 363 UI tests. All 42 earlier selections remain. Both the fresh build and the saved-graph replay added the same 321 UI tests. These IDs were already in the combined regression-support selection. The other individual queries kept their prior test sets.

The fixture's changed method is inside an enum annotated with `@MainActor`. The head compiler index resolves the attribute at line 5, column 2 to the Swift global actor (`s:ScM`). The #380 build resolves it to the same actor on the exact fixture blob present at the #383 base. Its repository tree differs from that base. The saved dependency list also includes the Observation, Previews and SwiftUI plugins. It records their use during compilation without identifying which declaration each expanded. The single-head comparison has no corresponding compiler resolution for the historical attribute. A compiled control with an imported peer macro named `MainActor` changes a separate function's return value after a blank-line edit. A spelling-based exemption would skip its failing caller.

The earlier fixture-only query lacked evidence that the attribute could not bind to a macro in either revision. For the original complete policies, the historical caller, launch and persistent-state boundaries below also remain. [Download the added test IDs, retained graph digests and blank-line controls under `attachedMacroRecheck`](ConsumerPrecision101Recheck.json.gz).

## Historical bindings and receipt isolation

An independent validation compile used all 46 UI-test Swift sources from each normalized Git base. In #380 the compiler bound three direct invocations of the deleted private query to two tests. One runs inside an XCTest assertion autoclosure. In #383 the old and new helpers each had two direct callers and used the same application factory. The momentum test’s Objective-C entry changed from returning void to returning a Boolean and accepting an error pointer. The production selector uses a single head build. These baseline compilations provide reference answers for checking its historical analysis.

On the original #383 simulator product, the edited converted-row test wrote eight activity receipts, two comment-version receipts and one note-header receipt. A reset-disabled launch preserved all 11 values in those three receipt families. The subsequent unread-dot relaunch test passed in the same app container and finished with 21 receipt keys, none shared with the first test. Both XCTest entries passed. Eight head-side tests explicitly disable reset, and six of them fell outside the earlier 91-test alternate policy. This run exercises one of those six.

A second experiment compared both original #383 scenarios to their historical predecessors, each starting with an empty receipt domain. All four named XCTest cases passed on iOS Simulator 26.2. Across the seven storage families cleared by the app’s reset, each base case left 15 values and each head case left 16. Every value survived a reset-disabled launch in its original app container. Each pair shared ten keys after normalizing the generated reader UUID. The remaining keys differed in the activity and comment-version families. The extra base build served as a runtime control. The selector still built only the head.

The compiled #383 UI module contains seven direct calls to the SDK’s default and bundle-identifier application constructors in each revision. Three target SpringBoard. Of the four default handles, one belongs to the launch factory, two check orientation, and one queries the unread menu. Both compiled test methods that use the unread query first call the private launch helper with its default reset. These observations cover those constructor call sites.

The original #380 waiting helper also ran on iOS Simulator 26.2 with its five-second timeout. Its immediate-success, polled-success, timeout and interrupted runs invoked the predicate 1, 2, 6 and 3 times. In a fifth run the polled callback slept for six seconds. The wait returned a timeout only after that callback finished, approximately 7.1 seconds after entry. All observed calls ran on the main thread. Across these runs there were zero additional calls during 1.5 seconds of observation after return. An intentionally retained closure did record a call after return in the positive control. The loaded Xcode 27.2 simulator XCTestCore image uses a run-loop timer for the synchronous wait and invalidates the timer during predicate-expectation cleanup. These checks cover the wait on that SDK. Effects in the application responding to accessibility queries still matter to the original policy.

For #380 the compiled geometry predicate captures a rectangle by value and an XCUIElement. Its only dynamically dispatched getters are the element’s `exists` and `frame`. The project’s rectangle check calls CoreGraphics for nullity, infinity, width and height. The predicate’s explicit stores target its Boolean result and local stack storage. This accounts for the project geometry calculation. The simulator traces above cover the observed callback lifetime. Excluding other tests also requires evidence about effects in the app that serves those queries.

Two instrumented builds of the original #380 head ran `testPinnedReplyKeepsSourceAndLocalDraftsSeparate()` on iOS Simulator 26.2. In each run, the test read the send button’s existence twice and its frame twice. During each of those four reads, the app entered the note inspector marker’s `accessibilityValue` getter twice. Branch tracing in the second run showed all eight calls forwarded to `super.accessibilityValue`. A video-screen control enabled the inspector’s diagnostic flag. The same getter then took its sample-serialization branch, and a frame read also entered the video scrubber’s frame getter. Both named tests passed in both runs.

On the video screen, constructing the deleted `replyDestination(_:in:)` query and checking its existence recorded zero entries in the instrumented getters. That screen had no matching destination. A separate build of the original #380 base ran both historical callers on their populated pickers. All five query constructions and four waits recorded zero entries in the instrumented app getters. Tapping “Result” recorded eight reads of the comments button’s SwiftUI accessibility value. Tapping “Original Result” recorded nine. Both historical tests passed. These counts cover the observed getter calls on this runtime. The selector still needs to establish the historical callers from a single head build and account for the UIKit superclass getter in the geometry scenario. The `original380Accessibility` record includes all three instrumentation patches, source hashes, per-process traces and query intervals. [Download the evidence](ConsumerPrecision101Recheck.json.gz).

The hostless Core report now distinguishes a verified Swift Testing factory with zero argument providers from a parameterized factory. For `CacheRecoveryTests/localCacheCloudRecoveryMarkerMergesAndClearsByRequestID()`, the unresolved effects belong to the suite’s runtime callbacks and test discovery. Its registration requires no generic argument iteration. The boundary remains unproven.

In a macOS Swift Testing control, two concurrent cases ran the original suite trait with the consumer’s task-local declaration. Each received a distinct directory and preferences suite. A child task inherited the directory and a detached task saw an empty scope. The trait removed the directories and cleared the preferences after normal completion and after an intentional thrown error. Applying that result to the complete consumer requires checking which tasks access persistence in the actual suite.

[Download the compiler input hashes, call sites, receipt observations and complete policy identifiers](ConsumerPrecision101Controls.json.gz).

## Consumer changes that preserve the historical Git base

Fresh captures at `2570f2c` ran the complete consumer policy on the original comparisons and two alternate heads. Each built the head once, consumed ten build-time SIL modules, verified the retained build and passed strict UI mapping. Replaying the saved graphs at `cdf8d3c` reproduced the primary and scoped test IDs, reason kinds and final execution lists. Both alternate heads preserve every production edit. Only the UI test sources change.

| Historical comparison | UI test source at head | Base UI | Regression UI | Total UI | Non-UI |
| --- | --- | ---: | ---: | ---: | ---: |
| #380 | Original | 47 | 313 | 360 | 1,848 |
| #380 | Local assertion, historical private query retained | 47 | 5 | 52 | 1,848 |
| #383 | Original | 47 | 316 | 363 | 1,853 |
| #383 | Test-owned scenarios with both old and new XCTest entries | 47 | 44 | 91 | 1,853 |

For #380, moving the geometry assertion into its only test caller and restoring the unused private query leaves five independently executed edited methods and no shared test-support path. The 52 UI identifiers match the earlier two-sided refactor exactly. The compiled restored query uses the SDK’s button query, predicate initializer, matching and first-match APIs. In the original capture, the assertion calls the UI module’s waiting helper, which passes a block capturing the predicate closures to XCTest. Safe exclusion on the original diff still requires the selector to establish the historical bindings from its own inputs and account for the callback’s lifetime and effects through that wait.

For #383, the two historical entries execute the revised scenarios, and two entries under the new names forward to them. The control retains the unused private helper and the original nonthrowing XCTest selector of the momentum test. Its 91 UI identifiers include all 89 from the earlier refactor plus both historical entries. This preserves the 42 independently identified fixture consumers and the modified receipt-relaunch test. The two names for each scenario also mean duplicate execution when running the full suite. On the original diff the renamed tests, persistent receipt state across app launches, and the edit to the compiled Core source `ChainOfCustodyCore/Data/AppStore.swift` still matter.

On iOS Simulator 26.2, four of five focused #380 regressions passed on the first run. `testCopyCommentsFilterAndPostToSelectedDestination()` timed out waiting for the edited text to refresh. That test body is byte-identical in the two products. It passed on clean simulators using both the original product and the alternate product. All six focused #383 tests passed with zero skips, including both historical entries, both new entries, the receipt relaunch and the momentum test.

Those captures selected 308 and 272 fewer UI tests than the respective originals. The older #383 graph adds back 274 regression tests when replayed without compiler macro declarations. The original comparisons still show zero saved executions, and #101 remains open.

[Download the exact identifiers, fallback decisions, build and patch identities, compiler binding checks and focused simulator results](ConsumerPrecision101Controls.json.gz). The new results are under `originalBaseHeadControls`. Its `blankLineControls` entry includes the Xcode fixture overlay, both one-line insertions and the selected test IDs in each analysis mode.

## Historical comparisons and consumer refactors at 5b602d4 and eff7597

The original #380 and #383 comparisons still schedule 360 and 363 UI tests. Two changes to how the consumer organizes its tests reduced the complete policies to 52 and 89 UI tests. The table shows the final execution lists after the consumer independently selected shared helpers and fixtures. Each primary query still selected every test in the plan. The first captures used 5b602d4. At eff7597, fresh builds of both original comparisons and saved-graph replays of the three source refactors reproduced their raw primary IDs, independently scoped IDs, reason kinds and final execution lists.

| Comparison | Test source used for comparison | Base UI | Regression UI | Total UI | Non-UI |
| --- | --- | ---: | ---: | ---: | ---: |
| #380 | Original | 47 | 313 | 360 | 1,848 |
| #380 | Geometry assertion local to its caller, old query inlined at its three uses | 47 | 5 | 52 | 1,848 |
| #383 | Original | 47 | 316 | 363 | 1,853 |
| #383 | Construct the application in the two tests and pass it to the private helper | 47 | 316 | 363 | 1,853 |
| #383 | Move the two scenarios into their tests, keeping the original base names and signature | 47 | 316 | 363 | 1,853 |
| #383 | Same test-owned scenarios, with XCTest names and throwing signature established in the base | 47 | 42 | 89 | 1,853 |

**#380.** The base control substitutes the deleted private query's body at all three call sites in its two historical callers. The head control moves the geometry assertion into its sole caller as a local function, preserving the call positions and its diagnostic defaults. The resulting consumer request identifies five edited test entries and zero shared paths. All five ran against the retained products and passed with zero skips. This policy schedules 308 fewer UI tests.

**#383.** Passing the application into the helper exposes the next unsupported operation, the nested function `closeViewer`. Moving the two scenarios into their test entries removes that helper, while the original base names and throwing signature still select all 363 UI tests. Replaying each changed test file independently reproduces this result. A compiled XCTest control exposes the Objective-C selectors `testReading` and `testReadingAndReturnError:` for the nonthrowing and throwing forms. Name-based pairing would miss that distinction.

Establishing the head signatures before changing the scenarios leaves one shared path in the regression-support request, the original application fixture. Its 42 UI consumers match the independently verified historical fixture list exactly. Each of the two changed test files individually contributes zero further UI candidates after excluding the independently executed edited tests. The complete policy retains all 47 Base entries and every edited test. It also retains the edited read-receipt relaunch test that the earlier 88-test union missed. This policy schedules 274 fewer UI tests.

**Callback and application-state controls.** On iOS Simulator 26.2 the original #380 waiter released a captured reference by the time it returned for an already-ready predicate, deferred fulfillment, timeout and interruption. The controls observed 1, 2, 2 and 2 calls respectively. A deliberately retained predicate remained callable and kept the reference alive until explicitly released. These observations apply to the tested helper and runtime. A general exclusion still needs an authenticated binding and effect model for the project callback and its callees.

Launching the original #383 app with the changed helper's fixture seeded five activity receipt keys. A fresh process with reset disabled preserved all five values, and a launch with reset enabled cleared all five. No comment-version keys appeared in that run. On a clean simulator, two default note fixture launches used distinct activity-reader namespaces and shared one note-header key. An explicit pairing ID produced the expected reader namespace. The relaunch test uses a fixed pairing and exercises persistence for its own note. The shared storage and distinct reader and note identities both matter to a historical isolation proof.

**Execution and reproduction.** Both converted-row tests and the fixed-pairing relaunch passed on the retained #383 products with zero skips. The focused runs took 182 seconds for five #380 regressions and 101 seconds for three #383 methods, including runner startup. As an execution control, the original #380 policy also selected `SettingsLayoutUITests/testPairingMenuAndCloudStatusNavigation()`. It ran successfully in 29.15 seconds on the original products. The refactored policy omits that method. Full-suite elapsed savings remain unmeasured. The ownership-only #383 control reuses the same compiled head as the stable-signature comparison and applies the consumer policy against the alternate Git base. Each other comparison uses the complete consumer selector with a fresh single head build, ten captured SIL modules, strict UI mappings and retained-product verification.

Both head-side refactors also apply to ChainOfCustody main at `7ba9db9`. On that checkout the local impact report identified the reply geometry test and both converted-row tests. All three executed and passed in the regression test plan on iOS Simulator 26.2. The converted-row tests retain their current XCTest names and duplicate the setup and checks common to both scenarios. The archive includes the exact input and output tree identifiers.

The original comparisons retain their fallbacks for the deleted query's historical bindings, the waiter, the renamed XCTest entries and application state. The hostless Core runtime boundary also remains unproven. Keep #101 open for narrowing the unchanged historical sources. The earlier 52- and 89-test comparisons both changed the base test sources. Reproducing those results requires the corresponding consumer edits.

[Download the raw primary and scope IDs, per-path controls, fallback decisions, final execution IDs, build and source-tree identities, patch digests and focused execution records](ConsumerPrecision101Controls.json.gz).

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

### Task-local storage across the Core Data callback

On the retained original #383 head, both hostless suites `CacheRecoveryTests` and `CloudPersistenceIsolationTests` passed all six methods, including both argument values for the parameterized journal test. Rebuilding the same Git sources with observation points produced the same seven passing cases on iOS Simulator 26.2. The trait created seven distinct directories and preference suites. After each case its directory was gone and its preference domain had zero keys.

The four cache tests made nine observed snapshot saves. On entry to each save, the task-local storage scope identified the current case. Inside each `NSManagedObjectContext.perform` callback that scope was `nil`. The named recovery-marker test made three of those saves, all on an in-memory store. In the concurrent recovery test, two caches shared a SQLite store in a separate, test-owned temporary directory. In the parameterized journal test, the child task and simulated relaunch both read the expected journal, and the nested scope used its own directory.

Two additional controls instrumented the named recovery test to construct a `CloudUploadOutbox(environment: .development)` immediately before and inside the callback. On fresh simulators the controls seeded opposite values for `cloudkit-legacy-storage-environment` in the case suite and the app-group suite, then reversed them. On all six paired observations the outbox namespace followed the case preference before the callback and the app-group preference inside it. The controls added those outbox constructions. The observation-only run recorded none in the named test. A hostless isolation proof therefore needs to follow the storage handle each callback actually uses. The suite trait alone cannot establish that an SDK callback reads case-owned preferences.

The compressed evidence includes both result inventories, source hashes, instrumentation patches, trace events and preference seeds under `original383CoreScoping`. [Download the evidence](ConsumerPrecision101Recheck.json.gz).
