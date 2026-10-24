// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: AGPL-3.0-only

public func calculateTax(_ amount: Int) -> Int {
    amount / 10
}

public func checkout(_ amount: Int) -> Int {
    amount + calculateTax(amount)
}

public func receipt(_ amount: Int) -> String {
    "Total: \(checkout(amount))"
}
