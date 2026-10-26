#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Zachary Gorak
# SPDX-License-Identifier: AGPL-3.0-only
"""Check capture failures/cancellation cannot publish retained executable bundles."""
import argparse
import os
from pathlib import Path
import signal
import shutil
import subprocess
import tempfile
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--tool', type=Path, required=True)
tool = parser.parse_args().tool.resolve(strict=True)
with tempfile.TemporaryDirectory(prefix='capture-failures-') as temporary:
    root = Path(temporary).resolve()
    (root / 'App.xcodeproj').mkdir()
    (root / 'App.xcodeproj/project.pbxproj').write_text('fixture')
    for args in [['init', '-q'], ['add', '.'], ['-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '-qm', 'fixture']]:
        subprocess.run(['git', *args], cwd=root, check=True, capture_output=True)
    (root / 'bin').mkdir()
    for name in ['xcodebuild', 'xcrun']:
        path = root / 'bin' / name
        path.write_text('''#!/usr/bin/env python3
import json,sys
if '-showBuildSettings' in sys.argv:
 print(json.dumps([{'buildSettings': {'TARGET_NAME':'App', 'PRODUCT_TYPE':'com.apple.product-type.application'}}]))
elif '-showsdks' in sys.argv: print('[]')
elif '-version' in sys.argv or '--version' in sys.argv: print('fixture toolchain')
else: sys.exit('Unexpected Xcode invocation')
''')
        path.chmod(0o755)
    helper = root / 'helper/capture-build.py'; helper.parent.mkdir()
    (helper.parent / 'Experimental').mkdir()
    for name in ['prepare_sil_capture.py', 'capture_swiftc.py', 'capture_inputs.py']:
        (helper.parent / 'Experimental' / name).write_text('# fixture\n')
    helper.write_text('''import json,os,pathlib,sys,time
args=sys.argv
session=pathlib.Path(args[args.index('--session')+1])
mode=os.environ['CAPTURE_FAILURE_MODE']
print('HELPER_STDERR_SENTINEL', file=sys.stderr, flush=True)
if mode=='setup-failure':
 pathlib.Path(os.environ['CAPTURE_DIAGNOSTICS_MARKER']).write_text(str(session))
 sys.exit('setup failed deliberately')
session.mkdir()
(session/'settings.json').write_text('[]')
(session/'build.log').write_text('CAPTURE_FAILURE_SENTINEL\\n' * 500)
pathlib.Path(os.environ['CAPTURE_DIAGNOSTICS_MARKER']).write_text(str(session))
if mode=='cancel': time.sleep(60)
if mode=='source-change':
 export=json.loads(pathlib.Path(args[args.index('--export-manifest')+1]).read_text())
 (pathlib.Path(export['root'])/'App.xcodeproj/project.pbxproj').write_text('tampered')
if mode=='failure': sys.exit('capture failed deliberately')
''')
    for storage in ['retained', 'cached', 'temporary']:
        for mode in ['setup-failure', 'failure', 'source-change', 'missing-products', 'cancel']:
            bundle = root / (storage + '-' + mode)
            marker = root / (storage + '-' + mode + '.marker')
            env = dict(os.environ, PATH=str(root / 'bin') + os.pathsep + os.environ['PATH'],
                       CAPTURE_FAILURE_MODE=mode, CAPTURE_DIAGNOSTICS_MARKER=str(marker))
            command = [str(tool), 'select', '--project', str(root / 'App.xcodeproj'), '--scheme', 'App',
                       '--destination', 'platform=macOS', '--base', 'HEAD', '--head', 'HEAD',
                       '--build-time-sil', str(helper)]
            if storage == 'retained': command += ['--retain-build', str(bundle)]
            if storage == 'cached': command += ['--analysis-cache', str(bundle), '--cache-context', 'fixture']
            if mode == 'cancel':
                process = subprocess.Popen(command, cwd=root, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
                try:
                    deadline = time.monotonic() + 15
                    while not marker.exists():
                        assert process.poll() is None and time.monotonic() < deadline
                        time.sleep(0.05)
                finally: os.killpg(process.pid, signal.SIGTERM)
                _, stderr = process.communicate(timeout=10)
                stderr = stderr.decode()
                assert process.returncode != 0
            else:
                result = subprocess.run(command, cwd=root, env=env, text=True, capture_output=True)
                assert result.returncode != 0, result.stdout
                stderr = result.stderr
                if mode == 'source-change': assert 'Source export or capture helper changed' in stderr, stderr
                if mode in ['setup-failure', 'failure']:
                    assert ('setup failed deliberately' if mode == 'setup-failure' else 'capture failed deliberately') in stderr, stderr
                    assert 'exit 1' in stderr, stderr
            session = Path(marker.read_text())
            diagnostics = session.parent
            assert str(diagnostics) in stderr, stderr
            assert 'HELPER_STDERR_SENTINEL' in (diagnostics / 'capture.log').read_text()
            assert (diagnostics / 'source-export.json').exists()
            if mode != 'setup-failure':
                assert 'CAPTURE_FAILURE_SENTINEL' in (session / 'build.log').read_text()
                assert (session / 'settings.json').exists()
            if storage == 'retained': assert (bundle / 'state').read_text() == 'incomplete'
            assert not (bundle / 'complete.json').exists() and not (bundle / 'head-graph.json').exists()
            if storage != 'retained': shutil.rmtree(diagnostics)
            print('PASS durable capture diagnostics:', storage, mode, flush=True)
