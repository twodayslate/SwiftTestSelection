#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Zachary Gorak
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
"""Config-free inline mapping acceptance against real Xcode build and plan discovery."""
import argparse
import json
import pathlib
import shutil
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--destination', required=True)
parser.add_argument('--tool', type=pathlib.Path, default=ROOT / '.build/debug/swift-test-impact')
options = parser.parse_args()


def run(args, cwd):
    result = subprocess.run([str(a) for a in args], cwd=cwd, text=True, capture_output=True)
    if result.returncode:
        raise AssertionError(f'{args}: {result.returncode}\n{result.stdout}\n{result.stderr}')
    return result


with tempfile.TemporaryDirectory(prefix='inline-mapping-xcode-') as directory:
    root = pathlib.Path(directory) / 'Fixture'
    shutil.copytree(ROOT / 'Fixtures/XcodeUITests', root)
    (root / '.swift-test-selection.json').unlink()
    ui = root / 'CheckoutUITests/CheckoutUITests.swift'
    text = ui.read_text()
    for declaration, payload in [
        ('final class SharingUITests:', {'sources': ['App/Sharing.swift']}),
        ('final class NotesUITests:', {'sources': ['App/Notes.swift']}),
        ('class SharedFixture:', {'symbols': ['ImpactDemo.sharingTitle()']}),
        ('    @MainActor func testStandalone()', {'sources': ['App/Common.swift']}),
        ('    @MainActor func testShareCopy()', {'symbols': ['ImpactDemo.intentionallyStaleDisabled()']}),
    ]:
        indent = '    ' if declaration.startswith('    ') else ''
        text = text.replace(declaration, indent + '// swift-test-selection: ' + json.dumps(payload) + '\n' + declaration)
    text += '\n// swift-test-selection: {"sources":["App/Notes.swift"]}\nextension NotesUITests {\n    @objc func testExtension() {}\n}\n'
    ui.write_text(text)
    plan_path = root / 'AllTests.xctestplan'
    plan = json.loads(plan_path.read_text())
    plan['testTargets'][0]['skippedTests'] = ['SharingUITests/testShareCopy()']
    plan_path.write_text(json.dumps(plan))
    for args in [['init', '-q'], ['add', '.'], ['-c', 'user.name=Test', '-c', 'user.email=test@example.invalid', 'commit', '-qm', 'Inline fixture']]:
        run(['git', *args], root)
    common = ['--project', root / 'ImpactDemo.xcodeproj', '--scheme', 'ImpactDemo', '--test-plan', 'AllTests', '--destination', options.destination]
    print('Building and discovering config-free inline fixture', flush=True)
    graph_path = pathlib.Path(directory) / 'graph.json'
    run([options.tool, 'graph', *common, '--output', graph_path], root)
    graph = json.loads(graph_path.read_text())
    assert graph.get('mappings') is None
    disabled = 'CheckoutUITests/SharingUITests/testShareCopy()'
    assert disabled not in graph['tests'], graph['tests']
    audit = json.loads(run([options.tool, 'inline-audit', '--graph', graph_path], root).stdout)
    assert not audit['diagnostics'], audit
    assert not audit['unmappedUITests'], audit
    assert all(not rule['unresolvedEntries'] for rule in audit['rules']), audit
    assert any(rule['feature']['tests'] == ['CheckoutUITests/NotesUITests/testExtension()'] for rule in audit['rules']), audit
    assert any('CheckoutUITests/InheritedUITests/testInheritedOne()' in rule['feature']['tests'] and 'ImpactDemo.sharingTitle()' in rule['feature'].get('symbols', []) for rule in audit['rules']), audit
    app = root / 'App/Sharing.swift'
    app.write_text(app.read_text().replace('sharedTitle("Sharing")', 'sharedTitle("Updated sharing")'))
    print('Selecting production change with no mapping file and strict validation', flush=True)
    report = json.loads(run([options.tool, 'select', *common, '--base', 'HEAD', '--format', 'json', '--strict-mappings'], root).stdout)
    assert disabled not in report['selectedTests']
    assert not report['uiMappingCoverage']['mappingFilePresent']
    explanations = [e for e in report['explanations'] if e['kind'] == 'explicitMapping']
    assert any(e['test'] == 'CheckoutUITests/SharingUITests/testShareSheet()' and 'CheckoutUITests.swift:' in e['reason'] for e in explanations), report
    assert any(e['test'] == 'CheckoutUITests/InheritedUITests/testInheritedOne()' for e in explanations), report
    assert not any(d['code'] in ['invalid_inline_mapping', 'missing_ui_mappings', 'unresolved_mapping_boundary'] for d in report['diagnostics']), report
    print('PASS: config-free real compiler/discovery selection, disabled-plan filtering, inheritance, extensions, strict validation and source explanations', flush=True)
