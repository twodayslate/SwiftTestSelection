#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Zachary Gorak
# SPDX-License-Identifier: AGPL-3.0-only

"""End-to-end validation against real SwiftPM/SIL/Git, isolated from the checkout."""
import json
import pathlib
import shutil
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
TOOL = ROOT / ".build/debug/swift-test-impact"


def run(args, cwd, expected=0):
    result = subprocess.run([str(a) for a in args], cwd=cwd, text=True, capture_output=True)
    if result.returncode != expected:
        raise AssertionError(f"{args}: exit {result.returncode}\n{result.stdout}\n{result.stderr}")
    return result


with tempfile.TemporaryDirectory(prefix="swift-impact-integration-") as directory:
    work = pathlib.Path(directory) / "Shop with spaces"
    shutil.copytree(ROOT / "Fixtures/Shop", work, ignore=shutil.ignore_patterns(".build", ".git", ".swiftpm"))
    tests = work / "Tests/ShopTests/CheckoutTests.swift"
    # The unrelated tests deliberately fail. Graph building/discovery must not run
    # their bodies, and the selected checkout run must leave them out.
    tests.write_text(tests.read_text().replace('greeting(), "Hello"', 'greeting(), "Deliberate failure"')
                     .replace('greeting() == "Hello"', 'greeting() == "Deliberate failure"'))
    run(["git", "init", "-q"], work)
    run(["git", "add", "."], work)
    run(["git", "-c", "user.name=Integration Test", "-c", "user.email=test@example.invalid", "commit", "-qm", "Fixture"], work)

    def select(*extra):
        result = run([TOOL, "select", "--package-path", work, "--base", "HEAD", "--format", "json", *extra], work)
        return json.loads(result.stdout), result

    graph = json.loads(run([TOOL, "graph", "--package-path", work], work).stdout)
    assert len(graph["tests"]) == 5, graph["tests"]
    assert not graph["diagnostics"], graph["diagnostics"]
    assert all(graph["tests"].values()), graph["tests"]
    print("PASS graph: XCTest and Swift Testing entry points resolved without running test bodies", flush=True)

    empty, result = select("--run")
    assert empty["selectedTests"] == [], empty
    assert "no test command was executed" in result.stderr
    print("PASS unchanged worktree: empty selection does not execute a full suite", flush=True)

    source = work / "Sources/Shop/Checkout.swift"
    original = source.read_text()
    source.write_text(original.replace("amount / 10", "amount / 10 + 0"))
    report, result = select("--run")
    expected = ["ShopTests.CheckoutTests/testCheckout", "ShopTests.CheckoutTests/testReceipt", "ShopTests.taxCalculation()"]
    assert report["selectedTests"] == expected, report
    assert not report["fullRunReasons"], report["fullRunReasons"]
    assert "Executed 2 tests" in result.stderr, result.stderr
    assert "Test taxCalculation() passed" in result.stderr, result.stderr
    print("PASS edit: selected and ran 3 of 5 tests; excluded both deliberately failing greeting tests", flush=True)

    source.write_text(original.replace("amount / 10", "newTax(amount)") + "func newTax(_ amount: Int) -> Int { amount / 10 }\n")
    report, _ = select()
    assert report["selectedTests"] == expected, report
    assert not report["fullRunReasons"], report["fullRunReasons"]
    print("PASS addition: new function selected its transitive tests without coverage history", flush=True)

    # Remove the helper and replace its call. The old graph remains available.
    source.write_text(original.replace("public func calculateTax(_ amount: Int) -> Int {\n    amount / 10\n}\n\n", "")
                      .replace("calculateTax(amount)", "amount / 10"))
    tests.write_text(tests.read_text().replace("#expect(calculateTax(100) == 10)", "#expect(checkout(100) == 110)"))
    report, _ = select()
    assert set(expected) <= set(report["selectedTests"]), report
    assert any(e["revision"] == "base" and e["reason"] == "Depends on a changed function" for e in report["explanations"]), report
    print("PASS deletion: base graph retained dependencies of removed functions", flush=True)

    run(["git", "restore", "."], work)
    (work / "Package.swift").write_text((work / "Package.swift").read_text() + "\n// build configuration changed\n")
    report, _ = select()
    assert len(report["selectedTests"]) == 5 and report["fullRunReasons"], report
    print("PASS manifest changes: explicit full-suite fallback", flush=True)

    run(["git", "restore", "."], work)
    (work / "Sources/Shop/NewFile.swift").write_text("public func unusedNewFunction() -> Int { 42 }\n")
    report, _ = select()
    assert "Sources/Shop/NewFile.swift" in report["changedFiles"], report
    assert any("unusedNewFunction" in name for name in report["unreferencedChanges"]), report
    print("PASS untracked source: included in analysis and reported as lacking a known test path", flush=True)

    dot = run([TOOL, "graph", "--package-path", work, "--format", "dot"], work).stdout
    assert dot.startswith("digraph TestImpact") and "calculateTax" in dot
    print("PASS Graphviz export", flush=True)

print("All integration checks passed.", flush=True)
