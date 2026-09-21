// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TeamsNotifier",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "TeamsCore",
            path: "Sources/TeamsCore"
        ),
        .executableTarget(
            name: "TeamsNotifier",
            dependencies: ["TeamsCore"],
            path: "Sources/TeamsNotifier"
        ),
        .testTarget(
            name: "TeamsCoreTests",
            dependencies: ["TeamsCore"],
            path: "Tests/TeamsCoreTests"
        ),
    ]
)
