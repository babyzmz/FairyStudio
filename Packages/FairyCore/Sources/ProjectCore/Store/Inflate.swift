import Foundation

/// Raw deflate 解码（RFC 1951）：stored / fixed / dynamic 三种块，LZ77 滑窗 32K。
/// 只读内存输入，输出上限由调用方传入（防 ZIP 炸弹）。
enum Inflate {
    enum InflateError: Error {
        case truncated
        case invalidBlock
        case invalidSymbol
        case overlongDistance
    }

    static func decode(_ data: Data, expectedSize: Int) throws -> Data {
        var reader = BitReader(data: data)
        var out = Data()
        out.reserveCapacity(min(max(expectedSize, 0), 8 << 20))
        var final = false
        while !final {
            final = try reader.bit("块头")
            let type = try reader.bits(2, "块类型")
            switch type {
            case 0:
                reader.alignToByte()
                let len = Int(try reader.bits(16, "stored 长度"))
                let nlen = Int(try reader.bits(16, "stored 补码"))
                guard len ^ 0xFFFF == nlen else { throw InflateError.invalidBlock }
                out.append(try reader.bytes(len, cap: expectedSize, have: out.count))
            case 1:
                try decodeBlock(reader: &reader, litLen: Huffman.fixedLitLen(), dist: Huffman.fixedDist(),
                                output: &out, cap: expectedSize)
            case 2:
                let (litLen, dist) = try dynamicTables(reader: &reader)
                try decodeBlock(reader: &reader, litLen: litLen, dist: dist, output: &out, cap: expectedSize)
            default:
                throw InflateError.invalidBlock
            }
        }
        return out
    }

    // MARK: - 块体

    private static func decodeBlock(reader: inout BitReader, litLen: Huffman, dist: Huffman,
                                    output: inout Data, cap: Int) throws {
        while true {
            let sym = try litLen.decode(from: &reader)
            if sym < 256 {
                guard output.count < cap + (1 << 20) else { throw InflateError.invalidBlock }
                output.append(UInt8(sym))
            } else if sym == 256 {
                return
            } else {
                let (base, extra) = lengthBaseExtra(sym)
                var length = base + Int(try reader.bits(extra, "长度附加"))
                let dsym = Int(try dist.decode(from: &reader))
                guard dsym < 30 else { throw InflateError.invalidSymbol }
                let (dbase, dextra) = distBaseExtra(dsym)
                let distance = dbase + Int(try reader.bits(dextra, "距离附加"))
                guard distance >= 1, distance <= output.count else { throw InflateError.overlongDistance }
                guard output.count + length <= cap + (1 << 20) else { throw InflateError.invalidBlock }
                // 重叠拷贝必须逐字节（memmove 语义）。
                var from = output.count - distance
                while length > 0 {
                    output.append(output[from])
                    from += 1
                    length -= 1
                }
            }
        }
    }

    private static func dynamicTables(reader: inout BitReader) throws -> (Huffman, Huffman) {
        let hlit = Int(try reader.bits(5, "HLIT")) + 257
        let hdist = Int(try reader.bits(5, "HDIST")) + 1
        let hclen = Int(try reader.bits(4, "HCLEN")) + 4
        // 码长码的码长（固定顺序）。
        let order = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]
        var clLens = [Int](repeating: 0, count: 19)
        for i in 0..<hclen { clLens[order[i]] = Int(try reader.bits(3, "码长码")) }
        let clTree = try Huffman(lengths: clLens)
        // 文本/距离两棵树的码长（含 16/17/18 游程）。
        var all: [Int] = []
        all.reserveCapacity(hlit + hdist)
        while all.count < hlit + hdist {
            let sym = Int(try clTree.decode(from: &reader))
            switch sym {
            case 0...15: all.append(sym)
            case 16:
                let repeatCount = 3 + Int(try reader.bits(2, "游程"))
                guard let last = all.last else { throw InflateError.invalidBlock }
                all.append(contentsOf: repeatElement(last, count: repeatCount))
            case 17:
                all.append(contentsOf: repeatElement(0, count: 3 + Int(try reader.bits(3, "游程"))))
            case 18:
                all.append(contentsOf: repeatElement(0, count: 11 + Int(try reader.bits(7, "游程"))))
            default: throw InflateError.invalidSymbol
            }
        }
        guard all.count == hlit + hdist else { throw InflateError.invalidBlock }
        return (try Huffman(lengths: Array(all.prefix(hlit))),
                try Huffman(lengths: Array(all.suffix(hdist))))
    }

    // MARK: - RFC 1951 长度 / 距离表（显式查表）

    private static let lengthBases = [
        3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31,
        35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
    private static let lengthExtras = [
        0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2,
        3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]

    private static let distBases = [
        1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193,
        257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577]
    private static let distExtras = [
        0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6,
        7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]

    private static func lengthBaseExtra(_ sym: UInt16) -> (base: Int, extra: Int) {
        let i = Int(sym) - 257
        guard i >= 0, i < lengthBases.count else { return (3, 0) }
        return (lengthBases[i], lengthExtras[i])
    }

    private static func distBaseExtra(_ sym: Int) -> (base: Int, extra: Int) {
        guard sym >= 0, sym < distBases.count else { return (1, 0) }
        return (distBases[sym], distExtras[sym])
    }
}

