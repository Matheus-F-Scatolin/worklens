// swift-tools-version:6.1
// SPDX-License-Identifier: MIT
import PackageDescription

let package = Package(
    name: "Worklens",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.11.0"),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "WorklensCore",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "Worklens",
            dependencies: [
                "WorklensCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "WorklensCoreTests",
            dependencies: ["WorklensCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
