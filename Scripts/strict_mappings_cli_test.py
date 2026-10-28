#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Zachary Gorak
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
"""Check strict mappings on saved/fresh/cached graphs without requiring Xcode."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--tool', type=Path, required=True)
tool = parser.parse_args().tool.resolve(strict=True)

with tempfile.TemporaryDirectory(prefix='strict-mappings-') as temporary:
    root = Path(temporary).resolve()
    project = root / 'App.xcodeproj'
    project.mkdir()
    (project / 'project.pbxproj').write_text('fixture')
    mapping = dict(version=1, features=[dict(name='checkout', symbols=['App.wasDeleted()'], tests=['UI/Suite'])])
    (root / 'ui.json').write_text(json.dumps(mapping))

    def git(*args):
        return subprocess.check_output(['git', *args], cwd=root, text=True).strip()

    git('init', '-q')
    git('config', 'user.name', 'Test')
    git('config', 'user.email', 'test@example.invalid')
    git('add', '.')
    git('commit', '-qm', 'Base')
    base = git('rev-parse', 'HEAD')
    revisions = [base]
    for filename in ['README.md', 'Tests.swift']:
        (root / filename).write_text('fixture')
        git('add', filename)
        git('commit', '-qm', filename)
        revisions.append(git('rev-parse', 'HEAD'))
    test = 'UI/Suite/testOne()'
    calls = root / 'calls.jsonl'
    bin_dir = root / 'bin'
    bin_dir.mkdir()
    for name in ['xcodebuild', 'xcrun']:
        mock = bin_dir / name
        mock.write_text('''#!/usr/bin/env python3
import json,os,pathlib,sys
args=sys.argv[1:]
with open(os.environ['IMPACT_CALLS'], 'a') as f: f.write(json.dumps(args)+'\\n')
if '-enumerate-tests' in args:
 pathlib.Path(args[args.index('-test-enumeration-output-path')+1]).write_text(json.dumps({'values':[{'enabledTests':[{'identifier':'UI/Suite/testOne()'}]}]}))
elif '-showBuildSettings' in args:
 print(json.dumps([{'buildSettings':{'TARGET_NAME':'App', 'PRODUCT_TYPE':'com.apple.product-type.application'}}]))
elif '-showsdks' in args: print('[]')
elif '-version' in args or '--version' in args: print('fixture toolchain')
elif 'build-for-testing' in args: print('** TEST BUILD SUCCEEDED **')
else: sys.exit('Unexpected build/test command')
''')
        mock.chmod(0o755)
    env = dict(os.environ, PATH=str(bin_dir) + os.pathsep + os.environ['PATH'], IMPACT_CALLS=str(calls))
    common = [str(tool), '--project', str(project), '--scheme', 'App', '--destination', 'platform=macOS', '--mappings', 'ui.json']

    def invoke(command, extra):
        return subprocess.run([common[0], command, *common[1:], *map(str, extra)], cwd=root, env=env, text=True, capture_output=True)

    def failure(result, revision, pattern='App.wasDeleted()', code='unresolved_mapping_symbol', feature='checkout'):
        assert result.returncode == 4, result.stderr
        assert not result.stdout, result.stdout
        error = json.loads(result.stderr.splitlines()[-1])
        assert error['code'] == 'strict_mapping_validation_failed', error
        assert len(error['diagnostics']) == 1, error
        diagnostic = error['diagnostics'][0]
        for key, value in dict(code=code, revision=revision, pattern=pattern, feature=feature, mappingFile='ui.json').items():
            assert diagnostic.get(key) == value, diagnostic
        assert diagnostic['buildContext']['scheme'] == 'App', diagnostic
        return diagnostic

    graph = dict(schemaVersion=2, analysisKind='xcode-sil-and-ui-mappings', targets=[], tests=[test], diagnostics=[],
                 sources={}, modules={}, mappings=mapping,
                 dependencies=dict(schemaVersion=1, toolchain='', functions={}, tests={}, diagnostics=[], testDiagnostics={}),
                 buildArtifact=dict(schemaVersion=1, id='fixture', revision=base,
                                    context=dict(container='project', path='App.xcodeproj', scheme='App', destination='platform=macOS',
                                                 configuration='', testPlan='', mappings='ui.json', sdkAndArchitecture='Debug|macosx|macosx|arm64'),
                                    toolchain='fixture', buildLogDigest='log', buildSettingsDigest='settings',
                                    productsDirectory=str(root / 'absent-products'), xctestrun='Tests.xctestrun', products={'Tests.xctestrun': 'digest'}))
    base_file, head_file = root / 'base.json', root / 'head.json'
    base_file.write_text(json.dumps(graph))
    for revision in revisions:
        graph['buildArtifact']['revision'] = revision
        head_file.write_text(json.dumps(graph))
        args = ['--base', base, '--head', revision, '--base-graph', base_file, '--head-graph', head_file, '--format', 'json']
        for full in [[], ['--full-suite']]:
            for run in [[], ['--run']]:
                failure(invoke('select', [*args, '--strict-mappings', *full, *run]), revision)
        assert invoke('select', args).returncode == 0  # Default remains conservative.
    assert not calls.exists(), 'Saved validation must not build or execute tests'
    print('PASS saved graphs: no-op, documentation-only, test-only, full suite and --run')

    # A valid sibling/source cannot mask a stale entry; a wildcard must match.
    revision = revisions[-1]
    node = dict(id='existing', module='App', name='stillExists()', regions=[dict(path='App.swift', startLine=1, endLine=1)],
                dependencies=[], uncertainties=[], dynamicDeclarations=[], resolvedDynamicDeclarations=[])
    graph['dependencies']['functions']['existing'] = node
    feature = graph['mappings']['features'][0]
    for patterns in [['App.stillExists()', 'App.wasDeleted()'], ['App.still*', 'App.missing*']]:
        feature['symbols'], feature['sources'] = patterns, ['App.swift']
        head_file.write_text(json.dumps(graph))
        failure(invoke('select', [*args, '--strict-mappings']), revision, patterns[-1])
    for patterns in [['App.stillExists()'], ['App.*'], []]:
        feature['symbols'] = patterns
        head_file.write_text(json.dumps(graph))
        result = invoke('select', [*args, '--strict-mappings'])
        assert result.returncode == 0, result.stderr  # Stale base is allowed.
    print('PASS siblings, sources, wildcard matching and head repairs over a stale base')

    # Saved execution validates even an empty report, before product/toolchain checks.
    feature['symbols'] = ['App.wasDeleted()']
    head_file.write_text(json.dumps(graph))
    report = json.loads(invoke('select', args).stdout)
    report['selectedTests'], report['onlyTestingArguments'] = [], []
    report_file = root / 'report.json'
    report_file.write_text(json.dumps(report))
    for command in ['run', 'verify-build']:
        failure(invoke(command, ['--report', report_file, '--head-graph', head_file, '--strict-mappings']), revision)
    graph.pop('dependencies')
    head_file.write_text(json.dumps(graph))
    legacy = invoke('select', [*args, '--strict-mappings'])
    assert legacy.returncode != 0 and not legacy.stdout  # Existing provenance check rejects legacy saved graphs.
    assert not calls.exists()
    print('PASS saved execution and legacy graphs cannot bypass validation')

    failure(invoke('select', ['--base', base, '--strict-mappings', '--run']), 'WORKTREE')
    print('PASS worktree validation fails before --run')

    # Fresh analysis and cold/warm analysis-cache paths all enforce the policy.
    # The minimal mock build intentionally has no compiled function matches.
    for revision in revisions:
        args = ['--base', base, '--head', revision, '--format', 'json', '--strict-mappings']
        failure(invoke('select', args), revision)
        cache = root / ('cache-' + revision)
        cached = [*args, '--analysis-cache', cache, '--cache-context', 'fixture']
        failure(invoke('select', cached), revision)
        before = len(calls.read_text().splitlines())
        failure(invoke('select', cached), revision)
        warm_calls = [json.loads(line) for line in calls.read_text().splitlines()[before:]]
        assert not any('build-for-testing' in c and '-showBuildSettings' not in c for c in warm_calls), warm_calls
        assert not any('-enumerate-tests' in c for c in warm_calls), warm_calls
    assert all('test' not in c and ('test-without-building' not in c or '-enumerate-tests' in c)
               for c in map(json.loads, calls.read_text().splitlines()))
    print('PASS fresh/cold/warm validation including no-op and non-production diffs; no test execution')

    # Mapping parse/schema failures must survive being discarded by the loader.
    invalid_policies = [
        ('fixture', json.dumps(dict(version=1, features=[dict(name='checkout', symbols=['App.wasDeleted()'], fixtures=['missing'])]))),
        ('duplicate', json.dumps(dict(version=1, features=[dict(name='checkout', symbols=['App.wasDeleted()'])] * 2))),
        ('json', '{broken json'),
    ]
    for label, contents in invalid_policies:
        (root / 'ui.json').write_text(contents)
        git('add', 'ui.json')
        git('commit', '-qm', 'Invalid mapping: ' + label)
        revision = git('rev-parse', 'HEAD')
        no_op = ['--base', revision, '--head', revision, '--format', 'json']
        cache = ['--analysis-cache', root / ('invalid-' + label), '--cache-context', 'fixture']
        for extra in [[], cache]:
            # Default behavior is unchanged; this also seeds a non-strict cache.
            ordinary = invoke('select', [*no_op, *extra])
            assert ordinary.returncode == 0, ordinary.stderr
            before = len(calls.read_text().splitlines())
            failure(invoke('select', [*no_op, *extra, '--strict-mappings']), revision,
                    pattern=None, feature=None, code='invalid_mapping_file')
            if extra:
                warm_calls = list(map(json.loads, calls.read_text().splitlines()[before:]))
                assert not any('build-for-testing' in c and '-showBuildSettings' not in c for c in warm_calls)
                assert not any('-enumerate-tests' in c for c in warm_calls)
        cold_cache = ['--analysis-cache', root / ('invalid-cold-' + label), '--cache-context', 'fixture']
        failure(invoke('select', [*no_op, *cold_cache, '--strict-mappings']), revision,
                pattern=None, feature=None, code='invalid_mapping_file')
        failure(invoke('select', ['--base', base, '--strict-mappings', '--run']), 'WORKTREE',
                pattern=None, feature=None, code='invalid_mapping_file')
    # Both new and pre-field saved graphs retain enough evidence to reject the file.
    graph['dependencies'] = dict(schemaVersion=1, toolchain='', functions={}, tests={}, diagnostics=[], testDiagnostics={})
    graph.pop('mappings')
    graph['buildArtifact']['revision'] = revision
    graph['diagnostics'] = ['Invalid UI mappings: Unknown fixture missing in UI feature checkout']
    report['headRevision'] = revision
    report_file.write_text(json.dumps(report))
    for legacy in [False, True]:
        if legacy:
            graph.pop('mappingLoadError')
        else:
            graph['mappingLoadError'] = 'Unknown fixture missing in UI feature checkout'
        head_file.write_text(json.dumps(graph))
        failure(invoke('select', [*no_op, '--base-graph', head_file, '--head-graph', head_file, '--strict-mappings', '--run']),
                revision, pattern=None, feature=None, code='invalid_mapping_file')
        for command in ['run', 'verify-build']:
            failure(invoke(command, ['--report', report_file, '--head-graph', head_file, '--strict-mappings']),
                    revision, pattern=None, feature=None, code='invalid_mapping_file')
    print('PASS new and legacy saved graphs reject invalid mappings before selection or execution')

    assert not any(c[0] == 'test' or c[0] == 'test-without-building' and '-enumerate-tests' not in c
                   for c in map(json.loads, calls.read_text().splitlines()))
    print('PASS malformed/structurally invalid mappings fail on fresh/cold/warm no-op paths before --run')

    for command in [[str(tool), 'select', '--base', 'HEAD', '--strict-mappings'],
                    [common[0], 'graph', *common[1:], '--strict-mappings']]:
        result = subprocess.run(command, cwd=root, env=env, text=True, capture_output=True)
        assert result.returncode == 1 and '--strict-mappings requires' in result.stderr, result.stderr
    print('PASS unsupported command modes reject the option')
