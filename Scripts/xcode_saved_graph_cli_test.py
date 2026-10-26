#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Zachary Gorak
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
"""Exercise retained-bundle validation in CLI selection without Xcode or products."""
import argparse
import hashlib
import json
import os
import pathlib
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--tool', type=pathlib.Path, required=True)
tool = parser.parse_args().tool.resolve(strict=True)

with tempfile.TemporaryDirectory(prefix='impact-saved-graph-cli-') as temporary:
    root = pathlib.Path(temporary).resolve()
    project = root / 'App.xcodeproj'
    project.mkdir()
    (project / 'project.pbxproj').write_text('CLI fixture; never built')
    for args in [['init', '-q'], ['add', '.'], ['-c', 'user.name=Test', '-c', 'user.email=test@example.invalid', 'commit', '-qm', 'Fixture']]:
        subprocess.run(['git', *args], cwd=root, check=True, capture_output=True)
    revision = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=root, text=True).strip()
    calls = root / 'unexpected-xcode-calls'
    bin_dir = root / 'bin'
    bin_dir.mkdir()
    for name in ['xcodebuild', 'xcrun']:
        mock = bin_dir / name
        mock.write_text('#!/usr/bin/env python3\nimport pathlib,sys\n'
                        f'pathlib.Path({str(calls)!r}).write_text("called")\n'
                        'sys.exit("Unexpected build or test command")\n')
        mock.chmod(0o755)
    env = dict(os.environ, PATH=str(bin_dir) + os.pathsep + os.environ['PATH'])
    test = 'UnitTests/Suite/testOne()'
    graph = dict(schemaVersion=2, analysisKind='xcode-sil-and-ui-mappings', targets=[], tests=[test], diagnostics=[],
                 sources={}, modules={}, dependencies=dict(schemaVersion=1, toolchain='', functions={}, tests={}, diagnostics=[], testDiagnostics={}),
                 buildArtifact=dict(schemaVersion=1, id='fixture', revision=revision,
                                    context=dict(container='project', path='App.xcodeproj', scheme='App', destination='platform=macOS',
                                                 configuration='', testPlan='', mappings='.swift-test-selection.json', sdkAndArchitecture='Debug|macosx|macosx|arm64'),
                                    toolchain='fixture', buildLogDigest='log', buildSettingsDigest='settings',
                                    productsDirectory=str(root / 'absent-products'), xctestrun='Tests.xctestrun', products={'Tests.xctestrun': 'digest'}))
    data = json.dumps(graph).encode()
    manual = root / 'manual.json'
    manual.write_bytes(data)
    bundle = root / 'retained'
    bundle.mkdir()
    retained = bundle / 'head-graph.json'
    retained.write_bytes(data)
    complete = dict(schemaVersion=1, graphDigest=hashlib.sha256(data).hexdigest(), inputIdentity={})
    completion = bundle / 'complete.json'
    completion.write_text(json.dumps(complete))
    common = [str(tool), 'select', '--project', str(project), '--scheme', 'App', '--destination', 'platform=macOS',
              '--base', revision, '--head', revision, '--format', 'json']

    # Manual captures remain valid; completed bundles need no surviving base products.
    for graph_path in [manual, retained]:
        result = subprocess.run([*common, '--base-graph', str(graph_path), '--head-graph', str(graph_path), '--full-suite'],
                                cwd=root, env=env, text=True, capture_output=True)
        assert result.returncode == 0, result.stderr
        assert json.loads(result.stdout)['selectedTests'] == [test]
    print('PASS manual captures and completed bundles remain selectable')

    for problem in ['incomplete', 'checksum']:
        if problem == 'incomplete':
            (bundle / 'state').write_text('incomplete')
            expected = 'Retained build is incomplete'
        else:
            (bundle / 'state').unlink()
            retained.write_bytes(data + b'\n')  # Valid JSON, invalid completion checksum.
            expected = 'Retained head graph is incomplete, corrupt, or incompatible'
        for side in ['base', 'head']:
            for run in [False, True]:
                base_graph, head_graph = (retained, manual) if side == 'base' else (manual, retained)
                result = subprocess.run([*common, '--base-graph', str(base_graph), '--head-graph', str(head_graph), '--full-suite',
                                         *(['--run'] if run else [])], cwd=root, env=env, text=True, capture_output=True)
                assert result.returncode != 0 and expected in result.stderr, (problem, side, run, result.stderr)
                assert not result.stdout, 'Rejected bundles must not emit a selection report'
                assert not calls.exists(), 'Rejected bundles must not invoke Xcode'
                print(f'PASS {problem} {side} rejected; run={run}')
    assert not calls.exists()
