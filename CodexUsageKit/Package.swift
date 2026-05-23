// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "CodexUsageKit",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "CodexUsageKit",
            targets: ["CodexUsageKit"]
        )
    ],
    targets: [
        .target(
            name: "CodexUsageKit",
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .testTarget(
            name: "CodexUsageKitTests",
            dependencies: ["CodexUsageKit"]
        )
    ]
)
