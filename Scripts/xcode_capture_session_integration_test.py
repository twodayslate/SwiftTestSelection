#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Zachary Gorak
# SPDX-License-Identifier: AGPL-3.0-only
"""Check incremental capture inventories without executing test bodies."""
import argparse
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--destination', required=True)
parser.add_argument('--tool', type=Path, required=True)
args = parser.parse_args()
tool = args.tool.resolve(strict=True)

with tempfile.TemporaryDirectory(prefix='impact-capture-session-') as temporary:
    root = Path(temporary).resolve()
    source = root / 'source'
    shutil.copytree(ROOT / 'Fixtures/XcodeUITests', source)

    def run(command, success=True):
        result = subprocess.run(list(map(str, command)), cwd=source, text=True, capture_output=True)
        assert (result.returncode == 0) == success, result.stdout + result.stderr
        return result

    def commit(message):
        run(['git', 'add', '.'])
        run(['git', '-c', 'user.name=Test', '-c', 'user.email=test@example.invalid', 'commit', '-qm', message])

    run(['git', 'init', '-q'])
    commit('Fixture')
    derived, session = root / 'derived', root / 'session'
    command = [sys.executable, ROOT / 'Scripts/capture-build.py', '--session', session,
               '--context', 'fixture', '--project', source / 'ImpactDemo.xcodeproj', '--scheme', 'ImpactDemo',
               '--test-plan', 'AllTests', '--configuration', 'Debug', '--destination', args.destination,
               '--derived-data', derived]
    run(command)
    seal = session / 'build.json'
    first = json.loads(seal.read_text())
    assert first['inventory'] and first['manifests']
    stale = derived / 'Build/Intermediates.noindex/Inactive/Deleted.SwiftFileList'
    stale.parent.mkdir(parents=True)
    stale.write_text(str(source / 'Deleted.swift') + '\n')
    run(command)
    incremental = json.loads(seal.read_text())
    assert incremental['inventory'] == first['inventory']
    assert incremental['manifests']
    assert '** TEST BUILD SUCCEEDED **' in (session / 'build.log').read_text()
    runner, = (derived / 'Build/Products').glob('*.xctestrun')
    result = run([tool, 'graph', '--project', source / 'ImpactDemo.xcodeproj', '--scheme', 'ImpactDemo',
                  '--test-plan', 'AllTests', '--configuration', 'Debug', '--destination', args.destination,
                  '--derived-data', derived, '--build-log', session / 'build.log', '--build-settings', session / 'settings.json',
                  '--xctestrun', runner, '--revision', 'HEAD', '--sil-capture', session, '--format', 'json'])
    graph = json.loads(result.stdout)
    assert len(graph['tests']) == 9 and not graph['diagnostics'] and not graph['dependencies']['diagnostics']
    assert 'Captured SIL' in result.stderr
    print('PASS fresh and incremental sealed capture ignore inactive source lists', flush=True)

    saved = seal.read_bytes()
    changed = list(command)
    changed[changed.index('--context') + 1] = 'different-context'
    assert 'fresh DerivedData' in run(changed, success=False).stderr
    assert seal.read_bytes() == saved  # Rejected before starting a build.
    changed = list(command)
    changed[changed.index('--session') + 1] = root / 'new-session'
    assert 'fresh DerivedData' in run(changed, success=False).stderr
    assert not (root / 'new-session/build.json').exists()
    print('PASS new/incompatible sessions cannot seal an incomplete incremental inventory', flush=True)

    # A genuine compiler failure still invalidates the old seal.
    with (source / 'App/Sharing.swift').open('a') as file:
        file.write('\n#error("Intentional capture regression")\n')
    commit('Broken build')
    assert 'Build failed' in run(command, success=False).stderr
    assert not seal.exists()
    print('PASS failed builds invalidate the capture seal', flush=True)
