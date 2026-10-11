import Foundation

/// Whether an owned game can run under Klepton on Apple Vision Pro (ARM64 only).
public enum LibraryStatus: String, Sendable, Codable, Comparable, CaseIterable {
    /// Klepton has a port (SupportedTitles).
    case playable
    /// Ships an ARM64 build (Android depot or arm64 Linux) but has no port yet.
    case candidate
    /// x86 only.
    case unsupported

    private var rank: Int {
        switch self { case .playable: return 0; case .candidate: return 1; case .unsupported: return 2 }
    }
    public static func < (a: LibraryStatus, b: LibraryStatus) -> Bool { a.rank < b.rank }
}

public struct ARMDepot: Sendable, Hashable, Codable {
    public enum Kind: String, Sendable, Codable { case android, linuxARM64 }
    public let depotID: UInt32
    public let kind: Kind
    /// Installed size of the public manifest, when PICS reports it.
    public let size: UInt64?
}

public struct LibraryEntry: Sendable, Hashable, Codable, Identifiable {
    public var id: UInt32 { appID }
    public let appID: UInt32
    public let name: String
    public let status: LibraryStatus
    /// Klepton target for `playable` titles.
    public let kleptonTarget: String?
    /// False when the port runs the Quest APK rather than a Steam depot (see SupportedTitle).
    public let portUsesSteamBuild: Bool?
    public let armDepots: [ARMDepot]
    public let isVR: Bool
    public let headerImageURL: URL

    /// Library order: playable, candidate, unsupported, then name.
    public static func libraryOrder(_ a: LibraryEntry, _ b: LibraryEntry) -> Bool {
        if a.status != b.status { return a.status < b.status }
        let c = a.name.localizedCaseInsensitiveCompare(b.name)
        return c == .orderedSame ? a.appID < b.appID : c == .orderedAscending
    }
}

extension LibraryEntry {
    /// The same facts with `status` / port fields recomputed against a supported-titles table.
    public func applying(_ supported: [UInt32: SupportedTitle]) -> LibraryEntry {
        let port = supported[appID]
        return LibraryEntry(appID: appID, name: name,
                            status: port != nil ? .playable : (armDepots.isEmpty ? .unsupported : .candidate),
                            kleptonTarget: port?.target, portUsesSteamBuild: port?.usesSteamBuild,
                            armDepots: armDepots, isVR: isVR, headerImageURL: headerImageURL)
    }
}

/// On-disk cache of the library: per package its app ids, per app its classification (nil =
/// not a game), each keyed by the PICS change number it was read at. Entries are stored
/// without the supported-titles table applied, so editing that table never needs a refetch.
public struct LibraryCache: Codable, Sendable {
    /// Bump when classify() or the known-ARM depot table changes, to drop old classifications.
    public static let currentVersion = 1

    public struct Package: Codable, Sendable { public var changeNumber: UInt32; public var appIDs: [UInt32] }
    public struct App: Codable, Sendable { public var changeNumber: UInt32; public var entry: LibraryEntry? }

    public var version = LibraryCache.currentVersion
    public var steamID: UInt64
    /// Steam-wide PICS change number read before this cache's fetch started.
    public var changeNumber: UInt32
    public var packages: [UInt32: Package] = [:]
    public var apps: [UInt32: App] = [:]

    static func load(_ url: URL, steamID: UInt64) -> LibraryCache? {
        guard let data = try? Data(contentsOf: url),
              let c = try? JSONDecoder().decode(LibraryCache.self, from: data),
              c.version == currentVersion, c.steamID == steamID else { return nil }
        return c
    }

    func save(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
}

/// The logged-on account's games, classified for Klepton.
public enum SteamLibrary {
    static let packageBatch = 200
    /// Apps per PICS request and requests in flight. App info averages ~8 KB per app; Steam
    /// splits responses over ~256 KB into several packets, which productInfo collects.
    static let appBatch = 50
    static let maxInFlight = 4
    static let batchTimeout: TimeInterval = 30

