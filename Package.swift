// swift-tools-version: 6.1
import PackageDescription
import Foundation

// Distribution channel. The Mac App Store build updates only through the
// App Store and carries no external links for updates or sponsorship; the
// direct build checks GitHub releases. Pick with ARTBIP_CHANNEL=appstore|direct
// (default direct, which is also what the CLI and tests use). See
// docs/architecture.md.
let appStore = ProcessInfo.processInfo.environment["ARTBIP_CHANNEL"] == "appstore"
let channelSettings: [SwiftSetting] = [.swiftLanguageMode(.v5)]
    + (appStore ? [.define("ARTBIP_APP_STORE")] : [.define("ARTBIP_DIRECT")])

let package = Package(
    name: "artbip",
    platforms: [.macOS(.v15)],
    dependencies: [
        // 1.6.0+ assumes a Swift 6.2 standard library when compiled by a
        // 6.2+ compiler. That fails on machines whose Command Line Tools
        // compiler has updated ahead of the selected macOS SDK.
        .package(url: "https://github.com/apple/swift-argument-parser", exact: "1.5.1"),
    ],
    targets: [
        .testTarget(name: "ArtbipCoreTests", dependencies: ["ArtbipCore"],
                    swiftSettings: [.swiftLanguageMode(.v5)]),
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
            swiftSettings: channelSettings
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
