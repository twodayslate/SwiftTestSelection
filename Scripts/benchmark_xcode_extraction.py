#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Zachary Gorak
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
"""Run the release extraction benchmark three times for each worker count.

Requires already built, unchanged products and a successful full build log.
Never builds executable app/test products or runs test bodies. SwiftPM's opt-in
benchmark test is the runner. Keep the selected scratch path free of other jobs.
"""
import argparse
import json
import os
import pathlib
import subprocess
import time

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--config', type=pathlib.Path, required=True)
p.add_argument('--scratch-path', required=True)
p.add_argument('--output', type=pathlib.Path, required=True)
a = p.parse_args()
a.output.mkdir()  # Refuse to overwrite a previous experiment.
config = json.loads(a.config.read_text())
results = []
for iteration in range(3):
    for workers in [1, 2]:
        name = f'workers-{workers}-run-{iteration+1}'
        current = dict(config, workers=str(workers), output=str((a.output/(name+'.json')).resolve()))
        config_file = (a.output/(name+'-config.json')).resolve()
        config_file.write_text(json.dumps(current))
        environment = dict(os.environ, IMPACT_EXTRACTION_BENCHMARK=str(config_file))
        start = time.monotonic()
        peak = samples = maximum_processes = 0
        with (a.output/(name+'.log')).open('wb') as log:
            child = subprocess.Popen(['swift', 'test', '-c', 'release', '--skip-build', '--scratch-path', a.scratch_path,
                                      '--filter', 'xcodeExtractionBenchmark'], env=environment, stdout=log, stderr=subprocess.STDOUT)
            while child.poll() is None:
                rows = subprocess.check_output(['ps', '-axo', 'pid=,ppid=,rss='], text=True)
                processes = [tuple(map(int, row.split())) for row in rows.splitlines() if row.strip()]
                descendants = {child.pid}
                while True:
                    expanded = descendants | {pid for pid, parent, _ in processes if parent in descendants}
                    if expanded == descendants: break
                    descendants = expanded
                live = [(pid, rss) for pid, _, rss in processes if pid in descendants]
                peak = max(peak, sum(rss * 1024 for _, rss in live))
                maximum_processes = max(maximum_processes, len(live))
                samples += 1
                time.sleep(0.1)
        if child.returncode:
            raise SystemExit(f'{name} failed ({child.returncode}); see its log')
        result = json.loads(pathlib.Path(current['output']).read_text())
        result.update(iteration=iteration+1, wallSeconds=time.monotonic()-start,
                      sampledPeakProcessTreeRSSBytes=peak, samples=samples,
                      maximumProcesses=maximum_processes,
                      memoryCaveat='Sampled sum includes runner and compiler children; shared pages counted repeatedly. Not physical footprint.')
        results.append(result)
        (a.output/'results.json').write_text(json.dumps(results, indent=2)+'\n')
        print(json.dumps(result), flush=True)
        if len({r['semanticDigest'] for r in results}) != 1:
            raise SystemExit('Graph semantics differ; do not accept these measurements')