    /// licenses -> PICS package info -> appids -> PICS app info -> classified games, sorted
    /// with `LibraryEntry.libraryOrder`. The session must be logged on.
    ///
    /// With `cacheURL`, only packages and apps that changed since the cached run are refetched.
    /// Change detection is one ClientPICSChangesSince request (what SteamKit-based tools such as
    /// SteamDB's updater use): Steam lists every app/package whose change number moved since
    /// ours. If our number is too old for that list (`force_full_*_update`), we fall back to a
    /// metadata-only PICS request for the owned items (change numbers, no buffers) and compare.
    public static func fetch(session: SteamSession,
                             supported: [UInt32: SupportedTitle] = SupportedTitles.byAppID,
                             cacheURL: URL? = nil,
                             log: @escaping @Sendable (String) -> Void = { _ in }) async throws -> [LibraryEntry] {
        guard await session.isLoggedOn else { throw SteamDepotError.authFailed("not logged on") }
        let started = Date()
        await session.waitForLicenses()
        let steamID = await session.steamID
        let cache = cacheURL.flatMap { LibraryCache.load($0, steamID: steamID) }

        // 1. What changed since the cached run (nil = unknown, verify each cached item).
        var changedApps: Set<UInt32>?
        var changedPackages: Set<UInt32>?
        var current: UInt32 = 0
        if let cache, cache.changeNumber > 0 {
            do {
                let ch = try await session.picsChanges(since: cache.changeNumber)
                current = ch.currentChangeNumber
                if !ch.fullAppUpdate { changedApps = Set(ch.apps.keys) }
                if !ch.fullPackageUpdate { changedPackages = Set(ch.packages.keys) }
                log("PICS changes since \(cache.changeNumber): \(ch.apps.count) apps, \(ch.packages.count) packages"
                    + (ch.fullAppUpdate || ch.fullPackageUpdate ? " (too old for a change list; checking change numbers)" : ""))
            } catch {
                log("PICS changes request failed (\(error)); checking change numbers")
            }
        } else if cacheURL != nil {
            current = (try? await session.picsChanges(since: 0, includeLists: false).currentChangeNumber) ?? 0
        }

        // 2. Owned packages -> app ids. Package 0 is the anonymous "Steam" sub every account
        // has (free tools, SDKs); purchases and free-to-play claims come with their own packages.
        var seenPackages = Set<UInt32>()
        let owned = await session.licenses
            .filter { $0.packageID != 0 && seenPackages.insert($0.packageID).inserted }
            .map { (id: $0.packageID, token: $0.accessToken) }
        let stalePackageIDs = try await stale(ids: owned.map(\.id), cached: cache?.packages.mapValues(\.changeNumber) ?? [:],
                                              changed: changedPackages, session: session, packages: owned)
        let toFetch = owned.filter { stalePackageIDs.contains($0.id) }
        var newCache = LibraryCache(steamID: steamID, changeNumber: current)
        for p in owned where !stalePackageIDs.contains(p.id) { newCache.packages[p.id] = cache?.packages[p.id] }
        for batch in toFetch.chunked(packageBatch) {
            let info = try await session.productInfo(packages: Array(batch), timeout: 90)
            for (id, item) in info.packages {
                guard let kv = item.kv else { continue }
                newCache.packages[id] = .init(changeNumber: item.changeNumber, appIDs: appIDs(inPackage: kv))
            }
        }
        var appIDs: [UInt32] = []
        var seenApps = Set<UInt32>()
        for p in owned {
            for app in newCache.packages[p.id]?.appIDs ?? [] where seenApps.insert(app).inserted { appIDs.append(app) }
        }
        log("\(owned.count) licenses (\(toFetch.count) fetched), \(appIDs.count) apps")

        // 3. App info for new or changed apps, a few batches in flight.
        let staleAppIDs = try await stale(ids: appIDs, cached: cache?.apps.mapValues(\.changeNumber) ?? [:],
                                          changed: changedApps, session: session, packages: nil)
        for id in appIDs where !staleAppIDs.contains(id) { newCache.apps[id] = cache?.apps[id] }
        let batches = appIDs.filter { staleAppIDs.contains($0) }.chunked(appBatch).map(Array.init)
        log("app info: \(batches.reduce(0) { $0 + $1.count }) apps to fetch in \(batches.count) batches, \(appIDs.count - staleAppIDs.count) cached")
        try await withThrowingTaskGroup(of: [UInt32: SteamSession.PICSItem].self) { g in
            var next = 0, done = 0
            func launch() {
                guard next < batches.count else { return }
                let b = batches[next]; next += 1
                g.addTask { try await appInfo(b, session: session, timeout: batchTimeout, log: log) }
            }
            for _ in 0..<maxInFlight { launch() }
            while let info = try await g.next() {
                for (id, item) in info {
                    guard let kv = item.kv else { continue } // not cached: retried next run
                    newCache.apps[id] = .init(changeNumber: item.changeNumber, entry: classify(appID: id, appInfo: kv, supported: [:]))
                }
                done += 1
                log("app info batch \(done)/\(batches.count)")
                launch()
            }
        }
        if let cacheURL {
            do { try newCache.save(cacheURL) } catch { log("could not save library cache: \(error)") }
        }
        let entries = appIDs.compactMap { newCache.apps[$0]?.entry?.applying(supported) }
        log(String(format: "%d games in %.1f s", entries.count, Date().timeIntervalSince(started)))
        return entries.sorted(by: LibraryEntry.libraryOrder)
    }

