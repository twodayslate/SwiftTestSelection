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
    private static let indexAddress = try! NSRegularExpression(pattern: #"^index_addr (?:\[stack_protection\] )?(%\d+), (%\d+)$"#)
    private static let tailAddress = try! NSRegularExpression(pattern: #"^ref_tail_addr (%\d+), \$(any (?:SuiteTrait|TestTrait))$"#)
    private static let arrayStorage = try! NSRegularExpression(pattern: #"^(?:struct_extract|unchecked_ref_cast) (%\d+)(?:, #(?:Array\._buffer|_ArrayBuffer\._storage|_ContiguousArrayBuffer\._storage|_BridgeStorage\.rawValue)| to \$__ContiguousArrayStorageBase)$"#)
    private static let pointerAddress = try! NSRegularExpression(pattern: #"^pointer_to_address (%\d+) to (?:\[\w+\] )*\$\*(any (?:SuiteTrait|TestTrait))$"#)
    private static let dependence = try! NSRegularExpression(pattern: #"^mark_dependence (%\d+) on %\d+$"#)
    private static let nominalPath = try! NSRegularExpression(pattern: #"^[A-Za-z_][A-Za-z_0-9]*(?:\.[A-Za-z_][A-Za-z_0-9]*)*$"#)
    private static let allocateArray = "$ss27_allocateUninitializedArrayySayxG_BptBwlF"
    private static let finalizeArray = "$ss27_finalizeUninitializedArrayySayxGABnlF"

    struct Conditions: Codable, Equatable, Sendable {
        var traitCount = 0
        var predicates: [Int: String] = [:]
        var serializedSlots: Set<Int>?
        var commentSlots: Set<Int>?

        func matches(_ source: Conditions) -> Bool {
            traitCount >= source.traitCount && predicates == source.predicates && serializedSlots == source.serializedSlots &&
                (source.traitCount..<traitCount).allSatisfy { commentSlots?.contains($0) == true }
        }
    }

    struct Evidence {
        var verifiedFactoryCall = false
        var cleanupIsSDKMetadata = false
        var nominalType: String?
        var emptyFactory: String?
        var deferredProviderCount: Int?
        var deferredConditions: Conditions?
        var traitTypes = Set<String>()
        var traitProducers = Set<String>()
        var deferredReferences = Set<String>()
    }

    private static let closureConversion = try! NSRegularExpression(pattern: #"^(?:thin_to_thick_function |partial_apply (?:\[\w+\] )*)(%\d+)(?: to |\()"#)

    private static func conditionName(_ symbol: String) -> String? {
        let prefix = "$s7Testing5TraitPA2A09ConditionB0VRszrlE"
        if symbol.hasPrefix(prefix + "7enabled2if_14sourceLocation") { return "enabled" }
        if symbol.hasPrefix(prefix + "8disabled2if_14sourceLocation") { return "disabled" }
        return nil
    }

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
                      conditionName(symbol) != nil else { continue }
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
                                             uses: [String: [String]], references: [String: String], evidence: inout Evidence) -> Conditions? {
        guard let finalize = definitions[argument].flatMap({ Pattern.groups(application, in: $0) }),
              references[finalize[0]] == finalizeArray, finalize[1] == element else { return nil }
        let array = finalize[2]
        guard let tuple = definitions[array].flatMap({ Pattern.groups(extraction, in: $0)?.first }),
              let allocate = definitions[tuple].flatMap({ Pattern.groups(application, in: $0) }),
              references[allocate[0]] == allocateArray, allocate[1] == element else { return nil }

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
        func integerOperand(_ id: String) -> Int? {
            let prefix = "integer_literal $Builtin.Word, "
            guard let literal = definitions[id], literal.hasPrefix(prefix) else { return nil }
            return Int(literal.dropFirst(prefix.count))
        }
        func elementIndex(_ address: String) -> Int? {
            guard let rhs = definitions[address] else { return nil }
            if let index = Pattern.groups(indexAddress, in: rhs) {
                guard let base = definitions[index[0]], Pattern.groups(indexAddress, in: base) == nil else { return nil }
                return integerOperand(index[1])
            }
            return 0 // The validated tail address or allocation pointer denotes element zero.
        }
        var commentSlots = Set<Int>(), serializedSlots = Set<Int>()
        let count = integerOperand(allocate[2])
        var predicates: [Int: String] = [:]
        for (slot, rhs) in definitions {
            guard let payload = Pattern.groups(existential, in: rhs), isElementAddress(payload[0]) else { continue }
            evidence.traitTypes.insert(payload[1])
            // SIL can print two distinct nominal types with the same spelling
            // even in one factory. Follow the value written to this exact slot
            // to recover its producer's module-qualified result type.
            for use in uses[slot] ?? [] {
                // Bind the SDK's predicate to its slot in the actual traits array. The
                // remaining constructor operands are eager. Only a capture-free
                // callback used exclusively in a deferred position proves locality.
                if let count, let index = elementIndex(payload[0]), index >= 0, index < count,
                   let call = Pattern.groups(application, in: use), let symbol = references[call[0]] {
                    let operands = call[2].components(separatedBy: ", ")
                    if element == "any SuiteTrait", symbol == SwiftTestingDiscoveryEffects.serializedGetter,
                       operands.count == 2, operands[0] == slot { serializedSlots.insert(index) }
                    if operands.first == slot, payload[1] == "Comment",
                       ["19__documentationLine", "20__documentationBlock", "6__line", "7__block"].contains(where: {
                           symbol == "$s7Testing5TraitPA2A7CommentVRszrlE" + $0 + "yAESSFZ"
                       }) { commentSlots.insert(index) }
                    if let condition = conditionName(symbol), operands.count == 5, operands[0] == slot, let conversion = definitions[operands[1]],
                       conversion.hasPrefix("thin_to_thick_function "),
                       let closure = Pattern.groups(closureConversion, in: conversion)?.first,
                       let target = references[closure], evidence.deferredReferences.contains(target) {
                        predicates[index] = condition
                    }
                }
                guard let stored = Pattern.groups(store, in: use), stored[1] == slot,
                      let value = definitions[stored[0]], let call = Pattern.groups(callee, in: value),
                      let producer = references[call[0]] else { continue }
                evidence.traitProducers.insert(producer)
            }
        }
        guard let count, !predicates.isEmpty || element == "any SuiteTrait" else { return nil }
        return Conditions(traitCount: count, predicates: predicates, serializedSlots: serializedSlots.isEmpty ? nil : serializedSlots,
                          commentSlots: commentSlots.isEmpty ? nil : commentSlots)
    }

    /// An empty test record still releases strings, arrays, a source location,
    /// and a closure capturing its suite metatype. Trace each released SSA value.
    /// A captured instance, an escaping address or an unfamiliar producer keeps
    /// the ordinary ARC fallback, even when the SDK traits array is empty.
    private static func metadataCleanup(_ releases: [String], factory: String,
                                        definitions: [String: String], uses: [String: [String]],
                                        references: [String: String], header: String) -> Bool {
        func applied(_ instruction: String) -> (String, [String])? {
            guard let fields = Pattern.groups(application, in: instruction),
                  let symbol = references[fields[0]] else { return nil }
            return (symbol, fields[2].components(separatedBy: ", "))
        }
        func literalString(_ id: String) -> Bool {
            guard let definition = definitions[id], let (symbol, args) = applied(definition),
                  symbol == "$sSS21_builtinStringLiteral17utf8CodeUnitCount7isASCIISSBp_BwBi1_tcfC",
                  args.count == 4 else { return false }
            return definitions[args[0]]?.hasPrefix("string_literal ") == true
        }
        func isMetatype(_ id: String) -> Bool {
            if definitions[id]?.hasPrefix("metatype ") == true { return true }
            guard let start = (header.range(of: id + " : $@thin ") ?? header.range(of: id + " : $@thick "))?.upperBound else { return false }
            return header[start...].prefix { $0 != "," && $0 != ")" }.hasSuffix(".Type")
        }
        func locationInitializer(_ slot: String, consumer: String) -> (String, [String])? {
            let writers = (uses[slot] ?? []).filter {
                $0 != consumer && !$0.hasPrefix("destroy_addr ") && !$0.hasPrefix("dealloc_stack ") && !$0.hasPrefix("debug_value ")
            }
            guard writers.count == 1, let call = applied(writers[0]), call.1.first == slot else { return nil }
            return call
        }
        func sourceLocation(_ slot: String, consumer: String) -> Bool {
            guard definitions[slot]?.hasPrefix("alloc_stack $SourceLocation") == true,
                  let (symbol, args) = locationInitializer(slot, consumer: consumer),
                  symbol == "$s7Testing14SourceLocationV17__uncheckedFileID8filePath4line6columnACSS_SSS2itcfC", args.count == 6 else { return false }
            return literalString(args[1]) && literalString(args[2])
        }
        return releases.allSatisfy { release in
            let parts = release.split(separator: " ")
            guard parts.count >= 2, let definition = definitions[String(parts[1])] else { return false }
            let id = String(parts[1])
            if literalString(id) { return true }
            let someString = "enum $Optional<String>, #Optional.some!enumelt, "
            if definition.hasPrefix(someString), literalString(String(definition.dropFirst(someString.count))) { return true }
            if definition == "enum $Optional<String>, #Optional.none!enumelt" { return true }
            if definition.hasPrefix("thin_to_thick_function "),
               let ref = Pattern.groups(closureConversion, in: definition)?.first, references[ref] != nil { return true }
            if let extract = Pattern.groups(extraction, in: definition), let producer = definitions[extract[0]],
               let (symbol, args) = applied(producer), symbol == allocateArray, args.count == 1 {
                return definitions[args[0]] == "integer_literal $Builtin.Word, 0" && uses[extract[0]] == [definition]
            }
            if definition.hasPrefix("partial_apply "), let ref = Pattern.groups(closureConversion, in: definition)?.first,
               references[ref] != nil, let capture = definition.range(of: ref + "("),
               let end = definition[capture.upperBound...].firstIndex(of: ")") {
                let args = definition[capture.upperBound..<end]
                return args.isEmpty || args.components(separatedBy: ", ").allSatisfy(isMetatype)
            }
            if sourceLocation(id, consumer: factory) { return true }
            guard definition.hasPrefix("alloc_stack $__SourceBounds"),
                  let (symbol, args) = locationInitializer(id, consumer: factory),
                  symbol.hasPrefix("$s7Testing14__SourceBoundsV21__uncheckedLowerBound"), args.count == 5,
                  let writer = uses[id]?.first(where: { applied($0)?.0 == symbol }) else { return false }
            return sourceLocation(args[1], consumer: writer)
        }
    }

    /// In an SDK-only factory every owned operand originates here. Inputs are
    /// the output slot and (for members) the suite metatype. With just literal
    /// metadata, SDK constructors and deferred thunks there is no user value
    /// whose cleanup could dispatch. Reject additional sources of values.
    private static func constructsOnlyMetadata(header: String, definitions: [String: String],
                                               eager: Set<String>, factory: String) -> Bool {
        guard header.range(of: #"^bb0\(%\d+ : \$\*Test(?:, %\d+ : \$@(?:thin|thick) [^,()]+\.Type)?\):"#,
                           options: .regularExpression) != nil,
              eager.subtracting([factory]).isSubset(of: SwiftTestingDiscoveryEffects.metadataCallees) else { return false }
        for rhs in definitions.values {
            let opcode = rhs.prefix { $0 != " " }
            switch opcode {
            case "apply", "function_ref", "thin_to_thick_function", "partial_apply",
                 "integer_literal", "string_literal", "metatype", "init_existential_metatype",
                 "tuple_extract", "struct_extract", "ref_tail_addr", "index_addr", "tuple_element_addr",
                 "init_existential_addr", "init_enum_data_addr", "mark_dependence", "pointer_to_address":
                continue
            case "enum":
                guard rhs.hasPrefix("enum $Optional<") else { return false }
            case "struct":
                guard rhs.hasPrefix("struct $Int (") else { return false }
            case "tuple":
                guard rhs == "tuple ()" else { return false }
            case "alloc_stack":
                guard ["alloc_stack $SourceLocation", "alloc_stack $__SourceBounds", "alloc_stack $Optional<Comment>"].contains(rhs) else { return false }
            case "unchecked_ref_cast":
                guard rhs.hasSuffix(" to $__ContiguousArrayStorageBase") else { return false }
            default: return false
            }
        }
        return true
    }

    static func isCleanup(_ instruction: String) -> Bool {
        instruction.hasPrefix("strong_release ") || instruction.hasPrefix("release_value ") ||
            instruction.hasPrefix("destroy_value ") || instruction.hasPrefix("destroy_addr ") ||
            instruction.hasPrefix("unmanaged_release ") || instruction.hasPrefix("end_lifetime ")
    }

    static func analyze(_ lines: [String], modeledInstructions: Bool) -> Evidence {
        var evidence = Evidence()
        var releases: [String] = [], header = ""
        var definitions: [String: String] = [:], uses: [String: [String]] = [:]
        for line in lines {
            let instruction = line.components(separatedBy: ", loc ")[0].components(separatedBy: ", scope ")[0].components(separatedBy: " // ")[0]
            if isCleanup(instruction) { releases.append(instruction) }
            if instruction.hasPrefix("bb0(") { header = instruction }
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
        if suite && arguments.count == 6 {
            evidence.deferredReferences = deferredReferences(factoryCall: call, factoryCallbacks: [],
                definitions: definitions, uses: uses, references: references)
        }
        // Parameterized overloads have additional arguments after the traits.
        let traitIndex = suite ? 3 : 5
        var conditions: Conditions?
        if (suite || factory.value.hasPrefix(functionPrefix)), arguments.indices.contains(traitIndex) {
            conditions = collectAppliedTraits(argument: arguments[traitIndex], element: suite ? "any SuiteTrait" : "any TestTrait",
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
        evidence.verifiedFactoryCall = true
        evidence.cleanupIsSDKMetadata = metadataCleanup(releases, factory: call, definitions: definitions, uses: uses, references: references, header: header)
        if modeledInstructions && !evidence.cleanupIsSDKMetadata {
            evidence.cleanupIsSDKMetadata = constructsOnlyMetadata(header: header, definitions: definitions,
                eager: Set(references.values).subtracting(evidence.deferredReferences), factory: factory.value)
        }
        // Suite arguments are local to members only when eager construction
        // consists entirely of SDK metadata and every deferred slot is accounted for.
        let eager = Set(references.values).subtracting(evidence.deferredReferences).subtracting([factory.value])
        let pureSuite = suite && modeledInstructions && evidence.cleanupIsSDKMetadata &&
            eager.isSubset(of: SwiftTestingDiscoveryEffects.metadataCallees)
        if !suite || pureSuite { evidence.deferredConditions = conditions }
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
            if pureSuite { evidence.deferredConditions = Conditions() }
        } else if fields[1] == "Never", definitions[arguments[2]] == "enum $Optional<@thick Never.Type>, #Optional.none!enumelt" {
            evidence.emptyFactory = "top-level"
        } else {
            evidence.emptyFactory = "member"
        }
        return evidence
    }
}
