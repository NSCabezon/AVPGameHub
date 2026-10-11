import Foundation

/// Network side of `steamdepot frame-scan` (read-only): owned apps and their raw PICS info.
public enum FrameScanFetch {
    /// licenses -> packages -> app ids -> PICS app info (raw KeyValues), no cache.
    public static func ownedAppInfo(session: SteamSession,
                                    log: @escaping @Sendable (String) -> Void = { _ in }) async throws -> [UInt32: KeyValue] {
        guard await session.isLoggedOn else { throw SteamDepotError.authFailed("not logged on") }
        await session.waitForLicenses()
        var seen = Set<UInt32>()
        let owned = await session.licenses
            .filter { $0.packageID != 0 && seen.insert($0.packageID).inserted }
            .map { (id: $0.packageID, token: $0.accessToken) }
        var appIDs: [UInt32] = []
        var seenApps = Set<UInt32>()
        for start in stride(from: 0, to: owned.count, by: SteamLibrary.packageBatch) {
            let batch = Array(owned[start..<min(start + SteamLibrary.packageBatch, owned.count)])
            let info = try await session.productInfo(packages: batch, timeout: 90)
            for p in batch {
                guard let kv = info.packages[p.id]?.kv else { continue }
                for a in SteamLibrary.appIDs(inPackage: kv) where seenApps.insert(a).inserted { appIDs.append(a) }
            }
        }
        log("\(owned.count) licenses, \(appIDs.count) apps")
        var out: [UInt32: KeyValue] = [:]
        let batches = stride(from: 0, to: appIDs.count, by: SteamLibrary.appBatch).map {
            Array(appIDs[$0..<min($0 + SteamLibrary.appBatch, appIDs.count)])
        }
        try await withThrowingTaskGroup(of: [UInt32: SteamSession.PICSItem].self) { g in
            var next = 0, done = 0
            func launch() {
                guard next < batches.count else { return }
                let b = batches[next]; next += 1
                g.addTask { try await SteamLibrary.appInfo(b, session: session, timeout: SteamLibrary.batchTimeout, log: log) }
            }
            for _ in 0..<SteamLibrary.maxInFlight { launch() }
            while let info = try await g.next() {
                for (id, item) in info { if let kv = item.kv { out[id] = kv } }
                done += 1
                if done % 10 == 0 || done == batches.count { log("app info batch \(done)/\(batches.count)") }
                launch()
            }
        }
        return out
    }

    /// PICS app info for given app ids (owned or not: depot config is public; manifests need ownership).
    public static func appInfo(session: SteamSession, apps: [UInt32],
                               log: @escaping @Sendable (String) -> Void = { _ in }) async throws -> [UInt32: KeyValue] {
        try await SteamLibrary.appInfo(apps, session: session, timeout: 60, log: log).compactMapValues(\.kv)
    }
}

// MARK: - Detection (pure)

/// Engine guessed from launch executables and depot file names.
public enum FrameEngine: String, Sendable, Codable, Hashable {
    case unityIL2CPP, unity, unreal, source2, godot, fna, unknown
}

/// Whether we already run a candidate.
public enum FrameSupport: String, Sendable, Codable, Hashable, Comparable {
    /// In the hub catalog (KleptonSteamContent.swift SteamGames: downloaded from Steam in the headset).
    case hub
    /// Klepton has a port (SupportedTitles), but not from this Steam build / not in the hub.
    case kleptonPort
    case none

    private var rank: Int { switch self { case .hub: return 0; case .kleptonPort: return 1; case .none: return 2 } }
    public static func < (a: FrameSupport, b: FrameSupport) -> Bool { a.rank < b.rank }
}

