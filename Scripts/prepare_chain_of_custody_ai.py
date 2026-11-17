#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Zachary Gorak
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
"""Prepare a small, fixed historical pilot; labels are source review, not coverage.

No model call or app/test execution occurs here. The Swift CLI extracts complete
syntax declarations from the exact revisions. Nothing reads today's app sources.
"""
import argparse
import json
from pathlib import Path
import re
import subprocess


def prepare(repository, cli, output):
    def git(*args):
        return subprocess.check_output(["git", "-C", str(repository), *args], text=True)

    notes = "ChainOfCustody/Features/Notes/"
    ui = "ChainOfCustodyUITests/"
    # Fixed before running the model. Keep related and unrelated pairs together
    # when splitting future prompt-development and held-out evaluation sets.
    groups = [
        ("841a9149c3691015ae4b62be8e5f9b698c2e42be", 361,
         notes + "NoteBlockCollectionCoordinator.swift",
         ["scrollViewWillBeginDragging", "scrollViewDidScroll"],
         ui + "PairingNotesUITests.swift", "PairingNotesEditingUITests",
         "testAddBlockButtonShrinksAndExpandsWithScrollAndTap",
         "The test opens the note collection and drags it; these UIScrollView delegate callbacks handle that drag."),
        ("45d0108f45dd1980437cef7814ebb47c1123f21a", 355,
         notes + "NoteUnreadActivity.swift", ["isUnread", "markBlockRead"],
         ui + "NoteCommentUnreadUITests.swift", "NoteCommentUnreadUITests",
         "testActivityAndCommentToolbarBadgesMatchBlockDots",
         "The test reads activity badges, injects new block activity, opens that block, and asserts its unread dot clears."),
        ("81b904108b1963d8241508a5430b31797953a80e", 365,
         notes + "NoteActivityView.swift", ["markAllRead", "activityIndex"],
         ui + "PairingNoteActivityUITests.swift", "PairingNoteActivityUITests",
         "testUnreadFilterAndMarkAllReadIncludeUnloadedPagesAndDelayedSync",
         "The test opens paginated note activity and invokes Mark All Read, then changes filters and checks delayed sync."),
    ]
    unrelated_file = ui + "CheckSettingsUITests.swift"
    unrelated_method = "testSubmittedSettingsReopenAndCancelledEditsStayUnsaved"

    def line(revision, path, name):
        text = git("show", revision + ":" + path)
        matches = list(re.finditer(r"\bfunc\s+" + re.escape(name) + r"\s*\(", text))
        if len(matches) != 1:
            raise ValueError(f"Expected one {name} in {revision}:{path}, got {len(matches)}")
        return text.count("\n", 0, matches[0].start()) + 1

    cases = []
    for revision, pr, path, functions, test_file, suite, method, rationale in groups:
        if git("rev-parse", "--verify", revision + "^{commit}").strip() != revision:
            raise ValueError("Revision did not resolve exactly")
        for function in functions:
            for related in (True, False):
                target_file = test_file if related else unrelated_file
                target_method = method if related else unrelated_method
                target_suite = suite if related else "CheckSettingsUITests"
                reason = rationale if related else (
                    "This journey launches the checkSettings fixture and edits check requests; "
                    "it never opens a note editor or note activity. Background/launch execution "
                    "has not been measured, so this is a source-review estimate, not a proven negative.")
                cases.append({
                    "id": f"pr{pr}-{function}-{'related' if related else 'comparison'}",
                    "revision": revision,
                    "function": {"path": path, "line": line(revision, path, function)},
                    "test": {"path": target_file, "line": line(revision, target_file, target_method)},
                    "testIdentifier": f"ChainOfCustodyUITests/{target_suite}/{target_method}()",
                    "expected": related,
                    "evidenceKind": "sourceReview",
                    "evidence": f"https://github.com/twodayslate/ChainOfCustody/pull/{pr} — {reason}",
                })
    output.mkdir(parents=True, exist_ok=True)
    manifest = output / "cases.json"
    manifest.write_text(json.dumps(cases, indent=2) + "\n")
    subprocess.run([str(cli), "ai", "prepare", "--repository", str(repository),
                    "--cases", str(manifest), "--output", str(output / "dataset.json")], check=True)
    print(f"Prepared {len(cases)} source-reviewed pairs at {output / 'dataset.json'}; no measured execution labels.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository", required=True, type=Path)
    parser.add_argument("--cli", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    prepare(args.repository.resolve(), args.cli.resolve(), args.output.resolve())


if __name__ == "__main__":
    main()
