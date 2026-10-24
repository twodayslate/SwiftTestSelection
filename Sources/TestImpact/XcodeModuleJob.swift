// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// Cooperative cancellation stops queued extraction and drains running compiler
/// jobs before returning. It never kills a compiler while it writes output.
public final class XcodeExtractionCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    public init() {}
    public func cancel() { lock.withLock { cancelled = true } }
    public var isCancelled: Bool { lock.withLock { cancelled } }
    func check() throws {
        if isCancelled { throw ImpactError("Extraction cancelled") }
    }
}

struct XcodeModuleJob: Sendable {
    let module: String
    let compiler: String
    let arguments: [String]
}

/// Exactly one producer and consumer. The semaphore publishes the result; the
/// consumer releases the fragment as soon as its ordered merge finishes.
final class XcodeModuleResult: @unchecked Sendable {
    private let ready = DispatchSemaphore(value: 0)
    private var result: Result<(SILModule, [String]), Error>?
    func complete(_ body: () throws -> (SILModule, [String])) {
        result = Result(catching: body)
        ready.signal()
    }
    func take() throws -> (SILModule, [String]) {
        ready.wait()
        defer { result = nil }
        return try result!.get()
    }
}
