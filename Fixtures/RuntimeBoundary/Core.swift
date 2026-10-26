// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
import Foundation

public var sharedValue = 3
public var escapedCallback: () -> Int = { sharedValue }
public class ProjectBase: NSObject {
    public override init() { super.init() }
    public func value() -> Int { sharedValue }
}
public class ProjectOverride: ProjectBase {
    public override func value() -> Int { escapedCallback() }
}
extension NSObject {
    public func importedExtension() -> Int { sharedValue }
}
public struct ProjectValue: Equatable {
    public let raw: Int
    public init(_ raw: Int) { self.raw = raw }
    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.raw == rhs.raw }
}
public func compare(_ uuid: UUID?, _ date: Date?) -> Bool {
    uuid == UUID(uuidString: "00000000-0000-0000-0000-000000000000") && date == Date(timeIntervalSince1970: 0)
}
public enum CoreState: Int { case one = 1 }
public func readRaw<T: RawRepresentable>(_ value: T) -> T.RawValue { value.rawValue }
