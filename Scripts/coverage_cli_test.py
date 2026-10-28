#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Zachary Gorak
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
"""Offline CLI contract checks: inspect, additive apply, preservation, and failures."""
import copy
import json
import os
import pathlib
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
TOOL = pathlib.Path(os.environ.get("SWIFT_TEST_IMPACT", ROOT / ".build/debug/swift-test-impact"))

with tempfile.TemporaryDirectory(prefix="coverage-cli-") as directory:
    work = pathlib.Path(directory)
    graph_path, artifact_path, mappings_path = [work / name for name in ["graph.json", "artifact.json", "mappings.json"]]
    graph = dict(schemaVersion=2, analysisKind="xcode-sil-and-ui-mappings", tests=["UI/Screen/testScreen()"], diagnostics=[],
                 targets=[dict(name="App", productType="com.apple.product-type.application", sourceFiles=["Screen.swift"]),
                          dict(name="UI", productType="com.apple.product-type.bundle.ui-testing", sourceFiles=["UITests.swift"])],
                 sources={"Screen.swift": dict(units=[], inheritance={}, diagnostics=[])}, modules={},
                 dependencies=dict(schemaVersion=1, toolchain="test", tests={}, diagnostics=[], testDiagnostics={},
                                   functions={"screen": dict(id="screen", name="screen()", module="App", dependencies=[],
                                                             regions=[dict(path="Screen.swift", startLine=1, endLine=3)],
                                                             uncertainties=[], dynamicDeclarations=[], resolvedDynamicDeclarations=[])}),
                 buildArtifact=dict(schemaVersion=1, id="build", revision="revision", context={"configuration": "Debug", "destination": "platform=iOS Simulator,id=test"},
                                    toolchain="test", buildLogDigest="log", buildSettingsDigest="settings", productsDirectory="/build", xctestrun="App.xctestrun", products={"App": "digest"}))
    graph_path.write_text(json.dumps(graph))

    def run(*args, fail=False):
        result = subprocess.run([str(TOOL), "coverage", *map(str, args)], text=True, capture_output=True)
        if fail:
            assert result.returncode == 1, result
            assert json.loads(result.stderr)["code"] == "coverage_command_failed", result
            return
        assert result.returncode == 0, result.stderr
        return json.loads(result.stdout)

    plan = run("plan", "--graph", graph_path, "--suite", "UI/Screen", "--app-target", "App")
    assert len(plan["executions"]) == 1
    artifact = dict(schemaVersion=1, sessions=[dict(id="isolated", identity=plan["identity"], sourceRoot="/source",
                    enabledTests=graph["tests"], selectedSuites=["UI/Screen"], appTargets=["App"], resultBundle="screen.xcresult", status="complete",
                    testResults=dict(devices=[dict(deviceId="test", deviceName="Phone", platform="iOS Simulator", osVersion="26.5", architecture="arm64")], testNodes=[dict(nodeType="UI test bundle", name="UI", children=[
                        dict(nodeType="Test Case", name="testScreen()", nodeIdentifier="Screen/testScreen()", result="Passed")])]),
                    coverage=dict(targets=[dict(name="App.app", executableLines=3, files=[dict(path="/source/Screen.swift", functions=[
                        dict(name="screen()", lineNumber=1, executionCount=1)])])]))])
    artifact_path.write_text(json.dumps(artifact))
    existing = dict(version=1, features=[dict(name="manual", sources=["Unobserved.swift"], tests=["UI/Screen"], annotation={"owner": "user"})],
                    runtimeDependencyPolicy="conservative", customPolicy={"review": True})
    mappings_path.write_text(json.dumps(existing))
    original = mappings_path.read_bytes()
    common = ["--graph", graph_path, "--artifact", artifact_path, "--mappings", mappings_path]
    proposed = run("import", *common)
    assert mappings_path.read_bytes() == original
    assert len(proposed["additions"]) == 1 and proposed["validationPassed"]
    assert proposed["mappings"]["features"][0] == existing["features"][0]
    assert proposed["mappings"]["customPolicy"] == existing["customPolicy"]
    run("import", *common, "--output", mappings_path, fail=True)
    assert mappings_path.read_bytes() == original
    run("apply", *common, "--output", work / "missing-parent/proposal.json", fail=True)
    assert mappings_path.read_bytes() == original
    applied = run("apply", *common)
    assert json.loads(mappings_path.read_text()) == applied["mappings"] == proposed["mappings"]
    assert not run("import", *common)["additions"]
    saved = mappings_path.read_bytes()
    for mutation in ["failed", "unknownIdentity", "missingEvidence", "partial", "missingResult", "missingIdentifier", "deviceMismatch", "missingDevices"]:
        bad = copy.deepcopy(artifact)
        session = bad["sessions"][0]
        if mutation == "failed":
            session["status"] = "failed"
        elif mutation == "unknownIdentity":
            session["identity"]["revision"] = "other"
        elif mutation == "missingEvidence":
            del session["testResults"]
        elif mutation == "partial":
            session["testResults"]["testNodes"][0]["children"][0]["result"] = "Skipped"
        elif mutation in ["missingResult", "missingIdentifier"]:
            case = dict(nodeType="Test Case", name="otherTest()", nodeIdentifier="Other/otherTest()", result="Failed")
            del case["result" if mutation == "missingResult" else "nodeIdentifier"]
            session["testResults"]["testNodes"][0]["children"].append(case)
        elif mutation == "deviceMismatch":
            session["testResults"]["devices"][0]["deviceId"] = "different-device"
        else:
            del session["testResults"]["devices"]
        artifact_path.write_text(json.dumps(bad))
        report = run("import", *common)
        assert any(d["severity"] == "error" for d in report["diagnostics"]), report
        run("apply", *common, fail=True)
        assert mappings_path.read_bytes() == saved
    artifact_path.write_text(json.dumps(artifact))
    invalid_symbols = copy.deepcopy(existing)
    invalid_symbols["features"][0]["symbols"] = ["App.screen()", "App.missing()"]
    mappings_path.write_text(json.dumps(invalid_symbols))
    saved = mappings_path.read_bytes()
    report = run("import", *common)
    assert not report["validationPassed"]
    assert report["mappingValidationDiagnostics"][0]["code"] == "unresolved_mapping_symbol"
    run("apply", *common, fail=True)
    assert mappings_path.read_bytes() == saved
    # Planning, import and apply must agree for Xcode's valid ID-only form.
    graph["buildArtifact"]["context"]["destination"] = "id=test"
    graph_path.write_text(json.dumps(graph))
    plan = run("plan", "--graph", graph_path, "--suite", "UI/Screen", "--app-target", "App")
    assert plan["identity"]["destination"] == "id=test"
    artifact["sessions"][0]["identity"] = plan["identity"]
    artifact_path.write_text(json.dumps(artifact))
    mappings_path.write_text(json.dumps(existing))
    report = run("import", *common)
    assert report["validationPassed"] and len(report["additions"]) == 1, report
    applied = run("apply", *common)
    assert json.loads(mappings_path.read_text()) == applied["mappings"]
    saved = mappings_path.read_bytes()
    artifact["sessions"][0]["testResults"]["devices"][0]["deviceId"] = "wrong-device"
    artifact_path.write_text(json.dumps(artifact))
    report = run("import", *common)
    assert not report["validationPassed"]
    assert any(d["code"] == "incompatible_destination" for d in report["diagnostics"])
    run("apply", *common, fail=True)
    assert mappings_path.read_bytes() == saved
    # Main's conditional mappings use graph schema 3. Preserve the complete
    # user-authored expression while adding independent positive associations.
    conditional = copy.deepcopy(existing)
    conditional["version"] = 2
    conditional["features"].append(dict(name="conditional", tests=["UI/Screen"],
        when={"all": [{"sourceChanged": "Screen.swift"}, {"any": [{"symbolChanged": "App.screen()"}]}]},
        annotation={"owner": "user-condition"}))
    graph["schemaVersion"] = 3
    graph["mappings"] = conditional
    graph_path.write_text(json.dumps(graph))
    plan = run("plan", "--graph", graph_path, "--suite", "UI/Screen", "--app-target", "App")
    artifact["sessions"][0]["identity"] = plan["identity"]
    artifact["sessions"][0]["testResults"]["devices"][0]["deviceId"] = "test"
    artifact_path.write_text(json.dumps(artifact))
    mappings_path.write_text(json.dumps(conditional))
    report = run("import", *common)
    assert report["validationPassed"] and len(report["additions"]) == 1, report
    assert report["mappings"]["version"] == 2
    assert report["mappings"]["features"][:2] == conditional["features"]
    assert all("when" not in feature for feature in report["additions"])
    applied = run("apply", *common)
    assert json.loads(mappings_path.read_text()) == applied["mappings"] == report["mappings"]
    assert not run("import", *common)["additions"]
    # Current inline-aware captures use schema 4 and the sourceSnapshots key.
    graph["schemaVersion"] = 4
    graph["sourceSnapshots"] = graph.pop("sources")
    graph_path.write_text(json.dumps(graph))
    plan = run("plan", "--graph", graph_path, "--suite", "UI/Screen", "--app-target", "App")
    artifact["sessions"][0]["identity"] = plan["identity"]
    artifact_path.write_text(json.dumps(artifact))
    mappings_path.write_text(json.dumps(conditional))
    report = run("import", *common)
    assert report["validationPassed"] and len(report["additions"]) == 1, report
    conditional["features"][1]["when"]["all"][1]["any"].append({"symbolChanged": "App.missing()"})
    mappings_path.write_text(json.dumps(conditional))
    saved = mappings_path.read_bytes()
    report = run("import", *common)
    assert not report["validationPassed"]
    assert report["mappingValidationDiagnostics"][0]["pattern"] == "App.missing()"
    run("apply", *common, fail=True)
    assert mappings_path.read_bytes() == saved
    print("PASS coverage CLI inspection, bundle names, additive apply, conditional mappings, unknown-field preservation, idempotence and rejected writes")
