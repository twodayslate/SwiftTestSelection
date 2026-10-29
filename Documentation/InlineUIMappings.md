# Inline UI dependency mappings

UI mappings can live entirely beside XCTest classes and methods. No mapping file,
Swift attribute, macro, runtime library, coverage baseline, or previous test run is
required. Production dependency graph extraction is still required: comments do
not substitute for compiler evidence.

```swift
import XCTest

/// Shared checkout dependencies.
/// swift-test-selection: {"sources":["App/Checkout/**"]}
@MainActor
final class CheckoutTests: XCTestCase {
    // swift-test-selection: {"symbols":["App.submitOrder()"]}
    func testSubmitOrder() { /* ... */ }
}
```

The reserved `swift-test-selection:` prefix starts a **single-line JSON object** in
a line comment, documentation comment, or a line inside a block comment. SwiftSyntax
attaches leading comment trivia to a declaration, including declarations with
attributes and modifiers. Blank lines and other documentation may intervene.
Trailing comments, directives inside function bodies, and unsupported declaration
positions produce file/line diagnostics instead of disappearing as ordinary prose.
Unknown payload keys, empty boundaries, malformed JSON, and invalid conditions
are rejected. Use multiple directives to add independent rules.

Payloads accept `sources` and/or `symbols`, with exactly the same repository-relative
paths, module-qualified symbol names and `*`/`**` pattern semantics as file mappings.
Each entry must resolve independently; a valid sibling never hides a stale entry.
Source boundaries must resolve to compiled source evidence. Paths to resources or
files outside the selected build cannot establish a compiled dependency boundary.
Normal selection reports a conservative fallback for invalid active annotations.
`--strict-mappings` rejects invalid head annotations and unresolved symbol/source
entries before execution, including empty diffs and full-suite requests.

## Binding and composition

Only Xcode's enabled executable inventory for the selected plan and build
configuration can receive a rule. A `test...` name or comment never invents a test.
This feature currently binds parameterless instance **XCTest UI methods** in UI
test targets; it does not infer Swift Testing or parameterized executable identities.

- A class directive applies to all enabled methods on that class, including methods
  inherited from a base class and methods declared in extensions.
- Defaults on every resolved base class add to subclass defaults. Relevant source
  declarations can live in other files or compiled project modules.
- A method directive adds a dependency for that executable. An inherited method
  retains its declaration's directives. An overriding method uses its own method
  directives; base-class defaults still apply.
- An extension directive applies to enabled methods **declared in that extension**,
  not every method on the extended class. Class and base-class defaults still apply.
  Escaped and qualified extension names are normalized. A typealiased extension
  can bind to a captured class when emitted method names and physical source
  locations prove one owner. Unresolved owners on enabled annotated methods
  produce diagnostics instead of silently dropping their rules.
- Nested classes retain their qualified names. Local declarations inside function
  bodies cannot supply test annotations. Ambiguous ancestry, aliases, missing
  compiler locations, and redirected `#sourceLocation` evidence fail conservatively.
  This includes inherited nested types that could shadow an outer superclass name:
  the resolver diagnoses the uncertain ancestry instead of borrowing outer defaults.
  Superclasses must resolve lexically or by an explicit module-qualified name;
  a unique name suffix elsewhere in the captured sources is not sufficient. Use
  `Helpers.Parent` for imported bases, with that declaration's source captured.
  Framework base names such as `XCTestCase` are also checked for project types or
  aliases that could shadow them. Their declaring source must directly import
  `XCTest` (or `Foundation` for `NSObject`) outside conditional compilation.
  Without that source proof or compiler import evidence excluding a collision,
  ancestry remains unresolved and the affected tests stay selected. Older saved
  snapshots missing framework-import proof must be regenerated before narrowing.
  Scoped type imports (including conditional ones) can override otherwise familiar
  base names even when their module's source is unavailable. Colliding scoped names
  keep ancestry unresolved; use an unambiguous module-qualified superclass instead.
  Re-exported scoped names participate across modules, including exports from
  imports-only files and transitive imports. Compiler import evidence must exclude
  an exporting module before its potentially shadowing name can be ignored.
  Whole-module imports also require captured export evidence, including transitively
  re-exported modules and every declared source file. An uncaptured binary module
  could re-export a scoped alias; its absence from the project import inventory is
  not proof that it is invisible. Such uncertainty keeps affected tests selected
  and fails strict validation. The supported SDK terminal modules (`XCTest`,
  `Foundation`, and `Swift`) do not require source capture.
  Compiler-injected imports (`-import-module` and `-testable-import-module`) also
  participate, even for binary modules absent from the project import inventory.
  The compiler options are retained in JSON and compact saved graphs.
  Saved snapshots without current import/re-export or compiler-option evidence
  require regeneration.
