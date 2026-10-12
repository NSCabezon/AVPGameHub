// Adapted from avp-play (MIT, github.com/myMartek/avp-play) core/Sources/AVPPlayCore/Fetcher.swift,
// FetchPlan.swift and ContentStore.swift.
// Changes: files land directly in a Klepton game container (recipe destinations), partial files
// and the completion record live in <root>/meta/, progress is reported in bytes for a UI.
import Foundation

/// One game's files on disk: `root` is the game's container root (the hub's
/// Documents/games/<target>/). Finished files sit at `root/<dest>/<name>`; partial downloads
/// and the record of what was verified sit in `root/meta/`.
public struct GameStore: Sendable {
    public let root: URL
    public init(root: URL) { self.root = root }

    public enum FileState: Equatable, Sendable {
        case missing
        case partial(Int64)
        case present(Int64)
    }

    /// What was downloaded and verified, written after every file.
    public struct Record: Codable, Sendable, Equatable {
        public struct File: Codable, Sendable, Equatable {
            public var size: Int64
            public var sha256: String
        }
        public var recipeId: String
        public var versionCode: Int
        /// Container-relative path -> verified size and checksum.
        public var files: [String: File] = [:]
        /// Store ids Meta refused for this account (404 on an add-on): never asked again.
        public var withheld: [String] = []
        public var complete = false
        public var updated = Date()
    }

    public var metaDir: URL { root.appendingPathComponent("meta", isDirectory: true) }
    public var recordURL: URL { metaDir.appendingPathComponent("metastore.json") }

    public func url(for file: RecipeFile) -> URL { root.appendingPathComponent(file.relativePath) }
    public func partialURL(for file: RecipeFile) -> URL {
        metaDir.appendingPathComponent(".partial", isDirectory: true).appendingPathComponent("\(file.id).part")
    }

    public static func fileSize(_ url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size].flatMap { ($0 as? NSNumber)?.int64Value }
    }

    public func state(of file: RecipeFile) -> FileState {
        if let s = GameStore.fileSize(url(for: file)) { return .present(s) }
        if let s = GameStore.fileSize(partialURL(for: file)) { return .partial(s) }
        return .missing
    }

    public func loadRecord() -> Record? {
        guard let data = try? Data(contentsOf: recordURL) else { return nil }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return try? d.decode(Record.self, from: data)
    }

    public func save(_ record: Record) throws {
        try FileManager.default.createDirectory(at: metaDir, withIntermediateDirectories: true)
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .prettyPrinted]
        e.dateEncodingStrategy = .iso8601
        try e.encode(record).write(to: recordURL, options: .atomic)
    }

    /// Offline (stat only): this recipe's required files, plus the voice-language packs in
    /// `locales`, are all verified at their exact size.
    public func isComplete(_ recipe: Recipe, locales: Set<String> = []) -> Bool {
        guard let r = loadRecord(), r.complete, r.recipeId == recipe.id, r.versionCode == recipe.versionCode else { return false }
        return recipe.files(locales: locales).allSatisfy { f in
            guard let v = r.files[f.relativePath], v.size == f.size else { return false }
            return GameStore.fileSize(url(for: f)) == f.size
        }
    }

    /// Bytes of the recipe's required files (plus the packs in `locales`) on disk (finished or
    /// partial), and the total.
    public func requiredProgress(_ recipe: Recipe, locales: Set<String> = []) -> (have: Int64, total: Int64) {
        var have: Int64 = 0, total: Int64 = 0
        for f in recipe.files(locales: locales) {
            total += f.size ?? 0
            switch state(of: f) {
            case .present(let s), .partial(let s): have += min(s, f.size ?? s)
            case .missing: break
            }
        }
        return (have, total)
    }

    /// Something of this recipe is on disk (a finished or partial file).
    public func hasAnything(_ recipe: Recipe) -> Bool {
        recipe.files.contains { state(of: $0) != .missing }
    }

    /// Every path this recipe may have written (what "delete game data" removes). Saves and
    /// anything else under android-files/ are not touched.
    public func ownedURLs(_ recipe: Recipe) -> [URL] {
        let addonFiles = (recipe.addons?.items ?? []).map { $0.asFile(dest: recipe.addons?.dest ?? "") }
        return [metaDir] + (recipe.files + addonFiles).map(url(for:))
    }
}

