// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OmniPilot",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/stephencelis/SQLite.swift.git", from: "0.15.3"),
    ],
    targets: [
        .executableTarget(
            name: "OmniPilot",
            dependencies: [
                .product(name: "SQLite", package: "SQLite.swift"),
            ],
            path: "Sources"
        ),
        .testTarget(
            name: "MeetingsTests",
            dependencies: ["OmniPilot"],
            path: "Tests/MeetingsTests"
        ),
    ]
)