    /// Ids to (re)fetch: not cached, or changed. `changed` nil means no change list was
    /// available, so cached ids are checked with a metadata-only PICS request instead.
    static func stale(ids: [UInt32], cached: [UInt32: UInt32], changed: Set<UInt32>?,
                      session: SteamSession, packages: [(id: UInt32, token: UInt64)]?) async throws -> Set<UInt32> {
        var out = Set(ids.filter { cached[$0] == nil })
        let known = ids.filter { cached[$0] != nil }
        if let changed {
            out.formUnion(known.filter { changed.contains($0) })
            return out
        }
        let tokens = Dictionary(packages ?? [], uniquingKeysWith: { a, _ in a })
        for batch in known.chunked(500) {
            let items = Array(batch).map { (id: $0, token: tokens[$0] ?? 0) }
            let info = packages != nil
                ? try await session.productInfo(packages: items, metaDataOnly: true).packages
                : try await session.productInfo(apps: items, metaDataOnly: true).apps
            for id in batch where info[id]?.changeNumber != cached[id] { out.insert(id) }
        }
        return out
    }

    /// App info for a batch with a timeout; a batch that times out is halved and retried so
    /// one app Steam never answers for cannot stall the run (it is skipped and logged).
    static func appInfo(_ ids: [UInt32], session: SteamSession, timeout: TimeInterval,
                        log: @Sendable (String) -> Void) async throws -> [UInt32: SteamSession.PICSItem] {
        do {
            let tokens = try await session.picsAccessTokens(apps: ids)
            return try await session.productInfo(apps: ids.map { (id: $0, token: tokens[$0] ?? 0) }, timeout: timeout).apps
        } catch SteamDepotError.timeout(let what) {
            guard ids.count > 1 else {
                log("skipping app \(ids[0]): PICS did not answer (\(what))")
                return [:]
            }
            log("PICS timed out for \(ids.count) apps; splitting")
            let half = ids.count / 2
            var out = try await appInfo(Array(ids[..<half]), session: session, timeout: timeout, log: log)
            out.merge(try await appInfo(Array(ids[half...]), session: session, timeout: timeout, log: log)) { a, _ in a }
            return out
        }
    }

    /// App ids listed in a PICS package ("appids" { "0" "546560" ... }).
    public static func appIDs(inPackage kv: KeyValue) -> [UInt32] {
        (kv["appids"]?.children ?? []).compactMap { $0.value.flatMap { UInt32($0) } }
    }

