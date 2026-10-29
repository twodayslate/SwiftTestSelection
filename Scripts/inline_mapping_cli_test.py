#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Zachary Gorak
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
"""Exercise the read-only inline proposal CLI without Xcode."""
import argparse
import json
import pathlib
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--tool', type=pathlib.Path, required=True)
tool = parser.parse_args().tool.resolve(strict=True)
with tempfile.TemporaryDirectory(prefix='inline-proposal-cli-') as directory:
    root = pathlib.Path(directory)
    source = root / 'Tests.swift'
    original = b'/// Preserve docs\r\nclass Suite: XCTestCase {\r\n    // Preserve comment\r\n    func testOne() {}\r\n}\r\n'
    source.write_bytes(original)
    payload = root / 'payload.json'
    payload.write_text(json.dumps({'sources': ['App/**']}, indent=2))
    common = [str(tool), 'inline-proposal', '--source', str(source), '--module', 'UI', '--suite', 'Suite', '--method', 'testOne()', '--payload', str(payload)]
    result = subprocess.run(common, capture_output=True, text=True)
    assert result.returncode == 0, result.stderr
    proposal = json.loads(result.stdout)
    inserted = ('    ' + proposal['directive'] + '\r\n').encode()
    assert proposal['proposedSource'].encode().replace(inserted, b'') == original, proposal
    assert source.read_bytes() == original
    assert len(proposal['sourceDigest']) == 64
    output = subprocess.run([*common, '--output', str(source)], capture_output=True, text=True)
    assert output.returncode != 0 and source.read_bytes() == original
    payload.write_text('{"symbols":["App.one()"],"when":{"sourceChanged":"App/A.swift"}}')
    malformed = subprocess.run(common, capture_output=True, text=True)
    assert malformed.returncode != 0 and source.read_bytes() == original
    payload.write_text('{"when":{"all":[{"symbolChanged":"App.one()"},{"sourceChanged":"App/A.swift"}]}}')
    conditional = subprocess.run(common, capture_output=True, text=True)
    assert conditional.returncode == 0, conditional.stderr
    assert '"when"' in json.loads(conditional.stdout)['directive']
    coverage = root / 'coverage.json'
    coverage_value = dict(schemaVersion=1, validationPassed=True, diagnostics=[],
                          additions=[dict(name='shared', sources=['App/Shared.swift'], tests=['UI/Suite', 'UI/Other'])],
                          provenance=[dict(id='shared-suite-run')])
    coverage.write_text(json.dumps(coverage_value))
    coverage_args = [str(tool), 'inline-proposal', '--source', str(source), '--module', 'UI', '--suite', 'Suite', '--target', 'UI', '--coverage-proposal', str(coverage)]
    covered = subprocess.run(coverage_args, capture_output=True, text=True)
    assert covered.returncode == 0, covered.stderr
    covered_proposal = json.loads(covered.stdout)
    assert json.loads(covered_proposal['coverageProposal']) == coverage_value
    assert covered_proposal['coverageFeatures'] == ['shared']
    assert source.read_bytes() == original
    protected = subprocess.run([*coverage_args, '--output', str(coverage)], capture_output=True, text=True)
    assert protected.returncode != 0 and json.loads(coverage.read_text()) == coverage_value
print('PASS: inline CLI proposals preserve CRLF/source, reject malformed policy and never overwrite inputs')
