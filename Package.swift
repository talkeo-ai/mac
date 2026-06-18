// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Talkeo",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Talkeo",
            path: "Sources/Talkeo"
        ),
        .testTarget(
            name: "TalkeoTests",
            dependencies: ["Talkeo"],
            path: "Tests/TalkeoTests"
        )
    ]
)
