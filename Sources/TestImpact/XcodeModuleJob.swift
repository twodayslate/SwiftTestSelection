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

enum XcodeModuleFragment: Sendable {
    case memory(SILModule)
    case file(URL)
    func load() throws -> SILModule {
        switch self {
        case .memory(let module): return module
        case .file(let path): return try GraphArchive.decodeValue(SILModule.self, from: Data(contentsOf: path))
        }
    }
    func remove() { if case .file(let path) = self { try? FileManager.default.removeItem(at: path) } }
}

/// Exactly one producer and consumer. The semaphore publishes the result; the
/// consumer releases the fragment as soon as its ordered merge finishes.
final class XcodeModuleResult: @unchecked Sendable {
    private let ready = DispatchSemaphore(value: 0)
    private var result: Result<(XcodeModuleFragment, [String], Bool), Error>?
    func complete(_ body: () throws -> (XcodeModuleFragment, [String], Bool)) {
        result = Result(catching: body)
        ready.signal()
    }
    func take() throws -> (XcodeModuleFragment, [String], Bool) {
        ready.wait()
        defer { result = nil }
        return try result!.get()
    }
}

/// Cache I/O and its progress callback are serialized; compiler/parser work is not.
final class ModuleCacheAccess: @unchecked Sendable {
    let lock = NSLock()
    let cache: XcodeModuleCache?
    init(_ cache: XcodeModuleCache?) { self.cache = cache }
    func load(_ module: String) -> SILModule? { lock.withLock {
        guard let identity = cache?.identity(for: module) else { return nil }
        return try? cache?.cache.loadModule(identity, report: false)
    } }
}