- Inline and file rules form a union. Selecting a test through either rule keeps it
  selected. There are no override, replace, exclusion or implicit policy switches.

For `#if` declarations, compiler function names and physical source ranges identify
active implementations. A conditional class requires a compiled member in its own
source range. Inactive declarations cannot lend their directives to an active
same-named declaration. If the build cannot prove a unique binding (for example an
empty conditional subclass without usable compiler locations), selection reports
that uncertainty and includes the affected enabled test.

Disabled declarations do not participate in active rule validation. In particular,
a disabled method with a stale symbol does not fail its enabled sibling's mapping.
An annotation on a disabled suite, disabled extension method, or overridden base
method does not require unrelated enabled tests to prove inline ancestry. Class
defaults and policies on plausible ancestors still require conservative binding.
An unrelated suffix match cannot exclude policies on an uncaptured imported ancestor.
Orphan directives in UI source files are diagnosed because they cannot be associated
with an executable safely. Orphan diagnostics in an enabled test's ancestor or
inherited-method source are also reported, even when no directive attached
successfully anywhere in the graph.
Unrelated support files and ancestors used only by disabled suites do not contribute
those diagnostics. The audit command below inspects the **active inventory**;
there is no all-plans/disabled-declarations audit mode. Run it against graphs captured
for each configuration you maintain.

## Conditions are direct-change policy

The version-2 `when` representation also works inline:

```swift
// swift-test-selection: {"when":{"all":[{"symbolChanged":"App.submitOrder()"},{"sourceChanged":"App/Prices.swift"}]}}
func testCombinedChange() { /* ... */ }
```

A single directive contains either `when` or dependency boundaries, never both.
`all`/`any` evaluate direct semantic changes across the comparison; they do not mean
that a changed dependency is reachable from a boundary. Use separate directives for
independent additive rules. All condition leaves are validated, even when another
leaf already determines the boolean value. Class defaults, file mappings, new-test
selection and conservative fallbacks can independently select the same test.
Reports include the annotation location and the condition's operand results; ordinary
boundary explanations include the compiler path. Head-only mode retains the existing
conservative fallback for conditions because it has no base compiler graph.
`sourceChanged` resolves against captured source snapshots, including empty and
imports-only files with no compiled functions. This differs from a `sources`
dependency boundary, which must have compiled roots to trace impact through callers.

## Change tracking and saved graphs

Directive content is normalized and stored separately from Swift semantic units.
Key order, whitespace and duplicate/order changes in dependency arrays do not change
the policy. Editing, adding or removing an active rule selects its associated tests;
base and head bindings both participate, so removal cannot erase the old association.
Deleted executable identifiers never escape the current enabled inventory. Location
changes appear in explanations without changing an otherwise identical rule.

Unrelated prose stays outside semantic fingerprints. Existing source-location rules
still apply: moving calls or attributes can change semantic location evidence,
particularly in conservative head-only analysis. Inline support does not weaken those
checks or automatically enable a diagnostic source-location policy.

Fresh and saved two-graph selection share the same resolver. Archive schema 4 stores
`sourceSnapshots` (replacing the required `sources` key), making old readers fail to
decode rather than silently ignore directive metadata. Cache identity includes the
new schema; analyzer and source input digests still participate. Legacy schema-2/3
archives remain readable, but UI source snapshots lacking directive metadata require
regeneration before narrowing. Compact and JSON archives preserve the same evidence.

Head-only mode reads base directives from Git alongside base syntax. A directive
change selects the enabled UI inventory with `head_only_inline_policy_changed`:
without a base compiler graph it cannot safely reconstruct old active bindings.
Unchanged directives bind against the head compiler graph normally. Existing runtime
uncertainty remains conservative. A file is still optional for global policies such
as an explicitly reviewed `runtimeDependencyPolicy: declared` contract; inline rules
never enable that contract automatically.

## Deterministic authoring and audit

```sh
swift-test-impact inline-audit --graph head-graph.json --output inline-audit.json

# payload.json: {"symbols":["App.submitOrder()"]}
swift-test-impact inline-proposal \
  --source UITests/CheckoutTests.swift --module UITests --suite CheckoutTests \
  --method 'testSubmitOrder()' --payload payload.json --output proposal.json
```