/// What the user wants beyond the required files.
public struct FetchSelection: Sendable, Equatable {
    /// Store-confirmed purchases. Add-on files are planned only for these.
    public var ownedSKUs: Set<String>
    /// Store ids Meta already refused for this account.
    public var withheld: Set<String>
    /// Voice-language packs to fetch (recipe file `locale` codes). Empty = none.
    public var locales: Set<String>
    public init(ownedSKUs: Set<String> = [], withheld: Set<String> = [], locales: Set<String> = []) {
        self.ownedSKUs = ownedSKUs
        self.withheld = withheld
        self.locales = locales
    }
}

public struct PlannedFetch: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        case download
        case resume(from: Int64)
        /// Already there at the right size.
        case keep
    }
    public let file: RecipeFile
    public let action: Action
}

public enum FetchPlan {
    /// Required files, plus the chosen voice-language packs, plus add-ons for confirmed SKUs only: no file is ever planned just to
    /// see whether Meta hands it out.
    public static func wantedFiles(recipe: Recipe, selection: FetchSelection) -> [RecipeFile] {
        var wanted = recipe.files.filter(\.required)
        wanted += recipe.files.filter { f in !f.required && f.locale.map(selection.locales.contains) == true }
        if let addons = recipe.addons, addons.kind == .deliveredAssets {
            wanted += addons.items.filter { selection.ownedSKUs.contains($0.sku) }.map { $0.asFile(dest: addons.dest) }
        }
        return wanted.filter { !selection.withheld.contains($0.id) }
    }

    public static func plan(recipe: Recipe, selection: FetchSelection,
                            record: GameStore.Record?, state: (RecipeFile) -> GameStore.FileState) -> [PlannedFetch] {
        let verified = record?.versionCode == recipe.versionCode ? record?.files ?? [:] : [:]
        return wantedFiles(recipe: recipe, selection: selection).map { file in
            switch state(file) {
            case .missing:
                return PlannedFetch(file: file, action: .download)
            case .present(let size):
                // A wrong size, or a file not verified for THIS build, is fetched again.
                if let expected = file.size, expected != size { return PlannedFetch(file: file, action: .download) }
                if let v = verified[file.relativePath], v.size == size,
                   file.sha256 == nil || file.sha256?.lowercased() == v.sha256 {
                    return PlannedFetch(file: file, action: .keep)
                }
                return PlannedFetch(file: file, action: .download)
            case .partial(let size):
                if let expected = file.size, size >= expected { return PlannedFetch(file: file, action: .download) }
                return PlannedFetch(file: file, action: .resume(from: size))
            }
        }
    }
}

public enum FetchError: Error, CustomStringConvertible, Equatable {
    case sizeMismatch(name: String, expected: Int64, actual: Int64)
    case checksumMismatch(name: String)

    public var description: String {
        switch self {
        case .sizeMismatch(let n, let e, let a): return "\(n): size is \(a) bytes instead of \(e) – discarded."
        case .checksumMismatch(let n): return "\(n): checksum doesn't match – discarded."
        }
    }
}

/// Runs a plan: one file after another, through the request gate, verified (size + sha256),
/// stopping at the first unexpected answer.
public struct Fetcher: Sendable {
    public struct Progress: Sendable, Equatable {
        public var fileIndex: Int
        public var fileCount: Int
        public var fileName: String
        /// Bytes of the planned files already on disk, and their total (sizes known from the recipe).
        public var bytesDone: Int64
        public var bytesTotal: Int64
        public var verifying: Bool
    }
    public struct Summary: Sendable, Equatable {
        public var kept = 0
        public var downloaded = 0
        public var bytes: Int64 = 0
        /// Add-on files Meta does not deliver to this account; skipped and remembered.
        public var withheld: [String] = []
    }

