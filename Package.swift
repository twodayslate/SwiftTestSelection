// swift-tools-version: 6.0
// SPDX-FileCopyrightText: 2026 Zachary Gorak
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import PackageDescription

let package = Package(
    name: "SwiftTestSelection",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "TestImpact", targets: ["TestImpact"]),
        .executable(name: "swift-test-impact", targets: ["SwiftTestImpactCLI"])
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-syntax.git", exact: "600.0.1"),
        .package(url: "https://github.com/stencilproject/Stencil.git", exact: "0.15.1")
    ],
    targets: [
        .target(name: "CompilerIndex"),
        .target(name: "TestImpact", dependencies: [
            "CompilerIndex",
            .product(name: "SwiftParser", package: "swift-syntax"),
            .product(name: "SwiftSyntax", package: "swift-syntax"),
            .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
            .product(name: "Stencil", package: "Stencil")
        ]),
        .executableTarget(name: "SwiftTestImpactCLI", dependencies: ["TestImpact"]),
        .testTarget(name: "TestImpactTests", dependencies: ["TestImpact"])
    ]
)
