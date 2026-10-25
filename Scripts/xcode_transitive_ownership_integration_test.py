#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Zachary Gorak
# SPDX-License-Identifier: AGPL-3.0-only
"""Real Xcode coverage for compiler ownership omitted by scheme build settings."""
import argparse
import hashlib
import importlib.util
import json
import pathlib
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = pathlib.Path(__file__).resolve().parents[1]
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--destination', required=True)
p.add_argument('--tool', type=pathlib.Path, default=ROOT / '.build/release/swift-test-impact')
p.add_argument('--output', type=pathlib.Path, required=True)
p.add_argument('--keep-work', action='store_true')
a = p.parse_args()
folder = pathlib.Path(tempfile.mkdtemp(prefix='swift-impact-ownership-'))
work = folder / 'App'
spec = importlib.util.spec_from_file_location('fixture', ROOT / 'Fixtures/XcodeTransitive/generate.py')
sys.dont_write_bytecode = True
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)
fixture.generate(work)


def run(args):
    result = subprocess.run(list(map(str, args)), cwd=work, text=True, capture_output=True)
    if result.returncode:
        (folder / 'failure.log').write_text(result.stdout + result.stderr)
        raise AssertionError(f'{args}: see {folder}/failure.log')
    return result


def commit(message):
    run(['git', 'add', '.'])
    run(['git', 'commit', '-qm', message])
    return run(['git', 'rev-parse', 'HEAD']).stdout.strip()


