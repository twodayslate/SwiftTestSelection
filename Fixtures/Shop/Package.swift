// swift-tools-version: 6.0
// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import PackageDescription

let package = Package(
    name: "Shop",
    platforms: [.macOS(.v13)],
    products: [.library(name: "Shop", targets: ["Shop"])],
    targets: [
        .target(name: "Shop"),
        .testTarget(name: "ShopTests", dependencies: ["Shop"])
    ]
)
