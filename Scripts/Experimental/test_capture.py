#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Zachary Gorak
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
"""Compiler integration regression for additional SIL (macOS, active Xcode)."""
import json
import os
import pathlib
import subprocess
import tempfile

HERE = pathlib.Path(__file__).parent.resolve()
compiler = subprocess.check_output(['xcrun', '--find', 'swiftc'], text=True).strip()
with tempfile.TemporaryDirectory(prefix='impact-capture-test-') as temporary:
    root = pathlib.Path(temporary).resolve()
    session = json.loads(subprocess.check_output(['python3', str(HERE / 'prepare_sil_capture.py'),
        '--compiler', compiler, '--output', str(root / 'toolchain')], text=True))
    (root / 'Model.swift').write_text('''import Foundation
var count = 0
protocol Worker { func work() -> Int }
class Base: NSObject {
    func work() -> Int { 1 }
    @objc dynamic func objectiveWork() -> Int { 2 }
    func setUp() { count += 1 }
}
class Child: Base, Worker { override func work() -> Int { 3 } }
func identity(_ value: Int) -> Int { value }
func escape() -> (Int) -> Int { identity }
func calls(_ worker: any Worker, _ object: Base, _ callback: (Int) -> Int) -> Int {
    worker.work() + object.work() + object.objectiveWork() + callback(count)
}
''')
    (root / 'Entry.swift').write_text('''@main struct Entry {
    static func main() {
        let object = Child()
        object.setUp()
        precondition(calls(object, object, escape()) == 9)
        print("execution OK")
    }
}
''')
    sources = [root / 'Model.swift', root / 'Entry.swift']
    objects = {str(source): {'object': str(source.with_suffix('.o')),
                            'dependencies': str(source.with_suffix('.d')),
                            'swift-dependencies': str(source.with_suffix('.swiftdeps'))} for source in sources}
    output_map = root / 'outputs.json'
    output_map.write_text(json.dumps(objects))
    original_map = output_map.read_bytes()
    environment = {**os.environ, **session['environment']}
    # One batch with multiple primaries: this caught silent SIL overwrites.
    command = [compiler, '-c', '-parse-as-library', '-Onone', '-g', '-enable-batch-mode',
               '-driver-batch-count', '1', '-j', '1', '-emit-dependencies',
               '-module-name', 'CaptureProbe', '-output-file-map', str(output_map), *map(str, sources)]
    subprocess.run(command + session['additionalSwiftFlags'], env=environment, check=True)
    assert output_map.read_bytes() == original_map
    manifests = [json.loads(p.read_text()) for p in (root / 'toolchain/capture').glob('*/manifest.json')]
    assert len(manifests) == 1 and manifests[0]['status'] == 'complete', manifests
    assert len(manifests[0]['silFiles']) == 2
    texts = [p.read_text() for p in (root / 'toolchain/capture').glob('*/*.sil')]
    assert all('sil_stage canonical' in text for text in texts)
    assert any('loc "' + str(sources[0]) + '"' in text for text in texts)
    assert any('loc "' + str(sources[1]) + '"' in text for text in texts)
    def code_bytes(path):
        return subprocess.check_output(['otool', '-s', '__TEXT', '__text', str(path)], text=True).splitlines()[1:]
    captured_code = [code_bytes(p.with_suffix('.o')) for p in sources]
    executable = root / 'probe'
    subprocess.run([compiler, *[str(p.with_suffix('.o')) for p in sources], '-o', str(executable)], check=True)
    assert subprocess.check_output([str(executable)], text=True).strip() == 'execution OK'
    subprocess.run(command, check=True)
    assert captured_code == [code_bytes(p.with_suffix('.o')) for p in sources], 'SIL capture changed object machine code'
    print(json.dumps({'compiler': session['compilerVersion'], 'fragments': len(texts),
                      'objectCodeIdentical': True, 'execution': 'passed', 'originalOutputMapUnchanged': True}))
