#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Zachary Gorak
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

"""Build once per revision, capture graphs, select offline, run relocated products."""
import argparse
import json
import os
import pathlib
import shutil
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
TOOL = ROOT / ".build/debug/swift-test-impact"
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--destination", required=True)
parser.add_argument("--keep-work", action="store_true")
options = parser.parse_args()
directory = pathlib.Path(tempfile.mkdtemp(prefix="swift-impact-artifacts-"))
work = directory / "App with spaces"
print(f"Artifact acceptance repository: {work}", flush=True)


def run(args, *, env=None, failure=None):
    result = subprocess.run([str(a) for a in args], cwd=work, text=True, capture_output=True, env=env)
    if failure:
        assert result.returncode != 0 and failure in result.stderr, (args, result.stdout, result.stderr)
    elif result.returncode:
        raise AssertionError(f"{args}: exit {result.returncode}\n{result.stdout}\n{result.stderr}")
    return result


try:
    shutil.copytree(ROOT / "Fixtures/XcodeUITests", work)
    (work / ".gitignore").write_text(".build/\nxcuserdata/\n")
    ui = work / "CheckoutUITests/CheckoutUITests.swift"
    original = ui.read_text().replace("XCTAssertEqual(2 + 2, 4)", "XCTAssertEqual(2 + 2, 0)")
    ui.write_text(original)
    for args in [["init", "-q"], ["config", "user.name", "Integration Test"],
                 ["config", "user.email", "test@example.invalid"], ["add", "."], ["commit", "-qm", "Base"]]:
        run(["git", *args])
    common = ["--project", work / "ImpactDemo.xcodeproj", "--scheme", "ImpactDemo", "--destination", options.destination, "--test-plan", "AllTests", "--configuration", "Debug"]
    xcode_common = ["-project", work / "ImpactDemo.xcodeproj", "-scheme", "ImpactDemo", "-destination", options.destination, "-testPlan", "AllTests", "-configuration", "Debug"]
    xcode = subprocess.check_output(["xcrun", "--find", "xcodebuild"], text=True).strip()
    # Record every Xcode invocation made by the tool; saved selection must make
    # none, capture must never build, and execution may only query/run products.
    wrapper = directory / "bin"
    wrapper.mkdir()
    calls = directory / "xcode-calls.jsonl"
    wrapper_script = wrapper / "xcodebuild"
    wrapper_script.write_text("#!/usr/bin/env python3\nimport json, os, sys\n"
                              "with open(os.environ['IMPACT_CALLS'], 'a') as f: f.write(json.dumps(sys.argv[1:]) + '\\n')\n"
                              "os.execv(os.environ['IMPACT_XCODE'], [os.environ['IMPACT_XCODE'], *sys.argv[1:]])\n")
    wrapper_script.chmod(0o755)
    env = dict(os.environ, PATH=str(wrapper) + os.pathsep + os.environ["PATH"], IMPACT_CALLS=str(calls), IMPACT_XCODE=xcode)

    run([TOOL, "graph", *common, "--derived-data", directory], failure="all of --derived-data")
    run([TOOL, "select", *common, "--base", "HEAD", "--base-graph", "missing"], failure="both --base-graph and --head-graph")
    run([TOOL, "select", *common, "--base", "HEAD", "--test-products", directory], failure="--test-products requires")

    def capture(label):
        revision = run(["git", "rev-parse", "HEAD"]).stdout.strip()
        derived = directory / (label + " DerivedData")
        log, settings = directory / (label + ".log"), directory / (label + "-settings.json")
        build_args = [xcode, "build-for-testing", *xcode_common, "-derivedDataPath", derived]
        log.write_text(run(build_args).stdout)
        settings.write_text(run([*build_args, "-showBuildSettings", "-json"]).stdout)
        test_runs = list((derived / "Build/Products").glob("*.xctestrun"))
        assert len(test_runs) == 1, test_runs
        output = directory / (label + "-graph.json")
        args = [TOOL, "graph", *common, "--derived-data", derived, "--build-log", log,
                "--build-settings", settings, "--xctestrun", test_runs[0], "--revision", revision, "--output", output]
        calls.write_text("")
        run(args, env=env)
        captured_calls = [json.loads(line) for line in calls.read_text().splitlines()]
        assert captured_calls and all(c[0] in ["-version", "test-without-building"] for c in captured_calls), captured_calls
        graph = json.loads(output.read_text())
        assert len(graph["tests"]) == 9 and not graph["diagnostics"] and not graph["dependencies"]["diagnostics"], graph
        assert graph["buildArtifact"]["revision"] == revision
        print(f"PASS {label} capture: no executable rebuild, 9 tests, revision/product provenance", flush=True)
        return revision, derived, output

    base, base_derived, base_graph = capture("base")
    ui.write_text(original.replace("assertSharingScreen(timeout: 5)", "assertSharingScreen(timeout: 6)", 1))
    run(["git", "add", "."])
    run(["git", "commit", "-qm", "One method"])
    head, head_derived, head_graph = capture("head")
    # Cached base graph is sufficient. Head products can move to another job.
    shutil.rmtree(base_derived)
    products = directory / "Relocated Products"
    shutil.copytree(head_derived / "Build/Products", products, symlinks=True)
    shutil.rmtree(head_derived)
    ui.write_text("invalid Swift worktree; must not be compiled\n")
    args = [TOOL, "select", *common, "--base", base, "--head", head, "--base-graph", base_graph, "--head-graph", head_graph, "--format", "json"]
    expected = "CheckoutUITests/SharingUITests/testShareSheet()"
    calls.write_text("")
    report = json.loads(run(args, env=env).stdout)
    assert report["selectedTests"] == [expected] and not report["diagnostics"], report
    assert report["buildArtifactID"] == json.loads(head_graph.read_text())["buildArtifact"]["id"], report
    assert calls.read_text() == "", calls.read_text()
    print("PASS cached report: no Xcode/compiler build, no base products, dirty worktree ignored", flush=True)
    mismatch = list(args)
    mismatch[mismatch.index("--base") + 1] = head
    run(mismatch, env=env, failure="Cached graph revision mismatch")
    print("PASS wrong cached base rejected", flush=True)
    # Diverge a branch so --merge-base must resolve back to the cached ancestor.
    run(["git", "restore", "."])
    run(["git", "checkout", "-qb", "target", base])
    (work / "Other.txt").write_text("unrelated target branch")
    run(["git", "add", "."]); run(["git", "commit", "-qm", "Diverged target"])
    merge = list(args); merge[merge.index("--base") + 1] = "target"
    merged = json.loads(run([*merge, "--merge-base"], env=env).stdout)
    assert merged["baseRevision"] == base and merged["selectedTests"] == [expected], merged
    ui.write_text("invalid Swift worktree; artifacts must still run\n")
    print("PASS merge-base uses the ancestor graph and explicit head", flush=True)
    calls.write_text("")
    result = run([*args, "--run", "--test-products", products], env=env)
    assert "Executed 1 test," in result.stderr and "** TEST EXECUTE SUCCEEDED **" in result.stderr, result.stderr
    executed = [json.loads(line) for line in calls.read_text().splitlines()]
    assert all(c[0] in ["-version", "test-without-building"] for c in executed), executed
    assert any(c[0] == "test-without-building" and "-only-testing:" + expected in c for c in executed), executed
    print("PASS relocated test-without-building: one method runs, failing neighbor skipped", flush=True)
    # Reuse the same products for a full run. Its intentionally failing neighbor
    # proves that runner failures propagate, and both app-hosted unit tests run.
    full_run = run([*args, "--full-suite", "--run", "--test-products", products], env=env, failure="** TEST EXECUTE FAILED **")
    assert len(json.loads(full_run.stdout)["selectedTests"]) == 9
    assert "Executed 2 tests," in full_run.stderr and "Executed 7 tests," in full_run.stderr, full_run.stderr
    print("PASS full artifact run: UI and unit tests execute; failing neighbor returns nonzero", flush=True)
    # Reject tampered products before xcodebuild (including an altered xctestrun).
    test_run = next(products.glob("*.xctestrun"))
    test_run.write_bytes(test_run.read_bytes() + b"\n")
    calls.write_text("")
    run([*args, "--run", "--test-products", products], env=env, failure="Test products differ")
    assert calls.read_text() == ""
    print("PASS stale/tampered products rejected before execution", flush=True)
    same = list(args)
    same[same.index("--base") + 1] = head
    same[same.index("--base-graph") + 1] = str(head_graph)
    # Empty selections need neither existing products nor Xcode commands.
    calls.write_text("")
    empty = json.loads(run([*same, "--run"], env=env).stdout)
    assert empty["selectedTests"] == [] and calls.read_text() == "", empty
    full = json.loads(run([*args, "--full-suite"], env=env).stdout)
    assert len(full["selectedTests"]) == 9
    print("PASS empty execution and explicit full-suite reporting", flush=True)
finally:
    if options.keep_work: print(f"Retained {directory}", flush=True)
    else: shutil.rmtree(directory)
print("All Xcode artifact acceptance checks passed.", flush=True)
