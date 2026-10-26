#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Zachary Gorak
# SPDX-License-Identifier: AGPL-3.0-only
"""Fresh head-only fixtures: one executable build, merge-base syntax, exact retained execution.

Requires an available simulator destination. Uses no persistent analysis cache.
Output records phase timings, sampled peak disk use (one-second samples), RSS and
execution time. Run on an otherwise idle runner for comparable measurements.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import re

ROOT = Path(__file__).resolve().parents[1]
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--tool', type=Path, required=True)
p.add_argument('--destination', required=True)
p.add_argument('--output', type=Path, required=True)
p.add_argument('--keep-work', action='store_true')
p.add_argument('--execute', action='store_true', help='Execute selected, empty and full controls on exact retained products')
a = p.parse_args()
tool = a.tool.resolve(strict=True)
directory = Path(tempfile.mkdtemp(prefix='impact-head-only-')).resolve()
source = directory/'source'
results = []
print(directory, flush=True)
try:
    shutil.copytree(ROOT/'Fixtures/XcodeUITests', source)
    (source/'.gitignore').write_text('.build/\n')
    mapping_path = source/'.swift-test-selection.json'
    mapping = json.loads(mapping_path.read_text())
    mapping.update(sourceLocationPolicy='diagnosticLineColumn', runtimeDependencyPolicy='declared', ignoredDocumentation=['AGENTS.md'])
    mapping_path.write_text(json.dumps(mapping))
    (source/'AGENTS.md').write_text('Documentation\n')
    def git(*args): return subprocess.check_output(['git', *args], cwd=source, text=True).strip()
    def commit(message):
        git('add', '.')
        git('-c','user.name=Test','-c','user.email=test@example.invalid','commit','-qm',message)
        return git('rev-parse','HEAD')
    git('init','-q'); base=commit('Baseline')
    unit=source/'UnitTests/ProductionTests.swift'
    original=unit.read_text()
    unit.write_text(original.replace('XCTAssertEqual(sharingTitle(), "Sharing")', 'XCTAssertEqual(sharingTitle(), "Sharing", "changed test")'))
    method=commit('Test method edit')
    (source/'AGENTS.md').write_text('Changed documentation\n')
    unit.write_text('// comment\n'+unit.read_text())
    mixed=commit('Same edit plus comments and documentation')
    git('checkout','-q','--detach',base)
    (source/'Target.md').write_text('Advanced target\n'); target=commit('Advanced target')
    git('checkout','-q','--detach',mixed)
    ui=source/'CheckoutUITests/CheckoutUITests.swift'
    ui.write_text(ui.read_text().replace('assertSharingScreen(timeout: 5)', 'assertSharingScreen(timeout: 6)',1))
    stacked=commit('Stacked test edit')
    git('checkout','-q','--detach',base)
    production=source/'App/Sharing.swift'
    production.write_text(production.read_text().replace('sharedTitle("Sharing")','sharedTitle("Sharing") + ""'))
    body=commit('Production body')
    git('checkout','-q','--detach',base)
    unit.write_text(original.replace('    func testNotes()', '    func testAdded() { XCTAssertEqual(1, 1) }\n    func testNotes()'))
    added=commit('Add test')
    git('checkout','-q','--detach',base)
    unit.write_text('// comment only\n'+original); empty=commit('Comment only')
    wrapper=directory/'bin'; wrapper.mkdir(); calls=directory/'calls.jsonl'
    real_xcode=subprocess.check_output(['xcrun','--find','xcodebuild'],text=True).strip()
    (wrapper/'xcodebuild').write_text("#!/usr/bin/env python3\nimport json,os,sys\nwith open(os.environ['IMPACT_CALLS'],'a') as f: f.write(json.dumps(sys.argv[1:])+'\\n')\nos.execv(os.environ['IMPACT_XCODE'],[os.environ['IMPACT_XCODE'],*sys.argv[1:]])\n")
    (wrapper/'xcodebuild').chmod(0o755)
    scratch=directory/'scratch'; scratch.mkdir()
    env=dict(os.environ, TMPDIR=str(scratch), PATH=str(wrapper)+os.pathsep+os.environ['PATH'], IMPACT_CALLS=str(calls), IMPACT_XCODE=real_xcode)
    common=['--project',source/'ImpactDemo.xcodeproj','--scheme','ImpactDemo','--test-plan','AllTests','--configuration','Debug','--destination',a.destination]
    def measured(label, command):
        calls.write_text(''); start=time.monotonic(); peak=0
        log=directory/(label+'.log')
        with log.open('w') as stream:
            proc=subprocess.Popen(list(map(str,['/usr/bin/time','-l',*command])),cwd=source,env=env,stdout=stream,stderr=subprocess.STDOUT)
            while proc.poll() is None:
                peak=max(peak,int(subprocess.check_output(['du','-sk',directory],text=True).split()[0])*1024)
                time.sleep(1)
        assert proc.returncode==0,(label,log.read_text()[-6000:])
        invocations=list(map(json.loads,calls.read_text().splitlines()))
        rss=re.search(r'(\d+)\s+maximum resident set size',log.read_text())
        row=dict(case=label,seconds=time.monotonic()-start,peakWorkspaceBytes=peak,maximumResidentSetBytes=int(rss[1]) if rss else None,
                 buildCount=sum('build-for-testing' in c and '-showBuildSettings' not in c for c in invocations))
        results.append(row)
        a.output.write_text(json.dumps(dict(workspace=str(directory),analyzerSHA256=hashlib.sha256(tool.read_bytes()).hexdigest(),destination=a.destination,measurements=results),indent=2)+'\n')
        return row,invocations
    def select(label, head, base_ref=target, expected_base=base):
        bundle=directory/label; report=directory/(label+'.json')
        row,calls=measured(label,[tool,'select',*common,'--base',base_ref,'--head',head,'--merge-base','--head-only',
            '--build-time-sil',ROOT/'Scripts/capture-build.py','--retain-build',bundle,'--format','json','--output',report])
        value=json.loads(report.read_text())
        assert row['buildCount']==1 and value['baseRevision']==expected_base and value['headRevision']==head
        assert value['analysisMode']=='head-only-git-syntax'
        assert not any(e['revision']!=head and e['phase']!='baseSourceSyntax' for e in value['analysisEvents'])
        assert all(Path(c[c.index('-derivedDataPath')+1]).resolve().parent==bundle for c in calls if 'build-for-testing' in c and '-showBuildSettings' not in c)
        row.update(selectedTests=value['selectedTests'],totalTests=value['totalTests'],diagnostics=value['diagnostics'],phases=value['analysisEvents'],base=value['baseRevision'],head=head)
        print('PASS',label,len(value['selectedTests']),row['seconds'],flush=True)
        return value,bundle,report
    def execute(label, selection):
        value,bundle,report=selection
        args=[*common,'--report',report,'--head-graph',bundle/'head-graph.json']
        verified=subprocess.run(list(map(str,[tool,'verify-build',*args])),cwd=source,env=env,text=True,capture_output=True)
        assert verified.returncode==0,verified.stderr
        row,calls=measured(label,[tool,'run',*args])
        assert row['buildCount']==0
        executions=[c for c in calls if c[0]=='test-without-building']
        if value['selectedTests']:
            actual,=executions
            assert actual[actual.index('-xctestrun')+1]==json.loads(verified.stdout)['xctestrun']
            assert sorted(c.removeprefix('-only-testing:') for c in actual if c.startswith('-only-testing:'))==value['selectedTests']
        else: assert not executions
        print('PASS',label,'zero builds',flush=True)
    a.output.parent.mkdir(parents=True,exist_ok=True)
    one=select('method',method); two=select('mixed',mixed)
    expected=['UnitTests/ProductionTests/testSharing()']
    assert one[0]['selectedTests']==two[0]['selectedTests']==expected
    assert not one[0]['diagnostics'] and not two[0]['diagnostics']
    stack=select('stacked',stacked,base_ref=mixed,expected_base=mixed)
    assert stack[0]['selectedTests']==['CheckoutUITests/SharingUITests/testShareSheet()']
    prod=select('production',body)
    assert 'UnitTests/ProductionTests/testSharing()' in prod[0]['selectedTests']
    assert 0<len(prod[0]['selectedTests'])<prod[0]['totalTests']
    full=select('added',added)
    assert len(full[0]['selectedTests'])==full[0]['totalTests']==10
    assert any(d['code']=='head_only_declaration_change' for d in full[0]['diagnostics'])
    none=select('empty',empty); assert none[0]['selectedTests']==[]
    if a.execute:
        execute('method-execution',one); execute('mixed-execution',two)
        execute('production-execution',prod); execute('full-execution',full); execute('empty-execution',none)
    # Never allow a malformed report to become unrestricted execution.
    bad=directory/'bad.json';bad.write_text('{}');calls.write_text('')
    fail=subprocess.run(list(map(str,[tool,'run',*common,'--report',bad,'--head-graph',full[1]/'head-graph.json'])),cwd=source,env=env,capture_output=True)
    assert fail.returncode!=0 and not any('test-without-building' in c for c in map(json.loads,calls.read_text().splitlines()))
    # Damage each trust boundary and require failure before any test launch.
    verified=subprocess.run(list(map(str,[tool,'verify-build',*common,'--report',full[2],'--head-graph',full[1]/'head-graph.json'])),cwd=source,env=env,capture_output=True,text=True)
    assert verified.returncode==0,verified.stderr
    for label, path in [('capture',full[1]/'SILCapture/build.json'),('products',Path(json.loads(verified.stdout)['xctestrun']))]:
        original=path.read_bytes(); calls.write_text('')
        try:
            path.write_bytes(original+b'\n')
            fail=subprocess.run(list(map(str,[tool,'run',*common,'--report',full[2],'--head-graph',full[1]/'head-graph.json'])),cwd=source,env=env,capture_output=True)
            assert fail.returncode!=0
            assert not any('test-without-building' in c or 'build-for-testing' in c for c in map(json.loads,calls.read_text().splitlines()))
            results.append(dict(case=label+'-tamper',exitCode=fail.returncode,buildCount=0,testLaunchCount=0))
        finally: path.write_bytes(original)
    a.output.write_text(json.dumps(dict(workspace=str(directory),analyzerSHA256=hashlib.sha256(tool.read_bytes()).hexdigest(),destination=a.destination,measurements=results),indent=2)+'\n')
finally:
    if not a.keep_work: shutil.rmtree(directory)
