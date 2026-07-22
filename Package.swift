// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "artbip",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "ArtbipCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "artbip",
            dependencies: [
                "ArtbipCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "ArtbipApp",
            dependencies: ["ArtbipCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Dev tool: renders marketing/press images of the UI headlessly
        // (SwiftUI ImageRenderer) — not part of the shipped app.
        .executableTarget(
            name: "ArtbipShots",
            dependencies: ["ArtbipCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
