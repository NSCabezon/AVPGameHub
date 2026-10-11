import Foundation

public enum StoreKind: String, CaseIterable, Identifiable, Sendable, Codable {
    case steam, meta
    public var id: String { rawValue }
    public var label: String { self == .steam ? "Steam" : "Meta" }
}

/// One game the hub can carry.
///
/// TODO: unify with the hub's KLCatalog (Klepton branch meta-store,
/// visionos/Sources/KleptonCatalog.swift). That table is Swift inside an `#if KL_HUB` app
/// target, so it cannot be imported here and parsing it would be fragile; the right fix is a
/// small JSON export (e.g. `targets.py --catalog-json`) both sides read. Until then this is a
/// deliberate copy of its rows, plus the Steam depot/APK facts from SteamGames
/// (KleptonSteamContent.swift) that the Mac needs to fetch an APK itself.
public struct CatalogEntry: Identifiable, Hashable, Sendable {
    public var id: String { target }
    public let target: String
    public let display: String
    public let steamApp: UInt32?
    /// Steam depot that carries an Android APK (nil = the Steam build is not an APK, e.g. Alyx's
    /// Linux arm64 build, which the headset downloads itself).
    public let steamAPKDepot: UInt32?
    public let steamAPKName: String?
    /// MetaStore recipe id (Recipes.recipe(id:)).
    public let metaRecipe: String?

    public var stores: [StoreKind] {
        (steamApp != nil ? [.steam] : []) + (metaRecipe != nil ? [.meta] : [])
    }

    /// Stores the Mac can fetch an APK from.
    public var apkStores: [StoreKind] {
        (steamAPKDepot != nil && steamAPKName != nil ? [.steam] : []) + (metaRecipe != nil ? [.meta] : [])
    }
}

public enum Catalog {
    public static let entries: [CatalogEntry] = [
        CatalogEntry(target: "alyx", display: "Half-Life: Alyx", steamApp: 546560,
                     steamAPKDepot: nil, steamAPKName: nil, metaRecipe: nil),
        CatalogEntry(target: "superhot", display: "SUPERHOT VR", steamApp: 617830,
                     steamAPKDepot: 617833, steamAPKName: "shvr.apk", metaRecipe: "superhot"),
        CatalogEntry(target: "beatsaber", display: "Beat Saber", steamApp: nil,
                     steamAPKDepot: nil, steamAPKName: nil, metaRecipe: "beatsaber"),
    ]

    public static func entry(_ target: String) -> CatalogEntry? { entries.first { $0.target == target } }
}

/// `python3 visionos/targets.py <target>` prints shell assignments (KLT_TREE=superhot,
/// KLT_LIBS='a b c'…). Parsed into a dictionary.
public enum TargetVars {
    public static func parse(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("export ") { line.removeFirst("export ".count) }
            guard let eq = line.firstIndex(of: "="), !line.hasPrefix("#") else { continue }
            let key = String(line[..<eq])
            guard !key.isEmpty, key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { continue }
            var value = String(line[line.index(after: eq)...])
            if value.count >= 2, let f = value.first, f == "'" || f == "\"", value.last == f {
                value = String(value.dropFirst().dropLast())
            }
            out[key] = value
        }
        return out
    }
}

public struct APKVersion: Equatable, Sendable, CustomStringConvertible {
    public var name: String?
    public var code: Int?
    public init(name: String?, code: Int?) { self.name = name; self.code = code }
    public var description: String {
        switch (name, code) {
        case let (n?, c?): return "\(n) (\(c))"
        case let (n?, nil): return n
        case let (nil, c?): return "(\(c))"
        default: return "—"
        }
    }

    /// The versionInfo block of an apktool.yml (`versionCode: 1598`, `versionName: 1.40.4_5283`).
    public static func parse(apktoolYML text: String) -> APKVersion? {
        var name: String?, code: Int?
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            func value(_ key: String) -> String? {
                guard line.hasPrefix(key + ":") else { return nil }
                return line.dropFirst(key.count + 1).trimmingCharacters(in: CharacterSet(charactersIn: " '\""))
            }
            if let v = value("versionCode") { code = Int(v) }
            if let v = value("versionName") { name = v }
        }
        return name == nil && code == nil ? nil : APKVersion(name: name, code: code)
    }
}
