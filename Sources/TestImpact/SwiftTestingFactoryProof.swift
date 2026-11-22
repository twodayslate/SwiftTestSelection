// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
import Foundation

/// Bounded SIL proofs for the SDK's test and suite factories. Source
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

    private static let existential = try! NSRegularExpression(pattern: #"^init_existential_addr (%\d+), \$([A-Za-z_][A-Za-z_0-9.]*)$"#)
    private static let store = try! NSRegularExpression(pattern: #"^store (%\d+) to (?:\[\w+\] )?(%\d+)(?: : .*|$)"#)
    private static let callee = try! NSRegularExpression(pattern: #"^apply (%\d+)(?:<.*>)?\("#)
    private static let indexAddress = try! NSRegularExpression(pattern: #"^index_addr (?:\[stack_protection\] )?(%\d+), %\d+$"#)
    private static let tailAddress = try! NSRegularExpression(pattern: #"^ref_tail_addr (%\d+), \$(any (?:SuiteTrait|TestTrait))$"#)
    private static let arrayStorage = try! NSRegularExpression(pattern: #"^(?:struct_extract|unchecked_ref_cast) (%\d+)(?:, #(?:Array\._buffer|_ArrayBuffer\._storage|_ContiguousArrayBuffer\._storage|_BridgeStorage\.rawValue)| to \$__ContiguousArrayStorageBase)$"#)
    private static let pointerAddress = try! NSRegularExpression(pattern: #"^pointer_to_address (%\d+) to (?:\[\w+\] )*\$\*(any (?:SuiteTrait|TestTrait))$"#)
    private static let dependence = try! NSRegularExpression(pattern: #"^mark_dependence (%\d+) on %\d+$"#)
    private static let nominalPath = try! NSRegularExpression(pattern: #"^[A-Za-z_][A-Za-z_0-9]*(?:\.[A-Za-z_][A-Za-z_0-9]*)*$"#)
    private static let allocateArray = "$ss27_allocateUninitializedArrayySayxG_BptBwlF"
    private static let finalizeArray = "$ss27_finalizeUninitializedArrayySayxGABnlF"

    struct Evidence {
        var nominalType: String?
        var emptyFactory: String?
        var deferredProviderCount: Int?
        var traitTypes = Set<String>()
        var traitProducers = Set<String>()
        var deferredReferences = Set<String>()
    }

    private static let closureConversion = try! NSRegularExpression(pattern: #"^(?:thin_to_thick_function |partial_apply (?:\[\w+\] )*)(%\d+)(?: to |\()"#)

    /// A function reference is deferred only if every occurrence is used solely
    /// to build a callback handed to the SDK. Captures and constructor arguments
    /// can execute user code during discovery and retain their ordinary edges.
    private static func deferredReferences(factoryCall: String, factoryCallbacks: [String], definitions: [String: String],
                                           uses: [String: [String]], references: [String: String]) -> Set<String> {
        var deferredValues = Set<String>()
        for instruction in definitions.values {
            let callbacks: [String]
            if instruction == factoryCall {
                callbacks = factoryCallbacks
            } else {
                guard let fields = Pattern.groups(application, in: instruction), let symbol = references[fields[0]],
                      symbol.hasPrefix("$s7Testing5TraitPA2A09ConditionB0VRszrlE7enabled2if_14sourceLocation") ||
                        symbol.hasPrefix("$s7Testing5TraitPA2A09ConditionB0VRszrlE8disabled2if_14sourceLocation") else { continue }
                let arguments = fields[2].components(separatedBy: ", ")
                guard arguments.count == 5 else { continue }
                callbacks = [arguments[1]]
            }
            for argument in callbacks {
                guard let conversion = definitions[argument], let closure = Pattern.groups(closureConversion, in: conversion)?.first,
                      uses[closure] == [conversion],
                      uses[argument]?.allSatisfy({ $0 == instruction || $0 == "strong_release " + argument ||
                          $0 == "release_value " + argument || $0 == "destroy_value " + argument }) == true else { continue }
                deferredValues.insert(closure)
            }
        }
        let eager = references.filter { !deferredValues.contains($0.key) }.values
        return Set(references.values).subtracting(eager)
    }

    /// Look backwards from the traits argument passed to Testing. Other arrays
    /// and existential temporaries in this factory can contain ordinary data.
    private static func collectAppliedTraits(argument: String, element: String, definitions: [String: String],
                                             uses: [String: [String]], references: [String: String], evidence: inout Evidence) {
        guard let finalize = definitions[argument].flatMap({ Pattern.groups(application, in: $0) }),
              references[finalize[0]] == finalizeArray, finalize[1] == element else { return }
        let array = finalize[2]
        guard let tuple = definitions[array].flatMap({ Pattern.groups(extraction, in: $0)?.first }),
              let allocate = definitions[tuple].flatMap({ Pattern.groups(application, in: $0) }),
              references[allocate[0]] == allocateArray, allocate[1] == element else { return }

        func isElementAddress(_ address: String) -> Bool {
            var id = address, visited = Set<String>()
            while visited.insert(id).inserted, let rhs = definitions[id] {
                if let index = Pattern.groups(indexAddress, in: rhs) {
                    id = index[0]
                } else if let tail = Pattern.groups(tailAddress, in: rhs), tail[1] == element {
                    // Swift's native Array lowering obtains its tail storage
                    // from the array (tuple element zero).
                    id = tail[0]
                    while id != array {
                        guard visited.insert(id).inserted, let projection = definitions[id],
                              let fields = Pattern.groups(arrayStorage, in: projection) else { return false }
                        id = fields[0]
                    }
                    return true
                } else if let pointer = Pattern.groups(pointerAddress, in: rhs), pointer[1] == element {
                    // Earlier toolchains use the allocation's raw pointer.
                    guard var origin = definitions[pointer[0]] else { return false }
                    if let dependent = Pattern.groups(dependence, in: origin) {
                        guard let raw = definitions[dependent[0]] else { return false }
                        origin = raw
                    }
                    return origin == "tuple_extract " + tuple + ", 1"
                } else { return false }
            }
            return false
        }
        for (slot, rhs) in definitions {
            guard let payload = Pattern.groups(existential, in: rhs), isElementAddress(payload[0]) else { continue }
            evidence.traitTypes.insert(payload[1])
            // SIL can print two distinct nominal types with the same spelling
            // even in one factory. Follow the value written to this exact slot
            // to recover its producer's module-qualified result type.
            for use in uses[slot] ?? [] {
                guard let stored = Pattern.groups(store, in: use), stored[1] == slot,
                      let value = definitions[stored[0]], let call = Pattern.groups(callee, in: value),
                      let producer = references[call[0]] else { continue }
                evidence.traitProducers.insert(producer)
            }
        }
    }

    static func analyze(_ lines: [String]) -> Evidence {
        var evidence = Evidence()
        var definitions: [String: String] = [:], uses: [String: [String]] = [:]
        for line in lines {
            let instruction = line.components(separatedBy: ", loc ")[0].components(separatedBy: ", scope ")[0].components(separatedBy: " // ")[0]
            let rhs: String
            if let fields = Pattern.groups(definition, in: instruction) {
                guard definitions.updateValue(fields[1], forKey: fields[0]) == nil else { return evidence }
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
              let call = calls.first, let fields = Pattern.groups(application, in: call) else { return evidence }
        let arguments = fields[2].components(separatedBy: ", ")
        // Both SDK ABIs have the same trait position. The older location-based
        // entry points are still declared in Testing's compiler interface.
        let locations = ["12sourceBounds", "14sourceLocation"]
        let suite = locations.contains { factory.value.hasPrefix("$s7Testing4TestV6__type_11displayName6traits" + $0) }
        let functionPrefix = "$s7Testing4TestV10__function5named2in02xcB18CompatibleSelector11displayName6traits"
        let function = locations.contains { factory.value.hasPrefix(functionPrefix + $0 + "10parameters12testFunction") }
        let parameterized = locations.contains {
            factory.value.hasPrefix(functionPrefix + "9arguments") && factory.value.contains($0 + "10parameters12testFunction")
        }
        var provenProviders: Int?
        if (function && arguments.count == 10) || (parameterized && arguments.count > 10) {
            // The argument providers follow traits. The final four operands
            // are the source location/bounds, parameters, test body, and Self.
            let callbacks = Array(arguments[6..<(arguments.count - 4)]) + [arguments[arguments.count - 2]]
            evidence.deferredReferences = deferredReferences(factoryCall: call, factoryCallbacks: callbacks,
                definitions: definitions, uses: uses, references: references)
            let providers = callbacks.dropLast()
            if parameterized && providers.allSatisfy({ argument in
                guard let conversion = definitions[argument], conversion.hasPrefix("thin_to_thick_function "),
                      let id = Pattern.groups(closureConversion, in: conversion)?.first,
                      let symbol = references[id] else { return false }
                return evidence.deferredReferences.contains(symbol)
            }) { provenProviders = providers.count }
        }
        // Parameterized overloads have additional arguments after the traits.
        let traitIndex = suite ? 3 : 5
        if (suite || factory.value.hasPrefix(functionPrefix)), arguments.indices.contains(traitIndex) {
            collectAppliedTraits(argument: arguments[traitIndex], element: suite ? "any SuiteTrait" : "any TestTrait",
                                 definitions: definitions, uses: uses, references: references, evidence: &evidence)
        }
        guard (suite && arguments.count == 6) || (function && arguments.count == 10) || provenProviders != nil else { return evidence }
        // The factory must initialize the returned Test directly. A generated
        // wrapper that mutates/escapes the result may install traits afterward.
        let outputHeader = "bb0(" + arguments[0] + " : $*Test"
        func isOutputParameter(_ instruction: String) -> Bool {
            instruction.hasPrefix(outputHeader + "):") || instruction.hasPrefix(outputHeader + ", ")
        }
        guard uses[arguments[0]]?.contains(where: isOutputParameter) == true,
              uses[arguments[0]]?.allSatisfy({ $0 == call || isOutputParameter($0) }) == true else { return evidence }
        // A nonempty traits array still permits entry-local provider edits
        // when source comparison preserves every eager trait and its location.
        if !evidence.traitTypes.isEmpty { evidence.deferredProviderCount = provenProviders }
        // Bind the actual SDK metatype operand as well as its generic substitution.
        let type = fields[1]
        if Pattern.groups(nominalPath, in: type) != nil {
            let literal = "metatype $@thick " + type + ".Type"
            if suite, definitions[arguments[1]] == literal {
                evidence.nominalType = type
            } else if function, let optional = definitions[arguments[2]] {
                let prefix = "enum $Optional<@thick " + type + ".Type>, #Optional.some!enumelt, "
                if optional.hasPrefix(prefix), definitions[String(optional.dropFirst(prefix.count))] == literal {
                    evidence.nominalType = type
                }
            }
        }
        let traits = arguments[traitIndex]
        guard let extract = definitions[traits].flatMap({ Pattern.groups(extraction, in: $0) }),
              let allocation = definitions[extract[0]],
              let allocate = Pattern.groups(application, in: allocation),
              references[allocate[0]] == allocateArray,
              allocate[1] == (suite ? "any SuiteTrait" : "any TestTrait"),
              definitions[allocate[2]] == "integer_literal $Builtin.Word, 0",
              uses[extract[0]] == [definitions[traits]!],
              uses[traits]?.allSatisfy({ $0 == call || $0 == "release_value " + traits || $0 == "destroy_value " + traits }) == true
        else { return evidence }
        // Never is the SDK's top-level sentinel, authenticated here by both the
        // generic substitution and the actual optional metatype argument.
        if let provenProviders {
            evidence.deferredProviderCount = provenProviders
        } else if suite {
            evidence.emptyFactory = "suite"
        } else if fields[1] == "Never", definitions[arguments[2]] == "enum $Optional<@thick Never.Type>, #Optional.none!enumelt" {
            evidence.emptyFactory = "top-level"
        } else {
            evidence.emptyFactory = "member"
        }
        return evidence
    }
}
