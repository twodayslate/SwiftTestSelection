#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Zachary Gorak
# SPDX-License-Identifier: AGPL-3.0-only
"""Measure an isolated Xcode build command and sample its compiler-process RSS.

RSS sums double-count shared pages and exclude persistent Xcode services whose
command lines do not mention DerivedData. This is explicitly a sampled metric,
not a process-tree physical-footprint peak. Keep other builds out of this path.
"""
import argparse
import json
import pathlib
import subprocess
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--derived-data', required=True)
parser.add_argument('--log', type=pathlib.Path, required=True)
parser.add_argument('--output', type=pathlib.Path, required=True)
parser.add_argument('command', nargs=argparse.REMAINDER)
a = parser.parse_args()
command = a.command[1:] if a.command[:1] == ['--'] else a.command
if not command: parser.error('a build command is required')
start = time.monotonic()
peak = 0
samples = 0
process_count = 0
with a.log.open('wb') as log:
    child = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT)
    while child.poll() is None:
        output = subprocess.check_output(['ps', '-axo', 'pid=,rss=,comm=,args='], text=True)
        rss = 0
        count = 0
        for line in output.splitlines():
            fields = line.strip().split(None, 3)
            if len(fields) < 4: continue
            _, memory, executable, arguments = fields
            if a.derived_data not in arguments: continue
            if pathlib.Path(arguments.split(None, 1)[0]).name not in ['xcodebuild', 'swift-frontend', 'swiftc', 'clang', 'clang++', 'ld', 'python3', 'Python']:
                continue
            if 'measure_build.py' in arguments: continue
            rss += int(memory) * 1024
            count += 1
        peak = max(peak, rss)
        process_count = max(process_count, count)
        samples += 1
        time.sleep(0.1)
result = {'seconds': time.monotonic()-start, 'exitCode': child.returncode,
          'sampledPeakCompilerAndDriverRSSBytes': peak, 'maxObservedProcesses': process_count,
          'samples': samples, 'samplingDelaySeconds': 0.1,
          'averageSampleIntervalSeconds': (time.monotonic()-start)/max(1, samples),
          'memoryCaveat': 'RSS sum counts shared pages repeatedly; excludes persistent services without DerivedData in arguments.'}
a.output.write_text(json.dumps(result, indent=2)+'\n')
print(json.dumps(result))
raise SystemExit(child.returncode)
