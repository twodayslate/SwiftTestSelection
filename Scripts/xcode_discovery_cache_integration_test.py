#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Zachary Gorak
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
"""Verify discovery cache runner identity and inactive DerivedData source lists.

Builds the Xcode fixture and enumerates tests without executing test bodies.
Run with a release --tool and an available iOS Simulator --destination.
"""
import argparse
import json
import pathlib
import plistlib
import shutil
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--tool', type=pathlib.Path, required=True)
parser.add_argument('--destination', required=True)
args = parser.parse_args()
tool = args.tool.resolve(strict=True)

with tempfile.TemporaryDirectory(prefix='impact-discovery-') as temporary:
    root = pathlib.Path(temporary).resolve()
    source = root / 'source'
    shutil.copytree(ROOT / 'Fixtures/XcodeUITests', source)

    def run(command):
        result = subprocess.run(list(map(str, command)), cwd=source, text=True, capture_output=True)
        assert result.returncode == 0, result.stdout + result.stderr
        return result

    for command in [['init', '-q'], ['add', '.'], ['-c', 'user.name=Test', '-c',
                    'user.email=test@example.invalid', 'commit', '-qm', 'Fixture']]:
        run(['git', *command])
    derived = root / 'DerivedData'
    options = ['-project', source / 'ImpactDemo.xcodeproj', '-scheme', 'ImpactDemo',
               '-testPlan', 'AllTests', '-configuration', 'Debug', '-destination', args.destination,
               '-derivedDataPath', derived]
    build = run(['xcodebuild', 'build-for-testing', *options])
    log = root / 'build.log'
    log.write_text(build.stdout + build.stderr)
    settings = root / 'settings.json'
    settings.write_text(run(['xcodebuild', 'build-for-testing', *options, '-showBuildSettings', '-json']).stdout)
    products = derived / 'Build/Products'
    original, = products.glob('*.xctestrun')
    restricted = products / 'Restricted.xctestrun'
    runner = plistlib.loads(original.read_bytes())
    for configuration in runner['TestConfigurations']:
        configuration['TestTargets'] = [t for t in configuration['TestTargets'] if t['BlueprintName'] == 'UnitTests']
        for target in configuration['TestTargets']:
            target['OnlyTestIdentifiers'] = ['ProductionTests/testSharing']
    restricted.write_bytes(plistlib.dumps(runner))
    # Both runners exist before the first fingerprint, so the Products manifest
    # stays identical when switching which runner is selected.
    common = [tool, 'graph', '--project', source / 'ImpactDemo.xcodeproj', '--scheme', 'ImpactDemo',
              '--test-plan', 'AllTests', '--configuration', 'Debug', '--destination', args.destination,
              '--derived-data', derived, '--build-log', log, '--build-settings', settings,
              '--revision', 'HEAD', '--format', 'json']

    def graph(runner, cached=True, mappings=None):
        command = [*common, '--xctestrun', runner]
        if mappings is not None:
            command += ['--mappings', mappings]
        if cached:
            command += ['--discovery-cache', root / 'cache', '--discovery-context', 'fixture']
        result = run(command)
        value = json.loads(result.stdout)
        assert not value['diagnostics'] and not value['dependencies']['diagnostics'], value
        return value, result.stderr

    one, _ = graph(restricted)
    assert one['tests'] == ['UnitTests/ProductionTests/testSharing()'], one['tests']
    full, messages = graph(original)
    assert len(full['tests']) == 9, full['tests']
    assert 'Discovery cache hit:' not in messages
    warm, messages = graph(original)
    assert warm['tests'] == full['tests'] and 'Discovery cache hit:' in messages
    print('PASS distinct runners miss the cache; identical runner reuses all nine tests', flush=True)

    stale = derived / 'Build/Intermediates.noindex/Inactive/Removed.SwiftFileList'
    stale.parent.mkdir(parents=True)
    stale.write_text(str(source / 'Deleted.swift') + '\n')
    fresh, _ = graph(original, cached=False)
    assert fresh['tests'] == full['tests']
    # Swift Set fields (including sourceFiles) have no JSON ordering contract.
    def canonical(value):
        if isinstance(value, dict):
            return {key: canonical(item) for key, item in value.items()}
        if isinstance(value, list):
            return sorted((canonical(item) for item in value), key=lambda item: json.dumps(item, sort_keys=True))
        return value

    assert canonical(fresh['targets']) == canonical(full['targets']), 'Source ownership changed'
    assert canonical(fresh['sources']) == canonical(full['sources']), 'Source snapshots changed'
    warm, messages = graph(original)
    assert warm['tests'] == full['tests'] and 'Discovery cache hit:' in messages
    print('PASS stale inactive source list does not block analysis or invalidate discovery', flush=True)
    # Gitignored/generated policy remains a first-class analysis input.
    mapping_name = 'GeneratedMappings.json'
    with (source / '.git/info/exclude').open('a') as exclude:
        exclude.write('\n' + mapping_name + '\n')
    mapping = source / mapping_name
    absent, _ = graph(original, mappings=mapping_name)
    assert absent.get('mappings') is None
    for selector in ['CheckoutUITests/SharingUITests', 'CheckoutUITests/NotesUITests']:
        policy = dict(version=1, features=[dict(name='sharing', sources=['App/Sharing.swift'], tests=[selector])])
        mapping.write_text(json.dumps(policy))
        assert not run(['git', 'status', '--porcelain', '--untracked-files=all']).stdout
        changed, messages = graph(original, mappings=mapping_name)
        assert changed['mappings'] == policy and 'Discovery cache hit:' not in messages
        warm, messages = graph(original, mappings=mapping_name)
        assert warm['mappings'] == policy and 'Discovery cache hit:' in messages
    mapping.unlink()
    removed, _ = graph(original, mappings=mapping_name)
    assert removed.get('mappings') is None
    print('PASS mapping creation, edits, and removal never reuse stale policy', flush=True)

    # Missing active inputs must still fail, even on a warm cache.
    active = source / 'UnitTests/ProductionTests.swift'
    saved = active.read_bytes()
    try:
        active.unlink()
        result = subprocess.run(list(map(str, [*common, '--xctestrun', original])), cwd=source,
                                text=True, capture_output=True)
        assert result.returncode != 0
    finally:
        active.write_bytes(saved)
