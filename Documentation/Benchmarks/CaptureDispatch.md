# Capture/replay dispatch validation (#19)

The concrete witness receiver fix merged in #24 avoids resolving
`witness_method $UIApplication.State, #Equatable."=="` against every Equatable
conformance. This follow-up verifies that behavior with real compiler output and
fixes a related safety gap: canonical SIL retains arbitrary generic parameter
names, not only `T`, `U`, `V`, or `Self`. A generic `Element` must not be resolved
as an unrelated concrete type named `Element`.

The parser reads balanced generic declarations from the function-type prefix,
stopping before parameter and result types. Nested constraints such as
`Element.Element == Array<Int>` retain the generic `Element`; a concrete
`Array<ComparisonResult>` parameter does not declare a generic parameter. Unknown
signature syntax retains an explicit unresolved-dispatch diagnostic. It keeps
those receivers, including their associated types, conservative. It retains the
broad witness candidate set and explicit dynamic-dispatch uncertainty when no
concrete receiver is established. It does not perform interprocedural generic
specialization or remove unknown edges to improve selected-test counts.

## Real compiler regression

`Fixtures/BuildTimeDispatch` contains `UIApplication.State` equality, three
unrelated Equatable types, a generic parameter that shadows the concrete
`Element`, an associated-type equality, a nested collection constraint, and concrete
equality inside an array parameter. The test produces canonical SIL as
an additional output of object compilation and separately replays whole-module
`-emit-sil`, with `-Onone -g` in both cases. No test bodies are executed.

The fixture checks that concrete state equality cannot reach unrelated equality
implementations and that generic equality retains all candidates and uncertainty.
It compares exact selected identifiers for every function/type-header edit,
including protocol, class and Objective-C dispatch, callbacks/escaped function
values, shared global state, inherited setup, and changed conformances. Callback
and global-state uncertainty must remain reachable. Compiler-stage metadata need
not be identical for these selection assertions to hold.

Run:

```sh
swift test -c release --filter realCompilerCaptureKeepsGenericReceiversBroadAndConcreteReceiversPrecise
```

## Large saved-input comparison

The archived ChainOfCustody capture is from revision
`1f0e37b69458200227c584d9a4563b5391948cdf`, Xcode 27 / Swift 6.4. The comparison
refreshes replay dependencies from the original export's normal-build log, using
the current parser and its original source/DerivedData paths. Capture parsing
uses the production per-module merger and ownership rule, then the same dispatch
resolver and test binder. A former global union in the investigation harness
could invent cross-module dependencies; it is no longer used.

This is a controlled graph/selector comparison. Archived prototype manifests
have source and SIL hashes, which the harness checks, but lack expanded input-list
snapshots required by today's stricter capture validator. They are **not** sealed
production captures and do not establish current provenance/completeness. The
harness removes executable artifact metadata from both exported graphs. These
results neither authorize executing those products nor replace full-suite CI
validation. Build-time capture remains opt-in.

Seven archived fragments contain no SIL functions or dispatch tables. The probe
explicitly lists and verifies these exclusions through `archivedEmptyFragments`
before comparing the remaining fragments; their hashes and bytes are still
accounted for. Today's production parser rejects such empty fragments. No
production validation rule was relaxed for this experiment.

## Results and intentional differences

The release suite passed all 122 tests. The new compiler fixture passed with both
Xcode 26.6 / Swift 6.3.3 and Xcode 27 / Swift 6.4. The existing object-capture
regression also passed on Xcode 26.6 with identical object machine code and the
expected executable result.

Both large graphs contain 124,013 functions and identical roots for 2,000 tests;
no source-bearing reference function is missing. Source-bearing differences are:
834 dependency sets, 1,008 dispatch/resolution sets, 928 uncertainty sets,
14 region sets, and 13 owning-module values (1,060 functions total; categories
overlap). Names all match. These graphs are not byte-for-byte or semantically
identical, and this sample does not certify every differing function.

- **Concrete equality:** `ChainOfCustodyApp.init()` now resolves its captured
  `UIApplication.State` equality to that type's witness, not hundreds of unrelated
  conformances. Replay instead references Swift's RawRepresentable equality
  helper. Both representations retain the appropriate implementation path;
  capture also records its explicit witness-dispatch uncertainty.
- **Unknown generic dispatch:** generic and unsupported compound receiver forms
  retain broad candidates and uncertainty. No interprocedural substitution model
  is claimed. Narrowing a source-named generic parameter to a same-named concrete
  type would be unsafe; the new collision fixture guards against that regression.
- **Static-state access:** canonical fragments preserve calls to addressors that
  whole-module replay can fold away. Their global/shared-state uncertainty remains
  conservative. It is not suppressed to force equivalent counts.
- **Regions and module attribution:** fragment merging can retain locations absent
  from replay. Shared generated key-path/actor thunks can have multiple owning
  modules; the production merge chooses the owning definition, rather than unioning
  every duplicate across modules. The recorded differences remain visible.

| Simulated edit | Replay | Capture | Identifier comparison |
| --- | ---: | ---: | --- |
| `SharingPeopleUITestView.swift:43` | 1,885 | 1,890 | Five added, none omitted |
| `NoteCommentsTests.swift:8` | 1 | 1 | Exact match |
| `SharingPeopleUITests.swift:6` | 1 | 1 | Exact match |

Repeating each edit with a README change produces the same identifiers and
full-run reasons. The five additional candidates are the same methods identified
by the original investigation. Four reach
`CloudEnvironmentHandoffDestinationRecordPolicy.assetClassificationVersion` through
`hasCurrentAssetClassification`; one reaches
`CloudSyncProtocol.pairingNoteTagCatalogVersion` through `supportsNoteTagUpload`.
Capture retains those addressor edges and replay does not. All five therefore
reach explicit `Global state access` uncertainty in capture; none does in replay.
These are conservative static-state fallbacks, not the unrelated concrete
Equatable edges reported for the app initializer. All identifiers and inspected
paths are preserved in [the result summary](CaptureDispatch.json).

The corrected parser also exposes missing concrete witness tables that the former
regex masked by treating types such as `UUID` and `Date` inside containers as
generic parameters. The existing resolver now retains explicit missing-table
uncertainty for those calls. Both production-edit totals are 17 higher than the
previous review snapshot; this fix does not claim a reduction in suite size.

The capture parse/hash checks took 58.18 seconds, binding 0.25 seconds, and the six
selection comparisons 33.21 seconds. The complete saved-input comparison, including
fresh compiler replay, took 395.27 seconds in this local release run. These are not
end-to-end capture/build or CI performance measurements. Earlier investigation
counts used different parser/selector versions and are not a speedup baseline.

The known concrete-dispatch regression and the named-generic safety gap are
covered. Remaining conservative generic/global-state behavior is deliberate,
and full-suite validation remains necessary before making capture a CI default.
