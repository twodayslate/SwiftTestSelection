#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Zachary Gorak
# SPDX-License-Identifier: AGPL-3.0-only
"""Opt-in build-for-testing with sealed supplementary SIL artifacts.

A stable session supports incremental builds. Complete fresh modules are used;
unchanged captures are reused only for identical input context. Other modules
replay during graph analysis. No test body is executed here.
"""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import time
import re


def digest(path):
    h = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''): h.update(chunk)
    return h.hexdigest()


def manifest(root):
    result = {}
    for directory, dirs, files in os.walk(root, followlinks=False):
        for name in dirs[:] + files:
            p = Path(directory) / name
            key = str(p.relative_to(root))
            if p.is_symlink():
                if not p.resolve().is_relative_to(root.resolve()): raise ValueError('Escaping product link: ' + key)
                result[key] = 'symlink:' + os.readlink(p)
                if name in dirs: dirs.remove(name)
            elif p.is_file(): result[key] = digest(p)
    if not result: raise ValueError('Empty products')
    return result


def output(args, cwd=None, env=None):
    return subprocess.check_output(args, cwd=cwd, env=env).decode()


def atomic(path, value):
    temporary = path.with_suffix('.tmp')
    temporary.write_text(json.dumps(value, indent=2) + '\n')
    temporary.replace(path)


def driver_inventory(log):
    result = {}
    for line in log.splitlines():
        if 'builtin-SwiftDriver -- ' not in line: continue
        args = shlex.split(line.split('builtin-SwiftDriver -- ', 1)[1])
        module = args[args.index('-module-name') + 1]
        if module in result and result[module] != args: raise ValueError('Multiple architectures/invocations: ' + module)
        result[module] = args
    return result


def select_manifests(fresh, previous):
    """Prefer fresh jobs, retaining older batches only for uncovered primaries.

    Batch boundaries can change between builds, so matching primary sets alone
    is insufficient. Unsupported records remain visible to the graph validator.
    """
    records = [(path, json.loads(path.read_text())) for path in fresh | previous]
    records.sort(key=lambda item: (item[0] in fresh, item[1].get('started', 0), str(item[0])), reverse=True)
    covered = {}
    chosen = set()
    paths = {}
    def canonical(directory, source):
        key = (directory, source)
        if key not in paths: paths[key] = str((Path(directory) / source).resolve())
        return paths[key]
    for path, job in records:
        arguments = job.get('arguments', [])
        sources = set(job.get('sourceFiles', []))
        primaries = set(job.get('primaryFiles', [])) or sources
        optimizations = [a for a in arguments if a in ['-Onone', '-O', '-Osize', '-Ounchecked']]
        if (job.get('status') != 'complete' or '-module-name' not in arguments
                or arguments.index('-module-name') + 1 == len(arguments)
                or not sources or sources != set(job.get('sources', {}))
                or not primaries <= sources or not job.get('directory')
                or optimizations[-1:] != ['-Onone'] or '-g' not in arguments):
            chosen.add(path)
            continue
        # Never let a different module, inventory or input bytes mask a record that
        # the graph loader needs to reject or replay.
        key = (arguments[arguments.index('-module-name') + 1],
               frozenset((canonical(job['directory'], s), h) for s, h in job['sources'].items()))
        primaries = {canonical(job['directory'], s) for s in primaries}
        if not primaries <= covered.get(key, set()):
            chosen.add(path)
            covered.setdefault(key, set()).update(primaries)
    return chosen


