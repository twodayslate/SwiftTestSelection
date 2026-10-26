// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation
import Testing
@testable import TestImpact

@Test func headerMapIdentityPreservesLookupAndNormalizesDestinations() throws {
    func map(root: String, key: String = "Demo.h", suffix: String = "Demo.h", little: Bool = true) -> Data {
        var bytes: [UInt8] = []
        func word(_ value: Int, _ count: Int = 4) {
            for index in 0..<count {
                bytes.append(UInt8(truncatingIfNeeded: value >> (8 * (little ? index : count - 1 - index))))
            }
        }
        let strings = "\0" + key + "\0" + root + "/\0" + suffix + "\0"
        word(0x686d6170); word(1, 2); word(0, 2)
        word(48); word(1); word(2); word(root.utf8.count + 1 + suffix.utf8.count)
        word(1); word(key.utf8.count + 2); word(key.utf8.count + root.utf8.count + 4)
        word(0); word(0); word(0)
        return Data(bytes + Array(strings.utf8))
    }
    func normalize(_ value: String) -> String {
        for root in ["/first/source", "/second/source"] where value.hasPrefix(root + "/") {
            return "<SOURCE>" + value.dropFirst(root.count)
        }
        return value
    }
    let original = map(root: "/first/source")
    let base = try #require(try XcodeHeaderMap.digest(original, normalize: normalize))
    #expect(try XcodeHeaderMap.digest(map(root: "/second/source", little: false), normalize: normalize) == base)
    #expect(try XcodeHeaderMap.digest(map(root: "/first/source", key: "Other.h"), normalize: normalize) != base)
    #expect(try XcodeHeaderMap.digest(map(root: "/first/source", suffix: "Other.h"), normalize: normalize) != base)
    #expect(try XcodeHeaderMap.digest(map(root: "/unknown/source"), normalize: normalize) != base)
    for length in 0..<original.count {
        #expect(try XcodeHeaderMap.digest(Data(original.prefix(length)), normalize: normalize) == nil)
    }
    for offset in [0, 4, 6, 8, 12, 16, 24, 28, 32] {
        var invalid = original
        invalid[offset] = 0xff
        #expect(try XcodeHeaderMap.digest(invalid, normalize: normalize) == nil)
    }
}
