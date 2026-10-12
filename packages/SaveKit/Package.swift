// swift-tools-version:6.0
//
// SaveKit — where each hub game keeps its saves, and the backup format shared by the Mac app
// (SaveBackupStore, devicectl copies) and the headset hub (SaveVault, iCloud Documents).
// Foundation + CryptoKit only, so it builds for both.
import PackageDescription

let package = Package(
    name: "SaveKit",
    platforms: [.macOS(.v15), .visionOS(.v2)],
    products: [
        .library(name: "SaveKit", targets: ["SaveKit"]),
    ],
    targets: [
        .target(name: "SaveKit", swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "SaveKitTests", dependencies: ["SaveKit"], swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
