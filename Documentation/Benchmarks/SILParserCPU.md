# SIL parser CPU investigation

Release profiles on real ChainOfCustody SIL repeatedly entered Foundation's `StringProtocol.contains` for ASCII instruction markers. The parser invoked that Unicode search repeatedly on each line. The candidate scans UTF-8 for fixed ASCII markers and trims ordinary SIL whitespace without Foundation, retaining Foundation behavior at Unicode boundaries. It preserves the existing regular expressions, streaming reader, bounded path cache and autorelease scopes.

## Measurements

Apple M5, 32 GiB, macOS 26.6.1; analyzer built with Xcode 26.6 / Swift 6.3.3. Input: a complete 150,077,071-byte (143.1 MiB) `ChainOfCustodyTests` SIL fragment, 13,609 functions, from consumer revision `1f0e37b69458200227c584d9a4563b5391948cdf`, compiled by Xcode 27.0. The input SHA-256 and raw measurements are in [SILParserCPU.json](SILParserCPU.json).

| Parser | Run 1 | Run 2 | Run 3 |
| --- | ---: | ---: | ---: |
| Reference | 22.359 s | 23.227 s | 23.998 s |
| Candidate | 5.870 s | 5.810 s | 5.722 s |

Median throughput increases from 6.46 MB/s to 25.83 MB/s (about 4×). Peak physical footprint was about 25.0 MiB for both; peak RSS was about 29.0 MiB versus 29.5 MiB. The CPU gain does not depend on retaining more input. Runs alternate in one release harness, and compilation/digest verification are outside the timed parse. Another local selection-validation process overlapped, so these are not controlled CI throughput guarantees.

One-second `sample` traces on separate, untimed parser processes showed repeated Foundation substring search in the reference; the candidate trace no longer contained that stack, and regex matching/location decoding became more prominent. Live `heap --noContent -s` snapshots were dominated by Swift string, dictionary and set storage used by the graph. They were taken at equal wall-clock offsets, not equal parsing progress, and are not allocation-rate comparisons. No memory-reduction claim is made from them. The timed whole-process peaks and the existing growing-input benchmark are the memory regression checks.

The 8/128 MiB constant-graph benchmark still compiled exactly eight regexes and stayed below 3 MiB peak footprint (under 8 MiB RSS), with no growth proportional to SIL size. The regular expressions remain shared and compiled once.

## Correctness and reproduction

The digest covers every function's ID, module, name, regions, dependencies, dynamic declarations, resolved declarations and uncertainty set, plus all dispatch-table entries. All six measured runs match. A separate comparison also matched every node field and dispatch entry across all 414 consumer fragments (1,404,070,178 bytes). Identical parser outputs preserve the downstream selection inputs. All 83 package tests pass. Existing tests cover streamed UTF-8 boundaries, CRLF, long lines, malformed UTF-8, callbacks/conversions and dispatch; additional coverage exercises Unicode edge whitespace, escaped Unicode paths, invalid/overflowing line numbers and function-value conversions.

```sh
python3 Scripts/benchmark_sil_compare.py \
  --input /absolute/path/module.sil --source-root /absolute/path/project \
  --reference ee2fa9c30b3e68661f05ce2b9aecc0b769005da3 --runs 3 --output /tmp/parser-comparison.json
python3 Scripts/benchmark_sil.py --output /tmp/parser-memory.json
swift test
```

The comparison script compiles reference sources from the requested Git revision and candidate sources from the working tree. It requires saved SIL but no project rebuild. Raw consumer source/SIL and local process dumps are not checked in.
