#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Zachary Gorak
# SPDX-License-Identifier: AGPL-3.0-only
"""Build-only capture regressions for documentation precision and log lifetime."""
import argparse
import importlib.util
import json
from pathlib import Path
import re
import subprocess
import tempfile
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--tool', type=Path, required=True)
parser.add_argument('--capture-helper', type=Path, required=True)
parser.add_argument('--destination', required=True)
parser.add_argument('--output', type=Path, required=True)
a = parser.parse_args()
folder = Path(tempfile.mkdtemp(prefix='capture-review-')).resolve()
work = folder / 'App'
repo = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('fixture', repo / 'Fixtures/XcodeGeneratedInputs/generate.py')
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)
fixture.generate(work)
print('WORK', folder, flush=True)
results = {'work': str(folder), 'cases': [], 'testBodiesExecuted': False}


def git(*args):
    return subprocess.check_output(['git', *args], cwd=work, text=True).strip()


def commit(message):
    git('add', '.')
    git('commit', '-qm', message)
    return git('rev-parse', 'HEAD')


git('init', '-q')
git('config', 'user.name', 'Fixture')
git('config', 'user.email', 'fixture@example.invalid')
(work / '.gitignore').write_text('.build/\nxcuserdata/\n')
doc = work / 'AGENTS.md'
doc.write_text('Standalone documentation\n')
resource_path = 'LocalCore/Sources/LocalCore/Resources/Guide.md'
resource = work / resource_path
resource.write_text('Bundled resource documentation\n')
policy = work / '.swift-test-selection.json'
mappings = json.loads(policy.read_text())
mappings['ignoredDocumentation'] = ['AGENTS.md', resource_path]
policy.write_text(json.dumps(mappings, indent=2))
base = commit('Documentation policy and resource fixture')
common = ['--project', str(work / 'ImpactDemo.xcodeproj'), '--scheme', 'ImpactDemo', '--test-plan', 'AllTests',
          '--configuration', 'Debug', '--destination', a.destination]


def select(name, head, expected, storage='cached'):
    report_path = folder / (name + '.json')
    args = ['/usr/bin/time', '-l', str(a.tool.resolve()), 'select', *common, '--base', base, '--head', head,
            '--build-time-sil', str(a.capture_helper.resolve()), '--format', 'json', '--output', str(report_path)]
    if storage != 'temporary': args += ['--analysis-cache', str(folder / 'cache'), '--cache-context', 'review-regression']
    if storage == 'retained': args += ['--retain-build', str(folder / name)]
    started = time.monotonic()
    result = subprocess.run(args, cwd=work, capture_output=True, text=True)
    (folder / (name + '.log')).write_text(result.stdout + result.stderr)
    assert result.returncode == 0, result.stderr[-4000:]
    report = json.loads(report_path.read_text())
    assert len(report['selectedTests']) == expected, report
    if name == 'mixed': assert report['selectedTests'] == ['CoreTests/ValueTests/testValue()'], report
    if name == 'resource': assert resource_path not in report['ignoredChanges'], report
    generated_fallback = any(d['code'] == 'generated_input_changed' for d in report['diagnostics'])
    assert generated_fallback == (name == 'resource'), report['diagnostics']
    for path in re.findall(r'Capturing supplementary SIL during build-for-testing; diagnostics: (.+)', result.stderr):
        diagnostics = Path(path)
        if storage == 'retained' and diagnostics == folder / name:
            assert (diagnostics / 'capture.log').exists()
        else:
            assert not diagnostics.exists(), f'Successful temporary capture leaked: {path}'
    if storage == 'retained':
        verify = subprocess.run([str(a.tool.resolve()), 'verify-build', *common, '--report', str(report_path),
                                 '--head-graph', str(folder / name / 'head-graph.json')], cwd=work, capture_output=True, text=True)
        assert verify.returncode == 0, verify.stderr
    peak = re.search(r'(\d+)\s+maximum resident set size', result.stderr)
    results['cases'].append({'case': name, 'seconds': round(time.monotonic() - started, 3),
                             'maximumResidentSetBytes': int(peak[1]) if peak else None,
                             'selectedTests': report['selectedTests'], 'totalTests': report['totalTests']})
    a.output.write_text(json.dumps(results, indent=2))
    print('PASS', name, expected, '/', report['totalTests'], flush=True)


doc.write_text('Updated standalone documentation\n')
select('documentation', commit('Ignored documentation edit'), 0, 'retained')
doc.write_text('Another standalone documentation edit\n')
test = work / 'CoreTests/ValueTests.swift'
test.write_text(test.read_text().replace('XCTAssertEqual(packageValue(), 42)', 'XCTAssertEqual(packageValue(), 40 + 2)'))
select('mixed', commit('One test and ignored documentation'), 1)
git('checkout', '--detach', base)
resource.write_text('Changed bundled Markdown resource\n')
select('resource', commit('Changed resource despite documentation pattern'), 15, 'temporary')
