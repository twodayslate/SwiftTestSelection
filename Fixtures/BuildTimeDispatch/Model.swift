// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: AGPL-3.0-only
import UIKit

struct Element: Equatable { var value: Int }
struct First: Equatable {
    var value: Int
    static func == (lhs: First, rhs: First) -> Bool { lhs.value == rhs.value }
}
struct Second: Equatable { var value: Int }
func concrete(_ state: UIApplication.State) -> Bool { state == .active }
func concreteContainer(_ values: [ComparisonResult], _ rhs: ComparisonResult) -> Bool { values[0] == rhs }
struct Rows: Equatable, Sequence {
    var values: [[Int]]
    static func == (lhs: Rows, rhs: Rows) -> Bool { lhs.values == rhs.values }
    func makeIterator() -> IndexingIterator<[[Int]]> { values.makeIterator() }
}
func nestedGeneric<Element: Equatable & Sequence>(_ a: Element, _ b: Element) -> Bool where Element.Element == [Int] {
    a == b
}
func generic<Element: Equatable>(_ a: Element, _ b: Element) -> Bool { a == b }
func associated<Values: Collection>(_ values: Values) -> Bool where Values.Element: Equatable {
    values.first == values.first
}
protocol Worker { func work() -> Int }
class Base: NSObject {
    func work() -> Int { 1 }
    @objc dynamic func objectiveWork() -> Int { 2 }
}
class Child: Base, Worker { override func work() -> Int { 3 } }
func protocolCall(_ worker: any Worker) -> Int { worker.work() }
func classCall(_ object: Base) -> Int { object.work() }
func objcCall(_ object: Base) -> Int { object.objectiveWork() }
func identity(_ value: Int) -> Int { value }
func escape() -> (Int) -> Int { identity }
func callbackCall(_ callback: (Int) -> Int) -> Int { callback(1) }
var shared = 0
func sharedState() -> Int { shared }
