// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
import Foundation

/// Positive contracts for the subset of SIL used during registration. A new
/// instruction or an opaque callee makes the shared discovery scope uncertain.
enum SwiftTestingDiscoveryEffects {
    static let serializedGetter = "$s7Testing5TraitPA2A015ParallelizationB0VRszrlE10serializedAEvgZ"

    /// These operations construct SDK metadata or native Array storage. Their
    /// arguments' producers are checked independently, including eager traits.
    static let metadataCallees: Set<String> = [
        "$sSS21_builtinStringLiteral17utf8CodeUnitCount7isASCIISSBp_BwBi1_tcfC",
        "$ss27_allocateUninitializedArrayySayxG_BptBwlF",
        "$ss27_finalizeUninitializedArrayySayxGABnlF",
        "$s7Testing14SourceLocationV17__uncheckedFileID8filePath4line6columnACSS_SSS2itcfC",
        "$s7Testing7CommentV13stringLiteralACSS_tcfC",
        "$s7Testing5TraitPA2A7CommentVRszrlE19__documentationLineyAESSFZ",
        "$s7Testing5TraitPA2A7CommentVRszrlE20__documentationBlockyAESSFZ",
        "$s7Testing5TraitPA2A7CommentVRszrlE6__lineyAESSFZ",
        "$s7Testing5TraitPA2A7CommentVRszrlE7__blockyAESSFZ",
        serializedGetter,
        "$s7Testing5TraitPA2A09ConditionB0VRszrlE7enabled2if_14sourceLocationAESbyYbKXA_AA7CommentVSgAA06SourceG0VtFZ",
        "$s7Testing5TraitPA2A09ConditionB0VRszrlE8disabled2if_14sourceLocationAESbyYbKXA_AA7CommentVSgAA06SourceG0VtFZ",
        "$s7Testing14SourceLocationV6__here6fileID0E4Path4line6columnACSS_SSS2itFZ",
        "$s7Testing14__SourceBoundsV21__uncheckedLowerBound05upperF0AcA0B8LocationV_Si4line_Si6columnttcfC",
    ]

    static func models(_ line: String, directReferences: [String: String], nilActors: inout Set<Substring>) -> Bool {
        let assignment = line.first == "%" ? line.range(of: " = ") : nil
        let instruction = assignment.map { line[$0.upperBound...] } ?? line[...]
        let opcode = instruction.prefix { $0 != " " }
        switch opcode {
        case "function_ref":
            return instruction.hasPrefix("function_ref @")
        case "apply", "partial_apply":
            var operand = instruction.dropFirst(opcode.count + 1)
            for modifier in ["[callee_guaranteed] ", "[on_stack] "] where operand.hasPrefix(modifier) {
                operand = operand.dropFirst(modifier.count)
            }
            guard operand.first == "%" else { return false }
            let end = operand.dropFirst().prefix(while: \.isNumber).endIndex
            guard end < operand.endIndex, operand[end] == "(" || operand[end] == "<" else { return false }
            return directReferences[String(operand[..<end])] != nil
        case "enum":
            if let assignment, instruction.hasPrefix("enum $Optional<any Actor>, #Optional.none!enumelt,") {
                nilActors.insert(line[..<assignment.lowerBound])
            }
            return true
        case "hop_to_executor":
            let receiver = instruction.dropFirst("hop_to_executor ".count).prefix { $0 == "%" || $0.isNumber }
            return nilActors.contains(receiver)
        case "store":
            return instruction.hasPrefix("store %") && instruction.contains(" to %")
        case "alloc_stack", "dealloc_stack", "debug_value", "debug_value_addr",
             "integer_literal", "string_literal", "float_literal", "metatype",
             "struct", "tuple", "tuple_extract", "struct_extract", "return",
             "tuple_element_addr", "init_existential_metatype", "init_enum_data_addr", "inject_enum_addr",
             "thin_to_thick_function", "strong_retain", "retain_value",
             "strong_release", "release_value", "destroy_value", "destroy_addr",
             "init_existential_addr", "index_addr", "ref_tail_addr", "pointer_to_address",
             "unchecked_ref_cast", "mark_dependence":
            return true
        default:
            // Block headers only introduce SSA parameters.
            guard line.hasPrefix("bb") else { return false }
            let suffix = line.dropFirst(2).drop(while: \.isNumber)
            return suffix.first == "(" || suffix.first == ":"
        }
    }
}
