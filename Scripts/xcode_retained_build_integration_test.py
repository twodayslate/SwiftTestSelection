#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Zachary Gorak
# SPDX-License-Identifier: AGPL-3.0-only
"""Select, exit, and execute exactly one unit and UI method from retained products."""
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
directory = pathlib.Path(tempfile.mkdtemp(prefix='swift-impact-retained-'))
work = directory / 'App'


def run(args, failure=None, env=None):
    result = subprocess.run(list(map(str, args)), cwd=work, env=env, text=True, capture_output=True)
    if failure:
        assert result.returncode != 0 and failure in result.stderr, (args, result.stdout, result.stderr)
    else:
        assert result.returncode == 0, (args, result.stdout, result.stderr)
    return result


try:
    shutil.copytree(ROOT / 'Fixtures/XcodeUITests', work)
    (work / '.gitignore').write_text('.build/\nxcuserdata/\n')
    for args in [['init', '-q'], ['config', 'user.name', 'Test'], ['config', 'user.email', 'test@example.invalid'], ['add', '.'], ['commit', '-qm', 'Base']]:
        run(['git', *args])
    base = run(['git', 'rev-parse', 'HEAD']).stdout.strip()
    ui = work / 'CheckoutUITests/CheckoutUITests.swift'
    ui.write_text(ui.read_text().replace('assertSharingScreen(timeout: 5)', 'assertSharingScreen(timeout: 6)', 1))
    unit = work / 'UnitTests/ProductionTests.swift'
    unit.write_text(unit.read_text().replace('XCTAssertEqual(sharingTitle(), "Sharing")', 'XCTAssertEqual(sharingTitle(), "Sharing", "retained smoke")'))
    run(['git', 'add', '.']); run(['git', 'commit', '-qm', 'One unit and one UI method'])
    head = run(['git', 'rev-parse', 'HEAD']).stdout.strip()
    common = ['--project', work/'ImpactDemo.xcodeproj', '--scheme', 'ImpactDemo', '--test-plan', 'AllTests', '--configuration', 'Debug', '--destination', a.destination]
    bundle, cache, report_path = directory/'retained', directory/'cache', directory/'impact.json'
    wrapper = directory/'bin'; wrapper.mkdir()
    calls = directory/'calls.jsonl'; calls.write_text('')
    real_xcode = run(['xcrun', '--find', 'xcodebuild']).stdout.strip()
    executable = wrapper/'xcodebuild'
    executable.write_text("#!/usr/bin/env python3\nimport os, sys, json\nwith open(os.environ['IMPACT_CALLS'], 'a') as f: f.write(json.dumps(sys.argv[1:])+'\\n')\nos.execv(os.environ['IMPACT_XCODE'], [os.environ['IMPACT_XCODE'], *sys.argv[1:]])\n")
    executable.chmod(0o755)
    env = dict(os.environ, PATH=str(wrapper)+os.pathsep+os.environ['PATH'], IMPACT_CALLS=str(calls), IMPACT_XCODE=real_xcode)
    start = time.monotonic()
    selection = run([a.tool, 'select', *common, '--base', base, '--head', head, '--analysis-cache', cache, '--cache-context', 'fixture-v1', '--retain-build', bundle, '--format', 'json', '--output', report_path], env=env)
    analysis_seconds = time.monotonic()-start
    (directory/'analysis.log').write_text(selection.stderr)
    report = json.loads(report_path.read_text())
    expected = ['CheckoutUITests/SharingUITests/testShareSheet()', 'UnitTests/ProductionTests/testSharing()']
    assert report['selectedTests'] == expected and not report['diagnostics'], report
    graph_file = bundle/'head-graph.json'
    graph = json.loads(graph_file.read_text())
    assert pathlib.Path(report['buildArtifactPath']).resolve() == (bundle/'head-graph.json').resolve()
    assert report['headRevision'] == graph['buildArtifact']['revision'] == head
    builds = [c for c in map(json.loads, calls.read_text().splitlines()) if 'build-for-testing' in c and '-showBuildSettings' not in c]
    assert len(builds) == 2, builds
    assert sum(pathlib.Path(c[c.index('-derivedDataPath')+1]).resolve().parent == bundle.resolve() for c in builds) == 1
    print('PASS head built once; exact unit and UI selection retained after exit', flush=True)
    # A cached head needs new executable products, but no repeated enumeration/SIL.
    calls.write_text('')
    warm_bundle = directory/'retained-warm'
    warm_path = directory/'warm-impact.json'
    run([a.tool, 'select', *common, '--base', base, '--head', head, '--analysis-cache', cache,
         '--cache-context', 'fixture-v1', '--retain-build', warm_bundle, '--format', 'json', '--output', warm_path], env=env)
    warm_report = json.loads(warm_path.read_text())
    assert warm_report['selectedTests'] == expected
    assert sum(e['detail'].startswith('hit:') for e in warm_report['analysisEvents']) == 2, warm_report['analysisEvents']
    assert not any(e['phase'] in ['enumeration', 'extraction'] for e in warm_report['analysisEvents'])
    warm_calls = list(map(json.loads, calls.read_text().splitlines()))
    assert sum('build-for-testing' in c and '-showBuildSettings' not in c for c in warm_calls) == 1
    print('PASS warm retained selection: both graphs reused, head products built once', flush=True)
    # Cache deletion and dirty current source cannot invalidate the owned bundle.
    shutil.rmtree(cache)
    ui.write_text('invalid Swift worktree')
    calls.write_text('')
    verified = json.loads(run([a.tool, 'verify-build', *common, '--report', report_path, '--head-graph', graph_file], env=env).stdout)
    assert pathlib.Path(verified['xctestrun']).exists()
    execution_args = [a.tool, 'run', *common, '--report', report_path, '--head-graph', graph_file]
    start = time.monotonic()
    execution = run(execution_args, env=env)
    execution_seconds = time.monotonic()-start
    (directory/'execution.log').write_text(execution.stderr)
    invocations = list(map(json.loads, calls.read_text().splitlines()))
    assert all(c[0] in ['-version', 'test-without-building'] for c in invocations), invocations
    actual = next(c for c in invocations if c[0] == 'test-without-building')
    assert sorted(x.removeprefix('-only-testing:') for x in actual if x.startswith('-only-testing:')) == expected
    assert '** TEST EXECUTE SUCCEEDED **' in execution.stderr and execution.stderr.count('Executed 1 test,') >= 2, execution.stderr
    print('PASS saved report executes one unit and one UI method without building', flush=True)
    # Empty selections do not turn into unrestricted commands, even without products.
    empty = dict(report, selectedTests=[], onlyTestingArguments=[])
    empty_path = directory/'empty.json'; empty_path.write_text(json.dumps(empty))
    calls.write_text('')
    run([a.tool, 'run', *common, '--report', empty_path, '--head-graph', graph_file], env=env)
    assert calls.read_text() == ''
    wrong = dict(report, headRevision=base)
    wrong_path = directory/'wrong.json'; wrong_path.write_text(json.dumps(wrong))
    run([a.tool, 'run', *common, '--report', wrong_path, '--head-graph', graph_file], failure='does not match', env=env)
    assert calls.read_text() == ''
    product = pathlib.Path(verified['xctestrun'])
    product.write_bytes(product.read_bytes()+b'\n')
    run(execution_args, failure='Test products differ', env=env)
    assert calls.read_text() == ''
    run([a.tool, 'run', *common, '--report', directory/'missing.json', '--head-graph', graph_file], failure='error:', env=env)
    print('PASS missing reports, wrong revision and stale products fail; empty runs execute nothing', flush=True)
    calls.write_text('')
    automatic = run([a.tool, 'select', *common, '--base', base, '--head', head, '--run', '--format', 'json'], env=env)
    automatic_report = json.loads(automatic.stdout)
    assert automatic_report['selectedTests'] == expected
    assert not pathlib.Path(automatic_report['buildArtifactPath']).parent.exists()
    automatic_calls = list(map(json.loads, calls.read_text().splitlines()))
    assert sum('build-for-testing' in c and '-showBuildSettings' not in c for c in automatic_calls) == 2
    assert not any(c[0] == 'test' for c in automatic_calls)
    assert '** TEST EXECUTE SUCCEEDED **' in automatic.stderr
    print('PASS select --head --run reuses the build and cleans up its temporary bundle', flush=True)
    a.output.parent.mkdir(parents=True, exist_ok=True)
    a.output.write_text(json.dumps(dict(analyzerSHA256=hashlib.sha256(a.tool.read_bytes()).hexdigest(), hardware=run(['sysctl', '-n', 'machdep.cpu.brand_string']).stdout.strip(), toolchain=run(['xcodebuild', '-version']).stdout.strip(), destination=a.destination, base=base, head=head, analysisSeconds=analysis_seconds, executionSeconds=execution_seconds, headBuildCount=1, totalBuildCount=2, automaticRunVerified=True, selectedTests=expected, events=report['analysisEvents']), indent=2)+'\n')
finally:
    if a.keep_work: print(f'Retained {directory}', flush=True)
    else: shutil.rmtree(directory)
