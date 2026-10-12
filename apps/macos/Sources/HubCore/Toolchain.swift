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
        PathCheck(name: "ANGLE (vendor)", relativePath: "vendor/out/xros",
                  fix: L("Compila ANGLE: `make angle-xros angle-xrsim` en Klepton (~14–20 GB, BUILDING.md)",
                         "Build ANGLE: `make angle-xros angle-xrsim` in Klepton (~14–20 GB, BUILDING.md)")),
        PathCheck(name: "ANGLE.xcframework", relativePath: "visionos/Frameworks/ANGLE_libGLESv2.xcframework",
                  fix: L("Lo crea la primera compilación del hub (`visionos/mkangle.sh`), con ANGLE ya compilado",
                         "Made by the first hub build (`visionos/mkangle.sh`) once ANGLE is built")),
    ]

    /// Whether a hub bundle id is unusable for a device build: empty, or one of the examples the
    /// docs and the placeholder row use (com.example.*, com.yourname.*). Nobody can sign for those,
    /// and the game data lives in the id's container, so it must be the user's own from the start.
    public static func isPlaceholderBundleID(_ id: String) -> Bool {
        let t = id.trimmingCharacters(in: .whitespaces).lowercased()
        return t.isEmpty || t.hasPrefix("com.example.") || t.hasPrefix("com.yourname.")
    }

    /// One game of the hub row and whether this Mac has what building it in needs
    /// (`python3 visionos/targets.py --hub-check hub`).
    public struct HubGameInput: Equatable, Sendable {
        public enum State: String, Sendable { case ok, missing, skip }
        public let game: String
        public let display: String
        public let state: State
        /// What is missing (empty when ok).
        public let missing: String
        /// How to get it (empty when ok).
        public let hint: String
    }

    /// Parses `targets.py --hub-check` lines: game, display, ok|missing|skip, what is missing, how to get it.
    public static func parseHubCheck(_ output: String) -> [HubGameInput] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 3, let state = HubGameInput.State(rawValue: f[2]) else { return nil }
            return HubGameInput(game: f[0], display: f[1], state: state,
                                missing: f.count > 3 ? f[3] : "", hint: f.count > 4 ? f[4] : "")
        }
    }

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
