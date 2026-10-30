#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Zachary Gorak
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
"""Exercise read-only mapping maintenance, including partially stale features."""
import argparse
import json
import pathlib
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--tool', type=pathlib.Path, required=True)
tool = parser.parse_args().tool.resolve(strict=True)
with tempfile.TemporaryDirectory(prefix='mapping-review-') as directory:
    root = pathlib.Path(directory)
    graph = root / 'graph.json'
    candidate = root / 'candidate.json'
    node = dict(id='feature', module='App', name='renamed()', regions=[dict(path='App.swift', startLine=1, endLine=1)],
                dependencies=[], uncertainties=[], resolvedDynamicDeclarations=[], dynamicDeclarations=[])
    mapping = dict(version=1, features=[dict(name='feature', symbols=['App.renamed()', 'App.oldName()'], tests=['UI/Suite'])])
    graph.write_text(json.dumps(dict(schemaVersion=4, analysisKind='xcode-sil-and-ui-mappings',
        targets=[dict(name='UI', productType='com.apple.product-type.bundle.ui-testing', sourceFiles=[])],
        tests=['UI/Suite/testOne()'], diagnostics=[], sourceSnapshots={}, modules={'UI': 'UI'}, mappings=mapping,
        dependencies=dict(schemaVersion=1, toolchain='', functions={'feature': node}, tests={}, diagnostics=[], testDiagnostics={}))))
    original = graph.read_bytes()
    command = [str(tool), 'mapping-review', '--graph', str(graph)]
    result = subprocess.run(command, text=True, capture_output=True)
    assert result.returncode == 0, result.stderr
    audit = json.loads(result.stdout)
    assert not audit['current']['valid']
    assert audit['current']['rules'][0]['unresolvedEntries'] == ['symbols: App.oldName()']
    mapping['features'][0]['symbols'] = ['App.renamed()']
    candidate.write_text(json.dumps(mapping))
    proposed = candidate.read_bytes()
    result = subprocess.run(command + ['--mappings', str(candidate)], text=True, capture_output=True)
    assert result.returncode == 0, result.stderr
    review = json.loads(result.stdout)
    assert review['proposed']['valid'] and 'preview' not in review
    assert review['proposed']['rules'][0]['matchedSymbols'] == ['App.renamed()']
    assert review['proposed']['rules'][0]['tests'] == ['UI/Suite/testOne()']
    for output in [graph, candidate]:
        rejected = subprocess.run(command + ['--mappings', str(candidate), '--output', str(output)], capture_output=True)
        assert rejected.returncode != 0
    rejected = subprocess.run(command + ['--base-graph', str(graph)], capture_output=True)
    assert rejected.returncode != 0
    assert graph.read_bytes() == original and candidate.read_bytes() == proposed
    broken = json.loads(original)
    broken['mappings'] = mapping
    diagnostic = 'Swift syntax could not be parsed completely: App.swift'
    broken['sourceSnapshots'] = {'App:App.swift': dict(units=[], inheritance={}, diagnostics=[diagnostic])}
    broken_graph = root / 'broken-source.json'
    broken_graph.write_text(json.dumps(broken))
    broken_bytes = broken_graph.read_bytes()
    result = subprocess.run([str(tool), 'mapping-review', '--graph', str(broken_graph),
                             '--mappings', str(candidate)], text=True, capture_output=True)
    assert result.returncode == 0, result.stderr
    review = json.loads(result.stdout)
    for audit in [review['current'], review['proposed']]:
        assert not audit['valid']
        assert audit['errors'] == []
        assert audit['graphDiagnostics'] == [diagnostic]
    assert broken_graph.read_bytes() == broken_bytes and candidate.read_bytes() == proposed
print('PASS: mapping review finds stale entries and source failures, validates repairs, and preserves inputs')
