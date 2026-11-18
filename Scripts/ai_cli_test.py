#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Zachary Gorak
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
"""CLI contracts, without requiring model inference or an Xcode app build."""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--tool", type=Path, default=ROOT / ".build/debug/swift-test-impact")
TOOL = parser.parse_args().tool.resolve()


def run(*arguments, expected=0):
    result = subprocess.run([str(TOOL), "ai", *map(str, arguments)], capture_output=True, text=True)
    assert result.returncode == expected, (arguments, result.returncode, result.stdout, result.stderr)
    return result


status = json.loads(run("status").stdout)
assert "availability" in status
run("status", "--graph", "unused", expected=1)
run("evaluate", expected=1)
with tempfile.TemporaryDirectory(prefix="ai-cli-") as directory:
    root = Path(directory)
    source = root / "Fixture.swift"
    source.write_text("func save() {}\nclass Suite {\n func testSave() { save() }\n}\n")
    def git(*args):
        return subprocess.check_output(["git", "-C", str(root), *args], text=True).strip()
    git("init", "-q")
    git("add", ".")
    git("-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-qm", "fixture")
    revision = git("rev-parse", "HEAD")
    cases = root / "cases.json"
    cases.write_text(json.dumps([{
        "id": "fixture", "revision": revision,
        "function": {"path": "Fixture.swift", "line": 1},
        "test": {"path": "Fixture.swift", "line": 3},
        "testIdentifier": "UI/Suite/testSave()", "evidenceKind": "unlabeled", "evidence": "fixture",
    }]))
    mapping = root / "custom.json"
    mapping.write_text(json.dumps({"version": 1, "features": [{
        "name": "save", "sources": ["Fixture.swift"], "tests": ["UI/Suite"]
    }]}))
    git("add", "custom.json")
    git("-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-qm", "mapping")
    revision = git("rev-parse", "HEAD")
    specs = json.loads(cases.read_text())
    specs[0]["revision"] = revision
    cases.write_text(json.dumps(specs))
    original = cases.read_bytes()
    run("prepare", "--repository", root, "--cases", cases, "--output", cases, expected=1)
    assert cases.read_bytes() == original
    dataset = root / "dataset.json"
    run("prepare", "--repository", root, "--cases", cases, "--output", dataset)
    payload = json.loads(dataset.read_text())
    assert payload["cases"][0]["input"]["revision"] == revision
    assert payload["cases"][0]["input"]["test"]["source"].strip() == "func testSave() { save() }"
    mapped = root / "mapped.json"
    run("prepare", "--repository", root, "--cases", cases, "--mappings", "custom.json", "--output", mapped)
    rules = json.loads(mapped.read_text())["cases"][0]["input"]["mappings"]["rules"]
    assert len(rules) == 1 and rules[0]["matchesTestSelector"]
    for mapping_path in ["./custom.json", "config//../custom.json"]:
        alias = json.loads(run("prepare", "--repository", root, "--cases", cases, "--mappings", mapping_path).stdout)
        assert alias == json.loads(mapped.read_text())
    original_mapping = mapping.read_bytes()
    run("prepare", "--repository", root, "--cases", cases, "--mappings", "custom.json", "--output", mapping, expected=1)
    assert mapping.read_bytes() == original_mapping
    run("prepare", "--repository", root, "--cases", cases, "--mappings", "absent.json", expected=1)
    original_dataset = dataset.read_bytes()
    alias = root / "alias.json"
    alias.symlink_to(dataset)
    run("evaluate", "--dataset", dataset, "--output", alias, expected=1)
    assert dataset.read_bytes() == original_dataset
    run("evaluate", "--dataset", dataset, "--dataset", dataset, expected=1)
    for value in ["-1", "101", "75.5", "high"]:
        run("evaluate", "--dataset", dataset, "--confidence-threshold", value, expected=1)
    run("evaluate", "--dataset", dataset, "--confidence-threshold", "75", "--confidence-threshold", "80", expected=1)
    # AI now supplements the normal selector; the separate selection action is gone.
    removed = run("select", "--dataset", dataset, expected=1)
    assert "select --ai" in removed.stderr
    def normal(*arguments):
        result = subprocess.run([str(TOOL), "select", *map(str, arguments)], capture_output=True, text=True)
        assert result.returncode == 1, (arguments, result.stdout, result.stderr)
        return result.stderr
    assert "Choose --ai or --no-ai" in normal("--base", "HEAD", "--ai", "--no-ai")
    assert "requires Xcode select with --head" in normal("--base", "HEAD", "--ai")
    assert "AI tuning options require --ai" in normal("--base", "HEAD", "--confidence-threshold", "80")
    assert "integer from 0 through 100" in normal("--base", "HEAD", "--ai", "--confidence-threshold", "101")
    assert "--ai-max-pairs must be positive" in normal("--base", "HEAD", "--ai", "--ai-max-pairs", "0")
    # Explicitly disabling AI does not load template files or probe the model.
    disabled = normal("--base", "HEAD", "--head", "HEAD", "--project", root / "Missing.xcodeproj",
                      "--no-ai", "--prompt-template", root / "absent.stencil")
    assert "Xcode mode requires --scheme and --destination" in disabled
    preview = json.loads(run("render", "--dataset", dataset).stdout)
    assert preview["templateVersion"] == "ui-reachability-v3"
    assert preview["engine"] == "Stencil 0.15.1"
    assert preview["rows"][0]["rendered"]["prompt"].startswith("Assess this source snapshot:")
    prompt_template = root / "prompt.stencil"
    instructions_template = root / "instructions.stencil"
    prompt_template.write_text("{{ function.region.path }}\n{{ function.source|required }}\n{% for call in test.calls %}{{ call }} {% endfor %}")
    instructions_template.write_text("{{ outputContract }}")
    preview = json.loads(run("render", "--dataset", dataset, "--prompt-template", prompt_template,
                             "--instructions-template", instructions_template).stdout)
    assert preview["templateVersion"].startswith("custom-stencil-v1:")
    assert preview["rows"][0]["rendered"]["prompt"].startswith("Fixture.swift\nfunc save() {}")
    assert "confidencePercent" in preview["rows"][0]["rendered"]["instructions"]
    for template_path, option in [(prompt_template, "--prompt-template"), (instructions_template, "--instructions-template")]:
        original_template = template_path.read_bytes()
        run("render", "--dataset", dataset, option, template_path, "--output", template_path, expected=1)
        assert template_path.read_bytes() == original_template
    for invalid_template in ["{% if test %}", "{{ typo|required }}", "{{ function.source|unknown_filter }}"]:
        prompt_template.write_text(invalid_template)
        run("evaluate", "--dataset", dataset, "--prompt-template", prompt_template, expected=1)
    # Oversized rendered prompts abstain without invoking the model, even when available.
    prompt_template.write_text("x" * 13000)
    oversize = json.loads(run("evaluate", "--dataset", dataset, "--prompt-template", prompt_template, expected=2).stdout)
    assert oversize["rows"][0]["prediction"]["confidencePercent"] is None
    assert oversize["selection"]["decisions"][0]["retainedForUnknown"]
    assert oversize["promptTemplates"]["promptTemplate"] == "x" * 13000
    assert oversize["templateDigest"] and oversize["templateEngine"] == "Stencil 0.15.1"
    # Invalid inputs must fail before probing or invoking the model.
    payload["cases"] *= 2
    invalid = root / "invalid.json"
    invalid.write_text(json.dumps(payload))
    run("evaluate", "--dataset", invalid, expected=1)
    if status["availability"] != "available":
        report = root / "report.json"
        run("evaluate", "--dataset", dataset, "--output", report, expected=2)
        value = json.loads(report.read_text())
        assert value["advisoryOnly"] and value["unlabeledCount"] == 1
        assert value["rows"][0]["prediction"]["confidencePercent"] is None
        assert value["rows"][0]["prediction"]["error"]
        print("PASS unavailable provider writes abstention report and exits 2")
    else:
        print("SKIP unavailable provider check: model is available; no inference requested")
print("PASS AI command validation, historical mappings, normal-selection AI flags, Stencil rendering/validation, unknown retention and input protection")
