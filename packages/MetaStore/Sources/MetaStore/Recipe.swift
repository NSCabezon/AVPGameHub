// Adapted from avp-play (MIT, github.com/myMartek/avp-play) core/Sources/AVPPlayCore/Recipe.swift.
// Changes: only Meta-store files (no Steam/URL/user sources, no directory trees); `target` is a
// Klepton target (visionos/targets.py); destinations are relative to the game's container root
// (Documents/games/<target>/ in the hub).
import Foundation

/// One game at one exact build: which store files belong to it and where they land. Purely
/// declarative — a recipe never runs code. Exact file ids + sizes + sha256 make a download
/// either exactly this build or an error.
public struct Recipe: Codable, Sendable, Identifiable, Equatable {
    public var schema: Int
    public var id: String
    public var title: String
    /// Android package of the APK.
    public var package: String
    public var versionName: String
    public var versionCode: Int
    /// Meta store app id, for ownership and purchase checks.
    public var appId: String
    /// The Klepton target that runs this build.
    public var target: String
    public var files: [RecipeFile]
    public var addons: Addons?
    /// Where the data came from (provenance, free text).
    public var origin: String?

    public var apk: RecipeFile? { files.first { $0.role == "apk" } }
}

public struct RecipeFile: Codable, Sendable, Hashable {
    public var name: String
    /// "apk", "main-obb", "patch-obb", "asset", "addon".
    public var role: String
    /// Store file id (binary or asset id); the download asks for exactly this.
    public var id: String
    public var size: Int64?
    public var sha256: String?
    public var required: Bool
    /// Destination folder relative to the game's container root ("" = the root).
    public var dest: String
    /// Different file name at the destination (nil = `name`).
    public var localName: String?

    public init(name: String, role: String, id: String, size: Int64?, sha256: String?, required: Bool,
                dest: String, localName: String? = nil) {
        self.name = name; self.role = role; self.id = id; self.size = size; self.sha256 = sha256
        self.required = required; self.dest = dest; self.localName = localName
    }

    public var localFileName: String { localName ?? name }
    /// Container-relative path of the finished file.
    public var relativePath: String { dest.isEmpty ? localFileName : "\(dest)/\(localFileName)" }
}

public struct Addons: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        /// The store only delivers what was bought; only store-confirmed SKUs are planned.
        case deliveredAssets = "delivered-assets"
    }
    public var kind: Kind
    public var dest: String
    public var items: [AddonItem]
}

public struct AddonItem: Codable, Sendable, Hashable {
    public var sku: String
    public var name: String
    public var id: String
    public var size: Int64?
    public var sha256: String?
    public var group: String?

    public func asFile(dest: String) -> RecipeFile {
        RecipeFile(name: name, role: "addon", id: id, size: size, sha256: sha256, required: false, dest: dest)
    }
}

public enum RecipeError: Error, CustomStringConvertible, Equatable {
    case unsupportedSchema(Int)
    case invalid(String)
    case unknown(String)

    public var description: String {
        switch self {
        case .unsupportedSchema(let v): return "Recipe schema \(v) is not supported."
        case .invalid(let why): return "Invalid recipe: \(why)"
        case .unknown(let id): return "No recipe '\(id)'."
        }
    }
}

extension Recipe {
    public static let supportedSchema = 1

    /// Everything a recipe must not do: paths outside the container, ambiguous names, ids that
    /// are not ids. Run on every load.
    public func validate() throws {
        guard schema == Recipe.supportedSchema else { throw RecipeError.unsupportedSchema(schema) }
        guard Recipe.isSafeName(id) else { throw RecipeError.invalid("identifier '\(id)'") }
        guard Recipe.isSafeName(target) else { throw RecipeError.invalid("target '\(target)'") }
        guard MetaClient.isNumericID(appId) else { throw RecipeError.invalid("store app id") }
        guard files.filter({ $0.role == "apk" }).count == 1 else { throw RecipeError.invalid("exactly one apk") }
        var paths = Set<String>()
        var skus = Set<String>()
        let addonFiles = (addons?.items ?? []).map { $0.asFile(dest: addons?.dest ?? "") }
        if let a = addons {
            guard Recipe.isSafeRelativePath(a.dest) else { throw RecipeError.invalid("addon folder '\(a.dest)'") }
            for item in a.items {
                guard MetaClient.isPlainSKU(item.sku), skus.insert(item.sku).inserted else {
                    throw RecipeError.invalid("addon sku '\(item.sku)'")
                }
            }
        }
        for f in files + addonFiles {
            guard Recipe.isSafeName(f.name) else { throw RecipeError.invalid("file name '\(f.name)'") }
            if let l = f.localName, !Recipe.isSafeName(l) { throw RecipeError.invalid("destination name '\(l)'") }
            guard MetaClient.isNumericID(f.id) else { throw RecipeError.invalid("file id of '\(f.name)'") }
            guard Recipe.isSafeRelativePath(f.dest) else { throw RecipeError.invalid("destination folder '\(f.dest)'") }
            guard paths.insert(f.relativePath).inserted else { throw RecipeError.invalid("'\(f.relativePath)' appears twice") }
            if let h = f.sha256, !(h.count == 64 && h.allSatisfy { $0.isHexDigit }) {
                throw RecipeError.invalid("checksum of '\(f.name)'")
            }
            if let s = f.size, s < 0 { throw RecipeError.invalid("size of '\(f.name)'") }
            // A required file without a checksum would accept anything Meta sends.
            if f.required, f.sha256 == nil || f.size == nil { throw RecipeError.invalid("'\(f.name)' needs size and sha256") }
        }
    }

    static func isSafeName(_ s: String) -> Bool {
        !s.isEmpty && s != "." && s != ".." && !s.contains("/") && !s.contains("\\") && !s.contains("\0")
            && !s.hasPrefix(".")
    }

    static func isSafeRelativePath(_ s: String) -> Bool {
        if s.isEmpty { return true }
        if s.hasPrefix("/") || s.contains("\\") || s.contains("\0") { return false }
        return s.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." && !$0.hasPrefix(".") }
    }

    public static func decode(_ data: Data) throws -> Recipe {
        let r = try JSONDecoder().decode(Recipe.self, from: data)
        try r.validate()
        return r
    }
}

/// The recipes compiled into the package (BuiltinRecipes.swift).
public enum Recipes {
    /// Every built-in recipe that decodes and validates (a bad one is a programming error,
    /// caught by the unit tests).
    public static let all: [Recipe] = BuiltinRecipes.json.compactMap { try? Recipe.decode(Data($0.utf8)) }

    public static func recipe(id: String) -> Recipe? { all.first { $0.id == id } }
    public static func recipes(target: String) -> [Recipe] { all.filter { $0.target == target } }
}
