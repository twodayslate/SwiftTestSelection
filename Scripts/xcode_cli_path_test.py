#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Zachary Gorak
# SPDX-License-Identifier: AGPL-3.0-only
"""Check analyzer discovery through real CLI launches, without building an app."""
import argparse
import os
import pathlib
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--tool', type=pathlib.Path, required=True)
tool = parser.parse_args().tool.resolve(strict=True)

with tempfile.TemporaryDirectory(prefix='impact-cli-path-') as temporary:
    root = pathlib.Path(temporary).resolve()
    project = root / 'App.xcodeproj'
    project.mkdir()
    (project / 'project.pbxproj').write_text('CLI fixture; never built')
    for args in [['init', '-q'], ['add', '.'], ['-c', 'user.name=Test', '-c', 'user.email=test@example.invalid', 'commit', '-qm', 'Fixture']]:
        subprocess.run(['git', *args], cwd=root, check=True, capture_output=True)
    bin_dir = root / 'bin'
    bin_dir.mkdir()
    (bin_dir / tool.name).symlink_to(tool)
    # A same-named local file must not become the analyzer's identity either.
    (root / tool.name).mkdir()
    sentinel = 'REGRESSION_REACHED_BUILD_SETTINGS'
    for name in ['xcodebuild', 'xcrun']:
        mock = bin_dir / name
        mock.write_text('#!/usr/bin/env python3\nimport sys\n'
                        'if "-showBuildSettings" in sys.argv:\n'
                        f' print({sentinel!r}, file=sys.stderr)\n sys.exit(86)\n'
                        'if "-showsdks" in sys.argv: print("[]")\n'
                        'elif "-version" in sys.argv or "--version" in sys.argv: print("fixture toolchain")\n'
                        'else: sys.exit("Unexpected build or test command")\n')
        mock.chmod(0o755)
    env = dict(os.environ, PATH=str(bin_dir) + os.pathsep + os.environ['PATH'])
    launches = [('absolute', str(tool), None),
                ('relative', os.path.relpath(tool, root), None),
                ('PATH-symlink', tool.name, None),
                ('launcher-argv0', 'arbitrary-launcher-name', str(tool))]
    for name, command, executable in launches:
        result = subprocess.run([command, 'select', '--project', str(project), '--scheme', 'App',
                                 '--destination', 'platform=macOS', '--base', 'HEAD', '--head', 'HEAD',
                                 '--analysis-cache', str(root / ('cache-' + name)), '--cache-context', 'fixture'],
                                executable=executable, cwd=root, env=env, capture_output=True, text=True)
        assert result.returncode != 0 and sentinel in result.stderr, (name, result.stdout, result.stderr)
        print('PASS executable discovery:', name)
