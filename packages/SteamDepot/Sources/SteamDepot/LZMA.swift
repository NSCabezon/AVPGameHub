import Foundation

/// Raw LZMA1 decoder (port of Igor Pavlov's public-domain LzmaSpec.cpp), used for Steam
/// "VZa" (VZip) depot chunks. Decodes the whole stream into a buffer of known size, so the
/// output buffer doubles as the dictionary window.
enum LZMA {
    static func decode(properties d0: UInt8, dictSize: UInt32, input: UnsafeRawBufferPointer,
                       output: UnsafeMutableRawBufferPointer, outSize: Int) throws {
        var d = Int(d0)
        guard d < 9 * 5 * 5 else { throw SteamDepotError.corrupt("LZMA: bad properties") }
        let lc = d % 9; d /= 9
        let lp = d % 5
        let pb = d / 5
        var decoder = try Decoder(lc: lc, lp: lp, pb: pb, input: input,
                                  output: output.bindMemory(to: UInt8.self), outSize: outSize,
                                  dictSize: max(dictSize, 1 << 12))
        defer { decoder.free() }
        try decoder.run()
    }

    private struct Decoder {
        // Probability layout offsets into one array.
        static let kNumStates = 12
        static let kNumPosBitsMax = 4
        static let kEndPosModelIndex = 14
        static let kNumFullDistances = 1 << (kEndPosModelIndex >> 1)
        static let kMatchMinLen = 2
        static let lenSize = 2 + 2 * (16 << 3) + 256

        static let oIsMatch = 0
        static let oIsRep = oIsMatch + (kNumStates << kNumPosBitsMax)
        static let oIsRepG0 = oIsRep + kNumStates
        static let oIsRepG1 = oIsRepG0 + kNumStates
        static let oIsRepG2 = oIsRepG1 + kNumStates
        static let oIsRep0Long = oIsRepG2 + kNumStates
        static let oPosSlot = oIsRep0Long + (kNumStates << kNumPosBitsMax)
        static let oPosDecoders = oPosSlot + 4 * 64
        static let oAlign = oPosDecoders + (1 + kNumFullDistances - kEndPosModelIndex)
        static let oLen = oAlign + 16
        static let oRepLen = oLen + lenSize
        static let oLiteral = oRepLen + lenSize

        let lc: Int, lp: Int, pb: Int
        let probs: UnsafeMutablePointer<UInt16>
        let probCount: Int
        let out: UnsafeMutablePointer<UInt8>
        let outSize: Int
        let dictSize: UInt32
        var pos = 0

        // range coder
        let inp: UnsafePointer<UInt8>
        let inSize: Int
        var inPos = 0
        var range: UInt32 = 0xFFFF_FFFF
        var code: UInt32 = 0
        var corrupted = false

        init(lc: Int, lp: Int, pb: Int, input: UnsafeRawBufferPointer, output: UnsafeMutableBufferPointer<UInt8>,
             outSize: Int, dictSize: UInt32) throws {
            guard output.count >= outSize else { throw SteamDepotError.corrupt("LZMA: output too small") }
            self.lc = lc; self.lp = lp; self.pb = pb
            probCount = Decoder.oLiteral + (0x300 << (lc + lp))
            probs = .allocate(capacity: probCount)
            probs.initialize(repeating: 1024, count: probCount)
            out = output.baseAddress!
            self.outSize = outSize
            self.dictSize = dictSize
            inp = input.bindMemory(to: UInt8.self).baseAddress!
            inSize = input.count
            // Range coder init: first byte must be 0, then 4 bytes of code.
            if inSize < 5 { corrupted = true; return }
            if inp[0] != 0 { corrupted = true }
            inPos = 1
            for _ in 0..<4 { code = code << 8 | UInt32(inp[inPos]); inPos += 1 }
        }

        func free() { probs.deallocate() }

        @inline(__always) mutating func nextByte() -> UInt32 {
            if inPos < inSize { let b = inp[inPos]; inPos += 1; return UInt32(b) }
            corrupted = true
            return 0
        }

        @inline(__always) mutating func normalize() {
            if range < (1 << 24) {
                range <<= 8
                code = code << 8 | nextByte()
            }
        }

        @inline(__always) mutating func bit(_ i: Int) -> Int {
            let p = UInt32(probs[i])
            let bound = (range >> 11) &* p
            let symbol: Int
            if code < bound {
                probs[i] = UInt16(p + ((2048 - p) >> 5))
                range = bound
                symbol = 0
            } else {
                probs[i] = UInt16(p - (p >> 5))
                code &-= bound
                range &-= bound
                symbol = 1
            }
            normalize()
            return symbol
        }

        @inline(__always) mutating func directBits(_ n: Int) -> UInt32 {
            var res: UInt32 = 0
            for _ in 0..<n {
                range >>= 1
                code &-= range
                let t = 0 &- (code >> 31)
                code &+= range & t
                normalize()
                res = (res << 1) &+ (t &+ 1)
            }
            return res
        }

        @inline(__always) mutating func bitTree(_ base: Int, _ numBits: Int) -> Int {
            var m = 1
            for _ in 0..<numBits { m = (m << 1) + bit(base + m) }
            return m - (1 << numBits)
        }

