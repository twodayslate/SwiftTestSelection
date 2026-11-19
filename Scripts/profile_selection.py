#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Zachary Gorak
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
"""Profile identical warm installed-tool invocations without changing their policy.

JSON configuration: cwd, selection (argv), verification (argv), report (path).
Use {run} in argv/paths for each repetition's fresh output/retained directory.
The supplied commands must perform the desired one-head capture and verification.
selection may invoke the complete consumer wrapper. In that case toolExecutable
identifies the installed analyzer independently of the wrapper/interpreter.
Optional consumerPhases and policyReport paths retain wrapper timings and policy.
No shell is involved. Failed selections/verification are preserved and stop the run.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import subprocess
import time


def policy_signature(report):
    """Keep independent scope decisions, not just the primary selected-ID count."""
    return {
        "selectedTests": sorted(report["selectedTests"]),
        "diagnostics": sorted((d["code"], d.get("message"), sorted(d.get("tests", []))) for d in report.get("diagnostics", [])),
        "positiveTests": sorted({e["test"] for e in report.get("explanations", []) if e.get("kind") != "fallback"}),
        "mappingCoverage": report.get("uiMappingCoverage"),
        "runtimeBoundaryDecisions": report.get("runtimeBoundaryDecisions"),
        "uiConditionDecisions": report.get("uiConditionDecisions"),
        "contractDecisions": [(d.get("contractID", d.get("id")), d["status"], sorted(d.get("failures", [])))
                              for key in ("helperContractDecisions", "helperBindingDecisions") for d in report.get(key, [])],
        "scopes": {s["scope"]["name"]: policy_signature(s["report"]) for s in report.get("selectionScopes", [])},
    }


def execute(argv, cwd, directory, phase):
    resource_path = directory / (phase + ".resources.txt")
    started = time.monotonic()
    with (directory / (phase + ".stdout.txt")).open("wb") as out, (directory / (phase + ".stderr.txt")).open("wb") as err:
        process = subprocess.run(["/usr/bin/time", "-lp", "-o", str(resource_path), *argv], cwd=cwd, stdout=out, stderr=err)
    raw = resource_path.read_text()
    values = {name: float(value) for name, value in re.findall(r"^(real|user|sys)\s+([0-9.]+)$", raw, re.M)}
    peak = re.search(r"(\d+)\s+maximum resident set size", raw)
    return {"argv": argv, "exitCode": process.returncode, "wallSeconds": time.monotonic() - started,
            "processFamilyCPUSeconds": values.get("user", 0) + values.get("sys", 0),
            "maximumResidentSetBytes": int(peak.group(1)) if peak else None, "time": values}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("configuration", type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--repetitions", type=int, default=3)
    args = parser.parse_args()
    if platform.system() != "Darwin" or args.repetitions < 1:
        parser.error("requires macOS and a positive repetition count")
    config = json.loads(args.configuration.read_text())
    for phase in ("selection", "verification"):
        if not isinstance(config.get(phase), list) or not config[phase] or not all(isinstance(v, str) for v in config[phase]):
            parser.error(phase + " must be a nonempty argv array")
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    summary = {"configuration": config, "platform": platform.platform(), "machine": platform.machine(),
               "cpuCount": os.cpu_count(), "toolchain": subprocess.check_output(["xcrun", "swift", "--version"], text=True),
               "developerDirectory": os.environ.get("DEVELOPER_DIR"), "repetitions": [],
               "timingContract": "selection measures the complete supplied command, including consumer orchestration when that command is a consumer wrapper. analysisEvents and consumerPhases are inclusive; never sum nested phases. Analyzer CPU excludes children; /usr/bin/time measures the command process family. Peaks are high-water marks, not additive. Additional verification commands are measured separately, even if the wrapper already verified. Preparation outside these commands is not measured."}
    signatures = []
    executable = Path(config.get("toolExecutable", config["selection"][0])).resolve()
    tool_digest = hashlib.sha256(executable.read_bytes()).hexdigest()
    summary["toolExecutable"] = str(executable)
    summary["executableSHA256"] = tool_digest
    for index in range(args.repetitions):
        directory = output / str(index + 1)
        directory.mkdir()
        expand = lambda s: s.replace("{run}", str(directory))
        record = {"loadBefore": os.getloadavg(), "selection": execute(list(map(expand, config["selection"])), config["cwd"], directory, "selection")}
        summary["repetitions"].append(record)
        if record["selection"]["exitCode"] == 0:
            record["verification"] = execute(list(map(expand, config["verification"])), config["cwd"], directory, "verification")
            report_path = Path(expand(config["report"]))
            report = json.loads(report_path.read_text())
            record["scopeVerification"] = []
            for scope_index, scope in enumerate(report.get("selectionScopes", [])):
                scoped_path = directory / ("scope-" + str(scope_index + 1) + ".json")
                scoped_path.write_text(json.dumps(scope["report"]) + "\n")
                verify = list(map(expand, config["verification"]))
                if "--report" not in verify:
                    raise SystemExit("Scope verification requires a verification command with --report")
                verify[verify.index("--report") + 1] = str(scoped_path)
                record["scopeVerification"].append(execute(verify, config["cwd"], directory, "verify-scope-" + str(scope_index + 1)))
            record["reportBytes"] = report_path.stat().st_size
            record["analysisEvents"] = report.get("analysisEvents", [])
            signature = policy_signature(report)
            if config.get("policyReport"):
                policy_path = Path(expand(config["policyReport"]))
                policy = json.loads(policy_path.read_text())
                # Retain exact execution IDs separately from raw impact. Build
                # IDs/paths change on each fresh capture and are not policy.
                signature["consumerPolicy"] = {key: policy.get(key) for key in (
                    "mode", "run_ui", "run_non_ui", "ui_tests", "non_ui_tests",
                    "regression_policy", "base_ui_tests", "regression_ui_tests",
                    "deferred_regression_tests", "regression_helper_changes",
                    "regression_support_tests", "regression_support_candidates")}
            if config.get("consumerPhases"):
                record["consumerPhases"] = json.loads(Path(expand(config["consumerPhases"])).read_text())
            signatures.append(signature)
            record["policySHA256"] = hashlib.sha256(json.dumps(signature, sort_keys=True).encode()).hexdigest()
            (directory / "policy.json").write_text(json.dumps(signature, indent=2, sort_keys=True) + "\n")
            graph = report.get("buildArtifactPath")
            if graph and Path(graph).is_file():
                record["graphBytes"] = Path(graph).stat().st_size
                bundle = Path(graph).parent
                for name, relative, pattern in (("exportedSwift", "source", "*.swift"), ("capturedSIL", "SILCapture", "*.sil")):
                    files = [p for p in (bundle / relative).rglob(pattern) if p.is_file()]
                    record[name] = {"files": len(files), "bytes": sum(p.stat().st_size for p in files)}
            build_seconds = sum(e["seconds"] for e in record["analysisEvents"] if e["phase"] == "build")
            record["buildSeconds"] = build_seconds
            record["selectionNonBuildSeconds"] = record["selection"]["wallSeconds"] - build_seconds
        record["executableUnchanged"] = hashlib.sha256(executable.read_bytes()).hexdigest() == tool_digest
        summary["equivalentSelectionsAndDecisionStatuses"] = bool(signatures) and all(s == signatures[0] for s in signatures)
        (output / "summary.json").write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n")
        print(json.dumps({"run": index + 1, "selectionSeconds": record["selection"]["wallSeconds"],
                          "verificationExit": record.get("verification", {}).get("exitCode")}), flush=True)
        if record["selection"]["exitCode"] or record.get("verification", {}).get("exitCode") or any(v["exitCode"] for v in record.get("scopeVerification", [])) or not record["executableUnchanged"] or not summary["equivalentSelectionsAndDecisionStatuses"]:
            raise SystemExit("Failed command, changed executable or changed policy; preserved evidence in " + str(directory))


if __name__ == "__main__":
    main()