try:
    (work / '.gitignore').write_text('.build/\nxcuserdata/\n')
    for args in [['init', '-q'], ['config', 'user.name', 'Test'], ['config', 'user.email', 'test@example.invalid']]:
        run(['git', *args])
    base = commit('Base with transitive production modules')
    common = ['--project', work / 'ImpactDemo.xcodeproj', '--scheme', 'ImpactDemo', '--test-plan', 'AllTests',
              '--configuration', 'Debug', '--destination', a.destination]
    cache = folder / 'cache'
    expected_owners = {'LocalCore': 'LocalCore/Sources/LocalCore/Value.swift',
                       'ShareExtension': 'ShareExtension/Controller.swift', 'ActionExtension': 'ActionExtension/Controller.swift'}

    def check_graph(graph):
        assert not graph['diagnostics'], graph['diagnostics']
        for module, path in expected_owners.items():
            assert graph['modules']['Compiler module: ' + module] == module, graph['modules']
            assert module + ':' + path in graph['sources'], (module, graph['sources'].keys())
        for module in ['ShareExtension', 'ActionExtension', 'UnitTests']:
            assert module + ':Shared/ExtensionValue.swift' in graph['sources']
            assert any(node['module'] == module and 'protocol witness for ExtensionValue.value()' in node['name']
                       for node in graph['dependencies']['functions'].values()), (module, 'missing protocol witness')
        assert not any(t['name'] == 'Unclassified build inputs' for t in graph['targets']), graph['targets']

    # Retain both graphs, proving both revisions have semantic snapshots. This
    # also seeds the normal revision cache, not a separately fabricated graph.
    base_bundle = folder / 'base'
    run([a.tool, 'select', *common, '--base', base, '--head', base, '--analysis-cache', cache, '--cache-context', 'ownership-fixture-v1',
         '--retain-build', base_bundle, '--format', 'json', '--output', folder / 'base-report.json'])
    base_graph = json.loads((base_bundle / 'head-graph.json').read_text())
    check_graph(base_graph)
    # The actual build settings must omit these targets (no mocked xcodebuild).
    settings_files = list(base_bundle.rglob('build-settings.json'))
    assert settings_files, list(base_bundle.iterdir())
    settings = json.loads(settings_files[0].read_text())
    settings_modules = {x['buildSettings'].get('PRODUCT_MODULE_NAME') for x in settings}
    assert not (set(expected_owners) & settings_modules), settings_modules
    print('PASS real build omits package/extensions from scheme settings; base owns all compiler sources', flush=True)

    package = work / 'LocalCore/Sources/LocalCore/Value.swift'
    package.write_text(package.read_text().replace('40 + 2', '41 + 1'))
    isolated = commit('Isolated package implementation change')
    start = time.monotonic()
    report_path = folder / 'isolated.json'
    head_bundle = folder / 'head'
    run([a.tool, 'select', *common, '--base', base, '--head', isolated, '--analysis-cache', cache, '--cache-context', 'ownership-fixture-v1',
         '--retain-build', head_bundle, '--format', 'json', '--output', report_path])
    cold = json.loads(report_path.read_text())
    head_graph = json.loads((head_bundle / 'head-graph.json').read_text())
    check_graph(head_graph)
    assert not any(d['code'] == 'unclassified_change' for d in cold['diagnostics']), cold
    assert 'UnitTests/ProductionTests/testPackage()' in cold['selectedTests'], cold
    assert 'UnitTests/ProductionTests/testSharing()' not in cold['selectedTests'], cold
    assert any(e['kind'] == 'dependency' and e['test'] == 'UnitTests/ProductionTests/testPackage()' for e in cold['explanations']), cold
    print('PASS isolated package edit enters semantic analysis and reaches its dependent test', flush=True)
    def canonical(value):
        # Graph collections are sets or declaration inventories; serialization
        # order is not part of graph identity. Preserve every field and value.
        if isinstance(value, dict):
            return {key: canonical(item) for key, item in value.items()}
        if isinstance(value, list):
            return sorted((canonical(item) for item in value), key=lambda item: json.dumps(item, sort_keys=True))
        return value

    def dependency_identity(graph):
        graph = json.loads(json.dumps(graph))
        for node in graph['functions'].values():
            if not any(node.get(key) for key in ['regions', 'dependencies', 'compilerReferences', 'uncertainties',
                                                 'dynamicDeclarations', 'resolvedDynamicDeclarations']):
                # Locationless resolved leaves (e.g. Swift.Int literals) can be
                # emitted by several modules. Xcode's parallel log order chooses
                # their non-owning emitter. Keep IDs/names and every graph edge;
                # retain module attribution for all located or non-leaf nodes.
                node.pop('module', None)
        return canonical(graph)

    # Warm graph reuse and uncached extraction must agree on graph and report.
    for label, options in [('warm', ['--analysis-cache', cache, '--cache-context', 'ownership-fixture-v1']), ('fresh', [])]:
        parity_bundle = folder / label
        result = json.loads(run([a.tool, 'select', *common, '--base', base, '--head', isolated, *options,
                                 '--retain-build', parity_bundle, '--format', 'json']).stdout)
        parity_graph = json.loads((parity_bundle / 'head-graph.json').read_text())
        check_graph(parity_graph)
        for field in ['targets', 'modules', 'sources', 'unsupportedSourceInputs']:
            assert canonical(parity_graph.get(field)) == canonical(head_graph.get(field)), (label, field)
        assert dependency_identity(parity_graph['dependencies']) == dependency_identity(head_graph['dependencies']), (label, 'dependencies')
        for field in ['selectedTests', 'diagnostics', 'fullRunReasons', 'explanations']:
            assert result[field] == cold[field], (label, field, result[field], cold[field])
        if label == 'warm':
            assert sum(e['detail'].startswith('hit:') for e in result['analysisEvents']) == 2
    print('PASS cached/fresh ownership, snapshots, dependencies, selection and reasons match', flush=True)
    run([a.tool, 'verify-build', *common, '--report', report_path, '--head-graph', head_bundle / 'head-graph.json'])
    execution = run([a.tool, 'run', *common, '--report', report_path, '--head-graph', head_bundle / 'head-graph.json'])
    (folder / 'execution.log').write_text(execution.stdout + execution.stderr)
    assert '** TEST EXECUTE SUCCEEDED **' in execution.stderr
    print('PASS selected tests execute from verified retained products', flush=True)

    shared = work / 'Shared/ExtensionValue.swift'
    shared.write_text(shared.read_text().replace('20 + 2', '21 + 1'))
    (work / 'README.md').write_text('Documentation changes alongside production code.\n')
    unit = work / 'UnitTests/ProductionTests.swift'
    unit.write_text(unit.read_text().replace('func testSharing() {', 'func testSharing() {\n        XCTAssertTrue(true)').replace(
        '    func testNotes()', '    func testAdded() { XCTAssertEqual(packageValue(), 42) }\n    func testNotes()'))
    mixed = commit('Shared extension edit, documentation, changed and added tests')
    mixed_path = folder / 'mixed.json'
    mixed_bundle = folder / 'mixed'
    run([a.tool, 'select', *common, '--base', isolated, '--head', mixed, '--analysis-cache', cache, '--cache-context', 'ownership-fixture-v1',
         '--retain-build', mixed_bundle, '--format', 'json', '--output', mixed_path])
    result = json.loads(mixed_path.read_text())
    check_graph(json.loads((mixed_bundle / 'head-graph.json').read_text()))
    assert not any(d['code'] == 'unclassified_change' for d in result['diagnostics']), result
    for name in ['testExtension', 'testAdded', 'testSharing']:
        assert f'UnitTests/ProductionTests/{name}()' in result['selectedTests'], result
    assert 'README.md' in result['ignoredChanges'], result
    assert 'UnitTests/ProductionTests/testNotes()' not in result['selectedTests'], result
    print('PASS shared multi-module source, docs, edited and added test methods', flush=True)
    a.output.parent.mkdir(parents=True, exist_ok=True)
    a.output.write_text(json.dumps(dict(analyzerSHA256=hashlib.sha256(a.tool.read_bytes()).hexdigest(),
        toolchain=run(['xcodebuild', '-version']).stdout.strip(), destination=a.destination,
        seconds=time.monotonic()-start, base=base, isolated=isolated, mixed=mixed,
        isolatedSelection=cold['selectedTests'], mixedSelection=result['selectedTests'],
        cachedFreshParity=True, selectedExecution=True), indent=2) + '\n')
finally:
    if a.keep_work:
        print(f'Retained {folder}', flush=True)
    else:
        shutil.rmtree(folder)
