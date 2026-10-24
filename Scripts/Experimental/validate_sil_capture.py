#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Zachary Gorak
# SPDX-License-Identifier: AGPL-3.0-only
"""Check experimental clean-build fragments against a full expected build log.

This intentionally rejects fresh incremental captures missing unchanged inputs.
It does not establish reviewed-revision/product provenance and cannot authorize
production selection. Existing artifact provenance checks remain mandatory.
"""
import argparse
import hashlib
import json
import pathlib
import shlex


def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for data in iter(lambda: stream.read(1024*1024), b''): h.update(data)
    return h.hexdigest()


def value(arguments, flag):
    return arguments[arguments.index(flag)+1] if flag in arguments else ''


def validate(capture, expected_log):
    expected = {}
    diagnostics = []
    if '** TEST BUILD SUCCEEDED **' not in expected_log.read_text():
        diagnostics.append('Expected inventory is not a successful full test build')
    for line in expected_log.read_text().splitlines():
        if 'builtin-SwiftDriver -- ' not in line: continue
        arguments = shlex.split(line.split('builtin-SwiftDriver -- ', 1)[1])
        key = (value(arguments, '-module-name'), value(arguments, '-target'))
        files = set()
        for argument in arguments:
            if argument.startswith('@'):
                files.update(str(pathlib.Path(p).resolve()) for p in shlex.split(pathlib.Path(argument[1:]).read_text()) if p.endswith('.swift'))
            elif argument.endswith('.swift'):
                files.add(str(pathlib.Path(argument).resolve()))
        if not files: diagnostics.append('No source inventory for ' + repr(key))
        expected.setdefault(key, set()).update(files)
    if not expected: diagnostics.append('No full-build compiler inventory')
    covered = {}
    fragments = 0
    for manifest in sorted(capture.glob('*/manifest.json')):
        record = json.loads(manifest.read_text())
        arguments = record['arguments']
        key = (value(arguments, '-module-name'), value(arguments, '-target'))
        optimizations = [a for a in arguments if a in ['-Onone', '-O', '-Osize', '-Ounchecked']]
        if optimizations[-1:] != ['-Onone'] or '-g' not in arguments:
            diagnostics.append('Unsupported optimization/debug settings: ' + str(manifest))
            continue
        if record['status'] != 'complete':
            diagnostics.append('Incomplete frontend capture: ' + str(manifest))
            continue
        # Frontend file lists are temporary. Use the inventory snapshotted before
        # compilation, not a list which may have disappeared or changed since.
        uses_lists = any(a in arguments for a in ['-filelist', '-primary-filelist'])
        source_files = record.get('sourceFiles')
        primaries = record.get('primaryFiles')
        if uses_lists and (source_files is None or primaries is None):
            diagnostics.append('Missing expanded file-list inventory: ' + str(manifest))
            continue
        if primaries is None:
            primaries = [arguments[i+1] for i, a in enumerate(arguments[:-1]) if a == '-primary-file']
        if not isinstance(primaries, list) or any(not isinstance(p, str) for p in primaries):
            diagnostics.append('Invalid primary inventory: ' + str(manifest))
            continue
        directory = pathlib.Path(record.get('directory', '.'))
        inputs = record.get('sources', {})
        if not inputs:
            diagnostics.append('Missing source fingerprints: ' + str(manifest))
            continue
        valid = True
        if source_files is not None and (not isinstance(source_files, list) or
                any(not isinstance(p, str) for p in source_files) or set(source_files) != set(inputs)):
            diagnostics.append('Incomplete expanded source fingerprints: ' + str(manifest))
            valid = False
        if key not in expected:
            diagnostics.append('Unexpected module/target: ' + repr(key))
            valid = False
        if any(p not in inputs for p in primaries):
            diagnostics.append('Missing primary input fingerprint: ' + str(manifest))
            valid = False
        for path, fingerprint in inputs.items():
            file = directory / path
            if not file.is_file() or digest(file) != fingerprint:
                diagnostics.append('Changed/missing source: ' + path)
                valid = False
        outputs = record.get('silFiles', [])
        if len(outputs) != max(1, len(primaries)) or len(set(outputs)) != len(outputs):
            diagnostics.append('Missing/duplicate per-primary SIL outputs: ' + str(manifest))
            valid = False
        for name in outputs:
            file = manifest.parent / name
            if pathlib.Path(name).name != name or not file.is_file() or digest(file) != record.get('silSHA256', {}).get(name):
                diagnostics.append('Changed/missing SIL: ' + str(file))
                valid = False
        if valid:
            covered.setdefault(key, set()).update(str((directory / p).resolve()) for p in (primaries or inputs.keys()))
            fragments += len(outputs)
    for key, inputs in expected.items():
        for path in sorted(inputs - covered.get(key, set())):
            diagnostics.append('Missing fragment coverage for ' + repr(key) + ': ' + path)
    return {'complete': not diagnostics, 'fragments': fragments,
            'modules': len(expected), 'diagnostics': diagnostics,
            'provenanceValidated': False}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--capture', type=pathlib.Path, required=True)
    parser.add_argument('--expected-build-log', type=pathlib.Path, required=True)
    parser.add_argument('--output', type=pathlib.Path)
    args = parser.parse_args()
    result = validate(args.capture, args.expected_build_log)
    text = json.dumps(result, indent=2) + '\n'
    if args.output: args.output.write_text(text)
    else: print(text, end='')
    raise SystemExit(0 if result['complete'] else 1)
