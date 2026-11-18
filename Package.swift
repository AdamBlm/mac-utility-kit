// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacUtilityKit",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "MacUtilityKit", targets: ["MacUtilityKit"])],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-cmark.git", exact: "0.7.0"),
    ],
    targets: [
        .target(name: "UtilityCore", dependencies: [
            .product(name: "cmark-gfm", package: "swift-cmark"),
            .product(name: "cmark-gfm-extensions", package: "swift-cmark"),
        ], resources: [.copy("Resources/confusables.txt")]),
        .executableTarget(name: "MacUtilityKit", dependencies: ["UtilityCore"]),
        .testTarget(name: "UtilityCoreTests", dependencies: ["UtilityCore"])
    ]
)
