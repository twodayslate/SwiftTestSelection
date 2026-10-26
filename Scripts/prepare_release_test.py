#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Zachary Gorak
# SPDX-License-Identifier: AGPL-3.0-only
"""Release transactions against a local bare Git remote; GitHub calls are mocked."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).with_name('prepare_release.py').resolve()


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='release transaction ')
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.remote = self.root / 'origin.git'
        self.work = self.root / 'checkout'
        self.git('init', '--bare', str(self.remote), cwd=self.root)
        self.git('init', '-b', 'main', str(self.work), cwd=self.root)
        self.git('config', 'user.name', 'Release Test')
        self.git('config', 'user.email', 'release@example.invalid')
        (self.work / 'VERSION').write_text('1.2.3\n')
        self.git('add', 'VERSION')
        self.git('commit', '-m', 'Initial version')
        self.git('remote', 'add', 'origin', str(self.remote))
        self.git('push', '-u', 'origin', 'main')
        self.sha = self.git('rev-parse', 'HEAD')
        self.log = self.root / 'github.jsonl'
        mock_bin = self.root / 'bin'
        mock_bin.mkdir()
        gh = mock_bin / 'gh'
        gh.write_text('''#!/usr/bin/env python3
import json
import os
from pathlib import Path
import subprocess
import sys
args = sys.argv[1:]
with open(os.environ['MOCK_GH_LOG'], 'a') as output:
    output.write(json.dumps(args) + '\\n')
if args[0] == 'api':
    if os.environ.get('MOCK_API_FAILURE'):
        sys.exit('GitHub API unavailable')
    if os.environ.get('MOCK_RIVAL_SHA'):
        subprocess.run(['git', '--git-dir', os.environ['MOCK_REMOTE'], 'update-ref',
                        'refs/heads/main', os.environ['MOCK_RIVAL_SHA']], check=True)
    print(os.environ.get('MOCK_RELEASES', ''))
elif args[:2] == ['workflow', 'run']:
    if args[2] == os.environ.get('MOCK_FAILED_DISPATCH'):
        sys.exit('Workflow dispatch failed')
else:
    sys.exit('Unexpected GitHub operation')
''')
        gh.chmod(0o755)
        self.environment = {**os.environ, 'PATH': str(mock_bin) + os.pathsep + os.environ['PATH'],
                            'MOCK_GH_LOG': str(self.log), 'MOCK_REMOTE': str(self.remote)}
        self.environment.pop('GITHUB_STEP_SUMMARY', None)

    def git(self, *arguments, cwd=None):
        return subprocess.check_output(['git', *arguments], cwd=cwd or self.work,
                                       stderr=subprocess.PIPE, text=True).strip()

    def remote_git(self, *arguments):
        return self.git('--git-dir', str(self.remote), *arguments)

    def prepare(self, bump='patch', **environment):
        return subprocess.run([sys.executable, str(SCRIPT), '--repository', 'owner/repo',
                               '--expected-sha', self.sha, '--bump', bump], cwd=self.work,
                              env={**self.environment, **environment}, text=True, capture_output=True)

    def assert_not_released(self, result, main=None):
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.remote_git('rev-parse', 'refs/heads/main'), main or self.sha)
        self.assertEqual(self.remote_git('tag', '--list'), '')

    def assert_release(self, bump, next_version):
        result = self.prepare(bump)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.remote_git('rev-parse', 'v1.2.3^{commit}'), self.sha)
        self.assertEqual(self.remote_git('show', 'v1.2.3:VERSION'), '1.2.3')
        self.assertEqual(self.remote_git('show', 'main:VERSION'), next_version)
        self.assertEqual(self.remote_git('rev-parse', 'main^'), self.sha)
        self.assertEqual(self.remote_git('diff-tree', '--no-commit-id', '--name-only', '-r', 'main'), 'VERSION')
        calls = [json.loads(line) for line in self.log.read_text().splitlines()]
        self.assertIn(['workflow', 'run', 'binaries.yml', '--repo', 'owner/repo', '--ref', 'v1.2.3'], calls)
        self.assertIn(['workflow', 'run', 'tests.yml', '--repo', 'owner/repo', '--ref', 'main'], calls)

    def test_patch_release_tags_old_version_and_bumps_main(self):
        self.assert_release('patch', '1.2.4')

    def test_minor_release_resets_patch(self):
        self.assert_release('minor', '1.3.0')

    def test_major_release_resets_minor_and_patch(self):
        self.assert_release('major', '2.0.0')

    def test_existing_remote_tags_are_rejected(self):
        for tag in ['v1.2.3', '1.2.3']:
            with self.subTest(tag=tag):
                self.git('tag', tag)
                self.git('push', 'origin', f'refs/tags/{tag}')
                result = self.prepare()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('already has a remote Git tag', result.stderr)
                self.assertEqual(self.remote_git('rev-parse', 'main'), self.sha)
                self.assertEqual((self.work / 'VERSION').read_text(), '1.2.3\n')
                self.git('push', 'origin', f':refs/tags/{tag}')
                self.git('tag', '-d', tag)

    def test_existing_release_without_tag_is_rejected(self):
        result = self.prepare(MOCK_RELEASES='v1.2.3\n')
        self.assert_not_released(result)
        self.assertIn('already has a GitHub release or draft', result.stderr)

    def test_api_failure_aborts_before_mutation(self):
        self.assert_not_released(self.prepare(MOCK_API_FAILURE='1'))
        self.assertEqual((self.work / 'VERSION').read_text(), '1.2.3\n')

    def test_invalid_version_is_rejected(self):
        for version in ['01.2.3', '1.2', '1.2.3-rc.1', 'not-a-version']:
            with self.subTest(version=version):
                (self.work / 'VERSION').write_text(version + '\n')
                self.git('commit', '-am', 'Invalid version fixture')
                self.git('push', 'origin', 'main')
                self.sha = self.git('rev-parse', 'HEAD')
                self.assert_not_released(self.prepare())

    def rival_commit(self):
        self.git('checkout', '-b', 'rival')
        (self.work / 'another-file').write_text('Concurrent update\n')
        self.git('add', 'another-file')
        self.git('commit', '-m', 'Concurrent update')
        rival = self.git('rev-parse', 'HEAD')
        self.git('push', 'origin', 'rival')
        self.git('checkout', 'main')
        return rival

    def test_stale_dispatch_does_not_release(self):
        rival = self.rival_commit()
        self.remote_git('update-ref', 'refs/heads/main', rival)
        result = self.prepare()
        self.assert_not_released(result, main=rival)
        self.assertIn('main moved', result.stderr)

    def test_atomic_push_rejects_a_concurrent_main_update(self):
        rival = self.rival_commit()
        self.assert_not_released(self.prepare(MOCK_RIVAL_SHA=rival), main=rival)

    def test_rejected_branch_update_does_not_leave_a_tag(self):
        hook = self.remote / 'hooks/pre-receive'
        hook.write_text('#!/bin/sh\ncat >/dev/null\necho "Branch rule rejected push" >&2\nexit 1\n')
        hook.chmod(0o755)
        self.assert_not_released(self.prepare())

    def test_dispatch_failure_reports_recovery_without_undoing_release(self):
        result = self.prepare(MOCK_FAILED_DISPATCH='binaries.yml')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.remote_git('rev-parse', 'v1.2.3^{commit}'), self.sha)
        self.assertEqual(self.remote_git('show', 'main:VERSION'), '1.2.4')
        self.assertIn('Recovery: gh workflow run binaries.yml', result.stderr)
        self.assertIn('Queued tests.yml on main', result.stdout)

    def test_rerunning_a_completed_dispatch_fails(self):
        self.assertEqual(self.prepare().returncode, 0)
        main = self.remote_git('rev-parse', 'main')
        self.git('checkout', '--detach', self.sha)
        self.assertNotEqual(self.prepare().returncode, 0)
        self.assertEqual(self.remote_git('rev-parse', 'main'), main)
        self.assertEqual(self.remote_git('tag', '--list'), 'v1.2.3')


if __name__ == '__main__':
    unittest.main()
