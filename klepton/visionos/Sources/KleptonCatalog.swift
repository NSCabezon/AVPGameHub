// The hub's closed catalog: every game it knows how to get, and from which store.
//
// ONE table (KLCatalog.entries), one row per Klepton target: display name, its
// Steam source (a SteamGames descriptor, KleptonSteamContent.swift) and/or its
// Meta source (a MetaStore recipe id — ../../packages/MetaStore). A store is a
// source only if it ships a build this port can run (an ARM64 Android/Quest APK
// or Linux arm64): Beat Saber on Steam is Windows-only, so it has no Steam source.
// Adding a game is one row here (+ the target in targets.py's hub list).
//
// The library (KleptonHub.swift) checks ownership in each signed-in store and
// offers only the store(s) that own the game as install options; owned in both,
// the player picks (remembered per game). Owned nowhere: shown greyed as "not in
// your library", never downloadable. A Meta source is also only offered when its
// recipe is exactly the build the hub's port was translated from (package +
// versionCode against the row's baked apktool.yml / AndroidManifest.xml) — another
// build would boot translated code against foreign IL2CPP metadata.
#if KL_HUB
import Foundation
#if canImport(SteamDepot)
import SteamDepot
#endif
#if canImport(MetaStore)
import MetaStore
#endif

enum KLStore: String, CaseIterable, Identifiable {
    case steam, meta
    var id: String { rawValue }
    var label: String { self == .steam ? "Steam" : "Meta" }
}

struct KLCatalogEntry {
    let target: String
    let display: String
    /// Steam app id; the download itself is SteamGames.descriptor(for: target).
    let steamApp: UInt32?
    /// MetaStore recipe id (Recipes.recipe(id:)).
    let metaRecipe: String?
}

enum KLCatalog {
    static let entries: [KLCatalogEntry] = [
        // Steam: the linuxsteamrtarm64 build, content depot 546561 (code is in the bundle). Not on Meta's store.
        KLCatalogEntry(target: "alyx", display: "Half-Life: Alyx", steamApp: 546560, metaRecipe: nil),
        // Steam: the Steam Frame Android build (depot 617833, shvr.apk = com.superhotgame.superhotvr 1.72,
        //        the build the port is translated from).
        // Meta:  the Quest build (unity.SUPERHOT_Team.SUPERHOT_VR_QA 1.161) — a different APK, so it is
        //        listed but only offered once the hub's port is built from it.
        KLCatalogEntry(target: "superhot", display: "SUPERHOT VR", steamApp: 617830, metaRecipe: "superhot"),
        // Meta only (Steam's Beat Saber is Windows-only): the Quest build 1.40.8_7379 — APK, main OBB
        // and the DLC song packs the account bought.
        KLCatalogEntry(target: "beatsaber", display: "Beat Saber", steamApp: nil, metaRecipe: "beatsaber"),
    ]

    static func entry(_ target: String) -> KLCatalogEntry? { entries.first { $0.target == target } }

    /// The stores this build can actually download the game from (the store's module is
    /// linked and the source exists).
    static func stores(_ target: String) -> [KLStore] {
        var out: [KLStore] = []
        #if canImport(SteamDepot)
        if entry(target)?.steamApp != nil, SteamGames.descriptor(for: target) != nil { out.append(.steam) }
        #endif
        #if canImport(MetaStore)
        if metaRecipe(target) != nil { out.append(.meta) }
        #endif
        return out
    }

    // MARK: Store choice (per game)

    private static func choiceKey(_ target: String) -> String { "kl.hub.store.\(target)" }
    static func chosenStore(_ target: String) -> KLStore? {
        UserDefaults.standard.string(forKey: choiceKey(target)).flatMap(KLStore.init(rawValue:))
    }
    static func choose(_ store: KLStore, for target: String) {
        UserDefaults.standard.set(store.rawValue, forKey: choiceKey(target))
    }

    // MARK: The build the hub's port was translated from

    /// package + versionCode of the APK tree the row's frameworks came from (its baked
    /// apktool.yml / AndroidManifest.xml); nil for a guest without them.
    static func embeddedBuild(_ row: KLHubGameRow) -> (package: String, versionCode: Int)? {
        func text(_ name: String) -> String? {
            row.meta[name].flatMap { Data(base64Encoded: $0) }.map { String(decoding: $0, as: UTF8.self) }
        }
        guard let yml = text("apktool.yml"), let manifest = text("AndroidManifest.xml") else { return nil }
        guard let codeLine = yml.split(separator: "\n").first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("versionCode:") }),
              let code = Int(codeLine.split(separator: ":").last?.trimmingCharacters(in: CharacterSet(charactersIn: " '\"")) ?? "")
        else { return nil }
        guard let r = manifest.range(of: "package=\"") else { return nil }
        let rest = manifest[r.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return (String(rest[..<end]), code)
    }

    #if canImport(MetaStore)
    static func metaRecipe(_ target: String) -> Recipe? { entry(target)?.metaRecipe.flatMap(Recipes.recipe(id:)) }

    /// nil when the Meta recipe is the port's build, else why it can't be offered.
    static func metaIncompatibility(_ row: KLHubGameRow) -> String? {
        guard let r = metaRecipe(row.target) else { return "no Meta recipe" }
        guard let b = embeddedBuild(row) else { return "this build carries no APK metadata for \(row.display)" }
        if b.package != r.package || b.versionCode != r.versionCode {
            return "Meta sells \(r.package) \(r.versionName) (\(r.versionCode)); this hub's port is "
                + "\(b.package) \(b.versionCode) — rebuild the port from Meta's build to install from Meta"
        }
        return nil
    }

    static func metaStore(_ target: String) -> GameStore { GameStore(root: Paths.containerURL(for: target)) }
    #endif

    // MARK: Which store's data a game boots from

    /// Offline: the stores whose data for this game is complete on the headset.
    static func installedStores(_ target: String) -> [KLStore] {
        var out: [KLStore] = []
        #if canImport(SteamDepot)
        if stores(target).contains(.steam), let d = SteamGames.descriptor(for: target), d.status().isComplete { out.append(.steam) }
        #endif
        #if canImport(MetaStore)
        if let r = metaRecipe(target), metaStore(target).isComplete(r) { out.append(.meta) }
        #endif
        return out
    }

    /// The store whose data Play uses: the chosen one if its data is complete, else the
    /// only/first complete one, else the chosen one (or the game's first store).
    static func activeStore(_ target: String) -> KLStore? {
        let installed = installedStores(target)
        if let c = chosenStore(target), installed.contains(c) { return c }
        if let first = installed.first { return first }
        return chosenStore(target) ?? stores(target).first
    }

    /// The downloaded APK the hub derives <row.apk> and <tree>/assets from (HubPrep), for
    /// the active store; nil = this game's data is not an APK from a store. `label` names
    /// it in the log, relative to the container.
    static func sourceAPK(_ target: String) -> (url: URL, label: String)? {
        switch activeStore(target) {
        case .meta?:
            #if canImport(MetaStore)
            guard let apk = metaRecipe(target)?.apk else { return nil }
            return (metaStore(target).url(for: apk), apk.relativePath)
            #else
            return nil
            #endif
        case .steam?:
            #if canImport(SteamDepot)
            guard let d = SteamGames.descriptor(for: target), let apk = d.apk else { return nil }
            return (d.root.appendingPathComponent(apk), "\(d.dataSubpath)/\(apk)")
            #else
            return nil
            #endif
        case nil:
            return nil
        }
    }
}
#endif
