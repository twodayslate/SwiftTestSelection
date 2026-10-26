// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation
import Testing
@testable import TestImpact

private func functionFingerprint(_ source: String, path: String = "A.swift") -> String {
    SwiftSourceSnapshot.parse(source, path: path, module: "App").units.first { $0.kind == "function" }!.fingerprint
}

@Test func locationSensitivityBelongsToTheExpression() {
    for macro in ["line", "column"] {
        let source = "func value() { print(#\(macro)) }"
        let shifted = source.replacingOccurrences(of: "print(", with: macro == "line" ? "print(\n" : "print(  ")
        #expect(functionFingerprint(source) != functionFingerprint(shifted))
    }
    for macro in ["file", "filePath", "fileID"] {
        let source = "func value() { print(#\(macro)) }"
        #expect(functionFingerprint(source) == functionFingerprint("\n\n" + source))
        #expect(functionFingerprint(source) != functionFingerprint(source, path: "B.swift"))
    }
    let fileID = "func value() { print(#fileID) }"
    #expect(functionFingerprint(fileID) == functionFingerprint(fileID, path: "Moved/A.swift"))
    let paths = "func value() { print(#filePath) }"
    #expect(functionFingerprint(paths) != functionFingerprint(paths, path: "Moved/A.swift"))
}

@Test func bareLocationDefaultsUseCallerContextButExpressionsUseDeclarationContext() {
    for macro in ["line", "column", "file", "fileID", "filePath"] {
        let source = "func value(location: Any = #\(macro)) { print(location) }"
        #expect(functionFingerprint(source) == functionFingerprint("\n    " + source, path: "B.swift"))
    }
    for expression in ["(#line)", "#line + 1"] {
        let source = "func value(location: Int = \(expression)) { print(location) }"
        #expect(functionFingerprint(source) != functionFingerprint("\n" + source))
    }
}

@Test func sourceLocationDirectivesPreservePresumedValuesAndSyntax() {
    let source = "#sourceLocation(file: \"Generated.swift\", line: 100)\nfunc value() { print(#line, #filePath) }\n#sourceLocation()"
    #expect(functionFingerprint(source) == functionFingerprint("// docs\n" + source))
    #expect(functionFingerprint(source) != functionFingerprint(source.replacingOccurrences(of: "\nfunc", with: "\n// docs\nfunc")))
    #expect(functionFingerprint(source) != functionFingerprint(source.replacingOccurrences(of: "100", with: "200")))
    #expect(functionFingerprint(source) != functionFingerprint(source.replacingOccurrences(of: "Generated.swift", with: "Other.swift")))
    let before = SwiftSourceSnapshot.parse(source, path: "A.swift", module: "App")
    let after = SwiftSourceSnapshot.parse(source.replacingOccurrences(of: "100", with: "200"), path: "A.swift", module: "App")
    #expect(before.units.filter { $0.kind != "function" }.map(\.fingerprint) != after.units.filter { $0.kind != "function" }.map(\.fingerprint))
}

@Test func documentationDetectionPreservesLiteralAndOperatorContents() {
    for (old, new) in [
        (#"func value() { print("// comment") }"#, #"func value() { print("// changed") }"#),
        (#"func value() { print(/comment/) }"#, #"func value() { print(/changed/) }"#),
        ("func value() { print(1 + 2) }", "func value() { print(1 - 2) }")
    ] { #expect(functionFingerprint(old) != functionFingerprint(new)) }
    let text = ##"func value() { print("#line /* comment */") }"##
    #expect(functionFingerprint(text) == functionFingerprint("// #line\n" + text))
}
