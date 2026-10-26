// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation

// Foundation/ICU and path operations can create autoreleased objects on macOS.
// Drain once per chunk (or in-memory batch), including on throwing paths.
func withSILAutoreleasePool<T>(_ body: () throws -> T) rethrows -> T {
    #if canImport(ObjectiveC)
    return try autoreleasepool(invoking: body)
    #else
    return try body()
    #endif
}

enum SILLineReader {
    static func read(file: URL, chunkSize: Int = 64 * 1024, consume: (String) throws -> Void) throws {
        precondition(chunkSize > 0)
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var pending = Data()
        while try withSILAutoreleasePool({
            guard let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty else { return false }
            var start = chunk.startIndex
            for end in chunk.indices where chunk[end] == 10 {
                if pending.isEmpty {
                    try emit(chunk[start..<end], consume: consume)
                } else {
                    pending.append(chunk[start..<end])
                    try emit(pending, consume: consume)
                    pending.removeAll(keepingCapacity: true)
                }
                start = chunk.index(after: end)
            }
            pending.append(chunk[start...])
            return true
        }) {}
        if !pending.isEmpty { try withSILAutoreleasePool { try emit(pending, consume: consume) } }
    }

    private static func emit(_ bytes: Data, consume: (String) throws -> Void) throws {
        guard let line = String(data: bytes, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        try consume(line)
    }
}
