// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Rounds",
    platforms: [.macOS("27.0")],
    targets: [
        .target(name: "RoundsCore"),
        .executableTarget(name: "rounds-hook", dependencies: ["RoundsCore"]),
        .executableTarget(name: "Rounds", dependencies: ["RoundsCore"]),
        .testTarget(name: "RoundsCoreTests", dependencies: ["RoundsCore"], resources: [.copy("Fixtures")]),
    ]
)
