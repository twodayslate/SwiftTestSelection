#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Zachary Gorak
# SPDX-License-Identifier: AGPL-3.0-only
"""Completeness checks must reject gaps, stale inputs, tampering and failures."""
import json
import pathlib
import tempfile
from validate_sil_capture import validate, digest

with tempfile.TemporaryDirectory(prefix='impact-capture-validation-') as temporary:
    root = pathlib.Path(temporary)
    source = root / 'Source.swift'
    source.write_text('func value() -> Int { 1 }\n')
    log = root / 'build.log'
    log.write_text(f'builtin-SwiftDriver -- swiftc -module-name Example -target arm64-apple-macos13.0 {source}\n** TEST BUILD SUCCEEDED **\n')
    capture = root / 'capture'
    capture.mkdir()
    assert not validate(capture, log)['complete'], 'Empty incremental capture must fail'
    job = capture / 'job'
    job.mkdir()
    sil = job / 'output.sil'
    sil.write_text('sil_stage canonical\n')
    record = dict(status='complete', arguments=['-frontend','-c','-Onone','-g','-module-name','Example',
        '-target','arm64-apple-macos13.0','-primary-file',str(source)], sources={str(source): digest(source)},
        silFiles=['output.sil'], silSHA256={'output.sil': digest(sil)})
    manifest = job / 'manifest.json'
    def check(expected):
        manifest.write_text(json.dumps(record))
        assert validate(capture, log)['complete'] == expected
    check(True)
    source.write_text('func value() -> Int { 2 }\n')
    check(False)
    record['sources'][str(source)] = digest(source)
    check(True)
    sil.write_text('tampered')
    check(False)
    record['silSHA256']['output.sil'] = digest(sil)
    check(True)
    record['silFiles'] = []
    check(False)
    record['silFiles'] = ['output.sil', 'output.sil']
    check(False)
    record['silFiles'] = ['output.sil']
    record['status'] = 'incomplete'
    check(False)
    record['status'] = 'complete'
    record['arguments'].append('-O')
    check(False)
    record['arguments'].pop()
    source.unlink()
    check(False)
print('Completeness regression checks passed')
