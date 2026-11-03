// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Rounds",
    platforms: [.macOS("27.0")],
    dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1")],
    targets: [
        .target(name: "RoundsCore"),
        .executableTarget(name: "rounds-hook", dependencies: ["RoundsCore"]),
        .executableTarget(
            name: "Rounds", dependencies: ["RoundsCore", .product(name: "Sparkle", package: "Sparkle")],
            // scripts/bundle.sh puts Sparkle.framework in Contents/Frameworks.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .testTarget(name: "RoundsCoreTests", dependencies: ["RoundsCore"], resources: [.copy("Fixtures")]),
    ]
)
