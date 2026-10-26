#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Zachary Gorak
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
"""Measure module-cache extraction from already built, immutable input snapshots.

The JSON configs must describe independently prepared builds. This script never
edits consumer sources or builds/runs app tests. Supply configurations in order:
cold, identical head, changed head with warm base, shared dependency changes.
Repeat configurations/cold caches explicitly to obtain repeated measurements.
Do not label these extraction-only times as end-to-end selection/build times.
"""
import argparse
import json
import os
import pathlib
import subprocess
import time

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--scratch-path', required=True)
p.add_argument('--output', type=pathlib.Path, required=True)
p.add_argument('configs', nargs='+', type=pathlib.Path)
a = p.parse_args()
a.output.mkdir()
results = []
for index, config_path in enumerate(a.configs):
    config = json.loads(config_path.read_text())
    name = f'{index+1:02}-{config_path.stem}'
    config['output'] = str((a.output/(name+'.json')).resolve())
    copied = (a.output/(name+'-config.json')).resolve()
    copied.write_text(json.dumps(config, indent=2))
    environment = dict(os.environ, IMPACT_MODULE_CACHE_BENCHMARK=str(copied))
    start = time.monotonic()
    with (a.output/(name+'.log')).open('wb') as log:
        child = subprocess.run(['swift', 'test', '-c', 'release', '--skip-build', '--scratch-path', a.scratch_path,
                                '--filter', 'moduleCacheBenchmark'], env=environment, stdout=log, stderr=subprocess.STDOUT)
    if child.returncode: raise SystemExit(f'{name} failed; inspect its log')
    result = json.loads(pathlib.Path(config['output']).read_text())
    result.update(name=name, wallSeconds=time.monotonic()-start)
    results.append(result)
    (a.output/'results.json').write_text(json.dumps(results, indent=2)+'\n')
    print(json.dumps({k:v for k,v in result.items() if k not in ['messages','moduleKeys']}), flush=True)
