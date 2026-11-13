import Foundation

enum DocError: LocalizedError {
    case corrupted(String)
    case unsupported(String)
    case encrypted
    case drm

    var errorDescription: String? {
        switch self {
        case .corrupted: return String(localized: "This file seems to be damaged.")
        case .unsupported: return String(localized: "This file version is not supported.")
        case .encrypted: return String(localized: "Password-protected HWP files are not supported.")
        case .drm: return String(localized: "Distribution or DRM-protected documents cannot be opened.")
        }
    }
}

@inline(__always) func le16(_ b: [UInt8], _ i: Int) -> Int {
    guard i >= 0, i + 1 < b.count else { return 0 }
    return Int(b[i]) | (Int(b[i + 1]) << 8)
}

@inline(__always) func le32(_ b: [UInt8], _ i: Int) -> Int {
    guard i >= 0, i + 3 < b.count else { return 0 }
    return le16(b, i) | (le16(b, i + 2) << 16)
}

enum RawInflate {
    /// Raw DEFLATE (RFC 1951, no zlib header). NSData `.zlib` 알고리즘이 정확히 이 형식이다.
    static func inflate(_ bytes: [UInt8]) throws -> [UInt8] {
        guard !bytes.isEmpty else { return [] }
        do {
            let out = try (Data(bytes) as NSData).decompressed(using: .zlib) as Data
            return [UInt8](out)
        } catch {
            throw DocError.corrupted("inflate")
        }
    }
}

/// 최소 ZIP 리더 (stored / deflate). HWPX·DOCX 등 OOXML/OWPML 컨테이너용.
struct ZipReader {
    struct Entry { let name: String; let method: Int; let compSize: Int; let size: Int; let localOffset: Int }
    let bytes: [UInt8]
    private(set) var entries: [String: Entry] = [:]

    init(_ data: Data) throws {
        bytes = [UInt8](data)
        guard bytes.count >= 22 else { throw DocError.corrupted("zip_small") }
        var eocd = -1
        var i = bytes.count - 22
        let stop = max(0, bytes.count - 22 - 65_535)
        while i >= stop {
            if bytes[i] == 0x50, bytes[i + 1] == 0x4B, bytes[i + 2] == 0x05, bytes[i + 3] == 0x06 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw DocError.corrupted("zip_eocd") }
        let count = le16(bytes, eocd + 10)
        var p = le32(bytes, eocd + 16)
        for _ in 0..<count {
            guard le32(bytes, p) == 0x02014B50 else { break }
            let method = le16(bytes, p + 10)
            let comp = le32(bytes, p + 20)
            let size = le32(bytes, p + 24)
            let n = le16(bytes, p + 28), e = le16(bytes, p + 30), c = le16(bytes, p + 32)
            let local = le32(bytes, p + 42)
            guard p + 46 + n <= bytes.count else { break }
            let name = String(decoding: bytes[(p + 46)..<(p + 46 + n)], as: UTF8.self)
            entries[name] = Entry(name: name, method: method, compSize: comp, size: size, localOffset: local)
            p += 46 + n + e + c
        }
    }

    var names: [String] { Array(entries.keys) }

    func read(_ name: String) throws -> [UInt8]? {
        guard let e = entries[name] else { return nil }
        let lp = e.localOffset
        guard le32(bytes, lp) == 0x04034B50 else { throw DocError.corrupted("zip_local") }
        let start = lp + 30 + le16(bytes, lp + 26) + le16(bytes, lp + 28)
        guard start + e.compSize <= bytes.count else { throw DocError.corrupted("zip_range") }
        let raw = Array(bytes[start..<(start + e.compSize)])
        switch e.method {
        case 0: return raw
        case 8: return try RawInflate.inflate(raw)
        default: throw DocError.unsupported("zip_method")
        }
    }
}

/// 최소 Compound File Binary(OLE2) 리더. HWP 5.x 용.
struct CfbReader {
    private let b: [UInt8]
    private let secSize: Int
    private let miniSize: Int
    private let cutoff: Int
    private var fat: [Int] = []
    private var miniFat: [Int] = []
    private var miniStream: [UInt8] = []
    private var streams: [String: (start: Int, size: Int)] = [:]

    init(_ data: Data) throws {
        b = [UInt8](data)
        let sig: [UInt8] = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]
        guard b.count >= 512, Array(b[0..<8]) == sig else { throw DocError.corrupted("cfb_sig") }
        secSize = 1 << le16(b, 30)
        miniSize = 1 << le16(b, 32)
        cutoff = le32(b, 56)
        guard secSize == 512 || secSize == 4096 else { throw DocError.corrupted("cfb_sector") }

