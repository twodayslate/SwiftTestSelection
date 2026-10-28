#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Zachary Gorak
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
"""Validate stale/ repaired mappings through real head-only build-time capture."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--tool', type=Path, required=True)
parser.add_argument('--destination', required=True)
a = parser.parse_args()
tool = a.tool.resolve(strict=True)
with tempfile.TemporaryDirectory(prefix='strict-head-only-') as temporary:
    work = Path(temporary).resolve()
    source = work / 'source'
    shutil.copytree(ROOT / 'Fixtures/XcodeUITests', source)
    mapping_file = source / '.swift-test-selection.json'
    mapping = json.loads(mapping_file.read_text())
    mapping['features'][0].setdefault('symbols', []).append('ImpactDemo.noSuchStrictMappingSymbol()')
    mapping_file.write_text(json.dumps(mapping))

    def git(*args):
        return subprocess.check_output(['git', *args], cwd=source, text=True).strip()

    git('init', '-q')
    git('config', 'user.name', 'Test')
    git('config', 'user.email', 'test@example.invalid')
    git('add', '.')
    git('commit', '-qm', 'Stale mapping')
    base = git('rev-parse', 'HEAD')
    bin_dir = work / 'bin'
    bin_dir.mkdir()
    calls = work / 'calls.jsonl'
    real_xcode = subprocess.check_output(['xcrun', '--find', 'xcodebuild'], text=True).strip()
    wrapper = bin_dir / 'xcodebuild'
    wrapper.write_text("#!/usr/bin/env python3\nimport json,os,sys\nwith open(os.environ['IMPACT_CALLS'],'a') as f: f.write(json.dumps(sys.argv[1:])+'\\n')\nos.execv(os.environ['IMPACT_XCODE'], [os.environ['IMPACT_XCODE'], *sys.argv[1:]])\n")
    wrapper.chmod(0o755)
    env = dict(os.environ, PATH=str(bin_dir) + os.pathsep + os.environ['PATH'], IMPACT_CALLS=str(calls), IMPACT_XCODE=real_xcode)
    common = [str(tool), 'select', '--project', str(source / 'ImpactDemo.xcodeproj'), '--scheme', 'ImpactDemo',
              '--test-plan', 'AllTests', '--configuration', 'Debug', '--destination', a.destination,
              '--base', base, '--head-only', '--build-time-sil', str(ROOT / 'Scripts/capture-build.py'), '--strict-mappings', '--format', 'json']
    failed = subprocess.run([*common, '--head', base, '--retain-build', str(work / 'stale'), '--run'],
                            cwd=source, env=env, text=True, capture_output=True)
    assert failed.returncode == 4, failed.stderr
    assert not failed.stdout
    error = json.loads(failed.stderr.splitlines()[-1])
    assert any(d['pattern'] == 'ImpactDemo.noSuchStrictMappingSymbol()' and d['revision'] == base for d in error['diagnostics']), error
    assert not (work / 'stale/complete.json').exists()
    assert not any(c[0] == 'test' or c[0] == 'test-without-building' and '-enumerate-tests' not in c
                   for c in map(json.loads, calls.read_text().splitlines()))
    print('PASS head-only no-op rejects a stale symbol before --run or retained publication', flush=True)
    mapping['features'][0]['symbols'].remove('ImpactDemo.noSuchStrictMappingSymbol()')
    mapping_file.write_text(json.dumps(mapping))
    git('add', '.')
    git('commit', '-qm', 'Repair stale mapping')
    head = git('rev-parse', 'HEAD')
    repaired = subprocess.run([*common, '--head', head, '--retain-build', str(work / 'repaired')],
                              cwd=source, env=env, text=True, capture_output=True)
    assert repaired.returncode == 0, repaired.stderr
    report = json.loads(repaired.stdout)
    assert report['analysisMode'] == 'head-only-git-syntax'
    assert report['headRevision'] == head and report['baseRevision'] == base
    print('PASS head-only repaired head passes over a stale base', flush=True)
