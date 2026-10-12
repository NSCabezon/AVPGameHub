import CommonCrypto
import CryptoKit
import Foundation
import XCTest
@testable import SteamDepot

/// Raw chunks staged by another HTTP client (the hub's background session) are decrypted,
/// decompressed and checked exactly like network chunks, and deleted once used.
final class StagingTests: XCTestCase {
    /// Steam's symmetric scheme in reverse: IV encrypted with AES-ECB, then AES-CBC + PKCS7.
    private func encrypt(_ plain: Data, key: Data, iv: Data) -> Data {
        func aes(_ input: Data, ecb: Bool, padding: Bool, iv: Data?) -> Data {
            var out = Data(count: input.count + kCCBlockSizeAES128)
            var moved = 0
            var options = CCOptions(0)
            if ecb { options |= CCOptions(kCCOptionECBMode) }
            if padding { options |= CCOptions(kCCOptionPKCS7Padding) }
            let cap = out.count
            let st = out.withUnsafeMutableBytes { o in input.withUnsafeBytes { i in key.withUnsafeBytes { k in (iv ?? Data()).withUnsafeBytes { v in
                CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), options, k.baseAddress, key.count,
                        iv == nil ? nil : v.baseAddress, i.baseAddress, input.count, o.baseAddress, cap, &moved)
            } } } }
            XCTAssertEqual(st, CCCryptorStatus(kCCSuccess))
            out.count = moved
            return out
        }
        return aes(iv, ecb: true, padding: false, iv: nil) + aes(plain, ecb: false, padding: true, iv: iv)
    }

    /// A one-entry stored (method 0) zip, the PKZip chunk format.
    private func storedZip(_ payload: Data) -> Data {
        var d = Data()
        func u16(_ v: Int) { d.append(UInt8(v & 0xff)); d.append(UInt8(v >> 8 & 0xff)) }
        func u32(_ v: Int) { u16(v & 0xffff); u16(v >> 16 & 0xffff) }
        let name = Data("z".utf8)
        // local header
        u32(0x04034b50); u16(10); u16(0); u16(0); u32(0); u32(0)
        u32(payload.count); u32(payload.count); u16(name.count); u16(0)
        d.append(name); d.append(payload)
        let cdOffset = d.count
        // central directory
        u32(0x02014b50); u16(10); u16(10); u16(0); u16(0); u32(0); u32(0)
        u32(payload.count); u32(payload.count); u16(name.count); u16(0); u16(0); u16(0); u16(0)
        u32(0); u32(0)
        d.append(name)
        let cdSize = d.count - cdOffset
        // end of central directory
        u32(0x06054b50); u16(0); u16(0); u16(1); u16(1); u32(cdSize); u32(cdOffset); u16(0)
        return d
    }

    func testStagedChunkIsUsedVerifiedAndDeleted() async throws {
        let plain = Data((0..<5000).map { UInt8($0 % 251) })
        let key = Data((0..<32).map { UInt8($0) })
        let raw = encrypt(storedZip(plain), key: key, iv: Data(repeating: 7, count: 16))
        let chunk = DepotManifest.Chunk(sha: Data(Insecure.SHA1.hash(data: plain)), checksum: DepotCrypto.adler(plain),
                                        offset: 0, uncompressedLength: UInt32(plain.count), compressedLength: UInt32(raw.count))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("staging-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try raw.write(to: dir.appendingPathComponent(chunk.id))

        // No usable server: a network fetch would fail, so success proves the staged file was used.
        let cdn = CDNClient(servers: [], depot: 1, app: 1, session: SteamSession(log: { _ in }), maxConnections: 1, log: { _ in })
        let (data, network, format) = try await cdn.fetchChunk(chunk, key: key, worker: 0, staging: dir)
        XCTAssertEqual(data, plain)
        XCTAssertEqual(network, 0)
        XCTAssertEqual(format, .pkzip)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent(chunk.id).path), "used chunks are deleted")
    }

    /// Staged chunks are handed out first (they sit at the END of the plan, where the background
    /// session works), chunks staged later are picked up on the next scan, and every chunk is
    /// handed out exactly once.
    func testQueueTakesStagedChunksFirst() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("staging-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let ids = (0..<20).map { String(format: "%040x", $0) }
        for id in ids[17...] { try Data([1]).write(to: dir.appendingPathComponent(id)) }
        try Data([1]).write(to: dir.appendingPathComponent("not-in-the-plan"))
        let q = JobQueue(ids, staging: dir, rescan: 0)
        var out: [String] = []
        for _ in 0..<3 { out.append(await q.next()!) }
        XCTAssertEqual(Set(out), Set(ids[17...]), "staged chunks first")
        out.append(await q.next()!)
        XCTAssertEqual(out.last, ids[0], "then the plan in order")
        // The background session stages another one while the run goes on.
        try Data([1]).write(to: dir.appendingPathComponent(ids[12]))
        out.append(await q.next()!)
        XCTAssertEqual(out.last, ids[12])
        while let id = await q.next() { out.append(id) }
        XCTAssertEqual(out.count, ids.count, "each chunk exactly once")
        XCTAssertEqual(Set(out), Set(ids))
    }

    func testQueueWithoutStagingIsThePlan() async {
        let q = JobQueue(["a", "b", "a"])
        var out: [String] = []
        while let id = await q.next() { out.append(id) }
        XCTAssertEqual(out, ["a", "b", "a"])
    }

    /// A planned file is pre-sized (sparse): it is not "present" until its chunks are written.
    func testLocalStatusCountsWrittenBytesNotPlannedSize() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("depot-\(UUID().uuidString)", isDirectory: true)
        let state = SteamDepotDownloader.stateDir(root)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let size: UInt64 = 64 << 20
        try "\(size)\t00\tbig.vpk\n\(size)\t00\tother.vpk".write(to: SteamDepotDownloader.fileListURL(root, depot: 7),
                                                                    atomically: true, encoding: .utf8)
        for name in ["big.vpk", "other.vpk"] {
            let fd = open(root.appendingPathComponent(name).path, O_RDWR | O_CREAT, 0o644)
            XCTAssertGreaterThanOrEqual(fd, 0)
            ftruncate(fd, off_t(size))
            if name == "big.vpk" {     // 8 MB of it written
                let chunk = [UInt8](repeating: 0xab, count: 8 << 20)
                _ = chunk.withUnsafeBytes { pwrite(fd, $0.baseAddress, chunk.count, 0) }
            }
            close(fd)
        }
        let st = SteamDepotDownloader.localStatus(directory: root, depot: 7)
        XCTAssertEqual(st.totalBytes, 2 * size)
        XCTAssertEqual(st.presentFiles, 2, "both at the expected size")
        XCTAssertGreaterThanOrEqual(st.presentBytes, 8 << 20)
        XCTAssertLessThan(st.presentBytes, 9 << 20, "the unwritten (sparse) part is not counted")
        XCTAssertFalse(st.isComplete)

        try "123\n".write(to: SteamDepotDownloader.markerURL(root, depot: 7), atomically: true, encoding: .utf8)
        let done = SteamDepotDownloader.localStatus(directory: root, depot: 7)
        XCTAssertTrue(done.isComplete)
        XCTAssertEqual(done.presentBytes, 2 * size, "a complete depot counts whole")
    }

    /// Resuming: chunks in a pre-sized file's holes are missing without being read. (APFS fills
    /// holes under ~16 MB when the file is closed, so the chunks here sit 32 MB apart.)
    func testPlanSkipsHolesWithoutHashing() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("plan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let len = 1 << 20, gap = 32 << 20
        let written = Data((0..<len).map { UInt8($0 % 253) })
        let zeros = Data(count: len)
        let chunks = (0..<4).map { i in
            let d = i == 2 ? written : zeros
            return DepotManifest.Chunk(sha: Data(Insecure.SHA1.hash(data: d)), checksum: DepotCrypto.adler(d),
                                       offset: UInt64(i * gap), uncompressedLength: UInt32(len), compressedLength: 1)
        }
        let size = UInt64(4 * gap)
        let file = DepotManifest.File(name: "big.vpk", size: size, flags: 0, shaContent: Data(count: 20),
                                      chunks: chunks, linkTarget: nil)
        let url = root.appendingPathComponent(file.name)
        let fd = open(url.path, O_RDWR | O_CREAT, 0o644)
        ftruncate(fd, off_t(size))
        _ = written.withUnsafeBytes { pwrite(fd, $0.baseAddress, len, off_t(2 * gap)) }
        close(fd)
        var st = stat()
        stat(url.path, &st)
        if UInt64(st.st_blocks) * 512 >= size { throw XCTSkip("this volume does not keep holes") }
        let meter = VerifyMeter(progress: DownloadProgress(), callback: { _ in })
        let plan = try SteamDepotDownloader.plan(file, root: root, onDisk: size, done: [], meter: meter)
        XCTAssertEqual(plan.missing.map(\.offset), [0, 1, 3].map { UInt64($0 * gap) },
                       "the written chunk is adopted, the holes are missing (although their content would hash right)")
        XCTAssertEqual(plan.hashedBytes, UInt64(len), "only the written chunk is read")
    }

    func testChunkPath() {
        XCTAssertEqual(ChunkPlan.chunkPath(depot: 546561, id: "ab12"), "depot/546561/chunk/ab12")
    }
}