public struct FrameDepot: Sendable, Codable, Hashable {
    public enum Kind: String, Sendable, Codable, Hashable {
        /// config.oslist android (Steam Frame APK depot).
        case android
        /// Linux arm64: config.osarch arm*, known-ARM table, or arm64 binaries seen in the manifest.
        case linuxARM64
        /// Linux depot that may carry arm64 binaries next to x86_64 ones (Alyx-style; PICS can't say).
        /// Needs a manifest listing to decide.
        case linuxProbe
        /// A probed Linux depot whose manifest(s) hold no arm64 binaries.
        case linuxX86

        public var isARM: Bool { self == .android || self == .linuxARM64 }
    }
    public var depotID: UInt32
    public var kind: Kind
    public var name: String?
    /// manifests.public.size (installed bytes), nil when PICS only has the old form or no public manifest.
    public var size: UInt64?
    /// manifests.public.gid
    public var publicGID: UInt64?
    /// Every branch that has a manifest for this depot.
    public var branches: [String]
    /// Branches built after `public` and not password-protected, with their manifest gids:
    /// a Frame/arm64 build often lands on a beta branch first (e.g. FEZ "sdl3"), so a probe
    /// lists these too.
    public var newerBranchGIDs: [String: UInt64] = [:]
    /// Why the depot was flagged.
    public var reasons: [String]
    /// Filled by a manifest listing: sample of arm64 / APK paths.
    public var evidence: [String] = []
}

public struct FrameLaunch: Sendable, Codable, Hashable {
    public var executable: String
    public var type: String?
    public var oslist: String?
    public var osarch: String?
    public var betakey: String?
}

public struct FrameCandidate: Sendable, Codable, Hashable {
    public var appID: UInt32
    public var name: String
    public var type: String
    public var isVR: Bool
    /// common.steam_frame_compatibility.category (Valve's Frame rating: 1 unknown/unsupported,
    /// 2 playable, 3 verified — same scale as Deck). Present for x86 games too (Proton/FEX).
    public var frameCategory: Int?
    /// common.steam_frame_compatibility.configuration.recommended_runtime: "lepton-*" = the
    /// Android build, "native" = Linux build, "proton-*" = Windows build under emulation.
    public var frameRuntime: String?
    public var depots: [FrameDepot]
    /// Launch options that run on ARM (android / .apk / arm64 executables).
    public var launches: [FrameLaunch]
    /// App-level hints (common.oslist android, lepton runtime, ...).
    public var hints: [String]
    public var engine: FrameEngine
    public var support: FrameSupport
    public var kleptonTarget: String?

    /// PICS (or a manifest listing) proves an ARM build exists; false = only a probe target.
    public var hasARMBuild: Bool { depots.contains { $0.kind.isARM } || !hints.isEmpty || !launches.isEmpty }
    /// Bytes of the ARM depots (public manifests).
    public var armSize: UInt64 { depots.filter { $0.kind.isARM }.reduce(0) { $0 + ($1.size ?? 0) } }

    /// Rough porting effort, lower = easier: already running < Klepton port < Unity < UE / Source 2
    /// < unknown engine; within a tier, smaller builds first.
    public var effortRank: Int {
        switch support {
        case .hub: return 0
        case .kleptonPort: return 1
        case .none:
            switch engine {
            case .unityIL2CPP, .unity: return 2
            case .unreal, .source2: return 3
            case .godot, .fna: return 4
            case .unknown: return 5
            }
        }
    }

    public static func effortOrder(_ a: FrameCandidate, _ b: FrameCandidate) -> Bool {
        if a.hasARMBuild != b.hasARMBuild { return a.hasARMBuild }
        if a.effortRank != b.effortRank { return a.effortRank < b.effortRank }
        if a.armSize != b.armSize { return a.armSize < b.armSize }
        return a.appID < b.appID
    }
}

public enum FrameScan {
    /// Titles the hub app can already download and run (vendor/Klepton visionos/Sources/
    /// KleptonSteamContent.swift, SteamGames). Keep in sync by hand.
    public static let hubCatalog: [UInt32: String] = [546560: "alyx", 617830: "superhot"]

