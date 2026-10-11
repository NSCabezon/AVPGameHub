// swift-tools-version:6.0
//
// MetaStore: download the user's OWN purchased Quest games from Meta's store, on the
// headset (the Klepton hub), like SteamDepot does for Steam. Personal use only.
//
// Large parts are adapted from avp-play (MIT, github.com/myMartek/avp-play, commit
// 22c8fe2): see the attribution line at the top of each file.
import PackageDescription

let package = Package(
    name: "MetaStore",
    platforms: [.macOS(.v15), .visionOS(.v2)],
    products: [
        .library(name: "MetaStore", targets: ["MetaStore"]),
        .executable(name: "metastore", targets: ["MetaStoreCLI"]),
    ],
    targets: [
        .target(name: "MetaStore", swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "MetaStoreCLI", dependencies: ["MetaStore"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "MetaStoreTests", dependencies: ["MetaStore"], swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
