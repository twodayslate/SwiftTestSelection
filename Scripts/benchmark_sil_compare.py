#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Zachary Gorak
# SPDX-License-Identifier: AGPL-3.0-only
"""Compare release parsers on saved real SIL, excluding compilation from timing.

The semantic digest covers every node field and dispatch-table entry. Peak memory
is the parser process (including digest verification); graph compilation/builds
are not included. Raw inputs are never copied into the repository.
"""
import argparse
import hashlib
import json
import pathlib
import re
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--input', type=pathlib.Path, required=True)
p.add_argument('--source-root', type=pathlib.Path, required=True)
p.add_argument('--reference', default='origin/main')
p.add_argument('--runs', type=int, default=3)
p.add_argument('--output', type=pathlib.Path, required=True)
a = p.parse_args()
if a.runs < 1: p.error('--runs must be positive')
revision = subprocess.check_output(['git', 'rev-parse', a.reference], cwd=ROOT, text=True).strip()
input_hash = hashlib.sha256()
with a.input.open('rb') as stream:
    for block in iter(lambda: stream.read(1024*1024), b''): input_hash.update(block)
results = []
with tempfile.TemporaryDirectory(prefix='sil-compare-') as directory:
    work = pathlib.Path(directory)
    main = (ROOT/'Scripts/SILParseBenchmark.swift').read_text()
    (work/'main.swift').write_text(main)
    for mode in ['reference', 'candidate']:
        target = work/mode
        target.mkdir()
        sources = []
        for name in ['DependencyGraph.swift', 'SILParser.swift', 'SILLineReader.swift']:
            source = target/name
            content = (ROOT/'Sources/TestImpact'/name).read_text()
            if mode == 'reference':
                content = subprocess.check_output(['git','show',revision+':Sources/TestImpact/'+name], cwd=ROOT, text=True)
            source.write_text(content)
            sources.append(str(source))
        subprocess.run(['swiftc','-O',*sources,str(work/'main.swift'),'-o',str(target/'parser')],check=True)
    for iteration in range(1,a.runs+1):
        for mode in ['reference','candidate']:
            run = subprocess.run(['/usr/bin/time','-l',str(work/mode/'parser'),str(a.input),str(a.source_root)],capture_output=True,text=True,check=True)
            result = json.loads(run.stdout)
            result.update(mode=mode,iteration=iteration)
            for label,key in [('maximum resident set size','peakRSSBytes'),('peak memory footprint','peakFootprintBytes')]:
                result[key] = int(re.search(r'(\d+)\s+'+label,run.stderr)[1])
            results.append(result)
            print(json.dumps(result),flush=True)
            a.output.write_text(json.dumps(dict(referenceRevision=revision,inputBytes=a.input.stat().st_size,
                inputSHA256=input_hash.hexdigest(),measurements=results),indent=2)+'\n')
assert len({r['digest'] for r in results}) == 1, 'Parser semantic parity failed'
