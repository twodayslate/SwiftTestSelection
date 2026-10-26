#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Zachary Gorak
# SPDX-License-Identifier: AGPL-3.0-only
"""Check capture failures/cancellation cannot publish retained executable bundles."""
import argparse
import os
from pathlib import Path
import signal
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
session=pathlib.Path(args[args.index('--session')+1]);session.mkdir()
(session/'settings.json').write_text('[]')
(session/'build.log').write_text('CAPTURE_FAILURE_SENTINEL\\n' * 500)
mode=os.environ['CAPTURE_FAILURE_MODE']
if mode=='cancel': time.sleep(60)
if mode=='source-change':
 export=json.loads(pathlib.Path(args[args.index('--export-manifest')+1]).read_text())
 (pathlib.Path(export['root'])/'App.xcodeproj/project.pbxproj').write_text('tampered')
if mode=='failure': sys.exit('capture failed deliberately')
''')
    for mode in ['failure', 'source-change', 'missing-products', 'cancel']:
        bundle = root / mode
        env = dict(os.environ, PATH=str(root / 'bin') + os.pathsep + os.environ['PATH'], CAPTURE_FAILURE_MODE=mode)
        command = [str(tool), 'select', '--project', str(root / 'App.xcodeproj'), '--scheme', 'App',
                   '--destination', 'platform=macOS', '--base', 'HEAD', '--head', 'HEAD', '--retain-build', str(bundle),
                   '--build-time-sil', str(helper)]
        if mode == 'cancel':
            process = subprocess.Popen(command, cwd=root, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
            try:
                deadline = time.monotonic() + 15
                while not (bundle / 'SILCapture/build.log').exists():
                    assert process.poll() is None and time.monotonic() < deadline
                    time.sleep(0.05)
            finally: os.killpg(process.pid, signal.SIGTERM)
            process.communicate(timeout=10)
            assert process.returncode != 0
        else:
            result = subprocess.run(command, cwd=root, env=env, text=True, capture_output=True)
            assert result.returncode != 0, result.stdout
            if mode == 'source-change': assert 'Source export or capture helper changed' in result.stderr, result.stderr
        assert 'CAPTURE_FAILURE_SENTINEL' in (bundle / 'SILCapture/build.log').read_text()
        assert (bundle / 'state').read_text() == 'incomplete'
        assert not (bundle / 'complete.json').exists() and not (bundle / 'head-graph.json').exists()
        print('PASS incomplete retained capture with durable diagnostics:', mode, flush=True)