    static let skippedTypes: Set<String> = ["dlc", "music", "video", "series", "episode", "config", "advertising", "hardware"]
    static let nameHints = ["frame", "android", "arm64", "aarch64", "quest", "lepton"]

    static func csv(_ s: String?) -> [String] {
        (s ?? "").lowercased().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    static func isARMExecutable(_ exe: String) -> Bool {
        let e = exe.lowercased()
        return e.hasSuffix(".apk") || e.contains("arm64") || e.contains("aarch64") || e.contains("linuxsteamrtarm64")
    }

    /// Flag one app's ARM-runnable depots / launches from its PICS app info ("appinfo" root).
    /// nil when nothing about it points at ARM and no Linux depot is worth a manifest probe.
    ///
    /// What Valve actually publishes (seen in this account's PICS, 2026-10-11):
    /// - Frame APK builds (SUPERHOT VR, Metro Awakening): a depot with `config.oslist android`
    ///   and a launch option `executable *.apk`, `type openxr`, `config.oslist android`;
    ///   `common.oslist` gains `android`; SUPERHOT's `common.steam_frame_compatibility.
    ///   configuration.recommended_runtime` is `lepton-stable` (Metro has no Frame block).
    /// - Half-Life: Alyx's arm64 Linux build: nothing in PICS. Depot 546564 is `oslist linux`
    ///   with no osarch and the launch is `game/hlvr.sh` (picks the arch at run time); only the
    ///   manifest shows `game/bin/linuxsteamrtarm64/`.
    /// - `steam_frame_compatibility` exists for x86 games too (Proton/FEX); its category is not
    ///   an ARM signal, only `recommended_runtime lepton-*` is. `proton-*-arm64` (The Lab) is the
    ///   host arch of the emulating Proton, still a Windows x86 build.
    public static func detect(appID: UInt32, appInfo kv: KeyValue,
                              supported: [UInt32: SupportedTitle] = SupportedTitles.byAppID,
                              hub: [UInt32: String] = hubCatalog,
                              probeAllLinux: Bool = false) -> FrameCandidate? {
        guard let common = kv["common"] else { return nil }
        let type = (common["type"]?.value ?? "").lowercased()
        guard !type.isEmpty, !skippedTypes.contains(type) else { return nil }
        let isVR = SteamLibrary.isVR(kv)

        var hints: [String] = []
        if csv(common["oslist"]?.value).contains("android") { hints.append("common.oslist android") }
        let frame = common["steam_frame_compatibility"]
        let category = frame?["category"]?.value.flatMap { Int($0) }
        let runtime = frame?["configuration"]?["recommended_runtime"]?.value
        if let runtime, runtime.lowercased().hasPrefix("lepton") { hints.append("lepton runtime (\(runtime))") }

        // Launch options that run on ARM.
        var launches: [FrameLaunch] = []
        for l in kv["config"]?["launch"]?.children ?? [] {
            guard let exe = l["executable"]?.value else { continue }
            let os = l["config"]?["oslist"]?.value
            let arch = l["config"]?["osarch"]?.value
            if isARMExecutable(exe) || csv(os).contains("android") || (arch ?? "").lowercased().contains("arm") {
                launches.append(FrameLaunch(executable: exe, type: l["type"]?.value, oslist: os, osarch: arch,
                                            betakey: l["config"]?["betakey"]?.value))
            }
        }
        let frameNative = runtime?.lowercased() == "native"

        // Depots.
        var depots: [FrameDepot] = []
        for d in kv["depots"]?.children ?? [] {
            guard let id = UInt32(d.name), d.value == nil, d["depotfromapp"] == nil, d["dlcappid"] == nil else { continue }
            let config = d["config"]
            let oslist = csv(config?["oslist"]?.value)
            let osarch = (config?["osarch"]?.value ?? "").lowercased()
            let name = d["name"]?.value
            var reasons: [String] = []
            var kind: FrameDepot.Kind?
            if oslist.contains("android") { kind = .android; reasons.append("oslist android") }
            if osarch.contains("arm") || osarch.contains("aarch") {
                kind = kind ?? .linuxARM64; reasons.append("osarch \(osarch)")
            }
            if SupportedTitles.knownARM64LinuxDepots.contains(id) {
                kind = kind ?? .linuxARM64; reasons.append("known arm64 linux depot")
            }
            if let n = name?.lowercased(), let h = nameHints.first(where: { n.contains($0) }) {
                kind = kind ?? (oslist.contains("linux") ? .linuxProbe : .android)
                reasons.append("name mentions \(h)")
            }
            let branches = (d["manifests"]?.children ?? []).map(\.name)
            if kind == nil, oslist.contains("linux"), !branches.isEmpty, isVR || frameNative || probeAllLinux {
                kind = .linuxProbe
                reasons.append(isVR ? "linux depot of a VR game" : frameNative ? "Frame runtime native" : "linux depot")
            }
            guard let kind else { continue }
            var depot = FrameDepot(depotID: id, kind: kind, name: name,
                                   size: SteamLibrary.publicSize(d),
                                   publicGID: SteamDepotDownloader.manifestGID(d, branch: "public"),
                                   branches: branches, reasons: reasons)
            if kind == .linuxProbe { depot.newerBranchGIDs = newerBranches(depot: d, branches: kv["depots"]?["branches"]) }
            depots.append(depot)
        }
        depots.sort { $0.depotID < $1.depotID }
        guard !depots.isEmpty || !launches.isEmpty || !hints.isEmpty else { return nil }

        let support: FrameSupport = hub[appID] != nil ? .hub : (supported[appID] != nil ? .kleptonPort : .none)
        return FrameCandidate(appID: appID, name: common["name"]?.value ?? "App \(appID)", type: type, isVR: isVR,
                              frameCategory: category, frameRuntime: runtime, depots: depots, launches: launches,
                              hints: hints, engine: guessEngine(launches.map(\.executable)),
                              support: support, kleptonTarget: hub[appID] ?? supported[appID]?.target)
    }

    /// Non-public, non-password branches built after `public` that have a manifest for `depot`.
    static func newerBranches(depot: KeyValue, branches: KeyValue?) -> [String: UInt64] {
        func built(_ b: String) -> UInt64 { branches?[b]?["timebuildupdated"]?.value.flatMap { UInt64($0) } ?? 0 }
        let publicBuilt = built("public")
        var out: [String: UInt64] = [:]
        for m in depot["manifests"]?.children ?? [] where m.name.lowercased() != "public" {
            guard branches?[m.name]?["pwdrequired"]?.value != "1", built(m.name) > publicBuilt,
                  let gid = SteamDepotDownloader.manifestGID(depot, branch: m.name) else { continue }
            out[m.name] = gid
        }
        return out
    }

    /// Engine from file names (depot manifest paths or launch executables). APK contents are
    /// opaque without downloading, so an APK-only depot usually stays `unknown` unless its name
    /// follows UE's `<Project>-Android-Shipping` pattern.
    public static func guessEngine(_ names: [String]) -> FrameEngine {
        let l = names.map { $0.lowercased() }
        func any(_ p: (String) -> Bool) -> Bool { l.contains(where: p) }
        if any({ $0.hasSuffix("libil2cpp.so") || $0.hasSuffix("gameassembly.so") || $0.contains("/il2cpp_data/") }) { return .unityIL2CPP }
        if any({ $0.hasSuffix("libunity.so") || $0.hasSuffix("unityplayer.so") || $0.hasSuffix("unityplayer.dll")
                 || $0.contains("_data/managed/") || $0.hasSuffix("_data/globalgamemanagers") }) { return .unity }
        if any({ $0.hasSuffix("libue4.so") || $0.hasSuffix("libunreal.so") || $0.contains("-android-shipping")
                 || $0.contains("-linuxarm64-shipping") || ($0.contains("/content/paks/") && $0.hasSuffix(".pak")) }) { return .unreal }
        if any({ ($0.contains("/bin/linuxsteamrtarm64/") || $0.contains("/bin/linuxsteamrt64/") || $0.contains("/bin/win64/"))
                 && ($0.hasSuffix("/libengine2.so") || $0.hasSuffix("/engine2.dll")) }) || any({ $0.hasSuffix("_dir.vpk") }) { return .source2 }
        if any({ $0.contains("libgodot") || $0.contains("godot") && $0.hasSuffix(".so") || ($0.hasSuffix(".pck") && !$0.contains("/")) }) { return .godot }
        if any({ $0.hasSuffix("fna.dll") }) { return .fna }
        return .unknown
    }

    /// Paths in a depot file list that are an arm64 Linux / Android build: an APK at the depot
    /// root (Frame APK depots ship `shvr.apk`, `<Project>-Android-Shipping-arm64.apk` there), or
    /// files under an arm64 / aarch64 directory (game/bin/linuxsteamrtarm64/, libaarch64/,
    /// arm64-v8a/). A nested APK is a resource, not the game (SteamVR carries the Steam Link VR
    /// client at drivers/vrlink/resources/android-steamlinkvr-release.apk).
    public static func armPaths(_ names: [String]) -> [String] {
        names.filter { n in
            let l = n.lowercased()
            if l.hasSuffix(".apk") { return !l.contains("/") }
            return l.split(separator: "/").dropLast().contains { $0.contains("arm64") || $0.contains("aarch64") }
        }
    }

    /// arm64 shared libraries outside an arm64 directory, e.g. a Unity plugin folder shipping
    /// `libEOSSDK-LinuxArm64-Shipping.so` next to an x86_64-only player (Old World, 7 Days to
    /// Die). Reported, but not a build: the engine itself is not there for arm64.
    public static func strayARMLibraries(_ names: [String]) -> [String] {
        let strong = Set(armPaths(names))
        return names.filter { n in
            let l = n.lowercased()
            return !strong.contains(n) && (l.hasSuffix(".apk")
                || (l.hasSuffix(".so") || l.contains(".so.")) && (l.contains("aarch64") || l.contains("arm64")))
        }
    }

    /// Fold a depot's manifest file list into a candidate: a probed Linux depot with arm64
    /// binaries becomes `linuxARM64`; the engine guess uses the file names.
    /// A probe of `public` with no arm64 binaries turns the depot into `linuxX86` (a later
    /// branch listing can still promote it).
    public static func apply(fileNames: [String], depot: UInt32, branch: String = "public", to c: inout FrameCandidate) {
        guard let i = c.depots.firstIndex(where: { $0.depotID == depot }) else { return }
        let arm = armPaths(fileNames)
        let tag = branch == "public" ? "" : "[\(branch)] "
        c.depots[i].evidence += arm.prefix(5).map { tag + $0 }
        if arm.isEmpty { c.depots[i].evidence += strayARMLibraries(fileNames).prefix(3).map { tag + "stray: " + $0 } }
        if !arm.isEmpty, !c.depots[i].kind.isARM {
            c.depots[i].kind = .linuxARM64
            c.depots[i].reasons.append(branch == "public" ? "manifest has arm64 binaries" : "branch \(branch) manifest has arm64 binaries")
        } else if arm.isEmpty, c.depots[i].kind == .linuxProbe, branch == "public" {
            c.depots[i].kind = .linuxX86
            c.depots[i].reasons.append("manifest: no arm64 binaries")
        }
        let e = guessEngine(fileNames + c.launches.map(\.executable))
        if e != .unknown, c.engine == .unknown || c.depots[i].kind.isARM { c.engine = e }
    }
}
