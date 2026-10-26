#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Zachary Gorak
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
"""Fresh Xcode validation for generated boundaries and recovered production roles."""
import argparse
import collections
import importlib.util
import json
import pathlib
import re
import subprocess
import sys
import tempfile
import time

ROOT = pathlib.Path(__file__).resolve().parents[1]
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--destination', required=True)
p.add_argument('--tool', type=pathlib.Path, required=True)
p.add_argument('--capture-helper', type=pathlib.Path)
p.add_argument('--output', type=pathlib.Path, required=True)
a = p.parse_args()
folder = pathlib.Path(tempfile.mkdtemp(prefix='swift-impact-generated-'))
work = folder / 'App'
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location('fixture', ROOT / 'Fixtures/XcodeGeneratedInputs/generate.py')
fixture = importlib.util.module_from_spec(spec); spec.loader.exec_module(fixture); fixture.generate(work)
results = {'work': str(folder), 'cases': []}
print('WORK', folder, flush=True)


def run(args, name):
    start = time.monotonic()
    result = subprocess.run(list(map(str, args)), cwd=work, text=True, capture_output=True)
    (folder / (name + '.log')).write_text(result.stdout + result.stderr)
    assert result.returncode == 0, f'{name} failed: {folder / (name + ".log")}'
    return result, round(time.monotonic() - start, 3)


def git(*args): return run(['git', *args], 'git')[0].stdout.strip()
def commit(message):
    git('add', '.'); git('commit', '-qm', message)
    return git('rev-parse', 'HEAD')


(work / '.gitignore').write_text('.build/\nxcuserdata/\n')
git('init', '-q'); git('config', 'user.name', 'Fixture'); git('config', 'user.email', 'fixture@example.invalid')
base = commit('Resource and runtime boundaries')
common = ['--project', work / 'ImpactDemo.xcodeproj', '--scheme', 'ImpactDemo', '--test-plan', 'AllTests', '--configuration', 'Debug', '--destination', a.destination]
cache = ['--analysis-cache', folder / 'cache', '--cache-context', 'generated-inputs-fixture-v1']


def select(label, head, cached=True, base_revision=None, capture=True):
    bundle = folder / label
    report_path = folder / (label + '.json')
    result, seconds = run(['/usr/bin/time', '-l', a.tool, 'select', *common, '--base', base_revision or base, '--head', head,
                           *(cache if cached else []), *(['--build-time-sil', a.capture_helper] if a.capture_helper and capture else []), '--retain-build', bundle, '--format', 'json', '--output', report_path], label)
    report = json.loads(report_path.read_text())
    graph = json.loads((bundle / 'head-graph.json').read_text())
    if a.capture_helper and capture and label in ['package', 'extension-fresh']:
        assert 'Captured SIL LocalCore: validated primary coverage; skipped compiler replay' in result.stderr, result.stderr[-3000:]
    assert not graph['diagnostics'], graph['diagnostics']
    assert not graph.get('unresolvedProductRoles'), graph.get('unresolvedProductRoles')
    assert not graph.get('unsupportedSourceInputs'), graph.get('unsupportedSourceInputs')
    assert graph['generatedSourceBoundaries']['LocalCore'], graph.get('generatedSourceBoundaries')
    assert not any(x['code'] in ['incomplete_graph', 'invalid_runtime_boundary', 'generated_input_changed'] for x in report['diagnostics']), report['diagnostics']
    run([a.tool, 'verify-build', *common, '--report', report_path, '--head-graph', bundle / 'head-graph.json'], label + '-verify')
    results['cases'].append(dict(case=label, seconds=seconds, selected=report['selectedTests'], total=report['totalTests'],
                                 diagnostics=dict(collections.Counter(x['code'] for x in report['diagnostics'])), events=report.get('analysisEvents', [])))
    a.output.write_text(json.dumps(results, indent=2))
    print('PASS', label, len(report['selectedTests']), '/', report['totalTests'], seconds, 'seconds', flush=True)
    return report, graph, bundle