    let client: MetaClient
    let store: GameStore
    let gate: RequestGate

    public init(client: MetaClient, store: GameStore, gate: RequestGate = RequestGate()) {
        self.client = client
        self.store = store
        self.gate = gate
    }

    public func run(_ plan: [PlannedFetch], recipe: Recipe,
                    progress: (@Sendable (Progress) -> Void)? = nil,
                    log: @Sendable (String) -> Void = { _ in }) async throws -> Summary {
        let fm = FileManager.default
        var summary = Summary()
        var record = store.loadRecord() ?? GameStore.Record(recipeId: recipe.id, versionCode: recipe.versionCode)
        if record.recipeId != recipe.id || record.versionCode != recipe.versionCode {
            record = GameStore.Record(recipeId: recipe.id, versionCode: recipe.versionCode)
        }
        record.complete = false
        try store.save(record)

        let total = plan.reduce(Int64(0)) { $0 + ($1.file.size ?? 0) }
        var done: Int64 = 0
        for (i, item) in plan.enumerated() {
            try Task.checkCancellation()
            let file = item.file
            let final = store.url(for: file)
            let partial = store.partialURL(for: file)
            var offset: Int64 = 0
            switch item.action {
            case .keep:
                summary.kept += 1
                done += file.size ?? 0
                continue
            case .download:
                try? fm.removeItem(at: partial)
            case .resume(let from):
                offset = from
            }
            let base = done
            let report: @Sendable (Int64, Int64?) -> Void = { got, _ in
                progress?(Progress(fileIndex: i + 1, fileCount: plan.count, fileName: file.name,
                                   bytesDone: base + got, bytesTotal: total, verifying: false))
            }
            report(offset, nil)

            let outcome: MetaClient.DownloadOutcome
            do {
                try await gate.waitForTurn()
                outcome = try await client.download(id: file.id, to: partial, resumeFrom: offset, progress: report)
                await gate.requestFinished()
            } catch MetaError.denied(status: 404) where file.role == "addon" {
                // An add-on Meta does not deliver to this account despite the purchase list: remembered,
                // never asked again; the others each get their one request.
                await gate.requestFinished()
                try? fm.removeItem(at: partial)
                record.withheld.append(file.id)
                try store.save(record)
                summary.withheld.append(file.name)
                log("not delivered by Meta for this account (HTTP 404): \(file.name) – skipped and remembered")
                continue
            } catch {
                await gate.requestFinished()
                throw error           // first unexpected outcome: ask for nothing more
            }

            let size = GameStore.fileSize(partial) ?? 0
            if let expected = file.size ?? outcome.totalSize, expected != size {
                try? fm.removeItem(at: partial)
                throw FetchError.sizeMismatch(name: file.name, expected: expected, actual: size)
            }
            progress?(Progress(fileIndex: i + 1, fileCount: plan.count, fileName: file.name,
                               bytesDone: base + size, bytesTotal: total, verifying: true))
            let digest = try Hashing.sha256(of: partial)
            if let expected = file.sha256, expected.lowercased() != digest {
                try? fm.removeItem(at: partial)
                throw FetchError.checksumMismatch(name: file.name)
            }
            try fm.createDirectory(at: final.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: final)
            try fm.moveItem(at: partial, to: final)
            record.files[file.relativePath] = .init(size: size, sha256: digest)
            record.updated = Date()
            try store.save(record)
            summary.downloaded += 1
            summary.bytes += size - offset
            done += file.size ?? size
            log("downloaded: \(file.name) (\(size) bytes\(outcome.resumed ? ", resumed" : "")\(file.sha256 == nil ? ", checksum recorded" : ", checksum matches"))")
        }
        record.complete = recipe.files.filter(\.required).allSatisfy { record.files[$0.relativePath] != nil }
        record.updated = Date()
        try store.save(record)
        try? fm.removeItem(at: store.metaDir.appendingPathComponent(".partial", isDirectory: true))
        return summary
    }
}
