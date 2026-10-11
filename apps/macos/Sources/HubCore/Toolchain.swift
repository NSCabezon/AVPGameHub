import Foundation

/// Pure helpers behind the Status screen (the probing itself is in the app).
public enum Toolchain {
    /// The team id in an Apple Development certificate's subject (`OU = ABCDE12345` or
    /// `OU=ABCDE12345`), as gen_xcodeproj.py's detect_team reads it.
    public static func teamID(fromSubject subject: String) -> String? {
        Pattern(#"OU\s*=\s*([A-Z0-9]{10})"#).groups(in: subject)?.first ?? nil
    }

    /// Whether `xcodebuild -showsdks` lists a visionOS device SDK, and its version.
    public static func visionOSSDK(inShowSDKs output: String) -> String? {
        Pattern(#"-sdk xros(\d+(?:\.\d+)*)"#).groups(in: output)?.first ?? nil
    }

    public struct PathCheck: Equatable, Sendable {
        public let name: String
        public let relativePath: String
        public let fix: String
    }

    /// What the Klepton checkout must hold for `build_run_vpro.sh hub` to work.
    public static let kleptonPieces: [PathCheck] = [
        PathCheck(name: "build_run_vpro.sh", relativePath: "build_run_vpro.sh",
                  fix: L("Ruta de Klepton incorrecta (Ajustes)", "Wrong Klepton path (Settings)")),
        PathCheck(name: "targets.py", relativePath: "visionos/targets.py",
                  fix: L("Checkout de Klepton incompleto", "Incomplete Klepton checkout")),
        PathCheck(name: "vendor-moltenvk", relativePath: "vendor-moltenvk",
                  fix: L("Falta MoltenVK: `make mvk` en Klepton (BUILDING.md)", "MoltenVK missing: `make mvk` in Klepton (BUILDING.md)")),
        PathCheck(name: "MoltenVK.xcframework", relativePath: "visionos/Frameworks/MoltenVK.xcframework",
                  fix: L("`visionos/mkmvk.sh` en Klepton", "Run `visionos/mkmvk.sh` in Klepton")),
        PathCheck(name: "vendor-fossilize", relativePath: "vendor-fossilize",
                  fix: L("`make fossilize` en Klepton (BUILDING.md)", "Run `make fossilize` in Klepton (BUILDING.md)")),
        PathCheck(name: "ANGLE (vendor)", relativePath: "vendor/out",
                  fix: L("Compila ANGLE: `visionos/mkangle.sh` (BUILDING.md)", "Build ANGLE: `visionos/mkangle.sh` (BUILDING.md)")),
        PathCheck(name: "ANGLE.xcframework", relativePath: "visionos/Frameworks/ANGLE_libGLESv2.xcframework",
                  fix: L("`visionos/mkangle.sh` en Klepton", "Run `visionos/mkangle.sh` in Klepton")),
    ]

    /// First defaults for Settings, from the environment the build scripts already use.
    public static func environmentDefaults(_ env: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var out: [String: String] = [:]
        for (key, envKey) in [("kleptonPath", "KLEPTON_DIR"), ("team", "KLEPTON_TEAM"),
                              ("deviceID", "KLEPTON_DEVICE"), ("bundleID", "KLEPTON_BUNDLE_ID")] {
            if let v = env[envKey], !v.isEmpty { out[key] = v }
        }
        return out
    }

    /// `<repo>/local/config.env` (KEY=VALUE lines, `#` comments) beside a `klepton/` checkout,
    /// mapped to the Settings keys the environment fills (KLEPTON_TEAM, KLEPTON_DEVICE,
    /// KLEPTON_BUNDLE_ID). The same file the build scripts read.
    public static func localConfigDefaults(kleptonDir: URL, fileManager: FileManager = .default) -> [String: String] {
        let file = kleptonDir.deletingLastPathComponent().appendingPathComponent("local/config.env")
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [:] }
        return environmentDefaults(parseConfig(text)).filter { $0.key != "kleptonPath" }
    }

    /// KEY=VALUE lines; blank lines, `#` comments and an `export ` prefix are allowed, quotes stripped.
    public static func parseConfig(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            if line.hasPrefix("export ") { line.removeFirst("export ".count) }
            guard let e = line.firstIndex(of: "=") else { continue }
            let key = line[..<e].trimmingCharacters(in: .whitespaces)
            let val = line[line.index(after: e)...].trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if !key.isEmpty { out[key] = val }
        }
        return out
    }

    /// Walks up from `start` looking for a repo that has klepton/ (the AVP Game Hub layout) or
    /// vendor/Klepton, so a checkout works without configuring anything.
    public static func findKlepton(from start: URL, fileManager: FileManager = .default) -> URL? {
        var dir = start.standardizedFileURL
        for _ in 0..<12 {
            for sub in ["klepton", "vendor/Klepton"] {
                let candidate = dir.appendingPathComponent(sub)
                if fileManager.fileExists(atPath: candidate.appendingPathComponent("build_run_vpro.sh").path) { return candidate }
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        return nil
    }
}