`inline-audit` accepts JSON or compact graph archives. Its JSON contains the bound
rules, exact enabled test identifiers, resolved compiler symbols, every unresolved
entry, binding diagnostics and unmapped UI tests (including file rule coverage).
File loading/schema errors are reported separately. Inline entries are still
resolved when the file policy is invalid, and invalid file rules do not count as
coverage for otherwise unmapped tests.
Normal `select --format json` supplies real-diff graph paths and condition decisions.

`inline-proposal` emits a source digest, declaration location, normalized directive,
and `proposedSource`. It preserves every original source byte and inserts one comment;
it never writes the source, removes an existing rule, runs tests, or changes a global
policy. Omit `--method` for a class default. Destinations must be unique unconditional
source declarations on their own line; inherited/conditional destinations require
manual review. Proposals are not a validation result: capture the proposed build and
run strict validation/audit before relying on them. Library clients use
`InlineMappingAuthoring.propose` and `InlineMappingAudit.inspect`.

Coverage-maintenance clients can feed an attributed candidate's `sources`/`symbols`
object into this proposal operation, choosing the source suite only after reconciling
its target/module with the enabled inventory. Keep coverage provenance next to the
proposal, never inside the selection directive. Shared startup dependencies stay
additive. Do not infer `all` conditions from functions that happened to execute together.

## Reviewed migration from file rules

1. Capture and audit the existing build for the intended plan/configuration. Save a
   selection report for representative changes, including shared dependencies.
2. For a simple suite rule, propose a class directive with the same boundaries. For
   an exact method rule, propose a method directive only if that declaration owns
   exactly the intended executable(s); inherited methods may belong to many suites.
3. Keep the file rule during review. Capture the proposed build, audit it, run strict
   validation and compare selected tests on the same representative changes. Inspect
   source locations, newly included tests, fallbacks and any missing association.
4. Remove a file rule only after checking every selector and every supported plan.
   `fixtures` and `dependsOn` are not inline payload keys: preserve those file rules
   or explicitly expand/review their full dependency closure. Never copy only the
   local boundary and silently drop shared dependencies.
5. Retain the file for global runtime/source-location/documentation policies and
   unrelated rules. Remove it only when all remaining semantics are represented.

This is an additive proposal and reviewed migration path, not an automatic deletion
or proof of dependency completeness. Independent full runs remain necessary to
validate the declared runtime relationships.

## Verification

`InlineMappingTests` covers config-free selection, source/symbol equivalence, additive
rules, disabled inventories, inheritance/extensions, conditional and nested binding,
strict partial-staleness checks, conditions, policy edits, archive compatibility,
head-only fallbacks, audit, and formatting-preserving proposals.

For real Xcode compilation and enabled-plan discovery:

```sh
swift build
python3 Scripts/xcode_inline_mapping_test.py \
  --destination 'platform=iOS Simulator,id=YOUR_SIMULATOR_ID'
```

The script copies the Xcode fixture to a temporary repository, removes its mapping
file, inserts inline rules, disables a stale annotated test, and verifies production
selection plus inherited/extension rule binding. It builds and enumerates tests; it
does not claim those explicit mappings are measured coverage.

## Coverage proposals and reusable skill

A version-1 coverage proposal from `coverage import` can produce inline output without
changing the collector or selection runtime:

```sh
swift-test-impact inline-proposal \
  --source UITests/CheckoutTests.swift --module UITests --suite CheckoutTests \
  --coverage-proposal coverage-proposal.json --target UITests \
  --output inline-coverage-proposal.json
```

This takes all proposed additions for that exact `Target/Class`, preserving shared
file boundaries as additive dependencies. The output retains the complete original
coverage proposal and its feature names; other suites still need their own proposals.
Invalid/error-bearing coverage proposals, conditions and shared feature references
cannot be silently flattened. The operation creates no source edits automatically.

The repository includes `skills/ui-inline-mappings/SKILL.md` for create/improve,
explain, audit and reviewed migration using these commands. Use it from a checkout:

```text
Use the ui-inline-mappings skill at skills/ui-inline-mappings/SKILL.md to audit this graph.
```

For personal installation, symlink that skill directory into your agent's skill
folder and retain the checkout so its maintained documentation and CLI remain
available. Example for Codex, run from the repository root:

```sh
mkdir -p "${CODEX_HOME:-$HOME/.codex}/skills"
ln -s "$PWD/skills/ui-inline-mappings" "${CODEX_HOME:-$HOME/.codex}/skills/ui-inline-mappings"
```

The CLI proposal and config-free Xcode tests exercise the skill's actual authoring,
audit and selection workflow; packaging validation is separate from behavioral proof.
