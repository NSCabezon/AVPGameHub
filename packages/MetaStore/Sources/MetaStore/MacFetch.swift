// `metastore fetch`: a recipe's files onto the Mac, for TRANSLATION ONLY (building a port needs the
// APK's code: apktool tree + guest libraries). Game data for playing is still downloaded by the
// hub on the headset. Same verified, resumable Fetcher as the hub.
import Foundation

public enum MacFetch {
    /// Where `fetch` writes, worked out from the arguments (no I/O).
    public struct Layout: Equatable, Sendable {
        /// The Fetcher's root: files land at root/<dest>/<name>; partials and the record in root/meta/.
        public var root: URL
        /// The recipe as fetched (only the APK with --apk-only).
        public var recipe: Recipe
        /// --apk-only to a file path: the finished APK is moved here from root.
        public var apkFile: URL?
    }

    /// The default for Beat Saber's APK: beside the Mac's apktool tree, named by version.
    public static func defaultOut(recipe: Recipe, apkOnly: Bool, kleptonDir: URL, cwd: URL) -> URL {
        if apkOnly, recipe.target == "beatsaber" {
            let short = recipe.versionName.split(separator: "_").first.map(String.init) ?? recipe.versionName
            return kleptonDir.appendingPathComponent("beatsaber-\(short).apk")
        }
        return cwd.appendingPathComponent("metastore-\(recipe.id)", isDirectory: true)
    }

    /// `out` ending in .apk (only with --apk-only) is the APK's file path; anything else is a directory.
    public static func layout(recipe: Recipe, apkOnly: Bool, out: URL) throws -> Layout {
        var r = recipe
        if apkOnly {
            guard let apk = recipe.apk else { throw RecipeError.invalid("no apk") }
            r.files = [apk]
            r.addons = nil
        }
        if apkOnly, out.pathExtension.lowercased() == "apk" {
            // Staging beside the target file (same volume: the final step is a rename), resumable.
            let stage = out.deletingLastPathComponent().appendingPathComponent(".metastore-fetch-\(recipe.id)", isDirectory: true)
            return Layout(root: stage, recipe: r, apkFile: out)
        }
        return Layout(root: out, recipe: r, apkFile: nil)
    }
}