def run(args):
    session = args.session.resolve()
    session.mkdir(parents=True, exist_ok=True)
    with (session / 'lock').open('w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        build(args, session)


def build(args, session):
    # Record this before showBuildSettings can create build metadata. A first
    # partial build cannot establish a complete inventory from its log alone.
    had_build = (args.derived_data.resolve() / 'Build').exists()
    container = (args.project or args.workspace).resolve()
    exported = getattr(args, 'export_manifest', None)
    export_digest = digest(exported) if exported else None
    if exported:
        export = json.loads(exported.read_text())
        root = Path(export['root']).resolve()
        revision = export['revision']
        if not re.fullmatch(r'[0-9a-f]{40}', revision) or not container.is_relative_to(root):
            raise ValueError('Invalid exported revision/container provenance')
        def source_identity():
            if digest(exported) != export_digest or manifest(root) != export['files']:
                raise ValueError('Exported source changed or does not match its revision manifest')
            return export_digest
    else:
        root = Path(output(['git', 'rev-parse', '--show-toplevel'], cwd=container.parent).strip()).resolve()
        revision = output(['git', 'rev-parse', 'HEAD'], cwd=root).strip()
        def source_identity():
            if output(['git', 'status', '--porcelain', '--untracked-files=all'], cwd=root).strip():
                raise ValueError('Capture requires a clean committed checkout')
            return output(['git', 'rev-parse', 'HEAD^{tree}'], cwd=root).strip()
    if session.is_relative_to(root): raise ValueError('Keep the session outside the source checkout')
    tree = source_identity()
    if exported and had_build:
        build_root = args.derived_data.resolve() / 'Build'
        if any(build_root.rglob('*.SwiftFileList')) or any((build_root / 'Products').rglob('*')):
            raise ValueError('Export capture requires fresh build products and compiler inputs')
        # The analyzer's cache lookup may resolve settings/packages first.
        had_build = False
    compiler = output(['xcrun', '--find', 'swiftc']).strip()
    toolchain = output(['xcodebuild', '-version']) + output(['xcrun', 'swiftc', '--version'])
    wrapper = session / 'wrapper'
    prepare = Path(__file__).parent / 'Experimental/prepare_sil_capture.py'
    if not wrapper.exists():
        subprocess.run([sys.executable, str(prepare), '--compiler', compiler, '--output', str(wrapper)], check=True, stdout=subprocess.DEVNULL)
    setup = json.loads((wrapper / 'session.json').read_text())
    if setup['environment']['IMPACT_REAL_SWIFTC'] != compiler or setup['compilerVersion'] != output([compiler, '--version']):
        raise ValueError('Toolchain changed; use a new session')
    env = dict(os.environ, **setup['environment'])
    capture = Path(env['IMPACT_SIL_CAPTURE'])
    before = set(capture.glob('*/manifest.json'))
    command = ['xcodebuild', 'build-for-testing', '-project' if args.project else '-workspace', str(container),
               '-scheme', args.scheme, '-destination', args.destination, '-derivedDataPath', str(args.derived_data.resolve())]
    if args.test_plan: command += ['-testPlan', args.test_plan]
    if args.configuration: command += ['-configuration', args.configuration]
    if getattr(args, 'only_use_package_versions_from_resolved_file', False): command += ['-onlyUsePackageVersionsFromResolvedFile']
    command += ['OTHER_SWIFT_FLAGS=$(inherited) ' + ' '.join(shlex.quote(v) for v in setup['additionalSwiftFlags'])]
    # Xcode's -MMD omits system headers, even when they are repository files.
    # Retain them so documentation exclusions can use complete Metal evidence.
    command += ['MTL_COMPILER_FLAGS=$(inherited) -Xclang -sys-header-deps']
    settings_path = session / 'settings.json'
    settings = subprocess.check_output(command + ['-showBuildSettings', '-json'], cwd=root, env=env)
    helper_files = [Path(__file__), prepare, prepare.with_name('capture_swiftc.py'), prepare.with_name('capture_inputs.py')]
    helper_identity = hashlib.sha256(json.dumps({p.name: digest(p) for p in helper_files}, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
    identity = dict(helper=helper_identity, tree=tree, context=args.context, toolchain=toolchain, settings=hashlib.sha256(settings).hexdigest(), command=command)
    seal_path = session / 'build.json'
    previous = json.loads(seal_path.read_text()) if seal_path.exists() else {}
    compatible = previous.get('root') == str(root) and all(previous.get('inputIdentity', {}).get(k) == identity[k] for k in ['helper', 'toolchain', 'settings', 'command', 'context'])
    if had_build and not compatible:
        raise ValueError('No compatible complete compiler inventory; use fresh DerivedData for a new or incompatible session')
    # Invalidate the old seal before the first build mutation, including failures.
    seal_path.unlink(missing_ok=True)
    settings_path.write_bytes(settings)
    log_path = session / 'build.log'
    build_started = time.monotonic()
    with log_path.open('wb') as log:
        result = subprocess.run(command, cwd=root, env=env, stdout=log, stderr=subprocess.STDOUT)
    build_seconds = time.monotonic() - build_started
    if result.returncode: raise ValueError('Build failed; complete log retained at ' + str(log_path))
    if tree != source_identity() or (not exported and revision != output(['git', 'rev-parse', 'HEAD'], cwd=root).strip()):
        raise ValueError('Source changed during build')
    if settings != subprocess.check_output(command + ['-showBuildSettings', '-json'], cwd=root, env=env):
        raise ValueError('Build settings changed during build')
    log = log_path.read_text()
    drivers = driver_inventory(log)
    # Xcode's no-op/partial build omits unchanged SwiftDriver jobs. Carry forward
    # invocations only under the same compiler, settings, root and build command.
    if compatible:
        for module, invocation in previous.get('drivers', {}).items():
            if module not in drivers:
                drivers[module] = invocation
                log += '\nbuiltin-SwiftDriver -- ' + shlex.join(invocation) + '\n'
    inventory = {}
    for module, invocation in drivers.items():
        sources = []
        for arg in invocation:
            if arg.startswith('@'): sources += shlex.split((root / arg[1:]).read_text())
            elif arg.endswith('.swift'): sources.append(arg)
        inventory[module] = sorted({str((root / p).resolve(strict=True)) for p in sources if p.endswith('.swift')})
        if not inventory[module]: raise ValueError('Empty module inventory: ' + module)
    # The first build starts with fresh DerivedData; subsequent builds merge
    # compatible retained invocations with the current log. Unrelated on-disk
    # lists from inactive configurations or deleted targets are not evidence of
    # active inputs and must not invalidate this inventory.
    if not inventory: raise ValueError('No compiler inventory; use a clean build for the first session')
    log_path.write_text(log)
    fresh = set(capture.glob('*/manifest.json')) - before
    retained = set()
    if compatible and previous.get('inputIdentity') == identity:
        retained = {session / p for p in previous.get('manifests', {})}
    chosen = select_manifests(fresh, retained)
    manifests = {str(p.relative_to(session)): digest(p) for p in sorted(chosen)}
    products = manifest(args.derived_data.resolve() / 'Build/Products')
    seal = dict(schemaVersion=1, root=str(root), revision=revision, toolchain=toolchain,
                sourceExportDigest=export_digest, helperIdentity=helper_identity, buildSeconds=build_seconds,
                buildLogDigest=digest(log_path), buildSettingsDigest=digest(settings_path),
                products=products, manifests=manifests, inventory=inventory, drivers=drivers, inputIdentity=identity)
    atomic(seal_path, seal)
    print(json.dumps(dict(silCapture=str(session), buildLog=str(log_path), buildSettings=str(settings_path), revision=revision), indent=2))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--session', type=Path, required=True)
    parser.add_argument('--context', required=True, help='Digest of external inputs, scripts and build environment')
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument('--project', type=Path)
    group.add_argument('--workspace', type=Path)
    parser.add_argument('--scheme', required=True)
    parser.add_argument('--destination', required=True)
    parser.add_argument('--derived-data', type=Path, required=True)
    parser.add_argument('--test-plan')
    parser.add_argument('--configuration')
    parser.add_argument('--export-manifest', type=Path, help='Analyzer-owned revision/source manifest for a Git archive export')
    parser.add_argument('--only-use-package-versions-from-resolved-file', action='store_true')
    try: run(parser.parse_args())
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        sys.exit('capture-build: ' + str(error))
