#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Zachary Gorak
# SPDX-License-Identifier: AGPL-3.0-only
"""Exercise the documented installer and, optionally, an extracted release."""
import argparse
import hashlib
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--distribution', type=Path)
options, test_args = parser.parse_known_args()
DISTRIBUTION = options.distribution.resolve() if options.distribution else None
VERSION = 'v0.0.0-test'


class InstallerTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='impact-install-test-')
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.project = self.root / 'Project with spaces'
        self.project.mkdir()
        self.tools = self.root / 'Temporary tools with spaces'
        self.tools.mkdir()
        self.assets = self.root / 'assets'
        self.assets.mkdir()
        self.mock_bin = self.root / 'mock-bin'
        self.mock_bin.mkdir()
        self.log = self.root / 'executed.log'
        self.archive = self.assets / f'swift-test-impact-{VERSION}-macos-universal.tar.gz'
        with tarfile.open(self.archive, 'w:gz') as bundle:
            data = b'#!/bin/sh\necho NEW >> "$EXECUTION_LOG"\n'
            entry = tarfile.TarInfo('./bin/swift-test-impact')
            entry.size, entry.mode = len(data), 0o755
            bundle.addfile(entry, io.BytesIO(data))
        self.write_checksum()
        # An old executable on PATH must not make a failed install look successful.
        old = self.mock_bin / 'swift-test-impact'
        old.write_text('#!/bin/sh\necho OLD >> "$EXECUTION_LOG"\n')
        old.chmod(0o755)
        curl = self.mock_bin / 'curl'
        curl.write_text('''#!/usr/bin/env python3
import os
from pathlib import Path
import shutil
import sys
target = Path(sys.argv[sys.argv.index('--output') + 1])
if os.environ.get('FAILED_DOWNLOAD') == target.name:
    target.write_bytes(b'partial response')
    sys.exit(22)
shutil.copyfile(Path(os.environ['RELEASE_ASSETS']) / target.name, target)
''')
        curl.chmod(0o755)
        section = (ROOT / 'README.md').read_text().split('## Install a prebuilt executable\n', 1)[1]
        self.script = section.split('```sh\n', 1)[1].split('```', 1)[0]
        self.script = self.script.replace('VERSION=vX.Y.Z', f'VERSION={VERSION}')

    def write_checksum(self):
        digest = hashlib.sha256(self.archive.read_bytes()).hexdigest()
        (self.assets / 'SHA256SUMS').write_text(f'{digest}  {self.archive.name}\n')

    def install(self, **environment):
        env = {**os.environ, 'PATH': str(self.mock_bin) + os.pathsep + os.environ['PATH'],
               'TMPDIR': str(self.tools), 'RELEASE_ASSETS': str(self.assets),
               'EXECUTION_LOG': str(self.log), **environment}
        env.pop('RUNNER_TEMP', None)  # Exercise the default outside GitHub Actions.
        return subprocess.run(['/bin/sh', '-c', self.script], cwd=self.project,
                              env=env, capture_output=True, text=True)

    def assert_failed_without_execution(self, result):
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(self.log.exists(), 'A failed install executed a stale binary')

    def test_successful_install_does_not_add_untracked_files(self):
        # Installation must leave even a repository with no ignore rules clean.
        subprocess.run(['git', 'init', '-q'], cwd=self.project, check=True)
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.log.read_text(), 'NEW\n')
        untracked = subprocess.check_output(['git', 'ls-files', '--others', '--exclude-standard'], cwd=self.project)
        self.assertEqual(untracked, b'')

    def test_archive_download_failure_stops_installation(self):
        self.assert_failed_without_execution(self.install(FAILED_DOWNLOAD=self.archive.name))

    def test_checksum_download_failure_stops_installation(self):
        self.assert_failed_without_execution(self.install(FAILED_DOWNLOAD='SHA256SUMS'))

    def test_bad_checksum_does_not_execute_existing_installation(self):
        self.assertEqual(self.install().returncode, 0)
        self.log.unlink()
        self.archive.write_bytes(b'corrupt archive')
        self.assert_failed_without_execution(self.install())

    def test_extraction_failure_does_not_execute_existing_installation(self):
        self.assertEqual(self.install().returncode, 0)
        self.log.unlink()
        self.archive.write_bytes(b'not a tar archive')
        self.write_checksum()
        self.assert_failed_without_execution(self.install())


@unittest.skipUnless(DISTRIBUTION, 'Pass --distribution to check a packaged release')
class PackagedCaptureTests(unittest.TestCase):
    def test_extracted_helpers_capture_a_real_compiler_job(self):
        helpers = ['capture-build.py', 'Experimental/prepare_sil_capture.py',
                   'Experimental/capture_swiftc.py', 'Experimental/capture_inputs.py']
        scripts = DISTRIBUTION / 'Scripts'
        for name in helpers:
            self.assertEqual((scripts / name).read_bytes(), (ROOT / 'Scripts' / name).read_bytes())
        subprocess.run([sys.executable, str(scripts / 'capture-build.py'), '--help'],
                       check=True, stdout=subprocess.DEVNULL)
        with tempfile.TemporaryDirectory(prefix='impact-packaged-capture-') as temporary:
            work = Path(temporary).resolve()
            compiler = subprocess.check_output(['xcrun', '--find', 'swiftc'], text=True).strip()
            setup = json.loads(subprocess.check_output([
                sys.executable, str(scripts / 'Experimental/prepare_sil_capture.py'),
                '--compiler', compiler, '--output', str(work / 'wrapper')], cwd=work, text=True))
            source = work / 'Smoke.swift'
            source.write_text('public func answer() -> Int { 42 }\n')
            subprocess.run([compiler, '-c', '-Onone', '-module-name', 'ReleaseSmoke',
                            str(source), '-o', str(work / 'Smoke.o'), *setup['additionalSwiftFlags']],
                           cwd=work, env={**os.environ, **setup['environment']}, check=True)
            manifests = list(Path(setup['environment']['IMPACT_SIL_CAPTURE']).glob('*/manifest.json'))
            self.assertTrue(manifests, 'Packaged wrapper did not capture the compiler job')
            for manifest in manifests:
                record = json.loads(manifest.read_text())
                self.assertEqual(record['status'], 'complete', record)
                self.assertGreater(record['silBytes'], 0)


if __name__ == '__main__':
    unittest.main(argv=[sys.argv[0], *test_args])
