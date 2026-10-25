#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Zachary Gorak
# SPDX-License-Identifier: AGPL-3.0-only
"""Experimental frontend wrapper; does not change optimization or codegen.

Requires IMPACT_SIL_CAPTURE and IMPACT_REAL_SWIFTC. Each object-producing frontend
job gets a private additional SIL output. This is a capture probe, not a complete
incremental graph cache or a supported replacement for compiler replay.
"""
import hashlib
import json
import os
import pathlib
import resource
import subprocess
import sys
import time
import uuid
from capture_inputs import frontend_inputs

compiler = os.environ['IMPACT_REAL_SWIFTC']
arguments = sys.argv[1:]
if os.environ.get('IMPACT_CAPTURE_TRACE'):
    with open(os.environ['IMPACT_CAPTURE_TRACE'], 'a') as trace:
        trace.write(json.dumps(arguments) + '\n')
if '-frontend' not in arguments:
    # Discovery queries pass through; install through -driver-use-frontend-path.
    os.execv(compiler, [compiler, *arguments])

if not any(a in arguments for a in ['-c', '-emit-object']):
    os.execv(compiler, [compiler, *arguments])

directory = pathlib.Path(os.environ['IMPACT_SIL_CAPTURE']).resolve()
directory.mkdir(parents=True, exist_ok=True)
job = directory / str(uuid.uuid4())
job.mkdir()  # Exclusive directory per frontend/batch/target/architecture invocation.
sil = job / 'output.sil'
def digest_file(path):
    digest = hashlib.sha256()
    with open(path, 'rb') as stream:
        for chunk in iter(lambda: stream.read(1024*1024), b''): digest.update(chunk)
    return digest.hexdigest()

source_files, primaries, input_lists = frontend_inputs(arguments, os.getcwd())
sources = {a: digest_file(a) for a in source_files}
record = dict(inputLists=input_lists, sources=sources, sourceFiles=source_files, primaryFiles=primaries, schemaVersion=1,
              compiler=compiler, directory=os.getcwd(), arguments=arguments,
              started=time.time(), status='incomplete')
manifest = job / 'manifest.json'
manifest.write_text(json.dumps(record, indent=2))
capture_arguments = list(arguments)
outputs = []
if len(primaries) > 1 and '-supplementary-output-file-map' not in capture_arguments:
    # Repeated -sil-output-path values are accepted by the compiler but can
    # overwrite the first path for each primary. A per-input map avoids this.
    keys = {'-emit-dependencies-path': 'dependencies', '-emit-const-values-path': 'const-values',
            '-emit-reference-dependencies-path': 'swift-dependencies', '-serialize-diagnostics-path': 'diagnostics'}
    output_map = {p: {} for p in primaries}
    counts = {k: 0 for k in keys}
    remaining = []
    cursor = 0
    while cursor < len(capture_arguments):
        argument = capture_arguments[cursor]
        if argument in keys:
            index = counts[argument]
            output_map[primaries[index]][keys[argument]] = capture_arguments[cursor+1]
            counts[argument] += 1
            cursor += 2
        else:
            remaining.append(argument)
            cursor += 1
    assert all(count in [0, len(primaries)] for count in counts.values()), 'Ambiguous supplementary outputs'
    private_map = job / 'original-supplementary-outputs.json'
    private_map.write_text(json.dumps(output_map))
    capture_arguments = remaining + ['-supplementary-output-file-map', str(private_map)]
if '-supplementary-output-file-map' in capture_arguments:
    map_index = capture_arguments.index('-supplementary-output-file-map') + 1
    output_map = json.loads(pathlib.Path(capture_arguments[map_index]).read_text())
    for index, source in enumerate(primaries or ['']):
        path = job / f'output-{index}.sil'
        output_map.setdefault(source, {})['sil'] = str(path)
        outputs.append(path)
    private_map = job / 'supplementary-outputs.json'
    private_map.write_text(json.dumps(output_map))
    capture_arguments[map_index] = str(private_map)
else:
    count = max(1, len(primaries))
    for index in range(count):
        path = sil if count == 1 else job / f'output-{index}.sil'
        capture_arguments += ['-sil-output-path', str(path)]
        outputs.append(path)
record['silFiles'] = [path.name for path in outputs]
manifest.write_text(json.dumps(record, indent=2))
result = subprocess.run([compiler, *capture_arguments])
record.update(exitCode=result.returncode, seconds=time.time()-record['started'],
              compilerPeakRSSBytes=resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss)
if result.returncode == 0 and sources and all(path.is_file() and path.stat().st_size for path in outputs) and all(
        pathlib.Path(p).is_file() and digest_file(p) == digest for p, digest in {**sources, **input_lists}.items()):
    record.update(status='complete', silBytes=sum(path.stat().st_size for path in outputs),
                  silSHA256={path.name: digest_file(path) for path in outputs})
else:
    record['status'] = 'failed'
temporary = job / 'manifest.tmp'
temporary.write_text(json.dumps(record, indent=2))
temporary.replace(manifest)
sys.exit(result.returncode)
