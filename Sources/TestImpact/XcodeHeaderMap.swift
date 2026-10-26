// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation

enum XcodeHeaderMap {
    /// Hash the lookup table with relocated destination paths. Preserve bucket
    /// order and key spelling: both influence Clang's lookup/reverse lookup.
    /// Unknown/malformed formats retain their exact byte identity instead.
    /// Format: clang/include/clang/Lex/HeaderMapTypes.h in llvm/llvm-project.
    static func digest(_ data: Data, normalize: (String) -> String) throws -> String? {
        let bytes = [UInt8](data)
        guard bytes.count > 24 else { return nil }
        let little: Bool
        switch Array(bytes.prefix(4)) {
        case [0x70, 0x61, 0x6d, 0x68]: little = true
        case [0x68, 0x6d, 0x61, 0x70]: little = false
        default: return nil
        }
        func word(_ offset: Int, _ count: Int = 4) -> Int {
            (0..<count).reduce(0) { $0 | Int(bytes[offset + $1]) << (8 * (little ? $1 : count - 1 - $1)) }
        }
        let strings = word(8), entries = word(12), buckets = word(16)
        guard word(4, 2) == 1, word(6, 2) == 0,
              buckets > 0, buckets & (buckets - 1) == 0,
              buckets <= (bytes.count - 24) / 12, entries < buckets,
              strings >= 24 + buckets * 12, strings < bytes.count else { return nil }
        func string(_ offset: Int) -> String? {
            guard offset < bytes.count - strings else { return nil }
            let start = strings + offset
            guard let end = bytes[start...].firstIndex(of: 0) else { return nil }
            return String(bytes: bytes[start..<end], encoding: .utf8)
        }
        var table: [[String]] = []
        var found = 0
        for index in 0..<buckets {
            let offset = 24 + index * 12
            if word(offset) == 0 { table.append([]); continue }
            guard let key = string(word(offset)), !key.isEmpty,
                  let prefix = string(word(offset + 4)), let suffix = string(word(offset + 8)) else { return nil }
            table.append([key, normalize(prefix + suffix)])
            found += 1
        }
        guard found == entries else { return nil }
        return XcodeGraphCache.digest(try JSONEncoder().encode(table))
    }
}
