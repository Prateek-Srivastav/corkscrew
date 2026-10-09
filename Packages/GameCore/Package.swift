// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "GameCore",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "GameCore", targets: ["GameCore"]),
        .executable(name: "gamecore-cli", targets: ["gamecore-cli"]),
        .executable(name: "perf-overlay", targets: ["perf-overlay"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        .target(name: "GameCore"),
        .executableTarget(
            name: "gamecore-cli",
            dependencies: ["GameCore", .product(name: "ArgumentParser", package: "swift-argument-parser")]
        ),
        .executableTarget(name: "perf-overlay", dependencies: ["GameCore"]),
        .testTarget(name: "GameCoreTests", dependencies: ["GameCore"]),
    ]
)