// MARK: - 位读取（LSB 先）

private struct BitReader {
    var data: Data
    var bytePos = 0
    var bitBuf: UInt64 = 0
    var bitCount = 0

    mutating func fill() {
        while bitCount <= 56, bytePos < data.count {
            bitBuf |= UInt64(data[bytePos]) << bitCount
            bitCount += 8
            bytePos += 1
        }
    }

    mutating func bits(_ n: Int, _ what: String) throws -> UInt32 {
        fill()
        guard bitCount >= n else { throw Inflate.InflateError.truncated }
        let value = UInt32(bitBuf & ((1 << n) - 1))
        bitBuf >>= n
        bitCount -= n
        _ = what
        return value
    }

    mutating func bit(_ what: String) throws -> Bool {
        try bits(1, what) == 1
    }

    mutating func alignToByte() {
        let skip = bitCount % 8
        bitBuf >>= skip
        bitCount -= skip
    }

    mutating func bytes(_ n: Int, cap: Int, have: Int) throws -> Data {
        alignToByte()
        // 位缓冲里可能还剩整字节（最多取够 n 个）。
        var out = Data()
        while out.count < n, bitCount >= 8 {
            out.append(UInt8(bitBuf & 0xFF))
            bitBuf >>= 8
            bitCount -= 8
        }
        let rest = n - out.count
        guard rest >= 0, bytePos + rest <= data.count else { throw Inflate.InflateError.truncated }
        guard have + n <= cap + (1 << 20) else { throw Inflate.InflateError.invalidBlock }
        if rest > 0 { out.append(data[bytePos..<bytePos + rest]) }
        bytePos += rest
        return out
    }
}

// MARK: - 规范 Huffman 解码（码长数组建表，按位查表）

private struct Huffman {
    /// firstCode[len]：该码长最小码字；firstIndex[len]：对应符号在 symbols 中的起始下标。
    var firstCode: [Int]
    var firstIndex: [Int]
    var symbols: [UInt16]
    var maxLen: Int

    init(lengths: [Int]) throws {
        let maxBits = lengths.max() ?? 0
        guard maxBits <= 15 else { throw Inflate.InflateError.invalidSymbol }
        maxLen = maxBits
        var blCount = [Int](repeating: 0, count: maxBits + 1)
        for len in lengths where len > 0 { blCount[len] += 1 }
        // 规范码字：code = (code + blCount[bits-1]) << 1。
        var nextCode = [Int](repeating: 0, count: maxBits + 1)
        var code = 0
        for bits in 1...max(maxBits, 1) {
            code = (code + blCount[bits - 1]) << 1
            nextCode[bits] = code
        }
        // 同码长符号按符号值排序。
        var ordered = [(len: Int, sym: Int)]()
        for (sym, len) in lengths.enumerated() where len > 0 { ordered.append((len, sym)) }
        ordered.sort { $0.len == $1.len ? $0.sym < $1.sym : $0.len < $1.len }
        symbols = []
        firstCode = [Int](repeating: -1, count: maxBits + 1)
        firstIndex = [Int](repeating: 0, count: maxBits + 1)
        var pos = 0
        var lastLen = -1
        for (len, sym) in ordered {
            let c = nextCode[len]
            nextCode[len] += 1
            if len != lastLen {
                firstCode[len] = c
                firstIndex[len] = pos
                lastLen = len
            }
            symbols.append(UInt16(sym))
            pos += 1
        }
    }

    /// 逐位累积码字查表（最长 15 位）。
    func decode(from reader: inout BitReader) throws -> UInt16 {
        var code = 0
        for len in 1...max(maxLen, 1) {
            code = (code << 1) | Int(try reader.bits(1, "huffman"))
            if len <= maxLen, firstCode[len] >= 0 {
                let index = code - firstCode[len]
                if index >= 0, index < spanOf(len) {
                    return symbols[firstIndex[len] + index]
                }
            }
        }
        throw Inflate.InflateError.invalidSymbol
    }

    /// 码长 len 的符号数（查 firstIndex 差分，末段用总数）。
    private func spanOf(_ len: Int) -> Int {
        var next = symbols.count
        if len < maxLen {
            for l in (len + 1)...maxLen {
                if firstCode[l] >= 0 { next = firstIndex[l]; break }
            }
        }
        return next - firstIndex[len]
    }

    static func fixedLitLen() throws -> Huffman {
        var lens = [Int](repeating: 0, count: 288)
        for i in 0...143 { lens[i] = 8 }
        for i in 144...255 { lens[i] = 9 }
        for i in 256...279 { lens[i] = 7 }
        for i in 280...287 { lens[i] = 8 }
        return try Huffman(lengths: lens)
    }

    static func fixedDist() throws -> Huffman {
        try Huffman(lengths: [Int](repeating: 5, count: 32))
    }
}
