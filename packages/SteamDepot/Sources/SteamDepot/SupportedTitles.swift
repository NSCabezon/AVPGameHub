import Foundation

/// A Steam title Klepton has a working port of.
public struct SupportedTitle: Sendable, Hashable, Codable {
    /// Klepton target name (vendor/Klepton/visionos/targets.py).
    public let target: String
    /// True when Klepton runs the build this package downloads from Steam. False when the
    /// port was made from the Quest (Meta Store) APK: owning the Steam title proves the
    /// licence, but the Steam depot is x86 or a Steam Frame Android build Klepton has not
    /// been tested with, so the APK must come from elsewhere for now.
    public let usesSteamBuild: Bool
    /// Tested manifests to fetch instead of the branch's latest. nil (every title today) =
    /// follow branch `public`, exactly as before pins existed.
    public let pinned: ManifestPins?

    public init(target: String, usesSteamBuild: Bool, pinned: ManifestPins? = nil) {
        self.target = target
        self.usesSteamBuild = usesSteamBuild
        self.pinned = pinned
    }

    /// Which manifest to fetch for `depot`: its pinned gid when this title pins it,
    /// otherwise the latest on `branch`. Pins only apply to branch `public`.
    public func manifestSelection(depot: UInt32, branch: String = "public") -> ManifestSelection {
        ManifestSelection.resolve(pins: pinned, depot: depot, branch: branch)
    }
}

/// Exact, tested depot manifests for a title, so a Steam update can't break the port.
/// Depots not listed follow branch `public`.
/// Adapted from Glovebox (MIT): GameProfile.pinnedManifests and packages/<game>/package.json
/// "steam.build" / "steam.manifests".
public struct ManifestPins: Sendable, Hashable, Codable {
    /// Steam buildid the manifests belong to (informational; PICS depots.branches.public.buildid).
    public let buildID: UInt32?
    /// depot id -> manifest gid.
    public let manifests: [UInt32: UInt64]

    public init(buildID: UInt32?, manifests: [UInt32: UInt64]) {
        self.buildID = buildID
        self.manifests = manifests
    }
}

/// Where a depot's manifest gid comes from.
public enum ManifestSelection: Sendable, Hashable {
    /// Latest manifest on this branch (read from PICS at download time).
    case branch(String)
    /// This exact manifest gid.
    case pinned(UInt64)

    public static func resolve(pins: ManifestPins?, depot: UInt32, branch: String = "public") -> ManifestSelection {
        if branch == "public", let gid = pins?.manifests[depot] { return .pinned(gid) }
        return .branch(branch)
    }

    /// The pinned gid, if any (what DepotDownloadOptions.pinnedManifestID takes).
    public var pinnedGID: UInt64? {
        if case .pinned(let gid) = self { return gid }
        return nil
    }
}

/// A pinned title compared against Steam's current public build (no download).
public struct ManifestUpdateStatus: Sendable, Hashable {
    public struct Drift: Sendable, Hashable {
        public let depotID: UInt32
        public let pinned: UInt64
        /// Latest public manifest; nil when PICS no longer lists one for the depot.
        public let latest: UInt64?
    }
    public let pinnedBuildID: UInt32?
    /// depots.branches.public.buildid from PICS.
    public let latestBuildID: UInt32?
    /// Pinned depots whose latest public manifest differs from the pin.
    public let drifted: [Drift]
    /// Steam has a newer (untested) build than the pins: an update exists but is not fetched.
    public var updateAvailable: Bool { !drifted.isEmpty }

    /// Adapted from Glovebox (MIT): SteamLauncher.needsUpdate compares installed vs planned
    /// manifests; here it is pinned vs latest public, read from an app's PICS info.
    public static func check(pins: ManifestPins, appInfo: KeyValue) -> ManifestUpdateStatus {
        let depots = appInfo["depots"]
        let drift: [Drift] = pins.manifests.keys.sorted().compactMap { id in
            let pinned = pins.manifests[id]!
            let latest = depots?[String(id)].flatMap { SteamDepotDownloader.manifestGID($0, branch: "public") }
            return latest == pinned ? nil : Drift(depotID: id, pinned: pinned, latest: latest)
        }
        let build = depots?["branches"]?["public"]?["buildid"]?.value.flatMap { UInt32($0) }
        return ManifestUpdateStatus(pinnedBuildID: pins.buildID, latestBuildID: build, drifted: drift)
    }
}

/// Steam appid -> Klepton port. Only titles whose appid was checked against PICS
/// (api.steamcmd.net) and that Klepton's README lists as working.
///
/// Left out on purpose:
/// - Engine ports (cs1, hl1, hl2, portal, vicecity, jkxr_*): community Android ports that
///   read the PC game's retail data. The Steam app is a data source, not the build
///   Klepton runs, and targets.py marks the Xash/Source ones as scaffolds that do not
///   boot yet.
/// - re4 and zix: Quest-only, not on Steam. vrchat: abandoned (anticheat).
///   steamlink-vr: not a game.
public enum SupportedTitles {
    public static let byAppID: [UInt32: SupportedTitle] = [
        // Half-Life: Alyx. The linux depot 546564 carries linuxsteamrtarm64, which
        // Klepton's glibc loader runs.
        // Not pinned yet. Example (Glovebox's tested build 25487405, from its
        // packages/alyx/package.json "steam.manifests"; adapted from Glovebox, MIT):
        //   SupportedTitle(target: "alyx", usesSteamBuild: true,
        //                  pinned: ManifestPins(buildID: 25_487_405, manifests: [
        //                      546_561: 1_436_897_171_613_240_821,   // shared content
        //                      546_564: 9_198_205_754_520_568_813,   // Linux binaries
        //                  ]))
        546560: SupportedTitle(target: "alyx", usesSteamBuild: true),
        // SUPERHOT VR: the port is translated from the Steam Frame shvr.apk (depot 617833,
        // 1.72); Meta sells a different app (1.161).
        617830: SupportedTitle(target: "superhot", usesSteamBuild: true),
        // Quest-APK ports. On Steam: Beat Saber, BONELAB, Into the Radius VR and
        // Vampire: Justice are Windows-only; Open Brush (1634874) and
        // Red Matter 2 (2081472) also ship an Android depot for Steam Frame.
        620980: SupportedTitle(target: "beatsaber", usesSteamBuild: false),
        // Metro Awakening: the Steam Frame Android depot 2669412 (APK + 14 OBBs) is the
        // build Klepton's `metro` target is translated from.
        2669410: SupportedTitle(target: "metro", usesSteamBuild: true),
        1592190: SupportedTitle(target: "bonelab", usesSteamBuild: false),
        1634870: SupportedTitle(target: "openbrush", usesSteamBuild: false),
        2081470: SupportedTitle(target: "redmatter2", usesSteamBuild: false),
        1012790: SupportedTitle(target: "intotheradius", usesSteamBuild: false),
        2431700: SupportedTitle(target: "vampire", usesSteamBuild: false),
    ]

    /// Depots whose PICS config cannot say they are ARM64 but are. Half-Life: Alyx marks
    /// 546564 only as `oslist linux` (no osarch); it holds both linuxsteamrt64 and
    /// linuxsteamrtarm64 binaries.
    public static let knownARM64LinuxDepots: Set<UInt32> = [546564]
}
