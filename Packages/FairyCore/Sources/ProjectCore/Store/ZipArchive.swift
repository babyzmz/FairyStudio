import Foundation

/// ZIP 编解码（ProjectCore 自带，不引入第三方依赖）。
/// - 写：仅 stored（不压缩），处处可读；
/// - 读：stored + deflated（自带 raw inflate，RFC 1951；系统 Compression 框架解不开多块 deflate，故不用）；
/// - 拒绝：加密、data-descriptor（无预填大小）、目录穿越由调用方校验。
public enum ZipArchive {
    public struct Entry: Sendable, Hashable {
        /// ZIP 内原始名（/ 分隔，UTF-8）。
        public var name: String
        public var data: Data
        public var isDirectory: Bool
        public var isSymlink: Bool
        public init(name: String, data: Data, isDirectory: Bool = false, isSymlink: Bool = false) {
            self.name = name; self.data = data; self.isDirectory = isDirectory; self.isSymlink = isSymlink
        }
    }

    public enum ZipError: Error, Sendable, Hashable {
        case corrupt(String)
        case unsupported(String)
    }

    // MARK: - 写（stored）

    public static func encode(_ entries: [Entry]) -> Data {
        var out = Data()
        var central = Data()
        for entry in entries {
            let name = Data(entry.name.utf8)
            let crc = crc32(entry.data)
            var local = Data()
            local.appendLE32(0x0403_4B50)
            local.appendLE16(20) // 解压所需版本
            local.appendLE16(0x0800) // UTF-8 文件名
            local.appendLE16(0) // stored
            local.appendLE16(0x7E7E); local.appendLE16(0x1F80) // 时间日期占位
            local.appendLE32(crc)
            local.appendLE32(UInt32(entry.data.count))
            local.appendLE32(UInt32(entry.data.count))
            local.appendLE16(UInt16(name.count))
            local.appendLE16(0)
            let localOffset = UInt32(out.count)
            out.append(local); out.append(name); out.append(entry.data)
            var c = Data()
            c.appendLE32(0x0201_4B50)
            c.appendLE16(20); c.appendLE16(20)
            c.appendLE16(0x0800); c.appendLE16(0)
            c.appendLE16(0x7E7E); c.appendLE16(0x1F80)
            c.appendLE32(crc)
            c.appendLE32(UInt32(entry.data.count))
            c.appendLE32(UInt32(entry.data.count))
            c.appendLE16(UInt16(name.count))
            c.appendLE16(0); c.appendLE16(0); c.appendLE16(0); c.appendLE16(0)
            // 目录 / 符号链接标记进外部属性，读回时可识别。
            var attrs: UInt32 = entry.isDirectory ? (0o040000 << 16) : (0o100644 << 16)
            if entry.isSymlink { attrs = UInt32(0o120777) << 16 }
            c.appendLE32(attrs)
            c.appendLE32(localOffset)
            central.append(c); central.append(name)
        }
        let centralOffset = UInt32(out.count)
        out.append(central)
        var end = Data()
        end.appendLE32(0x0605_4B50)
        end.appendLE16(0); end.appendLE16(0)
        end.appendLE16(UInt16(entries.count)); end.appendLE16(UInt16(entries.count))
        end.appendLE32(UInt32(central.count))
        end.appendLE32(centralOffset)
        end.appendLE16(0)
        out.append(end)
        return out
    }

    // MARK: - 读（stored + deflate）

    public struct DecodeLimits: Sendable {
        public var maxFiles: Int
        public var maxFileBytes: Int
        public var maxTotalBytes: Int
        public init(maxFiles: Int = 100, maxFileBytes: Int = 256 << 10, maxTotalBytes: Int = 2 << 20) {
            self.maxFiles = maxFiles; self.maxFileBytes = maxFileBytes; self.maxTotalBytes = maxTotalBytes
        }
    }

    public static func decode(_ data: Data, limits: DecodeLimits = .init()) throws -> [Entry] {
        guard limits.maxFiles >= 0, limits.maxFileBytes >= 0, limits.maxTotalBytes >= 0 else {
            throw ZipError.corrupt("非法解压限额")
        }
        guard let eocd = findEOCD(in: data) else { throw ZipError.corrupt("找不到 EOCD") }
        let count = Int(eocd.count)
        guard count <= limits.maxFiles else { throw ZipError.corrupt("ZIP 条目数超限") }
        let centralOffset = Int(eocd.centralOffset)
        var entries: [Entry] = []
        var cursor = centralOffset
        var total = 0
        for _ in 0..<count {
            let h: CentralHeader = try read(&cursor, data, "中央目录越界")
            guard h.signature == 0x0201_4B50 else { throw ZipError.corrupt("中央目录签名错误") }
            guard h.flags & 0x01 == 0 else { throw ZipError.unsupported("不支持加密 ZIP") }
            guard h.flags & 0x08 == 0 else { throw ZipError.unsupported("不支持 data-descriptor 条目：\(h.name)") }
            var localCursor = Int(h.localOffset)
            let l: LocalHeader = try read(&localCursor, data, "本地头越界")
            guard l.signature == 0x0403_4B50 else { throw ZipError.corrupt("本地头签名错误") }
            let extra = Int(l.nameLength) + Int(l.extraLength)
            guard localCursor <= data.count, extra <= data.count - localCursor else {
                throw ZipError.corrupt("本地文件名或扩展区越界")
            }
            localCursor += extra
            let compressed = Int(h.compressedSize), expanded = Int(h.uncompressedSize)
            guard localCursor <= data.count, compressed <= data.count - localCursor else {
                throw ZipError.corrupt("压缩内容越界")
            }
            guard expanded <= limits.maxFileBytes, total <= limits.maxTotalBytes,
                  expanded <= limits.maxTotalBytes - total else { throw ZipError.corrupt("ZIP 解压大小超限") }
            try Task.checkCancellation()
            let raw = data[localCursor..<(localCursor + compressed)]
            let bytes: Data
            switch h.method {
            case 0:
                guard compressed == expanded else { throw ZipError.corrupt("stored 大小不符") }
                bytes = Data(raw)
            case 8: bytes = try inflateRaw(Data(raw), expectedSize: Int(h.uncompressedSize), crc: h.crc)
            default: throw ZipError.unsupported("不支持的压缩方法 \(h.method)：\(h.name)")
            }
            guard bytes.count == expanded, crc32(bytes) == h.crc else {
                throw ZipError.corrupt("条目大小或 CRC32 不符")
            }
            total += bytes.count
            let fileType = (h.externalAttrs >> 16) & 0o170000
            entries.append(Entry(name: h.name, data: bytes,
                                 isDirectory: h.name.hasSuffix("/"),
                                 isSymlink: fileType == 0o120000))
        }
        return entries
    }

