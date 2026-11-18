// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacUtilityKit",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "MacUtilityKit", targets: ["MacUtilityKit"])],
    targets: [
        .target(name: "UtilityCore"),
        .executableTarget(name: "MacUtilityKit", dependencies: ["UtilityCore"]),
        .testTarget(name: "UtilityCoreTests", dependencies: ["UtilityCore"])
    ]
)
