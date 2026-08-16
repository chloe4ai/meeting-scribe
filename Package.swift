// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MeetingScribe",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "MeetingScribe",
            path: "Sources/MeetingScribe",
            swiftSettings: [.swiftLanguageMode(.v5)],
            // Embed Info.plist into the binary as well as the bundle. TCC reads the
            // embedded copy when the executable is invoked directly rather than through
            // LaunchServices, and without it `--self-test` is killed for requesting
            // speech recognition with "no usage description".
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Resources/Info.plist",
                ])
            ]
        ),
        .testTarget(
            name: "MeetingScribeTests",
            dependencies: ["MeetingScribe"],
            path: "Tests/MeetingScribeTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
