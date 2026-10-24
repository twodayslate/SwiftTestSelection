#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Zachary Gorak
# SPDX-License-Identifier: AGPL-3.0-only
"""Prepare an isolated compiler-wrapper layout; print build flags as JSON.

No installed toolchain files are modified. This is an investigation utility,
not a supported incremental capture or production graph input format.
"""
import argparse
import json
import pathlib
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--compiler', type=pathlib.Path, required=True)
parser.add_argument('--output', type=pathlib.Path, required=True)
args = parser.parse_args()
compiler = args.compiler.absolute()  # Preserve swiftc basename (driver mode).
help_text = subprocess.check_output([str(compiler), '-frontend', '-help-hidden'], text=True)
if '-sil-output-path ' not in help_text:
    parser.error('This compiler does not advertise additional SIL output')
toolchain_root = compiler.parent.parent
if not (toolchain_root / 'share/swift/features.json').is_file():
    parser.error('Use the toolchain compiler returned by xcrun --find swiftc, not a system shim')
root = args.output.absolute()
root.mkdir()  # A new session must not accidentally inherit old fragments.
(root / 'bin').mkdir()
# SwiftDriver discovers features.json and compiler/Clang resources relative to
# the frontend executable. A bare wrapper path silently loses those features.
for name in ['lib', 'share', 'include']:
    (root / name).symlink_to(compiler.parent.parent / name, target_is_directory=True)
frontend = root / 'bin' / 'swift-frontend'
frontend.symlink_to(pathlib.Path(__file__).with_name('capture_swiftc.py').absolute())
record = {
    'schemaVersion': 1,
    'experimental': True,
    'compilerVersion': subprocess.check_output([str(compiler), '--version'], text=True),
    'environment': {'IMPACT_REAL_SWIFTC': str(compiler), 'IMPACT_SIL_CAPTURE': str(root / 'capture')},
    'additionalSwiftFlags': ['-driver-use-frontend-path', str(frontend)],
    'limitation': 'Clean-build experiment only. No incremental reuse or completeness guarantee.'
}
(root / 'session.json').write_text(json.dumps(record, indent=2) + '\n')
print(json.dumps(record, indent=2))
