#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Zachary Gorak
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
"""Compile whole-module and per-primary file-list jobs with real frontends."""
import json
import os
import pathlib
import shlex
import subprocess
import tempfile
from validate_sil_capture import validate

HERE = pathlib.Path(__file__).parent.resolve()
compiler = subprocess.check_output(['xcrun', '--find', 'swiftc'], text=True).strip()
sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip()
with tempfile.TemporaryDirectory(prefix='impact-filelists-') as temporary:
    root = pathlib.Path(temporary).resolve()
    # Literal spaces, quotes and backslashes must not be interpreted as shell text.
    sources = [root / 'Model with spaces.swift', root / "Other's \\ model.swift"]
    sources[0].write_text('public func value() -> Int { helper() }\n')
    sources[1].write_text('func helper() -> Int { 42 }\n')
    for batch in [False, True]:
        folder = root / ('batch' if batch else 'whole')
        folder.mkdir()
        session = json.loads(subprocess.check_output(['python3', str(HERE / 'prepare_sil_capture.py'),
            '--compiler', compiler, '--output', str(folder / 'wrapper')], text=True))
        environment = {**os.environ, **session['environment']}
        source_list = folder / 'sources.txt'
        primary_list = folder / 'primaries.txt'
        # Relative inputs also exercise manifest working-directory handling.
        names = [p.name for p in sources]
        source_list.write_text('\n'.join(names) + '\n')
        args = ['-frontend', '-c', '-parse-as-library', '-Onone', '-g', '-target', 'arm64-apple-macosx14.0',
                '-sdk', sdk, '-module-name', 'FileListProbe', '-filelist', str(source_list)]
        outputs = [folder / 'first.o', folder / 'second.o'] if batch else [folder / 'whole.o']
        if batch:
            primary_list.write_text('\n'.join(reversed(names)) + '\n')
            args += ['-primary-filelist', str(primary_list)]
        for output in outputs: args += ['-o', str(output)]
        subprocess.run([compiler, *args], cwd=root, check=True)
        def code(path):
            return subprocess.check_output(['otool', '-s', '__TEXT', '__text', str(path)], text=True).splitlines()[1:]
        normal = [code(path) for path in outputs]
        subprocess.run([str(folder / 'wrapper/bin/swift-frontend'), *args], cwd=root, env=environment, check=True)
        assert normal == [code(path) for path in outputs], 'Capture changed executable code'
        manifests = list((folder / 'wrapper/capture').glob('*/manifest.json'))
        assert len(manifests) == 1
        record = json.loads(manifests[0].read_text())
        assert record['status'] == 'complete' and set(record['sources']) == set(names)
        assert record['primaryFiles'] == (names if batch else [])
        assert len(record['silFiles']) == len(outputs)
        assert len(set(record['silFiles'])) == len(outputs)
        texts = [(manifests[0].parent / p).read_text() for p in record['silFiles']]
        assert all('sil_stage canonical' in text for text in texts)
        for name in names:
            assert any(name.replace('\\', '\\\\') in text for text in texts), name
        log = folder / 'build.log'
        log.write_text('builtin-SwiftDriver -- ' + shlex.join([compiler, '-module-name', 'FileListProbe',
            '-target', 'arm64-apple-macosx14.0', *map(str, sources)]) + '\n** TEST BUILD SUCCEEDED **\n')
        source_list.unlink()
        if batch: primary_list.unlink()
        # No dependence on compiler temporary lists after a successful capture.
        assert validate(folder / 'wrapper/capture', log)['complete']
        original = sources[1].read_bytes()
        sources[1].write_bytes(original + b'\n// changed after capture\n')
        assert not validate(folder / 'wrapper/capture', log)['complete']
        sources[1].write_bytes(original)
        del record['sources'][names[1]]
        manifests[0].write_text(json.dumps(record))
        assert not validate(folder / 'wrapper/capture', log)['complete']
    # A successful compiler exit cannot bless a list changed during the job.
    changing_list = root / 'changing.txt'
    changing_list.write_text(sources[0].name + '\n')
    fake_compiler = root / 'mutating-compiler'
    fake_compiler.write_text("""#!/usr/bin/env python3
import pathlib, sys
arguments = sys.argv[1:]
pathlib.Path(arguments[arguments.index('-filelist')+1]).write_text('changed.swift\\n')
pathlib.Path(arguments[arguments.index('-sil-output-path')+1]).write_text('sil_stage canonical\\n')
""")
    fake_compiler.chmod(0o755)
    changed_capture = root / 'changed-capture'
    subprocess.run(['python3', str(HERE / 'capture_swiftc.py'), '-frontend', '-c',
        '-filelist', str(changing_list)], cwd=root, check=True,
        env={**os.environ, 'IMPACT_REAL_SWIFTC': str(fake_compiler), 'IMPACT_SIL_CAPTURE': str(changed_capture)})
    changed_manifest = next(changed_capture.glob('*/manifest.json'))
    assert json.loads(changed_manifest.read_text())['status'] == 'failed'
    print('Whole-module and per-primary file-list capture regressions passed')
