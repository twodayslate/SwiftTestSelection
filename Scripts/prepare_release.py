#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Zachary Gorak
# SPDX-License-Identifier: AGPL-3.0-only
"""Tag the current VERSION and atomically push the next development version."""
import argparse
import os
from pathlib import Path
import re
import subprocess
import sys


def run(*arguments):
    result = subprocess.run(arguments, text=True, capture_output=True)
    if result.returncode:
        raise RuntimeError(f'{" ".join(arguments[:2])} failed:\n{result.stderr or result.stdout}')
    return result.stdout.strip()


def prepare(repository, expected_sha, bump):
    if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', repository):
        raise RuntimeError('Expected repository in owner/name form')
    if not re.fullmatch(r'[0-9a-f]{40}', expected_sha):
        raise RuntimeError('Expected a full commit SHA')
    os.chdir(run('git', 'rev-parse', '--show-toplevel'))
    if run('git', 'status', '--porcelain'):
        raise RuntimeError('Release preparation requires a clean checkout')
    if run('git', 'rev-parse', 'HEAD') != expected_sha:
        raise RuntimeError('Checkout does not match the selected release commit')
    run('git', 'fetch', 'origin', 'refs/heads/main:refs/remotes/origin/main')
    if run('git', 'rev-parse', 'refs/remotes/origin/main') != expected_sha:
        raise RuntimeError('main moved since this run was requested; start a new run from main')

    version_file = Path('VERSION')
    run('git', 'ls-files', '--error-unmatch', 'VERSION')
    if version_file.is_symlink() or not version_file.is_file():
        raise RuntimeError('VERSION must be a regular tracked file')
    version = version_file.read_text().strip()
    if not re.fullmatch(r'(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)', version):
        raise RuntimeError('VERSION must contain a stable semantic version, such as 0.1.0')
    tag = 'v' + version
    # Both spellings represent the same SwiftPM version. Include drafts in the
    # release check, even if their Git tag has not been created or was removed.
    if run('git', 'ls-remote', '--tags', 'origin', f'refs/tags/{tag}', f'refs/tags/{version}'):
        raise RuntimeError(f'Version {version} already has a remote Git tag')
    releases = run('gh', 'api', '--paginate', f'repos/{repository}/releases', '--jq', '.[].tag_name')
    if {tag, version}.intersection(releases.splitlines()):
        raise RuntimeError(f'Version {version} already has a GitHub release or draft')

    major, minor, patch = map(int, version.split('.'))
    next_version = {
        'patch': f'{major}.{minor}.{patch + 1}',
        'minor': f'{major}.{minor + 1}.0',
        'major': f'{major + 1}.0.0',
    }[bump]
    identity = ['git', '-c', 'user.name=github-actions[bot]', '-c',
                'user.email=41898282+github-actions[bot]@users.noreply.github.com']
    version_file.write_text(next_version + '\n')
    run('git', 'add', '--', 'VERSION')
    run(*identity, 'commit', '-m', f'Bump version to {next_version} after {tag}')
    run(*identity, 'tag', '-a', tag, expected_sha, '-m', f'Release {tag}')
    # Compare-and-swap guards reject races; --atomic prevents a rejected branch
    # update (including branch protection) from leaving a published tag behind.
    run('git', 'push', '--atomic', f'--force-with-lease=refs/heads/main:{expected_sha}',
        f'--force-with-lease=refs/tags/{tag}:', 'origin',
        'HEAD:refs/heads/main', f'refs/tags/{tag}:refs/tags/{tag}')
    summary = (f'Released source tag `{tag}` at `{expected_sha}`.\n\n'
               f'`main` now has `VERSION` set to `{next_version}`.\n\n'
               'Binary publishing runs separately in **Build and release CLI**.\n')
    print(summary)
    if os.environ.get('GITHUB_STEP_SUMMARY'):
        with open(os.environ['GITHUB_STEP_SUMMARY'], 'a') as output:
            output.write(summary)

    # GITHUB_TOKEN pushes do not trigger push workflows. Explicit dispatches do.
    failures = []
    for workflow, ref in [('binaries.yml', tag), ('tests.yml', 'main')]:
        try:
            run('gh', 'workflow', 'run', workflow, '--repo', repository, '--ref', ref)
            print(f'Queued {workflow} on {ref}')
        except RuntimeError as error:
            failures.append(f'{error}\nRecovery: gh workflow run {workflow} --repo {repository} --ref {ref}')
    if failures:
        raise RuntimeError('Tag and version bump are already pushed; do not create another release.\n'
                           + '\n'.join(failures))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repository', required=True)
    parser.add_argument('--expected-sha', required=True)
    parser.add_argument('--bump', choices=['patch', 'minor', 'major'], default='patch')
    args = parser.parse_args()
    try:
        prepare(args.repository, args.expected_sha, args.bump)
    except (RuntimeError, OSError) as error:
        print(f'error: {error}', file=sys.stderr)
        sys.exit(1)
