// Adapted from Glovebox (MIT, github.com/glovebox-vr/glovebox)
//   launcher/Sources/SteamLauncherKit/Cloud/SteamCloud.swift (SteamCloud transport)
//   launcher/Sources/SteamLauncherKit/Proto/Messages.swift (Cloud.* messages)
//
// Steam Cloud (Auto-Cloud) over the CM connection: list a game's cloud files, download one,
// upload a batch. The sync policy lives in CloudSync.swift and only ever talks to the
// `CloudRemote` protocol, so it can be tested with a fake. There is no delete here on purpose:
// the sync never removes anything from the cloud.
import Foundation
import CryptoKit

/// One file in the user's Steam Cloud for an app, e.g. `%GameInstall%game/hlvr/save/s0/autosave.sav`.
public struct CloudFile: Sendable, Hashable, Codable {
    public var filename: String
    public var timestamp: UInt64
    public var size: UInt32
    public var url: String
    public var sha1Hex: String
    public var platforms: [String]

    public init(filename: String = "", timestamp: UInt64 = 0, size: UInt32 = 0, url: String = "",
                sha1Hex: String = "", platforms: [String] = []) {
        self.filename = filename; self.timestamp = timestamp; self.size = size; self.url = url
        self.sha1Hex = sha1Hex; self.platforms = platforms
    }
}

/// One file to upload in a batch.
public struct CloudUpload: Sendable, Equatable {
    public var name: String
    public var data: Data
    public var time: Date
    public init(name: String, data: Data, time: Date) { self.name = name; self.data = data; self.time = time }
}

/// What the sync engine needs from Steam Cloud. `SteamCloud` is the real one; tests use a fake.
public protocol CloudRemote: Sendable {
    func list() async throws -> [CloudFile]
    func download(_ file: CloudFile) async throws -> Data
    /// Uploads files as one batch; either every file is committed or the batch is failed.
    func upload(_ files: [CloudUpload]) async throws
}

enum CloudSHA {
    static func sha1(_ d: Data) -> Data { Data(Insecure.SHA1.hash(data: d)) }
    static func hex(_ d: Data) -> String { sha1(d).hex }
}

/// Steam Cloud over a logged-on SteamSession.
public struct SteamCloud: CloudRemote {
    public let session: SteamSession
    public let appID: UInt32
    public let buildID: UInt64
    public let machineName: String

    public init(session: SteamSession, appID: UInt32, buildID: UInt64 = 0, machineName: String = "Klepton") {
        self.session = session; self.appID = appID; self.buildID = buildID; self.machineName = machineName
    }

    public func list() async throws -> [CloudFile] {
        var out: [CloudFile] = []
        var start: UInt32 = 0
        while true {
            let (files, total) = try await session.cloudEnumerate(app: appID, start: start)
            out += files
            start += UInt32(files.count)
            if files.isEmpty || start >= total { break }
        }
        return out
    }

