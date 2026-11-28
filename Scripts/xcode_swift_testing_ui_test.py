#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Zachary Gorak
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
"""Verify selection, compiler binding and filtered execution of mixed UI tests on Xcode 27.3 or later."""
import argparse
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
TEST_FILE = 'CheckoutUITests/CheckoutUITests.swift'
SWIFT_TEST = 'CheckoutUITests/SwiftTestingUIRunner/showsWelcome()'
XCTEST = 'CheckoutUITests/SharingUITests/testShareSheet()'
UI_SUITE = '''
import Testing
import XCUIAutomation

struct SwiftTestingUIRunner {
    @MainActor @Test func showsWelcome() {
        let app = XCUIApplication()
        app.launch()
        #expect(app.staticTexts["welcome"].waitForExistence(timeout: 9))
    }
}
'''


def verify_binding(graph, identifier):
    target, suite, method = identifier.split('/')
    dependencies = graph['dependencies']
    module = graph['modules'][target]
    roots = [dependencies['functions'][symbol] for symbol in dependencies['tests'][identifier]]
    entries = [node['id'] for node in roots if node['module'] == module and node['name'] == suite + '.' + method
               and any(region['path'] == TEST_FILE for region in node['regions'])]
    assert len(entries) == 1, (identifier, entries)
    if identifier == SWIFT_TEST:
        assert entries[0] in dependencies['swiftTestingEntryRoots'][identifier], identifier
        registered = dependencies['swiftTestingRegisteredFactories'][module]
        factories = [node for node in roots if node['module'] == module and node['id'] in registered
                     and any(symbol.startswith('$s7Testing4TestV10__function') for symbol in node.get('compilerReferences', []))]
        assert len(factories) == 1, (identifier, 'expected one bound Swift Testing factory')


def passed_case(bundle, identifier):
    def result(kind):
        return json.loads(subprocess.check_output(
            ['xcrun', 'xcresulttool', 'get', 'test-results', kind, '--path', bundle]))
    summary = result('summary')
    assert (summary['passedTests'], summary['failedTests'], summary['skippedTests']) == (1, 0, 0), summary
    nodes = result('tests')['testNodes']
    cases = []
    while nodes:
        node = nodes.pop()
        nodes.extend(node.get('children', []))
        if node['nodeType'] == 'Test Case':
            cases.append((node['nodeIdentifier'], node['result']))
    assert cases == [(identifier.split('/', 1)[1], 'Passed')], cases
    return cases[0][0]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--destination', required=True)
    parser.add_argument('--tool', type=Path, default=ROOT / '.build/release/swift-test-impact')
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    tool = args.tool.resolve(strict=True)
    with tempfile.TemporaryDirectory(prefix='swift-testing-ui-') as scratch:
        work = Path(scratch).resolve()
        source = work / 'fixture'
        shutil.copytree(ROOT / 'Fixtures/XcodeUITests', source, ignore=shutil.ignore_patterns('.build', 'xcuserdata'))

        def run(*cmd):
            return subprocess.check_output(cmd, text=True, cwd=source).strip()

        def commit(message):
            run('git', 'add', '.')
            run('git', '-c', 'user.name=Test', '-c', 'user.email=test@example.invalid', 'commit', '-qm', message)
            return run('git', 'rev-parse', 'HEAD')

        mapping = source / '.swift-test-selection.json'
        config = json.loads(mapping.read_bytes())
        config['fixtures']['sharing'].append(SWIFT_TEST)
        mapping.write_text(json.dumps(config))
        path = source / TEST_FILE
        baseline = path.read_text() + UI_SUITE
        path.write_text(baseline)
        run('git', 'init', '-q')
        base = commit('Mixed UI tests')
        xctest_body = 'func testShareSheet() {\n        assertSharingScreen(timeout: 5)'
        assert baseline.count(xctest_body) == baseline.count('waitForExistence(timeout: 9)') == 1
        path.write_text(baseline.replace(xctest_body, xctest_body.replace('5)', '6)'))
                        .replace('waitForExistence(timeout: 9)', 'waitForExistence(timeout: 10)'))
        head = commit('Edit both UI methods')
        common = ['--project', 'ImpactDemo.xcodeproj', '--scheme', 'ImpactDemo', '--configuration', 'Debug',
                  '--test-plan', 'AllTests', '--destination', args.destination, '--strict-mappings']
        report_file = work / 'report.json'
        retained = work / 'retained'
        print('Selecting mixed UI tests and retaining the head build', flush=True)
        try:
            run(tool, 'select', *common, '--base', base, '--head', head, '--head-only', '--merge-base',
                '--build-time-sil', ROOT / 'Scripts/capture-build.py', '--retain-build', retained,
                '--format', 'json', '--output', report_file)
        except subprocess.CalledProcessError:
            build_log = retained / 'SILCapture/build.log'
            if build_log.exists():
                for line in build_log.read_text(errors='replace').splitlines():
                    if 'error:' in line:
                        print(line, file=sys.stderr)
            raise
        report = json.loads(report_file.read_bytes())
        graph_file = retained / 'head-graph.json'
        verified = json.loads(run(tool, 'verify-build', *common, '--report', report_file, '--head-graph', graph_file))
        graph = json.loads(graph_file.read_bytes())
        phases = [event['phase'] for event in report['analysisEvents']]
        assert phases.count('build') == 1 and 'compilerReplay' not in phases
        assert report['headRevision'] == graph['buildArtifact']['revision'] == head
        assert report['buildArtifactID'] == verified['buildArtifactID']
        assert report['selectedTests'] == verified['selectedTests']
        assert report['totalTests'] > 2 and report['selectedTests'] == sorted([SWIFT_TEST, XCTEST]), report['selectedTests']
        coverage = report['uiMappingCoverage']
        assert not any(coverage[key] for key in ['unmappedTests', 'unmatchedSelectors', 'unresolvedBoundaries']), coverage
        filters = {flag.removeprefix('-only-testing:'): flag for flag in verified['onlyTestingArguments']}
        assert set(filters) == set(verified['selectedTests'])
        executed = {}
        for identifier in [SWIFT_TEST, XCTEST]:
            verify_binding(graph, identifier)
            assert filters[identifier] == '-only-testing:' + identifier
            print('Executing ' + identifier, flush=True)
            bundle = work / (identifier.split('/')[1] + '.xcresult')
            subprocess.run(['xcodebuild', 'test-without-building', '-xctestrun', verified['xctestrun'],
                            '-destination', args.destination, '-parallel-testing-enabled', 'NO', filters[identifier],
                            '-resultBundlePath', bundle], cwd=source, check=True)
            executed[identifier] = passed_case(bundle, identifier)
        args.output.write_text(json.dumps(dict(toolchain=run('xcodebuild', '-version'),
            buildID=verified['buildArtifactID'], selectedTests=report['selectedTests'], totalTests=report['totalTests'],
            diagnostics=report['diagnostics'], executed=executed), indent=2) + '\n')


if __name__ == '__main__':
    main()
