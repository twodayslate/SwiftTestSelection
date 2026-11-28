#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Zachary Gorak
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
"""Verify selection, compiler binding and filtered execution of mixed UI tests on Xcode 27.3 or later."""
import argparse
import json
from pathlib import Path
import plistlib
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


def verify_binding(graph, identifier, source_path, swift_testing):
    target, suite, method = identifier.split('/')
    dependencies = graph['dependencies']
    module = graph['modules'][target]
    roots = [dependencies['functions'][symbol] for symbol in dependencies['tests'][identifier]]
    entries = [node['id'] for node in roots if node['module'] == module and node['name'] == suite + '.' + method
               and any(region['path'] == source_path for region in node['regions'])]
    assert len(entries) == 1, (identifier, entries)
    if swift_testing:
        assert entries[0] in dependencies['swiftTestingEntryRoots'][identifier], identifier
        registered = dependencies['swiftTestingRegisteredFactories'][module]
        factories = [node for node in roots if node['module'] == module and node['id'] in registered
                     and any(symbol.startswith('$s7Testing4TestV10__function') for symbol in node.get('compilerReferences', []))]
        assert len(factories) == 1, (identifier, 'expected one bound Swift Testing factory')


def passed_cases(bundle, selected):
    def result(kind):
        return json.loads(subprocess.check_output(
            ['xcrun', 'xcresulttool', 'get', 'test-results', kind, '--path', bundle]))
    summary = result('summary')
    assert (summary['passedTests'], summary['failedTests'], summary['skippedTests']) == (len(selected), 0, 0), summary
    nodes = [(root, None) for root in result('tests')['testNodes']]
    cases = []
    while nodes:
        node, target = nodes.pop()
        if node['nodeType'].lower().endswith('test bundle'):
            target = node['name']
        nodes.extend((child, target) for child in node.get('children', []))
        if node['nodeType'] == 'Test Case':
            assert target and node['result'] == 'Passed', node
            cases.append(target + '/' + node['nodeIdentifier'])
    assert sorted(cases) == sorted(selected), (cases, selected)
    return sorted(cases)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--destination', required=True)
    parser.add_argument('--tool', type=Path, default=ROOT / '.build/release/swift-test-impact')
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--control', choices=['swift-testing-unit', 'hostless-swift-testing-unit', 'xctest-ui'],
                        help='Run an app-hosted, hostless or same-UI-file control on an older Xcode.')
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

        other, other_path = SWIFT_TEST, TEST_FILE
        suite = UI_SUITE
        old, new = 'waitForExistence(timeout: 9)', 'waitForExistence(timeout: 10)'
        if args.control in ('swift-testing-unit', 'hostless-swift-testing-unit'):
            other = 'UnitTests/SwiftTestingUnitControl/sharingTitleIsShort()'
            other_path = 'UnitTests/ProductionTests.swift'
            suite = '''
import Testing
struct SwiftTestingUnitControl {
    @Test func sharingTitleIsShort() { #expect(sharingTitle().count < 9) }
}
'''
            old, new = 'sharingTitle().count < 9', 'sharingTitle().count < 10'
            if args.control == 'hostless-swift-testing-unit':
                # LLVM coverage installs a process initializer before test discovery.
                plan = source / 'AllTests.xctestplan'
                settings = json.loads(plan.read_bytes())
                settings['defaultOptions']['codeCoverage'] = False
                plan.write_text(json.dumps(settings))
                project = source / 'ImpactDemo.xcodeproj/project.pbxproj'
                contents = plistlib.loads(project.read_bytes())
                unit_settings, = [obj['buildSettings'] for obj in contents['objects'].values()
                                  if obj.get('buildSettings', {}).get('PRODUCT_BUNDLE_IDENTIFIER')
                                  == 'org.example.SwiftTestSelection.UnitTests']
                for key in ('TEST_HOST', 'TEST_HOST[sdk=macosx*]', 'BUNDLE_LOADER'):
                    del unit_settings[key]
                project.write_bytes(plistlib.dumps(contents, sort_keys=False))
                # A hostless bundle cannot resolve calls into the application.
                (source / other_path).write_text('''import XCTest
final class ProductionTests: XCTestCase {
    func testSharing() {}
    func testNotes() {}
}
private func sharingTitle() -> String { "Sharing" }
''')
        elif args.control == 'xctest-ui':
            other = 'CheckoutUITests/SharingUITests/testShareLink()'
            suite = ''
            old = 'func testShareLink() {\n        assertSharingScreen(timeout: 5)'
            new = old.replace('5)', '6)')
        else:
            mapping = source / '.swift-test-selection.json'
            config = json.loads(mapping.read_bytes())
            config['fixtures']['sharing'].append(other)
            mapping.write_text(json.dumps(config))

        xctest_body = 'func testShareSheet() {\n        assertSharingScreen(timeout: 5)'
        edits = {XCTEST: (TEST_FILE, xctest_body, xctest_body.replace('5)', '6)')),
                 other: (other_path, old, new)}
        original = {name: (source / name).read_text() for name in {TEST_FILE, other_path}}
        original[other_path] += suite

        def revision(edited, message):
            files = original.copy()
            for identifier in edited:
                name, before, after = edits[identifier]
                assert files[name].count(before) == 1, (name, before)
                files[name] = files[name].replace(before, after)
            for name, text in files.items():
                (source / name).write_text(text)
            return commit(message)

        run('git', 'init', '-q')
        base = revision([], 'Original tests')
        # All three bases are ancestors of the same compiled head. Each single
        # comparison differs from that head in exactly one method body.
        single_bases = {other: revision([XCTEST], 'Edit only the XCTest method'),
                        XCTEST: revision([other], 'Edit only the other method')}
        head = revision(edits, 'Edit both methods')
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
            for build_log in (retained / 'build.log', retained / 'SILCapture/build.log'):
                if not build_log.exists():
                    continue
                for line in build_log.read_text(errors='replace').splitlines():
                    if 'error:' in line:
                        print(line, file=sys.stderr)
            raise
        report = json.loads(report_file.read_bytes())
        graph_file = retained / 'head-graph.json'
        verified = json.loads(run(tool, 'verify-build', *common, '--report', report_file, '--head-graph', graph_file))
        graph = json.loads(graph_file.read_bytes())
        linked = graph['dependencies'].get('swiftTestingFactoriesByTarget') or {}
        if args.control == 'hostless-swift-testing-unit':
            assert linked.get('UnitTests'), 'Expected linked factory inventory for the hostless unit bundle'
        elif args.control == 'swift-testing-unit':
            assert 'UnitTests' not in linked, 'Unexpected closed discovery inventory for the application host'
        phases = [event['phase'] for event in report['analysisEvents']]
        assert phases.count('build') == 1 and 'compilerReplay' not in phases
        assert report['baseRevision'] == base and report['headRevision'] == graph['buildArtifact']['revision'] == head
        assert report['buildArtifactID'] == verified['buildArtifactID']
        assert report['selectedTests'] == verified['selectedTests']
        assert report['totalTests'] > 2 and report['selectedTests'] == sorted(edits), report['selectedTests']
        coverage = report['uiMappingCoverage']
        assert not any(coverage[key] for key in ['unmappedTests', 'unmatchedSelectors', 'unresolvedBoundaries']), coverage
        filters = {flag.removeprefix('-only-testing:'): flag for flag in verified['onlyTestingArguments']}
        assert set(filters) == set(verified['selectedTests'])
        executed, individual = {}, {}
        for identifier, single_base in single_bases.items():
            single_file = work / (identifier.split('/')[1] + '-' + identifier.split('/')[-1] + '.json')
            run(tool, 'select', *common, '--base', single_base, '--head', head, '--head-only', '--merge-base',
                '--head-graph', graph_file, '--format', 'json', '--output', single_file)
            single = json.loads(single_file.read_bytes())
            verified_single = json.loads(run(tool, 'verify-build', *common, '--report', single_file, '--head-graph', graph_file))
            assert single['baseRevision'] == single_base and single['headRevision'] == head
            assert single['buildArtifactID'] == verified_single['buildArtifactID'] == verified['buildArtifactID']
            positives = {entry['test'] for entry in single['explanations'] if entry['kind'] != 'fallback'}
            assert positives == {identifier}, (identifier, single['explanations'])
            expected = [identifier]
            swift_target = other.split('/', 1)[0]
            if identifier == XCTEST and args.control != 'xctest-ui' and swift_target not in linked:
                # Application and UI runner hosts can load registrations before filtering.
                discovery, = [d['fallback'] for d in single['diagnostics'] if d['code'] == 'swift_testing_discovery_effects']
                assert discovery['uncertaintyOnlyTests'] == [other] and not discovery['overlappingPositiveTests']
                expected = sorted([identifier, other])
            assert single['selectedTests'] == verified_single['selectedTests'] == expected, (identifier, single['explanations'])
            phases = [event['phase'] for event in single['analysisEvents']]
            assert 'build' not in phases and 'compilerReplay' not in phases, phases
            assert verified_single['onlyTestingArguments'] == [filters[test] for test in expected]
            assert filters[identifier] == '-only-testing:' + identifier
            individual[identifier] = dict(base=single_base, selected=expected, positives=sorted(positives), phases=phases)
            verify_binding(graph, identifier, edits[identifier][0], identifier == other and args.control != 'xctest-ui')
            print('Executing ' + ', '.join(expected), flush=True)
            bundle = single_file.with_suffix('.xcresult')
            subprocess.run(['xcodebuild', 'test-without-building', '-xctestrun', verified_single['xctestrun'],
                            '-destination', args.destination, '-parallel-testing-enabled', 'NO', *verified_single['onlyTestingArguments'],
                            '-resultBundlePath', bundle], cwd=source, check=True)
            passed = passed_cases(bundle, verified_single['selectedTests'])
            individual[identifier]['executed'] = passed
            # Keep the per-method result used by existing report readers.
            executed[identifier] = identifier.split('/', 1)[1]
        args.output.write_text(json.dumps(dict(toolchain=run('xcodebuild', '-version'),
            buildID=verified['buildArtifactID'], selectedTests=report['selectedTests'], totalTests=report['totalTests'],
            control=args.control, head=head, individual=individual, diagnostics=report['diagnostics'], executed=executed), indent=2) + '\n')


if __name__ == '__main__':
    main()
