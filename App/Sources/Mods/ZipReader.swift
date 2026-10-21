import Foundation
import Compression

/// Minimal read-only ZIP reader (stored + deflate) for inspecting mod jars and
/// modpacks without third-party code. ZIP64 archives are not supported.
struct ZipReader {
    struct Entry {
        let name: String
        let method: UInt16
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int
        var isDirectory: Bool { name.hasSuffix("/") }
    }

    enum ZipError: LocalizedError {
        case notZip, truncated, unsupportedMethod(UInt16), inflateFailed(String)
        var errorDescription: String? {
            switch self {
            case .notZip: return "Not a ZIP/JAR archive"
            case .truncated: return "Archive is truncated"
            case .unsupportedMethod(let m): return "Unsupported compression method \(m)"
            case .inflateFailed(let n): return "Could not decompress \(n)"
            }
        }
    }

    let data: Data
    let entries: [Entry]

    init(url: URL) throws {
        try self.init(data: Data(contentsOf: url, options: .mappedIfSafe))
    }

    init(data: Data) throws {
        self.data = data
        entries = try Self.readCentralDirectory(data)
    }

    func entry(_ name: String) -> Entry? { entries.first { $0.name == name } }

    func contents(of name: String) throws -> Data? {
        guard let e = entry(name) else { return nil }
        return try contents(of: e)
    }

    func contents(of e: Entry) throws -> Data {
        let base = data.startIndex
        let h = e.localHeaderOffset
        guard h + 30 <= data.count, data.u32(base + h) == 0x04034b50 else { throw ZipError.truncated }
        let nameLen = Int(data.u16(base + h + 26))
        let extraLen = Int(data.u16(base + h + 28))
        let start = h + 30 + nameLen + extraLen
        guard start + e.compressedSize <= data.count else { throw ZipError.truncated }
        let raw = data.subdata(in: (base + start)..<(base + start + e.compressedSize))
        switch e.method {
        case 0: return raw
        case 8: return try Self.inflate(raw, expected: e.uncompressedSize, name: e.name)
        default: throw ZipError.unsupportedMethod(e.method)
        }
    }

    static func inflate(_ raw: Data, expected: Int, name: String) throws -> Data {
        if expected == 0 { return Data() }
        var out = Data(count: expected)
        let written = out.withUnsafeMutableBytes { dst in
            raw.withUnsafeBytes { src in
                // COMPRESSION_ZLIB is raw DEFLATE (RFC 1951), exactly what ZIP stores.
                compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, expected,
                                          src.bindMemory(to: UInt8.self).baseAddress!, raw.count,
                                          nil, COMPRESSION_ZLIB)
            }
        }
        guard written == expected else { throw ZipError.inflateFailed(name) }
        return out
    }

    private static func readCentralDirectory(_ data: Data) throws -> [Entry] {
        let base = data.startIndex
        guard data.count >= 22 else { throw ZipError.notZip }
        // End of central directory: scan back over a possible comment.
        var eocd = -1
        var i = data.count - 22
        let floor = max(0, data.count - 22 - 65535)
        while i >= floor {
            if data.u32(base + i) == 0x06054b50 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw ZipError.notZip }
        let count = Int(data.u16(base + eocd + 10))
        var offset = Int(data.u32(base + eocd + 16))
        var entries: [Entry] = []
        entries.reserveCapacity(count)
        for _ in 0..<count {
            guard offset + 46 <= data.count, data.u32(base + offset) == 0x02014b50 else { throw ZipError.truncated }
            let method = data.u16(base + offset + 10)
            let csize = Int(data.u32(base + offset + 20))
            let usize = Int(data.u32(base + offset + 24))
            let nameLen = Int(data.u16(base + offset + 28))
            let extraLen = Int(data.u16(base + offset + 30))
            let commentLen = Int(data.u16(base + offset + 32))
            let local = Int(data.u32(base + offset + 42))
            guard offset + 46 + nameLen <= data.count else { throw ZipError.truncated }
            let nameData = data.subdata(in: (base + offset + 46)..<(base + offset + 46 + nameLen))
            let name = String(decoding: nameData, as: UTF8.self)
            entries.append(Entry(name: name, method: method, compressedSize: csize, uncompressedSize: usize, localHeaderOffset: local))
            offset += 46 + nameLen + extraLen + commentLen
        }
        return entries
    }

    /// Extracts entries under `prefix` into `destination`, refusing paths that
    /// escape it ("zip slip").
    func extract(prefix: String, to destination: URL) throws -> Int {
        let fm = FileManager.default
        let root = destination.standardizedFileURL.path
        var count = 0
        for e in entries where e.name.hasPrefix(prefix) && !e.isDirectory {
            let relative = String(e.name.dropFirst(prefix.count))
            guard !relative.isEmpty else { continue }
            let target = destination.appendingPathComponent(relative).standardizedFileURL
            guard target.path.hasPrefix(root + "/") else { throw InstallError.invalidFile("unsafe path \(e.name)") }
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents(of: e).write(to: target, options: .atomic)
            count += 1
        }
        return count
    }
}

private extension Data {
    func u16(_ i: Int) -> UInt16 { UInt16(self[i]) | UInt16(self[i + 1]) << 8 }
    func u32(_ i: Int) -> UInt32 {
        UInt32(self[i]) | UInt32(self[i + 1]) << 8 | UInt32(self[i + 2]) << 16 | UInt32(self[i + 3]) << 24
    }
}
