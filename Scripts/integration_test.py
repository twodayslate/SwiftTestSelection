#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Zachary Gorak
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

"""End-to-end validation against real SwiftPM/SIL/Git, isolated from the checkout."""
import argparse
import json
import pathlib
import shutil
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--tool", type=pathlib.Path, default=ROOT / ".build/debug/swift-test-impact")
TOOL = parser.parse_args().tool.resolve()


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

    # Match the documented external temporary install. Neither the executable nor
    # its non-Swift metadata may broaden an otherwise unchanged worktree diff.
    installation = pathlib.Path(directory) / "Installed tool with spaces/integration"
    (installation / "bin").mkdir(parents=True)
    shutil.copy2(TOOL, installation / "bin/swift-test-impact")
    (installation / "BUILD-INFO.txt").write_text("Integration installation\n")
    TOOL = installation / "bin/swift-test-impact"

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
    print("PASS unchanged worktree: installed binary and metadata do not select tests or execute a full suite", flush=True)

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

    # SwiftPM compiles this file into Shop despite its manifest-like basename.
    run(["git", "restore", "."], work)
    (work / "Sources/Shop/NewFile.swift").unlink()
    named = work / "Sources/Shop/Package.swift"
    named.write_text("public func unusedNewFunction() -> Int { 42 }\n")
    for state in ["untracked", "staged", "deleted"]:
        if state == "staged":
            run(["git", "add", named], work)
        if state == "deleted":
            run(["git", "-c", "user.name=Integration Test", "-c", "user.email=test@example.invalid", "commit", "-qm", "Add unused source"], work)
            named.unlink()
        report, _ = select()
        assert not report["selectedTests"] and not report["fullRunReasons"], (state, report)
        assert any("unusedNewFunction" in name for name in report["unreferencedChanges"]), report
    run(["git", "add", "-u"], work)
    run(["git", "mv", "Sources/Shop/Checkout.swift", "Sources/Shop/Package.swift"], work)
    template = '\npublic let manifestTemplate = """\n// swift-tools-version: 6.0\nimport PackageDescription\n"""\n'
    named.write_text("import Dispatch\n" + original + template)
    run(["git", "add", named], work)
    run(["git", "-c", "user.name=Integration Test", "-c", "user.email=test@example.invalid", "commit", "-qm", "Rename source"], work)
    named.write_text("import Dispatch\n" + original.replace("amount / 10", "amount / 5") + template)
    report, _ = select()
    assert report["selectedTests"] == expected and not report["fullRunReasons"], report
    # SwiftPM also accepts a tools-version line embedded in a string in a real
    # manifest. This source is both compiled by Shop and loadable as a package.
    dual = template + "\n#if canImport(PackageDescription)\nimport PackageDescription\nlet package = Package(name: \"Nested\")\n#else\n" + original + "#endif\n"
    named.write_text(dual)
    assert json.loads(run(["swift", "package", "--package-path", named.parent, "dump-package"], work).stdout)["name"] == "Nested"
    run(["git", "add", named], work)
    run(["git", "-c", "user.name=Integration Test", "-c", "user.email=test@example.invalid", "commit", "-qm", "Compile a dual-role manifest"], work)
    named.write_text(dual.replace("amount / 10", "amount / 5"))
    report, _ = select()
    assert len(report["selectedTests"]) == 5 and report["fullRunReasons"], report
    print("PASS compiled Package.swift: selected only the three callers of the edited function", flush=True)

print("All integration checks passed.", flush=True)
