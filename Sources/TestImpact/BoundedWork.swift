// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// A fixed worker count, deterministic output ordering, and no task per input.
/// Results must be small or part of the final resident graph. Large transient
/// fragments are spooled by the extraction caller instead of accumulating here.
enum BoundedWork {
    private final class State<T: Sendable>: @unchecked Sendable {
        let lock = NSLock()
        var next = 0
        var results: [Result<T, Error>?]
        init(count: Int) { results = Array(repeating: nil, count: count) }
        func claim() -> Int? { lock.withLock {
            guard next < results.count else { return nil }
            defer { next += 1 }; return next
        } }
        func put(_ value: Result<T, Error>, at index: Int) { lock.withLock { results[index] = value } }
    }
    static func map<Input: Sendable, Output: Sendable>(_ inputs: [Input], workers: Int,
        _ transform: @escaping @Sendable (Input) throws -> Output) throws -> [Output] {
        guard !inputs.isEmpty else { return [] }
        let state = State<Output>(count: inputs.count)
        DispatchQueue.concurrentPerform(iterations: min(max(workers, 1), 8, inputs.count)) { _ in
            while let i = state.claim() {
                state.put(Result { try withSILAutoreleasePool { try transform(inputs[i]) } }, at: i)
            }
        }
        return try state.results.map { try $0!.get() }
    }
}