        @inline(__always) mutating func bitTreeReverse(_ base: Int, _ numBits: Int) -> Int {
            var m = 1, symbol = 0
            for i in 0..<numBits {
                let b = bit(base + m)
                m = (m << 1) + b
                symbol |= b << i
            }
            return symbol
        }

        mutating func decodeLen(_ base: Int, _ posState: Int) -> Int {
            if bit(base) == 0 { return bitTree(base + 2 + (posState << 3), 3) }
            if bit(base + 1) == 0 { return 8 + bitTree(base + 2 + 128 + (posState << 3), 3) }
            return 16 + bitTree(base + 2 + 256, 8)
        }

        mutating func decodeDistance(_ len: Int) -> UInt32 {
            let lenState = min(len, 3)
            let posSlot = bitTree(Decoder.oPosSlot + (lenState << 6), 6)
            if posSlot < 4 { return UInt32(posSlot) }
            let numDirectBits = (posSlot >> 1) - 1
            var dist = UInt32((2 | (posSlot & 1)) << numDirectBits)
            if posSlot < Decoder.kEndPosModelIndex {
                dist &+= UInt32(bitTreeReverse(Decoder.oPosDecoders + Int(dist) - posSlot, numDirectBits))
            } else {
                dist &+= directBits(numDirectBits - 4) << 4
                dist &+= UInt32(bitTreeReverse(Decoder.oAlign, 4))
            }
            return dist
        }

        mutating func run() throws {
            if corrupted { throw SteamDepotError.corrupt("LZMA: bad stream header") }
            var state = 0
            var rep0: UInt32 = 0, rep1: UInt32 = 0, rep2: UInt32 = 0, rep3: UInt32 = 0
            let pbMask = (1 << pb) - 1
            let lpMask = (1 << lp) - 1
            while pos < outSize {
                let posState = pos & pbMask
                if bit(Decoder.oIsMatch + (state << Decoder.kNumPosBitsMax) + posState) == 0 {
                    // literal
                    let prevByte = pos > 0 ? Int(out[pos - 1]) : 0
                    let litState = ((pos & lpMask) << lc) + (prevByte >> (8 - lc))
                    let base = Decoder.oLiteral + 0x300 * litState
                    var symbol = 1
                    if state >= 7 {
                        let back = Int(rep0) + 1
                        guard back <= pos else { throw SteamDepotError.corrupt("LZMA: bad distance") }
                        var matchByte = Int(out[pos - back])
                        repeat {
                            let matchBit = (matchByte >> 7) & 1
                            matchByte <<= 1
                            let b = bit(base + ((1 + matchBit) << 8) + symbol)
                            symbol = (symbol << 1) | b
                            if matchBit != b { break }
                        } while symbol < 0x100
                    }
                    while symbol < 0x100 { symbol = (symbol << 1) | bit(base + symbol) }
                    out[pos] = UInt8(truncatingIfNeeded: symbol - 0x100)
                    pos += 1
                    state = state < 4 ? 0 : (state < 10 ? state - 3 : state - 6)
                    continue
                }
                var len: Int
                if bit(Decoder.oIsRep + state) != 0 {
                    if pos == 0 { throw SteamDepotError.corrupt("LZMA: rep at start") }
                    if bit(Decoder.oIsRepG0 + state) == 0 {
                        if bit(Decoder.oIsRep0Long + (state << Decoder.kNumPosBitsMax) + posState) == 0 {
                            state = state < 7 ? 9 : 11
                            let back = Int(rep0) + 1
                            guard back <= pos else { throw SteamDepotError.corrupt("LZMA: bad distance") }
                            out[pos] = out[pos - back]
                            pos += 1
                            continue
                        }
                    } else {
                        let dist: UInt32
                        if bit(Decoder.oIsRepG1 + state) == 0 {
                            dist = rep1
                        } else {
                            if bit(Decoder.oIsRepG2 + state) == 0 {
                                dist = rep2
                            } else {
                                dist = rep3
                                rep3 = rep2
                            }
                            rep2 = rep1
                        }
                        rep1 = rep0
                        rep0 = dist
                    }
                    len = decodeLen(Decoder.oRepLen, posState)
                    state = state < 7 ? 8 : 11
                } else {
                    rep3 = rep2; rep2 = rep1; rep1 = rep0
                    len = decodeLen(Decoder.oLen, posState)
                    state = state < 7 ? 7 : 10
                    rep0 = decodeDistance(len)
                    if rep0 == 0xFFFF_FFFF { break } // end marker
                    if rep0 >= dictSize || Int(rep0) >= pos { throw SteamDepotError.corrupt("LZMA: bad distance") }
                }
                len += Decoder.kMatchMinLen
                if len > outSize - pos { throw SteamDepotError.corrupt("LZMA: match past end") }
                let back = Int(rep0) + 1
                var src = pos - back
                for _ in 0..<len {
                    out[pos] = out[src]
                    pos += 1; src += 1
                }
            }
            if corrupted { throw SteamDepotError.corrupt("LZMA: input overrun") }
        }
    }
}