    /// Classify one PICS app ("appinfo" root, or any node holding common/config/depots).
    /// Returns nil for anything that is not a game (DLC, tools, demos, videos, ...).
    public static func classify(appID: UInt32, appInfo kv: KeyValue,
                                supported: [UInt32: SupportedTitle] = SupportedTitles.byAppID) -> LibraryEntry? {
        guard let common = kv["common"], common["type"]?.value?.lowercased() == "game" else { return nil }
        let arm = armDepots(kv)
        let port = supported[appID]
        let status: LibraryStatus = port != nil ? .playable : (arm.isEmpty ? .unsupported : .candidate)
        return LibraryEntry(appID: appID,
                            name: common["name"]?.value ?? "App \(appID)",
                            status: status,
                            kleptonTarget: port?.target,
                            portUsesSteamBuild: port?.usesSteamBuild,
                            armDepots: arm,
                            isVR: isVR(kv),
                            headerImageURL: headerImageURL(appID: appID, common: common))
    }

    /// VR if any of: common.openvrsupport / openxrsupport / onlyvrsupport = 1, a
    /// common.controllervr block, a VR store category (31 VR Support, 53 VR Supported,
    /// 54 VR Only), or a launch option of type vr / openxr / othervr. playareavr is not
    /// used alone: it only appears alongside these. Hybrid games (flat + optional VR,
    /// e.g. Golf It!) count as VR.
    public static func isVR(_ kv: KeyValue) -> Bool {
        let common = kv["common"]
        for key in ["openvrsupport", "openxrsupport", "onlyvrsupport"] where common?[key]?.value == "1" { return true }
        if let c = common?["controllervr"], !c.children.isEmpty { return true }
        if let cats = common?["category"] {
            for c in ["category_31", "category_53", "category_54"] where cats[c]?.value == "1" { return true }
        }
        for launch in kv["config"]?["launch"]?.children ?? [] {
            if let t = launch["type"]?.value?.lowercased(), ["vr", "openxr", "othervr"].contains(t) { return true }
        }
        return false
    }

    /// ARM64 depots: `config.oslist` contains "android" (Steam Frame / Quest-style APK), or a
    /// linux depot whose `config.osarch` mentions arm, or a depot in the known-ARM table
    /// (Half-Life: Alyx's 546564 is only marked "linux"). Depots shared from another app
    /// (depotfromapp, e.g. redistributables) and DLC depots are ignored.
    public static func armDepots(_ kv: KeyValue) -> [ARMDepot] {
        var out: [ARMDepot] = []
        for d in kv["depots"]?.children ?? [] {
            guard let id = UInt32(d.name), d.value == nil,
                  d["depotfromapp"] == nil, d["dlcappid"] == nil else { continue }
            let config = d["config"]
            let oslist = (config?["oslist"]?.value ?? "").lowercased()
                .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            let osarch = (config?["osarch"]?.value ?? "").lowercased()
            let kind: ARMDepot.Kind?
            if oslist.contains("android") {
                kind = .android
            } else if oslist.contains("linux") && osarch.contains("arm") {
                kind = .linuxARM64
            } else if SupportedTitles.knownARM64LinuxDepots.contains(id) {
                kind = .linuxARM64
            } else {
                kind = nil
            }
            guard let kind else { continue }
            out.append(ARMDepot(depotID: id, kind: kind, size: publicSize(d)))
        }
        return out.sorted { $0.depotID < $1.depotID }
    }

    /// manifests.public.size (current PICS format); nil for the old `"public" "<gid>"` form.
    static func publicSize(_ depot: KeyValue) -> UInt64? {
        depot["manifests"]?["public"]?["size"]?.value.flatMap { UInt64($0) }
    }

    /// common.header_image.english can be a hashed path ("<sha>/header.jpg"), which only
    /// the store_item_assets host serves; plain header.jpg works on both.
    static func headerImageURL(appID: UInt32, common: KeyValue) -> URL {
        if let file = common["header_image"]?["english"]?.value, !file.isEmpty,
           let url = URL(string: "https://shared.steamstatic.com/store_item_assets/steam/apps/\(appID)/\(file)") {
            return url
        }
        return URL(string: "https://cdn.cloudflare.steamstatic.com/steam/apps/\(appID)/header.jpg")!
    }
}

private extension Array {
    func chunked(_ size: Int) -> [ArraySlice<Element>] {
        stride(from: 0, to: count, by: size).map { self[$0..<Swift.min($0 + size, count)] }
    }
}
