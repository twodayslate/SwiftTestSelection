# Historical helper issues #58, #61 and #83

All three tickets specify an acceptance path for cases where isolation cannot be
proven. The four historical one-head comparisons already exercised those paths.
Each consumed ten SIL modules with strict mappings and verified the raw and
scoped products. This follow-up checks the archived IDs and inventories, adds
compiler diagnostics and investigates the actual source and dependency behavior.
It introduces no consumer policy or formatting grants.

| Issue and consumer comparison | Scoped total / UI | Known UI callers retained | Conditional UI target |
| --- | ---: | ---: | ---: |
| #58 · #299 · 40159996488 | 2,000 / 403 | 125 | 153 |
| #61 · #291 · 40031610717 | 1,961 / 384 | 1 | 46 |
| #61 · #291 · 40035642452 | 1,981 / 397 | 1 | 46 |
| #83 · #293 · 40058859478 | 1,972 / 394 | 12 | 52 |

These are the historical selections. The recorded before/after differences are
empty for all four. The archived full ID lists for #299 and #293 reproduce the
recorded SHA-256 digests. Both #291 reports preserve the independently traced
caller of the helper and its default thunk. The follow-up probes below are
isolated experiments. They did not rebuild or execute the historical app suites.
[Four comparison records](OpenPrecisionIssuesValidation.json) ·
[#299 IDs and explanations](Issue81Evidence/coc-299-selection.json) ·
[#293 IDs and explanations](Issue81Evidence/coc-293-selection.json)

## #58 · What executes under snapshot recording mode never

In both original #299 revisions, the snapshot source and package pin are
identical. The call at line 384 of `CalendarSnapshotUITests.swift` passes an
already-evaluated `UIImage` to `assertSnapshot(of:as:…)`. Compiling the original
method in an isolated XCTest class for the iOS simulator binds the first
argument to a stack partial application of a generated autoclosure. Its body
retains the captured image, stores it in the result and returns. It contains no
throw or call instruction, even though its formal type permits a thrown error.
[Historical call](https://github.com/twodayslate/ChainOfCustody/blob/0fcd75da18ddef3aa58160dbd3e2b32500793840/ChainOfCustodyUITests/CalendarSnapshotUITests.swift#L375-L398)

The dependency pin is SnapshotTesting 1.19.1 at `05b6f05b`. Its assertion
forwards the autoclosure to `verifySnapshot` and records any returned failure.
Verification creates a directory, reads the reference, calls the strategy's
snapshot and diff closures, and writes the failed image on mismatch. The catch
returns `error.localizedDescription`. The mismatch write and the catch are
reachable with `record: .never`.
[Pinned implementation](https://github.com/pointfreeco/swift-snapshot-testing/blob/05b6f05b55ff9e2dcdcc21ac78c6ba81ea624791/Sources/SnapshotTesting/AssertSnapshot.swift#L283-L550)

The probe rebuilt the pinned package from its Git tree with Xcode 27.1 and ran
on the iOS 26.2 simulator. It passed an already-created blue image, a red PNG reference,
the consumer's image precisions (0.99 and 0.5), and a temporary
`SNAPSHOT_ARTIFACTS` directory. Verification produced a 422-byte failure PNG and
preserved the reference bytes. A second run put an ordinary file where a
directory was required. The returned failure matched the localized description
of the underlying Foundation error. The [standalone probe](HistoricalHelperEvidence/SnapshotNever.swift)
uses the package’s public verification API and removes its temporary directory.

The remaining proof would have to bound the snapshot strategy callbacks,
reference and artifact destinations, and error reporting across affected tests.
The error-flow diagnostic now prints the compiler reference path from the XCTest
caller to the producer, including source regions where available. A reference
can also be an escaped value. In the original scope the NoteLinks block-context
share test remains selected through uncertainty. The 125 positive paths are
preserved separately. The 131 comparison and two import records used to expose
the snapshot boundary were hypothetical.
[Recorded scenarios](HelperBindingValidation.json) ·
[Consumer recheck](https://github.com/twodayslate/SwiftTestSelection/issues/58#issuecomment-6564677305)

## #61 · The exact extension assertion

Both original #291 heads have the helper at line 331, its sole known test caller
at line 354, and the specific `XCTAssertEqual(comment.value as? String, "Read")`
at line 369. The selector recognizes the four independent extension entries. Compiled
controls exercise repeated plain extension headers, the bounded scroll helper
and its default argument. The historical scopes each retain one declaration fallback
and report the unreviewed `Optional<String>` failure-formatting boundary.
[Historical assertion](https://github.com/twodayslate/ChainOfCustody/blob/1884b2fa641d0fb450e23c5b3af1191374742a9d/ChainOfCustodyUITests/NotificationUITests.swift#L354-L374) ·
[Both scope replays and controls](Issue61Validation.md)

The extractor now keeps observed SIL assertion locations by XCTest symbol and
generic substitutions. Compact and JSON graphs can carry these sites through
selection. Older captures still identify the containing producer. The additional
location grants no permission to remove a test. Isolated compiles of the exact
assertion from each original head reported the same XCTest symbol, substitution
and site, `ChainOfCustodyUITests/NotificationUITests.swift:369`.

Two separate XCTest probes deliberately failed this optional-string equality on
the iOS 26.2 simulator. One installed a retroactive `Optional` conformance to
`TextOutputStreamable`, the other to `CustomStringConvertible`. Neither witness
ran during the failed assertion. Direct invocation confirmed that each witness
was installed and observable. These observations narrow the explanation to
**missing proof of the formatter used in the historical host**. They provide no
evidence of an executed custom witness in #291. An exact review can cover a
specific assertion producer. Its historical bindings and remaining declaration
inventory still need to pass the independent checks to reach 46.
[Consumer recheck](https://github.com/twodayslate/SwiftTestSelection/issues/61#issuecomment-6535057169)

## #83 · Separate switch labels from possible declaration expansions

The archived #293 report contains 513 source/revision inventories and 27,190
construct locations. Each entry has physical coordinates, possible effects and
required evidence. Its helper audit identifies the bindings under investigation,
including `buttons`, `exists`, `subscript` and `waitUntilExists`. Four of six
reviewed formatting declarations discharged and two were unused. A subsequent
identity experiment rejected six reviews for shadowed `SwiftUI.State`.
[Full inventory and helper audit](OpenPrecisionEvidence/40058859478-inventories.json.gz) ·
[Consumer recheck](https://github.com/twodayslate/SwiftTestSelection/issues/83#issuecomment-6564677075)

Forty archived entries across thirty revision/file pairs spell `@unknown`.
Every one occurs on a switch default label in the original #293 sources.
Reparsing those thirty original source files with the updated analyzer removed
all forty switch-label entries and retained 438 other construct locations in
that subset. SwiftSyntax recognizes that grammar position as a compiler construct.
The branch body retains its ordinary compiler dependencies. A declaration
bearing the same attribute spelling remains in the inventory, as do arbitrary
macros, shadowed SDK names and unproven historical declarations. Counts of
resolved syntax locations cannot be converted to counts of removable tests.

### Reproduce the snapshot mismatch probe

Use a clean SnapshotTesting checkout at `05b6f05b55ff9e2dcdcc21ac78c6ba81ea624791`
and a booted iOS simulator. The following zsh commands use `SNAPSHOT_CHECKOUT`
for that checkout and `SIMULATOR_UDID` for the device. Run from the selector
repository with the desired Xcode selected.

```zsh
work=$(mktemp -d)
sdk=$(xcrun --sdk iphonesimulator --show-sdk-path)
platform=$(xcrun --sdk iphonesimulator --show-sdk-platform-path)
lib="$platform/Developer/Library"
flags=(-sdk "$sdk" -target arm64-apple-ios26.0-simulator
       -F "$lib/Frameworks" -F "$lib/PrivateFrameworks"
       -I "$platform/Developer/usr/lib" -L "$platform/Developer/usr/lib")
xcrun --sdk iphonesimulator swiftc "${flags[@]}" -swift-version 5 -Onone \
  -whole-module-optimization -parse-as-library -module-name SnapshotTesting \
  -emit-module -emit-module-path "$work/SnapshotTesting.swiftmodule" \
  -emit-object "$SNAPSHOT_CHECKOUT"/Sources/SnapshotTesting/**/*.swift \
  -o "$work/SnapshotTesting.o"
xcrun --sdk iphonesimulator swiftc "${flags[@]}" -I "$work" \
  Documentation/HistoricalHelperEvidence/SnapshotNever.swift \
  "$work/SnapshotTesting.o" -o "$work/probe"
SIMCTL_CHILD_DYLD_LIBRARY_PATH="$platform/Developer/usr/lib" \
SIMCTL_CHILD_DYLD_FRAMEWORK_PATH="$lib/Frameworks:$lib/PrivateFrameworks" \
  xcrun simctl spawn "$SIMULATOR_UDID" "$work/probe"
```
