import XCTest
import Security
@testable import SteamDepot

final class SteamDepotTests: XCTestCase {
    func testProtoRoundTrip() throws {
        var w = ProtoWriter()
        w.uint(1, UInt32(65581)); w.fixed64(2, 0x0110_0001_0000_0000); w.string(3, "hi")
        w.message(4) { $0.uint(1, UInt32(7)) }
        let m = try ProtoMessage(w.data)
        XCTAssertEqual(m.u32(1), 65581)
        XCTAssertEqual(m.u64(2), 0x0110_0001_0000_0000)
        XCTAssertEqual(m.string(3), "hi")
        XCTAssertEqual(try m.message(4)?.u32(1), 7)
    }

    func testSteamAdlerIsZeroSeeded() {
        XCTAssertEqual(DepotCrypto.adler(Data()), 0)
        // s1 = 'a' = 97, s2 = 97
        XCTAssertEqual(DepotCrypto.adler(Data("a".utf8)), 97 << 16 | 97)
    }

    func testVDF() throws {
        let kv = try KeyValue.parse(text: """
        "appinfo" { "depots" { "546564" { "config" { "oslist" "linux" } "manifests" { "public" { "gid" "9198205754520568813" } } } } }
        """)
        let d = kv["depots"]!["546564"]!
        XCTAssertEqual(d["config"]?["oslist"]?.value, "linux")
        XCTAssertEqual(SteamDepotDownloader.manifestGID(d, branch: "public"), 9198205754520568813)
    }

    func testZstdRoundTripFrame() throws {
        // zstd frame of "hello hello hello\n" produced by `zstd -c`.
        let frame = try XCTUnwrap(Data(hex: "28b52ffd04586d00003868656c6c6f200a0100314a11a3aa74ce"))
        let out = try Zstd.decompress(frame, expectedSize: 18)
        XCTAssertEqual(String(decoding: out, as: UTF8.self), "hello hello hello\n")
    }

    func testRSAEncryptRoundTrip() throws {
        let attrs: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits as String: 2048]
        var err: Unmanaged<CFError>?
        let priv = try XCTUnwrap(SecKeyCreateRandomKey(attrs as CFDictionary, &err))
        let pub = try XCTUnwrap(SecKeyCopyPublicKey(priv))
        let der = try XCTUnwrap(SecKeyCopyExternalRepresentation(pub, &err) as Data?)
        // Parse RSAPublicKey ::= SEQUENCE { INTEGER n, INTEGER e }
        var r = [UInt8](der)[...]
        func readLen() -> Int {
            let b = r.removeFirst()
            if b < 0x80 { return Int(b) }
            var n = 0
            for _ in 0..<(b & 0x7F) { n = n << 8 | Int(r.removeFirst()) }
            return n
        }
        XCTAssertEqual(r.removeFirst(), 0x30); _ = readLen()
        XCTAssertEqual(r.removeFirst(), 0x02); let nl = readLen(); var n = Data(r.prefix(nl)); r = r.dropFirst(nl)
        XCTAssertEqual(r.removeFirst(), 0x02); let el = readLen(); let e = Data(r.prefix(el))
        while n.first == 0 { n.removeFirst() }
        let enc = try SteamSession.rsaEncrypt(Data("hunter2".utf8), modulusHex: n.hex.uppercased(), exponentHex: e.hex)
        let dec = try XCTUnwrap(SecKeyCreateDecryptedData(priv, .rsaEncryptionPKCS1, enc as CFData, &err) as Data?)
        XCTAssertEqual(String(decoding: dec, as: UTF8.self), "hunter2")
    }
}
