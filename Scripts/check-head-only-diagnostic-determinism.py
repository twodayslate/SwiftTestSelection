#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Zachary Gorak
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
"""Run after swift test -c release; compare reports across fresh hash seeds."""
import argparse
import os
from pathlib import Path
import subprocess
import tempfile


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--configuration", choices=["debug", "release"], default="release")
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix="head-only-diagnostics-") as directory:
    expected = None
    for run in range(5):
        output = Path(directory) / f"{run}.json"
        environment = os.environ.copy()
        # Swift chooses a new randomized hash seed for each process.
        environment.pop("SWIFT_DETERMINISTIC_HASHING", None)
        environment["IMPACT_DIAGNOSTIC_DETERMINISM_OUTPUT"] = str(output)
        subprocess.run(
            ["swift", "test", "-c", args.configuration, "--skip-build", "--filter",
             "headOnlyAmbiguousDeclarationDiagnosticsAreDeterministic"],
            cwd=root, env=environment, check=True,
        )
        # Reading the required output also catches a stale binary/missing test.
        actual = output.read_bytes()
        if expected is not None and actual != expected:
            raise SystemExit(f"Diagnostic reports differed in process {run + 1}")
        expected = actual
print("Identical full/helper/import scope reports across five fresh processes.")