package = work / 'LocalCore/Sources/LocalCore/Value.swift'
package.write_text(package.read_text().replace('40 + 2', '41 + 1'))
package_head = commit('Independent package function edit')
report, graph, bundle = select('package', package_head)
assert 'CoreTests/ValueTests/testValue()' in report['selectedTests']
assert not report['fullRunReasons'], report['fullRunReasons']
assert len(report['selectedTests']) < report['totalTests']
package_report = report

# Return to the original tree; keep policy and resource inputs exactly equal.
git('checkout', '--detach', base)
extension = work / 'ShareExtension/Controller.swift'
extension.write_text(extension.read_text().replace('title = String(extensionValue())', 'title = "Sharing " + String(extensionValue())'))
extension_head = commit('Isolated extension function edit')
report, graph, bundle = select('extension', extension_head)
assert report.get('runtimeBoundaryDecisions'), report
assert 'UnitTests/ProductionTests/testHostedRuntime()' in report['selectedTests'], report['selectedTests']
assert not any(t.startswith('CoreTests/') for t in report['selectedTests']), report['selectedTests']
assert 'CheckoutUITests/NotesUITests/testNotes()' in report['selectedTests'], report['selectedTests']
assert not report['fullRunReasons'], report['fullRunReasons']
for label, cached in [('extension-warm', True), ('extension-fresh', False)]:
    parity, saved, _ = select(label, extension_head, cached)
    for field in ['selectedTests', 'diagnostics', 'fullRunReasons', 'runtimeBoundaryDecisions']:
        assert parity.get(field) == report.get(field), (label, field)
    assert saved['generatedSourceBoundaries'] == graph['generatedSourceBoundaries'], label
    def targets(value):
        return sorted([{**t, 'sourceFiles': sorted(t['sourceFiles'])} for t in value], key=lambda t: t['name'])
    assert targets(saved['targets']) == targets(graph['targets'])

# Replay and capture use independent fresh builds of both revisions.
if a.capture_helper:
    for label, revision, expected in [('replay-package', package_head, package_report), ('replay-extension', extension_head, report)]:
        replay, _, _ = select(label, revision, False, capture=False)
        for field in ['selectedTests', 'diagnostics', 'fullRunReasons', 'runtimeBoundaryDecisions']:
            assert replay.get(field) == expected.get(field), (label, field)

# A cold identical-revision analysis builds and captures exactly once.
if a.capture_helper:
    same, _, _ = select('same-revision', extension_head, False, extension_head)
    assert not same['selectedTests'] and not same['fullRunReasons'], same
    assert len([e for e in same['analysisEvents'] if e['phase'] == 'build']) == 1

# Selected and complete runs share the same verified head products.
execution, seconds = run([a.tool, 'run', *common, '--report', folder / 'extension.json', '--head-graph', bundle / 'head-graph.json'], 'selected-execution')
results['selectedExecutionSeconds'] = seconds

def executed(result):
    return sorted(set('/'.join(parts) + '()' for parts in re.findall(
        r"Test Case '-\[([^.]+)\.([^ ]+) ([^\]]+)\]' passed", result.stdout + result.stderr)))

results['executedSelectedTests'] = executed(execution)
assert results['executedSelectedTests'] == sorted(report['selectedTests']), results['executedSelectedTests']
artifact = graph['buildArtifact']
runfile = pathlib.Path(artifact['productsDirectory']) / artifact['xctestrun']
execution, seconds = run(['xcodebuild', 'test-without-building', '-xctestrun', runfile, '-destination', a.destination,
                  '-resultBundlePath', folder / 'full.xcresult'], 'full-execution')
results['fullExecutionSeconds'] = seconds
results['executedFullTests'] = executed(execution)
assert results['executedFullTests'] == sorted(graph['tests']), results['executedFullTests']
results['fullRunSucceeded'] = True
results['selectedRunSucceeded'] = True
a.output.write_text(json.dumps(results, indent=2))
print('PASS selected and full fixture executions; logs and xcresult:', folder, flush=True)