        // DIFAT → FAT 섹터 목록
        var fatSectors: [Int] = []
        for k in 0..<109 {
            let s = le32(b, 76 + k * 4)
            if s >= 0 && s < 0xFFFF_FFFA { fatSectors.append(s) }
        }
        var difat = le32(b, 68)
        var guardCount = 0
        while difat < 0xFFFF_FFFA && guardCount < 10_000 {
            let off = (difat + 1) * secSize
            guard off + secSize <= b.count else { break }
            let per = secSize / 4 - 1
            for k in 0..<per {
                let s = le32(b, off + k * 4)
                if s < 0xFFFF_FFFA { fatSectors.append(s) }
            }
            difat = le32(b, off + per * 4)
            guardCount += 1
        }
        var f: [Int] = []
        f.reserveCapacity(fatSectors.count * secSize / 4)
        for s in fatSectors {
            let off = (s + 1) * secSize
            guard off + secSize <= b.count else { continue }
            for k in 0..<(secSize / 4) { f.append(le32(b, off + k * 4)) }
        }
        fat = f

        // 디렉터리
        let dir = chain(le32(b, 48))
        var entries: [(name: String, type: Int, left: Int, right: Int, child: Int, start: Int, size: Int)] = []
        var k = 0
        while k + 128 <= dir.count {
            let nameLen = le16(dir, k + 64)
            let n = max(0, min(64, nameLen) - 2)
            let name = String(decoding: stride(from: 0, to: n, by: 2).map { UInt16(le16(dir, k + $0)) }, as: UTF16.self)
            entries.append((name, Int(dir[k + 66]), le32(dir, k + 68), le32(dir, k + 72), le32(dir, k + 76), le32(dir, k + 116), le32(dir, k + 120)))
            k += 128
        }
        guard let root = entries.first else { throw DocError.corrupted("cfb_dir") }
        miniStream = Self.read(chainOf: root.start, size: root.size, fat: fat, b: b, secSize: secSize)

        var mf: [Int] = []
        for s in Self.sectors(start: le32(b, 60), fat: fat) {
            let off = (s + 1) * secSize
            guard off + secSize <= b.count else { continue }
            for q in 0..<(secSize / 4) { mf.append(le32(b, off + q * 4)) }
        }
        miniFat = mf

        var map: [String: (Int, Int)] = [:]
        var visited = Set<Int>()
        func walk(_ idx: Int, _ prefix: String) {
            guard idx >= 0, idx < entries.count, !visited.contains(idx) else { return }
            visited.insert(idx)
            let e = entries[idx]
            walk(e.left, prefix)
            walk(e.right, prefix)
            let path = prefix.isEmpty ? e.name : prefix + "/" + e.name
            if e.type == 2 { map[path] = (e.start, e.size) }
            if e.type == 1 { walk(e.child, path) }
        }
        walk(root.child, "")
        streams = map.mapValues { (start: $0.0, size: $0.1) }
    }

    private static func sectors(start: Int, fat: [Int]) -> [Int] {
        var out: [Int] = []
        var s = start
        var seen = Set<Int>()
        while s >= 0 && s < fat.count && !seen.contains(s) {
            seen.insert(s); out.append(s); s = fat[s]
        }
        return out
    }

    private static func read(chainOf start: Int, size: Int, fat: [Int], b: [UInt8], secSize: Int) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(size)
        for s in sectors(start: start, fat: fat) {
            let off = (s + 1) * secSize
            guard off < b.count else { break }
            out.append(contentsOf: b[off..<min(b.count, off + secSize)])
            if out.count >= size { break }
        }
        return out.count > size ? Array(out[0..<size]) : out
    }

    private func chain(_ start: Int) -> [UInt8] {
        Self.read(chainOf: start, size: Int.max, fat: fat, b: b, secSize: secSize)
    }

    func read(_ path: String) -> [UInt8]? {
        guard let s = streams[path] else { return nil }
        if s.size < cutoff {
            var out: [UInt8] = []
            out.reserveCapacity(s.size)
            var m = s.start
            var seen = Set<Int>()
            while m >= 0 && m < miniFat.count + 1 && !seen.contains(m) && out.count < s.size {
                seen.insert(m)
                let off = m * miniSize
                guard off < miniStream.count else { break }
                out.append(contentsOf: miniStream[off..<min(miniStream.count, off + miniSize)])
                guard m < miniFat.count else { break }
                m = miniFat[m]
            }
            return out.count > s.size ? Array(out[0..<s.size]) : out
        }
        return Self.read(chainOf: s.start, size: s.size, fat: fat, b: b, secSize: secSize)
    }
}
