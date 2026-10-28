#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Zachary Gorak
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
"""Inspect a coverage plan, or execute it with --run and export attributed evidence.

Requires a captured coverage-enabled build and Xcode 26.x. Never rebuilds or
changes mapping files. An interrupted run leaves an incomplete session checkpoint.
"""
import argparse
import hashlib
import json
import os
import pathlib
import subprocess
import sys
import time


def capture(args, cwd):
    return subprocess.run(args, cwd=cwd, text=True, capture_output=True)


def manifest(root):
    result = {}
    for directory, dirs, files in os.walk(root, followlinks=False):
        for name in dirs[:]:
            path = pathlib.Path(directory) / name
            if path.is_symlink():
                files.append(name)
                dirs.remove(name)
        for name in files:
            path = pathlib.Path(directory) / name
            if path.is_symlink():
                if not path.resolve().is_relative_to(root.resolve()):
                    raise ValueError("Product symlink escapes build directory")
                digest = "symlink:" + os.readlink(path)
            else:
                h = hashlib.sha256()
                with path.open("rb") as stream:
                    for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                        h.update(chunk)
                digest = h.hexdigest()
            result[path.relative_to(root).as_posix()] = digest
    return result


def runtime_fingerprint(root, destination):
    if "Simulator" not in destination:
        return hashlib.sha256(b"").hexdigest()
    result = capture(["xcrun", "simctl", "list", "runtimes", "-j"], root)
    if result.returncode:
        raise ValueError("Cannot inspect simulator runtime inventory")
    inventory = json.loads(result.stdout)
    for runtime in inventory["runtimes"]:
        runtime.pop("lastUsage", None)

    def canonical(value):
        if isinstance(value, dict):
            return {key: canonical(item) for key, item in value.items()}
        if isinstance(value, list):
            return sorted(map(canonical, value), key=lambda item: json.dumps(
                item, sort_keys=True, separators=(",", ":"), ensure_ascii=False).replace("/", "\\/"))
        return value

    data = json.dumps(canonical(inventory), sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()
    return hashlib.sha256(data).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--plan", type=pathlib.Path, required=True)
    parser.add_argument("--source-root", type=pathlib.Path, required=True)
    parser.add_argument("--output-directory", type=pathlib.Path, required=True)
    parser.add_argument("--run", action="store_true", help="Execute suites; omitted by default")
    args = parser.parse_args()
    plan = json.loads(args.plan.read_text())
    if plan["schemaVersion"] != 1:
        raise ValueError("Unsupported plan version")
    if not args.run:
        print(json.dumps(plan, indent=2, sort_keys=True))
        return
    # Preserve the spelling used by the compiler (e.g. /var versus /private/var).
    # Resolving a local symlink here would make portable coverage paths external.
    root = args.source_root.absolute()
    revision = capture(["git", "rev-parse", "HEAD"], root)
    status = capture(["git", "status", "--porcelain", "--untracked-files=all"], root)
    if revision.returncode or status.returncode or revision.stdout.strip() != plan["identity"]["revision"] or status.stdout:
        raise ValueError("Collection requires the clean captured source revision")
    toolchain = capture(["xcodebuild", "-version"], root).stdout + capture(["xcrun", "swiftc", "--version"], root).stdout
    if toolchain != plan["identity"]["toolchain"]:
        raise ValueError("Selected toolchain differs from captured build")
    if plan["identity"].get("simulatorRuntimes") != runtime_fingerprint(root, plan["identity"]["destination"]):
        raise ValueError("Simulator runtime inventory differs from captured build")
    products = pathlib.Path(plan["productsDirectory"])
    if manifest(products) != plan["products"]:
        raise ValueError("Build products differ from captured graph")
    output = args.output_directory.resolve()
    output.mkdir(parents=True, exist_ok=False)
    artifact = {"schemaVersion": 1, "sessions": []}
    artifact_path = output / "coverage-artifact.json"

    def checkpoint():
        temp = output / "artifact.tmp"
        temp.write_text(json.dumps(artifact, indent=2, sort_keys=True) + "\n")
        temp.replace(artifact_path)

    start = time.monotonic()
    timings = []
    for index, execution in enumerate(plan["executions"]):
        bundle = output / f"suite-{index + 1}.xcresult"
        session = dict(id=execution["id"], identity=plan["identity"], sourceRoot=str(root),
                       enabledTests=plan["enabledTests"], selectedSuites=[execution["suite"]],
                       appTargets=plan["appTargets"], resultBundle=str(bundle), status="incomplete")
        artifact["sessions"].append(session)
        checkpoint()
        started = time.monotonic()
        with (output / f"suite-{index + 1}.log").open("w") as log:
            result = subprocess.run(["xcodebuild", *execution["arguments"], "-resultBundlePath", str(bundle)],
                                    cwd=root, stdout=log, stderr=subprocess.STDOUT)
        session["status"] = "complete" if result.returncode == 0 else "crashed" if result.returncode < 0 else "failed"
        for key, command in [
            ("testResults", ["xcrun", "xcresulttool", "get", "test-results", "tests", "--path", str(bundle)]),
            ("coverage", ["xcrun", "xccov", "view", "--report", "--json", str(bundle)]),
        ]:
            export = capture(command, root)
            (output / f"suite-{index + 1}-{key}.stderr").write_text(export.stderr)
            if export.returncode == 0:
                try:
                    session[key] = json.loads(export.stdout)
                except json.JSONDecodeError:
                    session["status"] = "incomplete"
        if manifest(products) != plan["products"]:
            session["status"] = "incomplete"
            checkpoint()
            raise ValueError("Build products changed during collection")
        timings.append(time.monotonic() - started)
        checkpoint()
    stats = dict(collectionSeconds=time.monotonic() - start, executionCount=len(timings),
                 executionSeconds=timings, artifactBytes=artifact_path.stat().st_size,
                 resultBundleBytes=sum(p.stat().st_size for bundle in output.glob("*.xcresult") for p in bundle.rglob("*") if p.is_file()))
    (output / "measurements.json").write_text(json.dumps(stats, indent=2) + "\n")
    print(json.dumps(dict(artifact=str(artifact_path), **stats), sort_keys=True))


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, KeyError) as error:
        print(json.dumps({"code": "coverage_collection_failed", "message": str(error)}), file=sys.stderr)
        sys.exit(1)
