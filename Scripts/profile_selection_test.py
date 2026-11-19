#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Zachary Gorak
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
"""Exercise wrapper measurements and exact raw/final policy invariants."""
import json
from pathlib import Path
import platform
import subprocess
import sys
import tempfile
import unittest


@unittest.skipUnless(platform.system() == "Darwin", "Darwin resource accounting")
class ProfileSelectionTests(unittest.TestCase):
    def run_profile(self, scenario):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            selection = root / "select.py"
            selection.write_text('''import json,sys
from pathlib import Path
root=Path(sys.argv[1]); scenario=sys.argv[2]
if scenario == "selection-failure": sys.exit(7)
report={"selectedTests":["UI/Suite/test()"], "diagnostics":[], "analysisEvents":[{"phase":"build","seconds":0.001}]}
report["selectionScopes"]=[{"scope":{"name":"support"},"report":{"selectedTests":[],"diagnostics":[]}}]
(root/"report.json").write_text(json.dumps(report))
policy={"mode":"selected","ui_tests":["UI/Suite/test()"],"non_ui_tests":[]}
if scenario == "policy-change" and root.name == "2": policy["ui_tests"]=[]
(root/"policy.json").write_text(json.dumps(policy))
(root/"phases.json").write_text(json.dumps([{"phase":"consumer","seconds":0.01}]))
''')
            verification = root / "verify.py"
            verification.write_text('''import json,sys
from pathlib import Path
path=Path(sys.argv[sys.argv.index("--report")+1]); json.loads(path.read_text())
if sys.argv[-1] == "scope-failure" and path.name.startswith("scope-"): sys.exit(9)
''')
            config = {"cwd": folder, "selection": [sys.executable, str(selection), "{run}", scenario],
                      "toolExecutable": str(selection),
                      "verification": [sys.executable, str(verification), "--report", "{run}/report.json", scenario],
                      "report": "{run}/report.json", "policyReport": "{run}/policy.json", "consumerPhases": "{run}/phases.json"}
            path = root / "configuration.json"; path.write_text(json.dumps(config))
            result = subprocess.run([sys.executable, str(Path(__file__).with_name("profile_selection.py")),
                                     str(path), "--output", str(root / "output"), "--repetitions", "2"], capture_output=True, text=True)
            return result, json.loads((root / "output/summary.json").read_text())

    def test_complete_wrapper_keeps_policy_and_scope_verification(self):
        result, summary = self.run_profile("success")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(summary["equivalentSelectionsAndDecisionStatuses"])
        self.assertEqual(len(summary["repetitions"]), 2)
        for run in summary["repetitions"]:
            self.assertEqual(run["consumerPhases"][0]["phase"], "consumer")
            self.assertEqual(run["scopeVerification"][0]["exitCode"], 0)
            self.assertGreater(run["selection"]["wallSeconds"], 0)
            self.assertTrue(run["executableUnchanged"])

    def test_policy_only_change_fails_despite_identical_raw_ids(self):
        result, summary = self.run_profile("policy-change")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(summary["equivalentSelectionsAndDecisionStatuses"])

    def test_selection_and_scope_failures_are_preserved(self):
        for scenario in ["selection-failure", "scope-failure"]:
            result, summary = self.run_profile(scenario)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(len(summary["repetitions"]), 1)
            run = summary["repetitions"][0]
            failure = run["selection"] if scenario == "selection-failure" else run["scopeVerification"][0]
            self.assertNotEqual(failure["exitCode"], 0)


if __name__ == "__main__":
    unittest.main()
