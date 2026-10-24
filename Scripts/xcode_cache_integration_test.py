#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Zachary Gorak
# SPDX-License-Identifier: AGPL-3.0-only
"""Measure release cache reuse and compare selections with fresh Xcode analysis."""
import argparse
import json
import hashlib
import os
import pathlib
import shutil
import subprocess
import tempfile
import time

ROOT = pathlib.Path(__file__).resolve().parents[1]
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--destination', required=True)
p.add_argument('--tool', type=pathlib.Path, default=ROOT / '.build/release/swift-test-impact')
p.add_argument('--output', type=pathlib.Path, required=True)
p.add_argument('--keep-work', action='store_true')
a = p.parse_args()
directory = pathlib.Path(tempfile.mkdtemp(prefix='swift-impact-cache-'))
work = directory / 'App'
results = []


def run(args, **kwargs):
    value = subprocess.run([str(x) for x in args], cwd=work, text=True, capture_output=True, **kwargs)
    assert value.returncode == 0, (args, value.stdout, value.stderr)
    return value.stdout.strip()


try:
    shutil.copytree(ROOT / 'Fixtures/XcodeUITests', work)
    (work / '.gitignore').write_text('.build/\nxcuserdata/\n')
    for args in [['init', '-q'], ['config', 'user.name', 'Test'], ['config', 'user.email', 'test@example.invalid'], ['add', '.'], ['commit', '-qm', 'Base']]:
        run(['git', *args])
    base = run(['git', 'rev-parse', 'HEAD'])
    ui = work / 'CheckoutUITests/CheckoutUITests.swift'
    ui.write_text(ui.read_text().replace('assertSharingScreen(timeout: 5)', 'assertSharingScreen(timeout: 6)', 1))
    run(['git', 'add', '.']); run(['git', 'commit', '-qm', 'One method'])
    head = run(['git', 'rev-parse', 'HEAD'])
    common = [a.tool, 'select', '--project', work / 'ImpactDemo.xcodeproj', '--scheme', 'ImpactDemo', '--test-plan', 'AllTests', '--configuration', 'Debug', '--destination', a.destination, '--base', base, '--head', head, '--format', 'json']
    cache = directory / 'cache'
    cached = [*common, '--analysis-cache', cache, '--cache-context', 'fixture-hermetic-v1']
    wrapper = directory / 'bin'; wrapper.mkdir()
    calls = directory / 'calls.jsonl'
    real_xcode = run(['xcrun', '--find', 'xcodebuild'])
    executable = wrapper / 'xcodebuild'
    executable.write_text("#!/usr/bin/env python3\nimport os, sys, json\nwith open(os.environ['IMPACT_CALLS'], 'a') as f: f.write(json.dumps(sys.argv[1:])+'\\n')\nos.execv(os.environ['IMPACT_XCODE'], [os.environ['IMPACT_XCODE'], *sys.argv[1:]])\n")
    executable.chmod(0o755)
    env = dict(os.environ, PATH=str(wrapper)+os.pathsep+os.environ['PATH'], IMPACT_CALLS=str(calls), IMPACT_XCODE=real_xcode)

    def select(label, args, builds):
        calls.write_text('')
        start = time.monotonic()
        process = subprocess.run(['/usr/bin/time', '-l', *map(str, args)], cwd=work, env=env, text=True, capture_output=True)
        (directory / (label + '.log')).write_text(process.stderr)
        assert process.returncode == 0, process.stderr
        report = json.loads(process.stdout)
        invocations = [json.loads(line) for line in calls.read_text().splitlines()]
        count = sum('build-for-testing' in c and '-showBuildSettings' not in c for c in invocations)
        assert count == builds, (label, count, report.get('analysisEvents'), process.stderr)
        assert report['selectedTests'] == ['CheckoutUITests/SharingUITests/testShareSheet()'], report
        assert not report['diagnostics'], report
        memory = next(int(line.split()[0]) for line in process.stderr.splitlines() if 'maximum resident set size' in line)
        results.append(dict(case=label, seconds=time.monotonic()-start, peakRSSBytes=memory, buildCount=count, events=report.get('analysisEvents'), selectedTests=report['selectedTests']))
        print(f'PASS {label}: {results[-1]["seconds"]:.2f}s, {count} builds', flush=True)
        return report

    cold = select('cold', cached, 2)
    warm = select('warm', cached, 0)
    assert sum(e['detail'].startswith('hit:') for e in warm['analysisEvents']) == 2
    fresh = select('fresh', common, 2)
    for key in ['selectedTests', 'onlyTestingArguments', 'diagnostics', 'ignoredChanges', 'uiMappingCoverage', 'changedFiles']:
        assert cold[key] == warm[key] == fresh[key], key
    # A new head reuses the actual merge base; it must not reuse the former head.
    ui.write_text(ui.read_text().replace('timeout: 6', 'timeout: 7', 1))
    run(['git', 'add', '.']); run(['git', 'commit', '-qm', 'Next head'])
    next_head = run(['git', 'rev-parse', 'HEAD'])
    next_args = list(cached); next_args[next_args.index('--head')+1] = next_head
    select('new-head-warm-base', next_args, 1)
    # A stale base branch diverges; lookup must use its ancestor, not the tip.
    run(['git', 'checkout', '-qb', 'target', base])
    (work / 'Unrelated.md').write_text('unrelated branch')
    run(['git', 'add', '.']); run(['git', 'commit', '-qm', 'Target diverged'])
    merge_args = list(next_args); merge_args[merge_args.index('--base')+1] = 'target'; merge_args += ['--merge-base']
    merged = select('merge-base', merge_args, 0)
    assert merged['baseRevision'] == base and merged['headRevision'] == next_head
    # Corrupt a real persisted graph: selection must rebuild that side.
    manifests = list(cache.glob('*/manifest.json'))
    entry = next(f.parent for f in manifests if json.loads(f.read_text())['identity']['revision'] == base)
    (entry / 'graph.json').write_text('{}')
    select('corrupt-base-rebuilt', merge_args, 1)
    # Serialized concurrent readers cannot observe eviction/staging state.
    processes = [subprocess.Popen(list(map(str, merge_args)), cwd=work, env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE) for _ in range(2)]
    for process in processes:
        out, err = process.communicate()
        assert process.returncode == 0, err
        report = json.loads(out)
        assert report['selectedTests'] == warm['selectedTests']
        assert sum(e['detail'].startswith('hit:') for e in report['analysisEvents']) == 2
    print('PASS concurrent readers: two complete warm selections', flush=True)
    a.output.parent.mkdir(parents=True, exist_ok=True)
    a.output.write_text(json.dumps(dict(tool=str(a.tool), analyzerSHA256=hashlib.sha256(a.tool.read_bytes()).hexdigest(), toolchain=run(['xcodebuild', '-version']), hardware=run(['sysctl', '-n', 'machdep.cpu.brand_string']), destination=a.destination, base=base, head=head, measurements=results), indent=2)+'\n')
finally:
    if a.keep_work: print(f'Retained {directory}', flush=True)
    else: shutil.rmtree(directory)
