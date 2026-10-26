// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation
import CryptoKit
let start = ContinuousClock.now
let parsed = try SILParser.parse(file: URL(fileURLWithPath: CommandLine.arguments[1]), module: "Probe", sourceRoot: URL(fileURLWithPath: CommandLine.arguments[2]))
let duration = start.duration(to: .now).components
let seconds = Double(duration.seconds) + Double(duration.attoseconds) / 1e18
var digest = SHA256()
func add(_ value: String) { digest.update(data: Data(value.utf8)); digest.update(data: Data([0])) }
for key in parsed.functions.keys.sorted() {
 let node = parsed.functions[key]!
 add(key); add(node.module); add(node.name)
 for region in node.regions { add("r\(region.path):\(region.startLine):\(region.endLine)") }
 for edge in node.dependencies.sorted() { add("d" + edge) }
 for edge in node.dynamicDeclarations.sorted() { add("y" + edge) }
 for edge in node.uncertainties.sorted() { add("u" + edge) }
 for edge in node.resolvedDynamicDeclarations.sorted() { add("v" + edge) }
}
for key in parsed.dispatchTargets.keys.sorted() { add(key); for value in parsed.dispatchTargets[key]!.sorted() { add(value) } }
let hash = digest.finalize().map { String(format: "%02x", $0) }.joined()
print("{\"seconds\":\(seconds),\"functions\":\(parsed.functions.count),\"digest\":\"\(hash)\"}")
