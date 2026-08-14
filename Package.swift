// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MeetingScribe",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "MeetingScribe",
            path: "Sources/MeetingScribe",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "MeetingScribeTests",
            dependencies: ["MeetingScribe"],
            path: "Tests/MeetingScribeTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
