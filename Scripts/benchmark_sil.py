#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Zachary Gorak
# SPDX-License-Identifier: AGPL-3.0-only
"""Release SIL regression benchmark, independent of Xcode/project builds (macOS).

Generates growing files with a constant graph, checks memory bounds, and counts
actual regex constructor calls in instrumented copies of the production sources.
No instrumentation or counters are added to the shipped library.
"""
import argparse
import json
import pathlib
import re
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
MAIN = r'''
import Foundation

enum SILBenchmark {
    nonisolated(unsafe) static var compilations = 0
    static func regex(pattern: String) throws -> NSRegularExpression {
        compilations += 1
        precondition(compilations <= 8, "SIL regexes must be compiled once, not per line")
        return try NSRegularExpression(pattern: pattern)
    }
}
let start = ContinuousClock.now
let graph = try SILParser.parse(file: URL(fileURLWithPath: CommandLine.arguments[1]),
                                module: "Bench", sourceRoot: URL(fileURLWithPath: "/project"))
let duration = start.duration(to: .now).components
let seconds = Double(duration.seconds) + Double(duration.attoseconds) / 1e18
let node = graph.functions["caller"]!
precondition(graph.functions.count == 1 && node.dependencies == ["callback"])
precondition(node.regions == [SourceRegion(path: "Sources/Shop.swift", startLine: 1, endLine: 3)])
precondition(node.dynamicDeclarations == ["Thing.run"])
precondition(graph.dispatchTargets == ["Thing.run": ["callback"]])
print("{\"seconds\":\(seconds),\"regex_compilations\":\(SILBenchmark.compilations),\"functions\":\(graph.functions.count)}")
'''
BLOCK = b'''  %0 = function_ref @callback : $@convention(thin) () -> (), loc "/project/Sources/Shop.swift":2:4
  %1 = copy_value %0 : $@convention(thin) () -> ()
  %2 = apply %1() : $@convention(thin) () -> (), loc "/project/Sources/Shop.swift":3:1
  %3 = class_method %self : $Thing, #Thing.run : $@convention(method) () -> ()
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--sizes-mib', type=int, nargs='+', default=[8, 128])
    parser.add_argument('--max-peak-mib', type=int, default=256)
    parser.add_argument('--max-growth-mib', type=int, default=64)
    parser.add_argument('--output', type=pathlib.Path)
    args = parser.parse_args()
    if not args.sizes_mib or min(args.sizes_mib) <= 0:
        parser.error('sizes must be positive')
    results = []
    with tempfile.TemporaryDirectory(prefix='sil-benchmark-') as directory:
        work = pathlib.Path(directory)
        sources = []
        for name in ['DependencyGraph.swift', 'SILParser.swift', 'SILLineReader.swift']:
            source = work / name
            source.write_text((ROOT / 'Sources/TestImpact' / name).read_text().replace(
                'NSRegularExpression(pattern:', 'SILBenchmark.regex(pattern:'))
            sources.append(str(source))
        (work / 'main.swift').write_text(MAIN)
        executable = work / 'parser'
        subprocess.run(['swiftc', '-O', '-swift-version', '6', *sources, str(work / 'main.swift'),
                        '-o', str(executable)], check=True)
        for size in sorted(args.sizes_mib):
            sil = work / 'input.sil'
            with sil.open('wb') as stream:
                stream.write(b'// caller(), loc "/project/Sources/Shop.swift":1:1\nsil hidden @caller : $@convention(thin) () -> () {\n')
                batch = BLOCK * 1024
                remaining = size * 1024 * 1024 // len(BLOCK)
                while remaining >= 1024:
                    stream.write(batch)
                    remaining -= 1024
                stream.write(BLOCK * remaining)
                stream.write(b"} // end sil function 'caller'\nsil_vtable Thing {\n #Thing.run: (Thing) -> () -> () : @callback\n}\n")
            run = subprocess.run(['/usr/bin/time', '-l', str(executable), str(sil)],
                                 capture_output=True, text=True, check=True, timeout=300)
            result = json.loads(run.stdout)
            result['input_bytes'] = sil.stat().st_size
            for label, key in [('maximum resident set size', 'peak_rss_bytes'),
                               ('peak memory footprint', 'peak_footprint_bytes')]:
                match = re.search(r'(\d+)\s+' + label, run.stderr)
                if not match:
                    raise RuntimeError('macOS /usr/bin/time metric missing: ' + label)
                result[key] = int(match[1])
            assert result['regex_compilations'] <= 8, result
            assert max(result['peak_rss_bytes'], result['peak_footprint_bytes']) <= args.max_peak_mib * 1024**2, result
            results.append(result)
            print(json.dumps(result), flush=True)
    for metric in ['peak_rss_bytes', 'peak_footprint_bytes']:
        assert max(r[metric] for r in results) - min(r[metric] for r in results) <= args.max_growth_mib * 1024**2, results
    if args.output:
        args.output.write_text(json.dumps(results, indent=2) + '\n')


if __name__ == '__main__':
    main()
