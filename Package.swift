// swift-tools-version: 5.10
// UseTrack — macOS Activity Tracker

import PackageDescription

let package = Package(
    name: "UseTrack",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "UseTrackCollector", targets: ["UseTrackCollector"]),
        .executable(name: "UseTrackMenuBar", targets: ["UseTrackMenuBar"]),
    ],
    dependencies: [
        .package(url: "https://github.com/stephencelis/SQLite.swift.git", from: "0.15.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
    ],
    targets: [
        .executableTarget(
            name: "UseTrackCollector",
            dependencies: [
                .product(name: "SQLite", package: "SQLite.swift"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .executableTarget(
            name: "UseTrackMenuBar",
            dependencies: [
                .product(name: "SQLite", package: "SQLite.swift"),
            ],
            resources: [
                .copy("Resources/ECharts")
            ]
        ),
        .testTarget(
            name: "UseTrackCollectorTests",
            dependencies: ["UseTrackCollector"]
        ),
    ]
)
