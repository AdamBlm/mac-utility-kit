// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MacUtilityKit",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "MacUtilityKit", targets: ["MacUtilityKit"]),
        .executable(name: "muk", targets: ["MacUtilityCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle.git", exact: "2.10.1"),
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts.git", exact: "2.3.0"),
        .package(url: "https://github.com/swiftlang/swift-cmark.git", exact: "0.7.0"),
        .package(url: "https://github.com/swiftlang/swift-subprocess.git", exact: "1.0.2"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", exact: "1.8.2"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", exact: "0.12.1"),
    ],
    targets: [
        .target(name: "CSystemArchive", linkerSettings: [.linkedLibrary("archive")]),
        .target(name: "CSystemRegex", linkerSettings: [.linkedLibrary("icucore")]),
        .target(name: "UtilityCore", dependencies: [
            "CSystemRegex",
            "CSystemArchive",
            .product(name: "Subprocess", package: "swift-subprocess"),
            .product(name: "cmark-gfm", package: "swift-cmark"),
            .product(name: "cmark-gfm-extensions", package: "swift-cmark"),
        ], resources: [.copy("Resources/confusables.txt"), .copy("Resources/eff_large_wordlist.txt")]),
        .executableTarget(name: "MacUtilityKit", dependencies: [
            "UtilityCore", .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
            .product(name: "Sparkle", package: "Sparkle"),
        ], linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .executableTarget(name: "MacUtilityCLI", dependencies: [
            "UtilityCore", .product(name: "ArgumentParser", package: "swift-argument-parser"),
            .product(name: "MCP", package: "swift-sdk"),
        ]),
        .testTarget(name: "UtilityCoreTests", dependencies: ["UtilityCore"],
                    resources: [.copy("Fixtures/tagged-audio.m4a")])
    ]
)
