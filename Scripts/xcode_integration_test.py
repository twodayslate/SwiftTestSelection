#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Zachary Gorak
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

"""Fine-grained acceptance checks against real Xcode/SIL/Git and an iOS simulator."""
import argparse
import json
import pathlib
import plistlib
import shutil
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
TOOL = ROOT / ".build/debug/swift-test-impact"
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--destination", required=True)
parser.add_argument("--keep-work", action="store_true", help="Retain the temporary repository and xcresults")
options = parser.parse_args()


def run(args, cwd):
    result = subprocess.run([str(a) for a in args], cwd=cwd, text=True, capture_output=True)
    if result.returncode:
        raise AssertionError(f"{args}: exit {result.returncode}\n{result.stdout}\n{result.stderr}")
    return result


directory = tempfile.mkdtemp(prefix="swift-impact-xcode-acceptance-")
work = pathlib.Path(directory) / "UI App with spaces"
print(f"Acceptance repository: {work}", flush=True)
try:
    shutil.copytree(ROOT / "Fixtures/XcodeUITests", work, ignore=shutil.ignore_patterns(".build", "xcuserdata", ".git"))
    (work / ".gitignore").write_text(".build/\nxcuserdata/\n")
    ui = work / "CheckoutUITests/CheckoutUITests.swift"
    healthy_ui = ui.read_text()
    # The unselected method in the SAME target deliberately fails.
    ui.write_text(healthy_ui.replace("XCTAssertEqual(2 + 2, 4)", "XCTAssertEqual(2 + 2, 0)"))
    original_ui = ui.read_text()
    run(["git", "init", "-q"], work)
    run(["git", "config", "user.name", "Integration Test"], work)
    run(["git", "config", "user.email", "test@example.invalid"], work)
    run(["git", "add", "."], work)
    run(["git", "commit", "-qm", "Fixture"], work)
    base = run(["git", "rev-parse", "HEAD"], work).stdout.strip()
    common = ["--project", work / "ImpactDemo.xcodeproj", "--scheme", "ImpactDemo", "--test-plan", "AllTests", "--destination", options.destination]
    share = "CheckoutUITests/SharingUITests/"
    inherited = "CheckoutUITests/InheritedUITests/"
    sharing = {share + f"test{name}()" for name in ["ShareSheet", "ShareLink", "ShareCopy", "Standalone"]}
    helpers = sharing - {share + "testStandalone()"}
    inherited_tests = {inherited + "testInheritedOne()", inherited + "testInheritedTwo()"}
    notes = "CheckoutUITests/NotesUITests/testNotes()"
    unit_sharing = "UnitTests/ProductionTests/testSharing()"
    unit_notes = "UnitTests/ProductionTests/testNotes()"
    all_tests = sharing | inherited_tests | {notes, unit_sharing, unit_notes}

    def select(label, expected, *extra, base_ref="HEAD", fallback=False):
        print(f"CHECK {label}", flush=True)
        result = run([TOOL, "select", *common, "--base", base_ref, "--format", "json", *extra], work)
        report = json.loads(result.stdout)
        assert set(report["selectedTests"]) == set(expected), (label, report)
        assert report["onlyTestingArguments"] == ["-only-testing:" + test for test in sorted(expected)], report
        if not fallback:
            assert not report["diagnostics"], (label, report["diagnostics"])
        assert all(any(e["test"] == test for e in report["explanations"]) for test in expected), report
        print(f"PASS {label}: {len(expected)}/{len(all_tests)} tests", flush=True)
        return report, result

    graph = json.loads(run([TOOL, "graph", *common], work).stdout)
    assert set(graph["tests"]) == all_tests, graph["tests"]
    assert not graph["diagnostics"] and not graph["dependencies"]["diagnostics"], graph
    assert all(graph["dependencies"]["tests"].values()), graph["dependencies"]["tests"]
    print("PASS single-plan discovery: 7 UI methods in one target, 2 unit methods", flush=True)

    _, result = select("empty diff", set(), "--run")
    assert "no Xcode test command was executed" in result.stderr

    ui.write_text(original_ui.replace("assertSharingScreen(timeout: 5)", "assertSharingScreen(timeout: 6)", 1))
    _, result = select("one edited method; unrelated failing method in same target skipped", {share + "testShareSheet()"}, "--run")
    assert "Executed 1 test," in result.stderr and "** TEST SUCCEEDED **" in result.stderr, result.stderr

    ui.write_text(original_ui.replace("    @MainActor func testStandalone()", "    func testNew() { XCTAssertTrue(true) }\n    @MainActor func testStandalone()"))
    select("new method", {share + "testNew()"})

    ui.write_text(original_ui.replace("    @MainActor func testStandalone() {\n        XCTAssertEqual(2 + 2, 0)\n    }\n", ""))
    select("deleted method", set())

    ui.write_text(original_ui.replace("timeout: timeout)", "timeout: timeout + 0)"))
    select("helper used by three methods", helpers)

    ui.write_text(original_ui.replace("continueAfterFailure = false", "continueAfterFailure = true"))
    select("class setup", sharing)

    ui.write_text(original_ui.replace("        1\n", "        1 + 0\n"))
    select("inherited helper and setup dependencies", inherited_tests)

    ui.write_text("// formatting only\n" + original_ui.replace("timeout: 5", "timeout:  5"))
    select("comments and whitespace", set())
    run(["git", "restore", "."], work)

    source = work / "App/Sharing.swift"
    source.write_text(source.read_text().replace('sharedTitle("Sharing")', 'sharedTitle("Sharing") + ""'))
    report, _ = select("mapped sharing feature plus affected unit test", sharing | inherited_tests | {unit_sharing})
    assert {e["kind"] for e in report["explanations"]} == {"dependency", "explicitMapping"}, report
    run(["git", "restore", "."], work)

    source = work / "App/Common.swift"
    source.write_text(source.read_text().replace("    feature\n", '    feature + ""\n'))
    select("shared production dependency propagates to both features", all_tests)
    run(["git", "restore", "."], work)

    run(["git", "mv", "App/Sharing.swift", "App/Renamed.swift"], work)
    project = work / "ImpactDemo.xcodeproj/project.pbxproj"
    objects = plistlib.loads(project.read_bytes())
    for obj in objects["objects"].values():
        if obj.get("path") == "App/Sharing.swift": obj["path"] = "App/Renamed.swift"
    project.write_bytes(plistlib.dumps(objects, sort_keys=False))
    select("pure source move with project reference update", set())
    run(["git", "reset", "--hard", "HEAD"], work)

    (work / ".swift-test-selection.json").unlink()
    (work / "App/Common.swift").write_text((work / "App/Common.swift").read_text().replace("    feature\n", '    feature + ""\n'))
    report, _ = select("missing mappings fail conservatively", all_tests, fallback=True)
    assert any(d["code"] == "missing_ui_mappings" for d in report["diagnostics"]), report
    run(["git", "restore", "."], work)

    # Diverged target branch: its unrelated file must not enter the PR diff.
    run(["git", "checkout", "-qb", "target"], work)
    (work / "TargetOnly.txt").write_text("Target branch change\n")
    run(["git", "add", "."], work)
    run(["git", "commit", "-qm", "Target branch"], work)
    run(["git", "checkout", "-qb", "feature", base], work)
    ui.write_text(original_ui.replace("assertSharingScreen(timeout: 5)", "assertSharingScreen(timeout: 6)", 1))
    run(["git", "add", "."], work)
    run(["git", "commit", "-qm", "Feature method edit"], work)
    head = run(["git", "rev-parse", "HEAD"], work).stdout.strip()
    # An invalid worktree proves --head builds AND executes its exported revision.
    ui.write_text("deliberately invalid Swift worktree\n")
    report, result = select("PR merge-base and explicit head execution", {share + "testShareSheet()"}, "--head", head, "--merge-base", "--run", base_ref="target")
    assert report["baseRevision"] == base and report["headRevision"] == head, report
    assert report["comparisonMode"] == "merge-base" and "Executed 1 test," in result.stderr
    run(["git", "restore", "."], work)

    # Finish with an actual healthy full run to validate the consolidated plan.
    ui.write_text(healthy_ui)
    run(["git", "add", "."], work)
    run(["git", "commit", "-qm", "Healthy full-suite baseline"], work)
    _, result = select("explicit full suite in the consolidated plan", all_tests, "--full-suite", "--run")
    assert "** TEST SUCCEEDED **" in result.stderr, result.stderr
    assert "Executed 7 tests," in result.stderr and "Executed 2 tests," in result.stderr, result.stderr

    workspace = work / "ImpactDemo.xcworkspace"
    workspace.mkdir()
    (workspace / "contents.xcworkspacedata").write_text('<?xml version="1.0"?><Workspace version="1.0"><FileRef location="group:ImpactDemo.xcodeproj"/></Workspace>')
    args = ["--workspace", workspace, *common[2:]]
    workspace_graph = json.loads(run([TOOL, "graph", *args], work).stdout)
    assert set(workspace_graph["tests"]) == all_tests and not workspace_graph["dependencies"]["diagnostics"], workspace_graph
    print("PASS workspace discovery", flush=True)
finally:
    if options.keep_work: print(f"Retained {work}", flush=True)
    else: shutil.rmtree(directory)
print("All Xcode acceptance checks passed.", flush=True)
