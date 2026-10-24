// swift-tools-version: 6.0
// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: AGPL-3.0-only

import PackageDescription

let package = Package(
    name: "SwiftTestSelection",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "TestImpact", targets: ["TestImpact"]),
        .executable(name: "swift-test-impact", targets: ["SwiftTestImpactCLI"])
    ],
    targets: [
        .target(name: "TestImpact"),
        .executableTarget(name: "SwiftTestImpactCLI", dependencies: ["TestImpact"]),
        .testTarget(name: "TestImpactTests", dependencies: ["TestImpact"])
    ]
)
