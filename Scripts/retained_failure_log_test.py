#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Zachary Gorak
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
"""Verify durable failed/cancelled build evidence through the real CLI, using mocked Xcode."""
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

with tempfile.TemporaryDirectory(prefix='retained-logs-') as temporary:
    root = Path(temporary).resolve()
    (root / 'App.xcodeproj').mkdir()
    (root / 'App.xcodeproj/project.pbxproj').write_text('mock fixture')
    for args in [['init', '-q'], ['add', '.'], ['-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '-qm', 'fixture']]:
        subprocess.run(['git', *args], cwd=root, check=True, capture_output=True)
    (root / 'bin').mkdir()
    for name in ['xcodebuild', 'xcrun']:
        path = root / 'bin' / name
        path.write_text('''#!/usr/bin/env python3
import json, os, sys, time
if '-showBuildSettings' in sys.argv:
 print(json.dumps([{'target': 'App', 'buildSettings': {'TARGET_NAME': 'App', 'PRODUCT_TYPE': 'com.apple.product-type.application'}}]))
elif '-showsdks' in sys.argv: print('[]')
elif '-version' in sys.argv or '--version' in sys.argv: print('fixture toolchain')
elif 'build-for-testing' in sys.argv:
 print('EARLY_ROOT_CAUSE_SENTINEL', flush=True)
 print('EARLY_STDERR_SENTINEL', file=sys.stderr, flush=True)
 print('subsequent compiler output\\n' * 1000, flush=True)
 print('BUILD_OUTPUT_FLUSHED', flush=True)
 if os.environ['LOG_TEST_MODE'] == 'cancel': time.sleep(60)
 sys.exit(65 if os.environ['LOG_TEST_MODE'] == 'build-failure' else 0)
elif '-enumerate-tests' in sys.argv:
 sys.exit('ANALYSIS_FAILURE_SENTINEL')
else: sys.exit('Unexpected command')
''')
        path.chmod(0o755)
    for mode in ['build-failure', 'analysis-failure', 'cancel']:
        bundle = root / mode
        env = dict(os.environ, PATH=str(root / 'bin') + os.pathsep + os.environ['PATH'], LOG_TEST_MODE=mode)
        command = [str(tool), 'select', '--project', str(root / 'App.xcodeproj'), '--scheme', 'App',
                   '--destination', 'platform=macOS', '--base', 'HEAD', '--head', 'HEAD', '--retain-build', str(bundle)]
        log = bundle / 'build.log'
        if mode == 'cancel':
            process = subprocess.Popen(command, cwd=root, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                       text=True, start_new_session=True)
            try:
                deadline = time.monotonic() + 15
                while not log.exists() or 'BUILD_OUTPUT_FLUSHED' not in log.read_text():
                    assert process.poll() is None and time.monotonic() < deadline, 'Build did not start'
                    time.sleep(0.05)
            finally:
                os.killpg(process.pid, signal.SIGTERM)
            stdout, stderr = process.communicate(timeout=10)
            assert process.returncode != 0
        else:
            result = subprocess.run(command, cwd=root, env=env, text=True, capture_output=True)
            stderr = result.stderr
            assert result.returncode != 0, result.stdout
            assert ('failed (65)' if mode == 'build-failure' else 'ANALYSIS_FAILURE_SENTINEL') in stderr, stderr
        contents = log.read_text()
        assert 'EARLY_ROOT_CAUSE_SENTINEL' in contents and 'EARLY_STDERR_SENTINEL' in contents
        assert 'BUILD_OUTPUT_FLUSHED' in contents and len(contents) > 8000
        assert str(log) in stderr, stderr
        assert (bundle / 'build-settings.json').exists()
        assert (bundle / 'state').read_text() == 'incomplete'
        assert not (bundle / 'complete.json').exists() and not (bundle / 'head-graph.json').exists()
        print('PASS durable build log:', mode, flush=True)
