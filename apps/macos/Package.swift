// swift-tools-version:6.0
//
// AVP Game Hub — a personal control panel for the Vision Pro hub: status, store accounts,
// games, build & install, launch & test, session stats. Wraps the same tools the CLI flow uses
// (Klepton's build_run_vpro.sh, xcrun devicectl, SteamDepot, MetaStore).
//
//   swift build                      # debug build
//   swift run AVPGameHub              # run it
//   swift test                       # HubCore tests (log parsing, session decoding, ...)
//   scripts/make-app.sh              # release build wrapped as "AVP Game Hub.app"
import PackageDescription

let package = Package(
    name: "AVPGameHub",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "AVPGameHub", targets: ["AVPGameHub"]),
        .library(name: "HubCore", targets: ["HubCore"]),
    ],
    dependencies: [
        .package(path: "../../packages/SteamDepot"),
        .package(path: "../../packages/MetaStore"),
        .package(path: "../../packages/SaveKit"),
    ],
    targets: [
        // No UI and no store code: process running, devicectl commands, log and session parsing.
        // Re-exports SaveKit (save table and backup format, shared with the headset hub).
        .target(name: "HubCore", dependencies: [.product(name: "SaveKit", package: "SaveKit")],
                swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(
            name: "AVPGameHub",
            dependencies: [
                "HubCore",
                .product(name: "SteamDepot", package: "SteamDepot"),
                .product(name: "MetaStore", package: "MetaStore"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // MetaStore only for the sign-in test against a fake ovr-platform-util (Tests/Fixtures).
        .testTarget(name: "HubCoreTests",
                    dependencies: ["HubCore", .product(name: "MetaStore", package: "MetaStore")],
                    swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
