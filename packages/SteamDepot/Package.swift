// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "SteamDepot",
    platforms: [.macOS(.v15), .visionOS(.v2)],
    products: [
        .library(name: "SteamDepot", targets: ["SteamDepot"]),
        .executable(name: "steamdepot", targets: ["SteamDepotCLI"]),
    ],
    targets: [
        // zstd v1.5.7 decompressor, vendored (BSD). Needed for "VSZa" (VZstd) depot chunks.
        .target(
            name: "CZstd",
            exclude: ["LICENSE", "README.vendored"],
            cSettings: [
                .define("ZSTD_DISABLE_ASM", to: "1"),
                .define("ZSTD_LEGACY_SUPPORT", to: "0"),
                .define("ZSTD_MULTITHREAD", to: "0"),
                .define("XXH_NAMESPACE", to: "SD_ZSTD_"),
            ]
        ),
        .target(name: "SteamDepot", dependencies: ["CZstd"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "SteamDepotCLI", dependencies: ["SteamDepot"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "SteamDepotTests", dependencies: ["SteamDepot"], swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
