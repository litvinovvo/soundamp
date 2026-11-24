import Compression
import Foundation

/// Read-only ZIP reader for skin archives (.wsz). Supports stored and deflate
/// entries, which is what Winamp skins use. No ZIP64, no encryption.
public struct ZipArchive {
    public struct Entry {
        public let path: String
        public let method: UInt16
        public let compressedSize: Int
        public let uncompressedSize: Int
        let localHeaderOffset: Int

        public var isDirectory: Bool { path.hasSuffix("/") }
        /// Last path component, e.g. "xmms-turquoise/Main.bmp" → "Main.bmp".
        public var fileName: String { path.split(separator: "/").last.map(String.init) ?? path }
    }

    /// Skins are a few hundred KB; refuse absurd entries (zip bombs, bogus headers).
    public static let maxEntrySize = 32 * 1024 * 1024

    public enum ZipError: Error, Equatable {
        case tooLarge(String)
        case notAZip
        case corrupt(String)
        case unsupportedMethod(UInt16)
        case decompressionFailed(String)
    }

    public let entries: [Entry]
    private let data: Data

    public init(data: Data) throws {
        self.data = data
        guard data.count >= 22 else { throw ZipError.notAZip }

        // End of central directory record: scan backwards (it may be followed by a comment).
        let eocdSig: UInt32 = 0x0605_4B50
        var eocd = -1
        let lowest = max(0, data.count - 22 - 65_535)
        var i = data.count - 22
        while i >= lowest {
            if data.u32(i) == eocdSig { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw ZipError.notAZip }

        let count = Int(data.u16(eocd + 10))
        let cdOffset = Int(data.u32(eocd + 16))
        guard cdOffset < data.count else { throw ZipError.corrupt("central directory offset") }

        var list: [Entry] = []
        var p = cdOffset
        for _ in 0..<count {
            guard p + 46 <= data.count, data.u32(p) == 0x0201_4B50 else { throw ZipError.corrupt("central directory entry") }
            let flags = data.u16(p + 8)
            let method = data.u16(p + 10)
            let csize = Int(data.u32(p + 20))
            let usize = Int(data.u32(p + 24))
            let nameLen = Int(data.u16(p + 28))
            let extraLen = Int(data.u16(p + 30))
            let commentLen = Int(data.u16(p + 32))
            let localOffset = Int(data.u32(p + 42))
            guard p + 46 + nameLen <= data.count else { throw ZipError.corrupt("file name") }
            let nameData = data.subdata(in: (p + 46)..<(p + 46 + nameLen))
            let utf8 = flags & 0x0800 != 0
            let name = (utf8 ? String(data: nameData, encoding: .utf8) : nil)
                ?? String(data: nameData, encoding: .utf8)
                ?? String(data: nameData, encoding: .isoLatin1) ?? ""
            list.append(Entry(path: name.replacingOccurrences(of: "\\", with: "/"), method: method,
                              compressedSize: csize, uncompressedSize: usize, localHeaderOffset: localOffset))
            p += 46 + nameLen + extraLen + commentLen
        }
        entries = list
    }

    public init(contentsOf url: URL) throws {
        try self.init(data: Data(contentsOf: url))
    }

    public func extract(_ entry: Entry) throws -> Data {
        guard entry.uncompressedSize <= Self.maxEntrySize, entry.compressedSize <= Self.maxEntrySize else {
            throw ZipError.tooLarge(entry.path)
        }
        let h = entry.localHeaderOffset
        guard h + 30 <= data.count, data.u32(h) == 0x0403_4B50 else { throw ZipError.corrupt("local header for \(entry.path)") }
        let start = h + 30 + Int(data.u16(h + 26)) + Int(data.u16(h + 28))
        guard start + entry.compressedSize <= data.count else { throw ZipError.corrupt("data for \(entry.path)") }
        let raw = data.subdata(in: start..<(start + entry.compressedSize))

        switch entry.method {
        case 0:
            return raw
        case 8:
            if entry.uncompressedSize == 0 { return Data() }
            var out = Data(count: entry.uncompressedSize)
            let written = out.withUnsafeMutableBytes { dst in
                raw.withUnsafeBytes { src in
                    compression_decode_buffer(
                        dst.bindMemory(to: UInt8.self).baseAddress!, entry.uncompressedSize,
                        src.bindMemory(to: UInt8.self).baseAddress!, raw.count,
                        nil, COMPRESSION_ZLIB) // COMPRESSION_ZLIB = raw DEFLATE (no zlib header)
                }
            }
            guard written == entry.uncompressedSize else { throw ZipError.decompressionFailed(entry.path) }
            return out
        default:
            throw ZipError.unsupportedMethod(entry.method)
        }
    }

    /// Case-insensitive lookup by file name, ignoring folders inside the
    /// archive. Like Winamp, the last matching entry wins.
    public func entry(named name: String) -> Entry? {
        let lower = name.lowercased()
        return entries.last { !$0.isDirectory && $0.fileName.lowercased() == lower }
    }

    /// Lookup by base name with any of the given extensions ("main", ["bmp", "png"]).
    public func entry(base: String, extensions: [String]) -> Entry? {
        let b = base.lowercased()
        return entries.last { e in
            guard !e.isDirectory else { return false }
            let n = e.fileName.lowercased()
            return extensions.contains { n == "\(b).\($0)" }
        }
    }
}

private extension Data {
    func u16(_ o: Int) -> UInt16 {
        UInt16(self[startIndex + o]) | UInt16(self[startIndex + o + 1]) << 8
    }

    func u32(_ o: Int) -> UInt32 {
        UInt32(u16(o)) | UInt32(u16(o + 2)) << 16
    }
}
