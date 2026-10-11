import Foundation
import CommonCrypto
import CryptoKit

/// Steam's symmetric scheme: first 16 bytes are the IV encrypted with AES-256-ECB,
/// the rest is AES-256-CBC with PKCS7 padding.
enum DepotCrypto {
    static func symmetricDecrypt(_ input: Data, key: Data) throws -> Data {
        guard key.count == 32 else { throw SteamDepotError.corrupt("depot key must be 32 bytes") }
        guard input.count >= 32, input.count % 16 == 0 else { throw SteamDepotError.corrupt("bad ciphertext length \(input.count)") }
        let iv = try aes(input.prefix(16), key: key, iv: nil, ecb: true, padding: false)
        return try aes(input.dropFirst(16), key: key, iv: iv, ecb: false, padding: true)
    }

    private static func aes(_ input: Data, key: Data, iv: Data?, ecb: Bool, padding: Bool) throws -> Data {
        var out = Data(count: input.count + kCCBlockSizeAES128)
        var moved = 0
        var options = CCOptions(0)
        if ecb { options |= CCOptions(kCCOptionECBMode) }
        if padding { options |= CCOptions(kCCOptionPKCS7Padding) }
        let outCapacity = out.count
        let status = out.withUnsafeMutableBytes { o in
            input.withUnsafeBytes { i in
                key.withUnsafeBytes { k in
                    (iv ?? Data()).withUnsafeBytes { v in
                        CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), options,
                                k.baseAddress, key.count, iv == nil ? nil : v.baseAddress,
                                i.baseAddress, input.count, o.baseAddress, outCapacity, &moved)
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw SteamDepotError.corrupt("AES decrypt failed (\(status))") }
        out.count = moved
        return out
    }

    /// Steam's Adler-32 variant: seeded with 0 instead of 1 (SteamKit: Adler32.Calculate(0, ...)).
    static func adler(_ data: Data) -> UInt32 {
        data.withUnsafeBytes { adler(UnsafeRawBufferPointer($0)) }
    }

    static func adler(_ buf: UnsafeRawBufferPointer) -> UInt32 {
        var s1: UInt32 = 0, s2: UInt32 = 0
        let base: UInt32 = 65521
        var i = 0
        let n = buf.count
        let p = buf.bindMemory(to: UInt8.self)
        while i < n {
            let end = min(n, i + 5552)
            while i < end {
                s1 &+= UInt32(p[i]); s2 &+= s1
                i += 1
            }
            s1 %= base; s2 %= base
        }
        return s2 << 16 | s1
    }

    static func sha1(_ data: Data) -> Data { Data(Insecure.SHA1.hash(data: data)) }
}
