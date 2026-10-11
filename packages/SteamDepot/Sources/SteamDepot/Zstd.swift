import Foundation
import CZstd

/// zstd frame decompression via the vendored reference decoder.
enum Zstd {
    static func decompress(_ frame: Data, expectedSize: Int) throws -> Data {
        var out = Data(count: expectedSize)
        let written = out.withUnsafeMutableBytes { o in
            frame.withUnsafeBytes { i in
                ZSTD_decompress(o.baseAddress, expectedSize, i.baseAddress, frame.count)
            }
        }
        if ZSTD_isError(written) != 0 {
            throw SteamDepotError.corrupt("zstd: \(String(cString: ZSTD_getErrorName(written)))")
        }
        guard written == expectedSize else { throw SteamDepotError.corrupt("zstd: size \(written) != \(expectedSize)") }
        return out
    }
}
