#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Zachary Gorak
# SPDX-License-Identifier: AGPL-3.0-only

"""Validate actual XCUITest discovery, selection, and execution in a temporary repo.

Requires a usable Xcode destination and UI automation permissions. Example:
  python3 Scripts/xcode_integration_test.py --destination 'platform=iOS Simulator,id=YOUR-UUID'
"""
import argparse
import json
import pathlib
import shutil
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
TOOL = ROOT / ".build/debug/swift-test-impact"
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--destination", required=True)
options = parser.parse_args()


def run(args, cwd):
    result = subprocess.run([str(a) for a in args], cwd=cwd, text=True, capture_output=True)
    if result.returncode:
        raise AssertionError(f"{args}: exit {result.returncode}\n{result.stdout}\n{result.stderr}")
    return result


with tempfile.TemporaryDirectory(prefix="swift-impact-xcode-integration-") as directory:
    work = pathlib.Path(directory) / "UI App with spaces"
    shutil.copytree(ROOT / "Fixtures/XcodeUITests", work,
                    ignore=shutil.ignore_patterns(".build", "xcuserdata", ".git"))
    (work / ".gitignore").write_text(".build/\nxcuserdata/\n")
    # If selection accidentally runs the other target, the execution must fail.
    greeting = work / "GreetingUITests/GreetingUITests.swift"
    greeting.write_text(greeting.read_text().replace("XCTAssertTrue", "XCTAssertFalse"))
    run(["git", "init", "-q"], work)
    run(["git", "add", "."], work)
    run(["git", "-c", "user.name=Integration Test", "-c", "user.email=test@example.invalid",
         "commit", "-qm", "Fixture"], work)
    common = ["--project", work / "ImpactDemo.xcodeproj", "--scheme", "ImpactDemo",
              "--destination", options.destination]

    def select(*extra):
        result = run([TOOL, "select", *common, "--base", "HEAD", "--format", "json", *extra], work)
        return json.loads(result.stdout), result

    graph = json.loads(run([TOOL, "graph", *common], work).stdout)
    expected = ["CheckoutUITests/CheckoutUITests/testCheckoutScreen()",
                "GreetingUITests/GreetingUITests/testGreetingScreen()"]
    assert graph["tests"] == expected, graph
    assert not graph["diagnostics"], graph
    assert graph["analysisKind"] == "xcode-build-targets", graph
    assert all(target["sourceFiles"] for target in graph["targets"]), graph
    print("PASS compiled target ownership and exact XCUITest discovery without test-body execution", flush=True)

    report, result = select("--run")
    assert report["selectedTests"] == [], report
    assert "no Xcode test command was executed" in result.stderr, result.stderr
    print("PASS unchanged worktree: empty selection executes no tests", flush=True)

    checkout = work / "CheckoutUITests/CheckoutUITests.swift"
    checkout.write_text(checkout.read_text().replace("timeout: 5", "timeout: 6"))
    report, result = select("--run")
    assert report["selectedTests"] == expected[:1], report
    assert not report["fullRunReasons"], report
    # Verify execution, not just xcodebuild's exit status (zero tests can succeed).
    assert "Executed 1 test," in result.stderr, result.stderr
    assert "** TEST SUCCEEDED **" in result.stderr, result.stderr
    assert "testGreetingScreen' started" not in result.stderr, result.stderr
    print("PASS selected and executed 1 of 2 UI tests; deliberately failing unrelated target skipped", flush=True)

    run(["git", "restore", "."], work)
    app = work / "App/App.swift"
    app.write_text(app.read_text().replace("Hello, checkout", "Hello, checkout!"))
    report, _ = select()
    assert report["selectedTests"] == expected and report["fullRunReasons"], report
    print("PASS app changes select all UI tests across the process boundary", flush=True)

    # Exercise the workspace adapter with the same scheme and compiled targets.
    workspace = work / "ImpactDemo.xcworkspace"
    workspace.mkdir()
    (workspace / "contents.xcworkspacedata").write_text(
        '<?xml version="1.0" encoding="UTF-8"?><Workspace version="1.0">'
        '<FileRef location="group:ImpactDemo.xcodeproj"></FileRef></Workspace>')
    workspace_args = ["--workspace", workspace, "--scheme", "ImpactDemo", "--destination", options.destination]
    workspace_graph = json.loads(run([TOOL, "graph", *workspace_args], work).stdout)
    assert workspace_graph["tests"] == expected and not workspace_graph["diagnostics"], workspace_graph
    print("PASS workspace discovery", flush=True)

print("All Xcode integration checks passed.", flush=True)