    // MARK: - deflate 解码（自带 raw inflate，RFC 1951；解完自验 CRC32 与大小）

    private static func inflateRaw(_ raw: Data, expectedSize: Int, crc: UInt32) throws -> Data {
        let out = try Inflate.decode(raw, expectedSize: expectedSize)
        guard out.count == expectedSize else { throw ZipError.corrupt("解压后大小不符（期望 \(expectedSize)，实际 \(out.count)）") }
        guard crc32(out) == crc else { throw ZipError.corrupt("CRC32 不符") }
        return out
    }

    // MARK: - 解析辅助

    private struct EOCD { var count: UInt16; var centralOffset: UInt32 }
    private struct CentralHeader {
        var signature: UInt32; var flags: UInt16; var method: UInt16
        var crc: UInt32; var compressedSize: UInt32; var uncompressedSize: UInt32
        var name: String; var externalAttrs: UInt32; var localOffset: UInt32
    }
    private struct LocalHeader { var signature: UInt32; var nameLength: UInt16; var extraLength: UInt16 }

    private static func findEOCD(in data: Data) -> EOCD? {
        // EOCD 在末尾 22 字节 + 注释（最多 64KB）范围内。
        let lo = max(0, data.count - (22 + 65536))
        var i = data.count - 22
        while i >= lo {
            if data[i] == 0x50, data[i+1] == 0x4B, data[i+2] == 0x05, data[i+3] == 0x06 {
                let count = data.u16(at: i + 10)
                let centralOffset = data.u32(at: i + 16)
                return EOCD(count: count, centralOffset: centralOffset)
            }
            i -= 1
        }
        return nil
    }

    private static func read(_ cursor: inout Int, _ data: Data, _ what: String) throws -> CentralHeader {
        guard cursor + 46 <= data.count else { throw ZipError.corrupt(what) }
        let sig = data.u32(at: cursor)
        let flags = data.u16(at: cursor + 8)
        let method = data.u16(at: cursor + 10)
        let crc = data.u32(at: cursor + 16)
        let comp = data.u32(at: cursor + 20)
        let uncomp = data.u32(at: cursor + 24)
        let nameLen = Int(data.u16(at: cursor + 28))
        let extraLen = Int(data.u16(at: cursor + 30))
        let commentLen = Int(data.u16(at: cursor + 32))
        let attrs = data.u32(at: cursor + 38)
        let localOff = data.u32(at: cursor + 42)
        cursor += 46
        guard cursor + nameLen <= data.count else { throw ZipError.corrupt("文件名越界") }
        let name = String(decoding: data[cursor..<cursor + nameLen], as: UTF8.self)
        let tail = nameLen + extraLen + commentLen
        guard tail <= data.count - cursor else { throw ZipError.corrupt("中央目录扩展区越界") }
        cursor += tail
        return CentralHeader(signature: sig, flags: flags, method: method, crc: crc,
                             compressedSize: comp, uncompressedSize: uncomp,
                             name: name, externalAttrs: attrs, localOffset: localOff)
    }

    private static func read(_ cursor: inout Int, _ data: Data, _ what: String) throws -> LocalHeader {
        guard cursor + 30 <= data.count else { throw ZipError.corrupt(what) }
        let sig = data.u32(at: cursor)
        let nameLen = data.u16(at: cursor + 26)
        let extraLen = data.u16(at: cursor + 28)
        cursor += 30
        return LocalHeader(signature: sig, nameLength: nameLen, extraLength: extraLen)
    }

    /// CRC-32（IEEE）。ZIP 完整性自验用。
    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc & 1) == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1 }
        }
        return crc ^ 0xFFFF_FFFF
    }
}

private extension Data {
    func u16(at i: Int) -> UInt16 { UInt16(self[i]) | (UInt16(self[i + 1]) << 8) }
    func u32(at i: Int) -> UInt32 { UInt32(self[i]) | (UInt32(self[i + 1]) << 8) | (UInt32(self[i + 2]) << 16) | (UInt32(self[i + 3]) << 24) }
    mutating func appendLE16(_ v: UInt16) { append(UInt8(v & 0xFF)); append(UInt8((v >> 8) & 0xFF)) }
    mutating func appendLE32(_ v: UInt32) {
        append(UInt8(v & 0xFF)); append(UInt8((v >> 8) & 0xFF)); append(UInt8((v >> 16) & 0xFF)); append(UInt8((v >> 24) & 0xFF))
    }
}
