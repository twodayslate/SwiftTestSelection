#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Zachary Gorak
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
"""Real Xcode cache-only baseline checks, exact build counts and retained execution."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--tool', type=Path, required=True)
p.add_argument('--destination', required=True)
p.add_argument('--output', type=Path, required=True)
p.add_argument('--keep-work', action='store_true')
a = p.parse_args()
tool = a.tool.resolve(strict=True)
directory = Path(tempfile.mkdtemp(prefix='impact-cached-base-')).resolve()
source = directory / 'source'
results = []

try:
    shutil.copytree(ROOT / 'Fixtures/XcodeUITests', source)
    (source / '.gitignore').write_text('.build/\n')
    def git(*args):
        return subprocess.check_output(['git', *args], cwd=source, text=True).strip()
    def commit(message):
        git('add', '.')
        git('-c', 'user.name=Test', '-c', 'user.email=test@example.invalid', 'commit', '-qm', message)
        return git('rev-parse', 'HEAD')
    git('init', '-q')
    base = commit('Baseline')
    unit = source / 'UnitTests/ProductionTests.swift'
    unit.write_text(unit.read_text().replace('XCTAssertEqual(sharingTitle(), "Sharing")',
                                           'XCTAssertEqual(sharingTitle(), "Sharing", "changed test")'))
    head = commit('Child PR')
    git('branch', 'child', head)
    git('checkout', '-qb', 'target', base)
    (source / 'Target.md').write_text('Target has advanced independently')
    target = commit('Advanced target branch')
    git('checkout', '-q', 'child')
    ui = source / 'CheckoutUITests/CheckoutUITests.swift'
    ui.write_text(ui.read_text().replace('assertSharingScreen(timeout: 5)', 'assertSharingScreen(timeout: 6)', 1))
    stacked = commit('Stacked PR')
    wrapper = directory / 'bin'; wrapper.mkdir()
    calls = directory / 'calls.jsonl'
    real_xcode = subprocess.check_output(['xcrun', '--find', 'xcodebuild'], text=True).strip()
    (wrapper / 'xcodebuild').write_text("#!/usr/bin/env python3\nimport json,os,sys\nwith open(os.environ['IMPACT_CALLS'],'a') as f: f.write(json.dumps(sys.argv[1:])+'\\n')\nos.execv(os.environ['IMPACT_XCODE'],[os.environ['IMPACT_XCODE'],*sys.argv[1:]])\n")
    (wrapper / 'xcodebuild').chmod(0o755)
    env = dict(os.environ, PATH=str(wrapper)+os.pathsep+os.environ['PATH'], IMPACT_CALLS=str(calls), IMPACT_XCODE=real_xcode)
    common = ['--project', source/'ImpactDemo.xcodeproj', '--scheme', 'ImpactDemo', '--test-plan', 'AllTests',
              '--configuration', 'Debug', '--destination', a.destination]
    cache = directory/'cache'
    def select(label, base_ref='target', head_ref=head, policy='require', context='fixture-v1',
               cache_path=cache, builds=0, miss=False, extra=(), expected_base=base, configuration="Debug", destination=a.destination):
        calls.write_text('')
        bundle = directory/label
        report_path = directory/(label+'.json')
        options = list(common)
        options[options.index('--configuration')+1] = configuration
        options[options.index('--destination')+1] = destination
        command = [tool, 'select', *options, '--base', base_ref, '--head', head_ref, '--merge-base',
                   '--analysis-cache', cache_path, '--cache-context', context, '--cached-base-policy', policy,
                   '--build-time-sil', ROOT/'Scripts/capture-build.py', '--retain-build', bundle,
                   '--format', 'json', '--output', report_path, *extra]
        start = time.monotonic()
        proc = subprocess.run(list(map(str, command)), cwd=source, env=env, text=True, capture_output=True)
        (directory/(label+'.log')).write_text(proc.stdout+proc.stderr)
        invocations = list(map(json.loads, calls.read_text().splitlines()))
        actual_builds = [c for c in invocations if 'build-for-testing' in c and '-showBuildSettings' not in c]
        assert len(actual_builds) == builds, (label, actual_builds, proc.stderr)
        if miss:
            assert proc.returncode == 3, (label, proc.stderr)
            error = json.loads(proc.stderr.splitlines()[-1])
            assert error['code'] == 'cached_base_unavailable' and error['revision'] == expected_base and error['reason'], error
            assert not bundle.exists() and not report_path.exists()
            assert not any('test-without-building' in c for c in invocations)
            value = error
        else:
            assert proc.returncode == 0, (label, proc.stderr)
            value = json.loads(report_path.read_text())
            assert value['baseRevision'] == expected_base
            graph = json.loads((bundle/'head-graph.json').read_text())
            assert value['headRevision'] == graph['buildArtifact']['revision'] == head_ref
            assert value['buildArtifactID'] == graph['buildArtifact']['id']
            assert (bundle/'complete.json').exists() and (bundle/'SILCapture/build.json').exists()
            assert all(Path(c[c.index('-derivedDataPath')+1]).resolve().parent == bundle for c in actual_builds)
            assert not any(e['revision'] != head_ref and e['phase'] in ['build', 'enumeration', 'extraction'] for e in value['analysisEvents'])
        results.append(dict(case=label, seconds=time.monotonic()-start, buildCount=builds, result=value))
        print(f'PASS {label}: {builds} builds', flush=True)
        return value, bundle, report_path

    # Cold fail must happen before a head workspace, build, enumeration or test.
    select('empty', miss=True)
    # The ordinary main build publishes its own baseline and retains its products.
    producer, _, _ = select('producer', base_ref=base, head_ref=base, builds=1, extra=['--full-suite'])
    assert len(producer['selectedTests']) == 9
    baseline_entry = next(f.parent for f in cache.glob('*/manifest.json')
                          if json.loads(f.read_text())['identity'].get('revision') == base
                          and json.loads(f.read_text())['identity'].get('schema') == 'xcode-analysis-cache-1/graph-2')
    for label, kwargs in [('wrong-context', {'context': 'other'}),
                          ('wrong-configuration', {'configuration': 'Release'}),
                          ('wrong-destination', {'destination': a.destination + ',arch=arm64'}),
                          ('wrong-revision', {'base_ref': head, 'head_ref': stacked, 'expected_base': head})]:
        select(label, miss=True, **kwargs)
    # Damage/eviction cannot trigger rebuilding. Restore the valid entry for hit tests.
    backup = directory/'baseline-copy'; shutil.copytree(baseline_entry, backup)
    payload = json.loads((baseline_entry/'manifest.json').read_text())['payload']
    (baseline_entry/payload).write_bytes(b'corrupt')
    corrupt, _, _ = select('corrupt', miss=True)
    assert 'checksum mismatch' in corrupt['reason']
    shutil.copytree(backup, baseline_entry)
    shutil.rmtree(baseline_entry)
    select('evicted', miss=True)
    shutil.copytree(backup, baseline_entry)
    selected, bundle, report_path = select('stale-target-hit', builds=1)
    assert selected['selectedTests'] == ['UnitTests/ProductionTests/testSharing()'] and not selected['diagnostics']
    assert any(e['phase'] == 'cache' and e['revision'] == base and e['detail'].startswith('hit:') for e in selected['analysisEvents'])
    # The child graph is now the actual merge base of a stacked PR, not target's tip.
    stacked_report, _, _ = select('stacked-hit', base_ref=head, head_ref=stacked, expected_base=head, builds=1)
    assert stacked_report['selectedTests'] == ['CheckoutUITests/SharingUITests/testShareSheet()']

    def execute(label, bundle, report_path, expected):
        calls.write_text('')
        args = [*common, '--report', report_path, '--head-graph', bundle/'head-graph.json']
        verified = subprocess.run(list(map(str, [tool, 'verify-build', *args])), cwd=source, env=env, text=True, capture_output=True)
        assert verified.returncode == 0, verified.stderr
        test_run = json.loads(verified.stdout)['xctestrun']
        proc = subprocess.run(list(map(str, [tool, 'run', *args])), cwd=source, env=env, text=True, capture_output=True)
        (directory/(label+'.log')).write_text(proc.stdout+proc.stderr)
        assert proc.returncode == 0, proc.stderr
        invocations = list(map(json.loads, calls.read_text().splitlines()))
        assert not any('build-for-testing' in c for c in invocations)
        actual, = [c for c in invocations if c[0] == 'test-without-building']
        assert actual[actual.index('-xctestrun')+1] == test_run
        assert sorted(c.removeprefix('-only-testing:') for c in actual if c.startswith('-only-testing:')) == sorted(expected)
        results.append(dict(case=label, buildCount=0, xctestrun=test_run, selectedTests=expected))
        print(f'PASS {label}: verified exact retained products, zero builds', flush=True)

    execute('selected-execution', bundle, report_path, selected['selectedTests'])
    fallback, fallback_bundle, fallback_path = select('full-fallback', policy='full-suite', context='fresh-context', builds=1)
    assert len(fallback['selectedTests']) == 9
    assert any(d['code'] == 'cached_base_unavailable' for d in fallback['diagnostics'])
    execute('full-execution', fallback_bundle, fallback_path, fallback['selectedTests'])
    # A malformed report is still an error; it must never turn into full execution.
    bad = directory/'bad.json'; bad.write_text('{}')
    calls.write_text('')
    proc = subprocess.run(list(map(str, [tool, 'run', *common, '--report', bad, '--head-graph', fallback_bundle/'head-graph.json'])),
                          cwd=source, env=env, text=True, capture_output=True)
    assert proc.returncode != 0
    assert not any('test-without-building' in c or 'build-for-testing' in c for c in map(json.loads, calls.read_text().splitlines()))
    print('PASS malformed report cannot execute', flush=True)
    a.output.parent.mkdir(parents=True, exist_ok=True)
    a.output.write_text(json.dumps(dict(analyzerSHA256=hashlib.sha256(tool.read_bytes()).hexdigest(), destination=a.destination,
                                       base=base, head=head, target=target, stacked=stacked, measurements=results), indent=2)+'\n')
finally:
    if a.keep_work: print(f'Retained {directory}', flush=True)
    else: shutil.rmtree(directory)
