// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Scrollini",
    platforms: [
        .macOS(.v13),
    ],
    targets: [
        .executableTarget(
            name: "Scrollini",
            path: "Sources/Scrollini"
        ),
        .testTarget(
            name: "ScrolliniTests",
            dependencies: ["Scrollini"],
            path: "Tests"
        ),
    ]
)
