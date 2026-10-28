#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Zachary Gorak
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
"""Build the two-screen fixture once, collect two isolated suites, import and apply.

Leaves the work directory and measured evidence for review. Requires Xcode 26.x.
"""
import argparse
import json
import os
import pathlib
import shutil
import subprocess
import tempfile
import time

ROOT = pathlib.Path(__file__).resolve().parents[1]
TOOL = pathlib.Path(os.environ.get("SWIFT_TEST_IMPACT", ROOT / ".build/debug/swift-test-impact"))
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--destination")
parser.add_argument("--reuse-collection", type=pathlib.Path, help="Re-import an existing acceptance directory without building or executing tests")
args = parser.parse_args()
if not args.reuse_collection and not args.destination:
    parser.error("--destination is required for collection")
directory = args.reuse_collection or pathlib.Path(tempfile.mkdtemp(prefix="swift-impact-coverage-"))
work = directory / "source"
print(f"Coverage acceptance directory: {directory}", flush=True)


def run(command):
    result = subprocess.run([str(a) for a in command], cwd=work, text=True, capture_output=True)
    if result.returncode:
        raise AssertionError(f"{command}\n{result.stdout[-8000:]}\n{result.stderr[-8000:]}")
    return result.stdout


if not args.reuse_collection:
    shutil.copytree(ROOT / "Fixtures/XcodeCoverage", work)
    for command in [["init", "-q"], ["config", "user.name", "Integration Test"],
                    ["config", "user.email", "test@example.invalid"], ["add", "."], ["commit", "-qm", "Coverage fixture"]]:
        run(["git", *command])
    revision = run(["git", "rev-parse", "HEAD"]).strip()
    common = ["--project", work / "ImpactDemo.xcodeproj", "--scheme", "ImpactDemo", "--destination", args.destination,
              "--configuration", "Debug", "--test-plan", "AllTests"]
    xcode = ["-project", work / "ImpactDemo.xcodeproj", "-scheme", "ImpactDemo", "-destination", args.destination,
             "-configuration", "Debug", "-testPlan", "AllTests", "-derivedDataPath", directory / "DerivedData", "-enableCodeCoverage", "YES"]
    start = time.monotonic()
    initial_start = start
    log = directory / "build.log"
    log.write_text(run(["xcodebuild", "build-for-testing", *xcode]))
    build_seconds = time.monotonic() - start
    settings = directory / "settings.json"
    settings.write_text(run(["xcodebuild", "build-for-testing", *xcode, "-showBuildSettings", "-json"]))
    test_run, = (directory / "DerivedData/Build/Products").glob("*.xctestrun")
    graph = directory / "graph.json"
    run([TOOL, "graph", *common, "--derived-data", directory / "DerivedData", "--build-log", log,
         "--build-settings", settings, "--xctestrun", test_run, "--revision", revision, "--output", graph])
    plan = directory / "plan.json"
    run([TOOL, "coverage", "plan", "--graph", graph, "--suite", "CheckoutUITests/SharingUITests",
         "--suite", "CheckoutUITests/NotesUITests", "--app-target", "ImpactDemo", "--output", plan])
    print(f"PASS one coverage-enabled build ({build_seconds:.2f}s); captured graph and two-suite collection plan", flush=True)
    run(["python3", ROOT / "Scripts/collect-ui-coverage.py", "--plan", plan, "--source-root", work,
         "--output-directory", directory / "collection", "--run"])
    initial_seconds = time.monotonic() - initial_start
    (directory / "build-measurements.json").write_text(json.dumps(dict(buildSeconds=build_seconds, initialCollectionSeconds=initial_seconds)))
graph = directory / "graph.json"

artifact = directory / "collection/coverage-artifact.json"
mapping_file = work / ".swift-test-selection.json"
original_mapping = mapping_file.read_bytes() if mapping_file.exists() else None
started = time.monotonic()
proposal = json.loads(run([TOOL, "coverage", "import", "--graph", graph, "--artifact", artifact]))
import_seconds = time.monotonic() - started
(directory / "proposal.json").write_text(json.dumps(proposal, indent=2))
assert proposal["validationPassed"], proposal
assert not [d for d in proposal["diagnostics"] if d["severity"] == "error"], proposal["diagnostics"]
features = {entry["sources"][0]: entry["tests"] for entry in proposal["additions"]}
assert features["App/Sharing.swift"] == ["CheckoutUITests/SharingUITests"], features
assert features["App/Notes.swift"] == ["CheckoutUITests/NotesUITests"], features
assert features["App/Common.swift"] == ["CheckoutUITests/NotesUITests", "CheckoutUITests/SharingUITests"], features
assert not proposal["unmappedSuites"], proposal
assert (mapping_file.read_bytes() if mapping_file.exists() else None) == original_mapping
run([TOOL, "coverage", "apply", "--graph", graph, "--artifact", artifact,
     "--mappings", work / ".swift-test-selection.json", "--output", directory / "applied.json"])
assert json.loads((work / ".swift-test-selection.json").read_text()) == proposal["mappings"]
repeat = json.loads(run([TOOL, "coverage", "import", "--graph", graph, "--artifact", artifact, "--mappings", work / ".swift-test-selection.json"]))
assert not repeat["additions"], repeat
measurements = json.loads((directory / "collection/measurements.json").read_text())
if (directory / "build-measurements.json").exists():
    measurements.update(json.loads((directory / "build-measurements.json").read_text()))
measurements.update(importGenerationSeconds=import_seconds)
(directory / "measurements.json").write_text(json.dumps(measurements, indent=2) + "\n")
print("PASS isolated screen associations, retained shared code, additive apply and idempotence", flush=True)
print(json.dumps(measurements, indent=2), flush=True)