    public func download(_ file: CloudFile) async throws -> Data {
        let r = try await session.cloudDownloadInfo(app: appID, filename: file.filename)
        let urlString = r.host.isEmpty ? file.url : "\(r.https ? "https" : "http")://\(r.host)\(r.path)"
        guard let url = URL(string: urlString), !urlString.isEmpty else {
            throw SteamDepotError.protocolError("cloud: no URL for \(file.filename)")
        }
        var req = URLRequest(url: url)
        for (k, v) in r.headers { req.setValue(v, forHTTPHeaderField: k) }
        let (body, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw SteamDepotError.protocolError("cloud download of \(file.filename): HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        var content = body
        if r.rawFileSize != 0, r.rawFileSize != r.fileSize, body.starts(with: [0x50, 0x4B, 0x03, 0x04]) {
            content = try Inflate.unzipFirst(body)
        }
        let expected = r.sha.isEmpty ? (Data(hex: file.sha1Hex) ?? Data()) : r.sha
        if !expected.isEmpty, CloudSHA.sha1(content) != expected {
            throw SteamDepotError.corrupt("cloud file \(file.filename) failed its hash check")
        }
        return content
    }

    public func upload(_ files: [CloudUpload]) async throws {
        guard !files.isEmpty else { return }
        let batch = try await session.cloudBeginBatch(app: appID, machineName: machineName,
                                                      files: files.map(\.name), buildID: buildID)
        do {
            for f in files { try await uploadOne(f, batch: batch) }
        } catch {
            try? await session.cloudCompleteBatch(app: appID, batch: batch, result: EResult.fail)
            throw error
        }
        try await session.cloudCompleteBatch(app: appID, batch: batch, result: EResult.ok)
    }

    private func uploadOne(_ f: CloudUpload, batch: UInt64) async throws {
        let sha = CloudSHA.sha1(f.data)
        let blocks = try await session.cloudBeginFileUpload(app: appID, size: UInt32(f.data.count), sha: sha,
                                                            timestamp: UInt64(max(0, f.time.timeIntervalSince1970)),
                                                            filename: f.name, batch: batch)
        var ok = true
        for b in blocks {
            guard let url = URL(string: "\(b.https ? "https" : "http")://\(b.host)\(b.path)") else { ok = false; break }
            var req = URLRequest(url: url)
            req.httpMethod = b.method
            for (k, v) in b.headers { req.setValue(v, forHTTPHeaderField: k) }
            if let explicit = b.explicitBody {
                req.httpBody = explicit
            } else {
                let start = Int(b.offset), end = min(f.data.count, start + Int(b.length))
                guard start <= end else { ok = false; break }
                req.httpBody = f.data.subdata(in: start..<end)
            }
            let (_, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if !(200..<300).contains(code) { ok = false; break }
        }
        let committed = try await session.cloudCommitFileUpload(app: appID, succeeded: ok, sha: sha, filename: f.name)
        guard ok, committed else { throw SteamDepotError.protocolError("Steam Cloud didn't accept \(f.name)") }
    }
}

// MARK: - Cloud.* unified messages (field numbers from SteamDatabase/Protobufs steammessages_cloud)

struct CloudDownloadInfo {
    var fileSize: UInt32 = 0, rawFileSize: UInt32 = 0
    var sha = Data()
    var host = "", path = ""
    var https = true
    var headers: [(String, String)] = []
}

struct CloudUploadBlock {
    var host = "", path = "", https = true, method = "PUT"
    var headers: [(String, String)] = []
    var offset: UInt64 = 0, length: UInt32 = 0
    var explicitBody: Data?
}

extension SteamSession {
    private func cloudCall(_ method: String, _ body: Data) async throws -> Data {
        guard isLoggedOn else { throw SteamDepotError.authFailed("not logged on") }
        let resp = try await cm.serviceCall(method, body: body, authed: true)
        guard resp.eresult == EResult.ok else { throw SteamDepotError.steamResult(method, resp.eresult) }
        return resp.body
    }

    /// Cloud.EnumerateUserFiles#1 — one page of the app's cloud files, and the total.
    func cloudEnumerate(app: UInt32, start: UInt32) async throws -> ([CloudFile], UInt32) {
        var w = ProtoWriter()
        w.uint(1, app); w.bool(2, true); w.uint(3, UInt32(500)); w.uint(4, start)
        let body = try await cloudCall("Cloud.EnumerateUserFiles#1", w.data)
        let r = try Self.parseCloudEnumerate(body)
        logger("Cloud.EnumerateUserFiles app \(app) from \(start): \(r.0.count) files, total \(r.1) (\(body.count) bytes)")
        return r
    }

    static func parseCloudEnumerate(_ body: Data) throws -> ([CloudFile], UInt32) {
        let m = try ProtoMessage(body)
        let files = try m.messages(1).map { f in
            CloudFile(filename: f.string(3) ?? "", timestamp: f.u64(4) ?? 0, size: f.u32(5) ?? 0,
                      url: f.string(6) ?? "", sha1Hex: f.string(10) ?? "", platforms: f.strings(9))
        }
        return (files, m.u32(2) ?? 0)
    }

    /// Cloud.ClientFileDownload#1 — where to fetch a file (and whether it is zipped).
    func cloudDownloadInfo(app: UInt32, filename: String) async throws -> CloudDownloadInfo {
        var w = ProtoWriter()
        w.uint(1, app); w.string(2, filename); w.uint(3, UInt32(1))  // realm 1 = Steam global
        let m = try ProtoMessage(try await cloudCall("Cloud.ClientFileDownload#1", w.data))
        var r = CloudDownloadInfo()
        r.fileSize = m.u32(2) ?? 0; r.rawFileSize = m.u32(3) ?? 0; r.sha = m.bytes(4) ?? Data()
        r.host = m.string(7) ?? ""; r.path = m.string(8) ?? ""; r.https = m.bool(9) ?? true
        for h in try m.messages(10) { r.headers.append((h.string(1) ?? "", h.string(2) ?? "")) }
        return r
    }

    /// Cloud.BeginAppUploadBatch#1
    func cloudBeginBatch(app: UInt32, machineName: String, files: [String], buildID: UInt64) async throws -> UInt64 {
        var w = ProtoWriter()
        w.uint(1, app); w.string(2, machineName)
        for f in files { w.string(3, f) }
        if buildID != 0 { w.uint(6, buildID) }
        return try ProtoMessage(try await cloudCall("Cloud.BeginAppUploadBatch#1", w.data)).u64(1) ?? 0
    }

    /// Cloud.CompleteAppUploadBatchBlocking#1
    func cloudCompleteBatch(app: UInt32, batch: UInt64, result: Int32) async throws {
        var w = ProtoWriter()
        w.uint(1, app); w.uint(2, batch); w.uint(3, UInt32(bitPattern: result))
        _ = try await cloudCall("Cloud.CompleteAppUploadBatchBlocking#1", w.data)
    }

    /// Cloud.ClientBeginFileUpload#1 — the HTTP requests that carry the file.
    func cloudBeginFileUpload(app: UInt32, size: UInt32, sha: Data, timestamp: UInt64, filename: String,
                              batch: UInt64) async throws -> [CloudUploadBlock] {
        var w = ProtoWriter()
        w.uint(1, app); w.uint(2, size); w.uint(3, size); w.bytes(4, sha); w.uint(5, timestamp); w.string(6, filename)
        w.uint(7, UInt32.max)   // platforms_to_sync: all, as Auto-Cloud does
        w.bool(10, false)       // can_encrypt
        w.uint(13, batch)
        let m = try ProtoMessage(try await cloudCall("Cloud.ClientBeginFileUpload#1", w.data))
        return try m.messages(2).map { g in
            var b = CloudUploadBlock()
            b.host = g.string(1) ?? ""; b.path = g.string(2) ?? ""; b.https = g.bool(3) ?? true
            b.method = [1: "GET", 2: "HEAD", 3: "POST", 4: "PUT", 5: "DELETE"][g.i32(4) ?? 4] ?? "PUT"
            for h in try g.messages(5) { b.headers.append((h.string(1) ?? "", h.string(2) ?? "")) }
            b.offset = g.u64(6) ?? 0; b.length = g.u32(7) ?? 0; b.explicitBody = g.bytes(8)
            return b
        }
    }

    /// Cloud.ClientCommitFileUpload#1
    func cloudCommitFileUpload(app: UInt32, succeeded: Bool, sha: Data, filename: String) async throws -> Bool {
        var w = ProtoWriter()
        w.bool(1, succeeded); w.uint(2, app); w.bytes(3, sha); w.string(4, filename)
        return try ProtoMessage(try await cloudCall("Cloud.ClientCommitFileUpload#1", w.data)).bool(1) ?? false
    }
}
