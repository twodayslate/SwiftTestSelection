// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
import Foundation

/// A small, fail-closed proof for the SDK's nonparameterized factories. Source
/// attribute spelling and generated function names do not establish this fact.
/// Unsupported lowering, escaping arrays, and legacy captures retain fallback.
enum SwiftTestingFactoryProof {
    static func isFactory(_ symbol: String) -> Bool {
        symbol.hasPrefix("$s7Testing4TestV10__function") || symbol.hasPrefix("$s7Testing4TestV6__type")
    }

    private static let definition = try! NSRegularExpression(pattern: #"^(%\d+) = (.*)$"#)
    private static let reference = try! NSRegularExpression(pattern: #"^function_ref @([^ ]+) : "#)
    private static let application = try! NSRegularExpression(pattern: #"^apply (%\d+)(?:<(.*)>)?\((%\d+(?:, %\d+)*)\) : "#)
    private static let extraction = try! NSRegularExpression(pattern: #"^tuple_extract (%\d+), 0$"#)
    private static let value = try! NSRegularExpression(pattern: #"%\d+"#)

    static func emptyFactory(_ lines: [String]) -> String? {
        var definitions: [String: String] = [:], uses: [String: [String]] = [:]
        for line in lines {
            let instruction = line.components(separatedBy: ", loc ")[0].components(separatedBy: " // ")[0]
            let rhs: String
            if let fields = Pattern.groups(definition, in: instruction) {
                guard definitions.updateValue(fields[1], forKey: fields[0]) == nil else { return nil }
                rhs = fields[1]
            } else { rhs = instruction }
            for match in value.matches(in: rhs, range: NSRange(rhs.startIndex..., in: rhs)) {
                uses[(rhs as NSString).substring(with: match.range), default: []].append(rhs)
            }
        }
        let references = definitions.compactMapValues { Pattern.groups(reference, in: $0)?.first }
        let factories = references.filter { isFactory($0.value) }
        guard factories.count == 1, let factory = factories.first,
              let calls = uses[factory.key], calls.count == 1,
              let call = calls.first, let fields = Pattern.groups(application, in: call) else { return nil }
        let arguments = fields[2].components(separatedBy: ", ")
        // Both SDK ABIs have the same trait position. The older location-based
        // entry points are still declared in Testing's compiler interface.
        let locations = ["12sourceBounds", "14sourceLocation"]
        let suite = locations.contains { factory.value.hasPrefix("$s7Testing4TestV6__type_11displayName6traits" + $0) }
        let function = locations.contains { factory.value.hasPrefix("$s7Testing4TestV10__function5named2in02xcB18CompatibleSelector11displayName6traits" + $0 + "10parameters12testFunction") }
        guard (suite && arguments.count == 6) || (function && arguments.count == 10) else { return nil }
        // The factory must initialize the returned Test directly. A generated
        // wrapper that mutates/escapes the result may install traits afterward.
        let outputHeader = "bb0(" + arguments[0] + " : $*Test"
        func isOutputParameter(_ instruction: String) -> Bool {
            instruction.hasPrefix(outputHeader + "):") || instruction.hasPrefix(outputHeader + ", ")
        }
        guard uses[arguments[0]]?.contains(where: isOutputParameter) == true,
              uses[arguments[0]]?.allSatisfy({ $0 == call || isOutputParameter($0) }) == true else { return nil }
        let traits = arguments[suite ? 3 : 5]
        guard let extract = definitions[traits].flatMap({ Pattern.groups(extraction, in: $0) }),
              let allocation = definitions[extract[0]],
              let allocate = Pattern.groups(application, in: allocation),
              references[allocate[0]] == "$ss27_allocateUninitializedArrayySayxG_BptBwlF",
              allocate[1] == (suite ? "any SuiteTrait" : "any TestTrait"),
              definitions[allocate[2]] == "integer_literal $Builtin.Word, 0",
              uses[extract[0]] == [definitions[traits]!],
              uses[traits]?.allSatisfy({ $0 == call || $0 == "release_value " + traits || $0 == "destroy_value " + traits }) == true
        else { return nil }
        if suite { return "suite" }
        // Never is the SDK's top-level sentinel, authenticated here by both the
        // generic substitution and the actual optional metatype argument.
        if fields[1] == "Never", definitions[arguments[2]] == "enum $Optional<@thick Never.Type>, #Optional.none!enumelt" {
            return "top-level"
        }
        return "member"
    }
}
