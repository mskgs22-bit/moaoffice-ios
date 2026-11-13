// 본 제품은 한글과컴퓨터의 한/글 문서 파일(.hwp) 공개 문서를 참고하여 개발하였습니다.
import Foundation

/// HWP 5.x 바이너리 → 문단·표. (Android engine-hwp 의 Hwp5Engine 을 옮긴 것, 서식은 생략)
enum Hwp5Parser {
    struct Rec { let tag: Int; let level: Int; let data: [UInt8] }

    static let B = 16
    static let PARA_HEADER = B + 50, PARA_TEXT = B + 51, CTRL_HEADER = B + 55, LIST_HEADER = B + 56, TABLE = B + 61

    static func ctrlId(_ s: String) -> Int {
        let u = Array(s.utf8)
        return (Int(u[0]) << 24) | (Int(u[1]) << 16) | (Int(u[2]) << 8) | Int(u[3])
    }
    static let TBL = ctrlId("tbl "), HEAD = ctrlId("head"), FOOT = ctrlId("foot"), FN = ctrlId("fn  "), EN = ctrlId("en  ")

    static func parse(_ data: Data) throws -> HwpDocument {
        if data.prefix(19) == Data("HWP Document File V".utf8) { throw DocError.unsupported("hwp_3x") }
        let cfb = try CfbReader(data)
        guard let fh = cfb.read("FileHeader"), fh.count >= 40,
              String(decoding: fh[0..<17], as: UTF8.self) == "HWP Document File" else { throw DocError.corrupted("hwp_header") }
        let version = le32(fh, 32), props = le32(fh, 36)
        guard (version >> 24) == 5 else { throw DocError.unsupported("hwp_version") }
        if props & 2 != 0 { throw DocError.encrypted }
        if props & 4 != 0 || props & 0x10 != 0 || props & 0x400 != 0 { throw DocError.drm }
        let compressed = props & 1 != 0

        var blocks: [HwpBlock] = []
        var i = 0
        while let raw = cfb.read("BodyText/Section\(i)") {
            let d = try (compressed ? RawInflate.inflate(raw) : raw)
            var cur = Cursor(recs: records(d))
            if i > 0 { blocks.append(.pageBreak) }
            blocks += paragraphs(&cur, level: 0, count: .max)
            i += 1
        }
        guard i > 0 else { throw DocError.corrupted("hwp_no_section") }
        return HwpDocument(blocks: blocks)
    }

    static func records(_ d: [UInt8]) -> [Rec] {
        var out: [Rec] = []
        var p = 0
        while p + 4 <= d.count {
            let h = le32(d, p); p += 4
            let tag = h & 0x3FF, level = (h >> 10) & 0x3FF
            var size = (h >> 20) & 0xFFF
            if size == 0xFFF { guard p + 4 <= d.count else { break }; size = le32(d, p); p += 4 }
            guard p + size <= d.count else { break }
            out.append(Rec(tag: tag, level: level, data: Array(d[p..<(p + size)])))
            p += size
        }
        return out
    }

    struct Cursor {
        let recs: [Rec]
        var i = 0
        var peek: Rec? { i < recs.count ? recs[i] : nil }
    }

    static func paragraphs(_ c: inout Cursor, level: Int, count: Int) -> [HwpBlock] {
        var out: [HwpBlock] = []
        var n = 0
        while n < count, let r = c.peek {
            if r.level < level { break }
            if r.tag == PARA_HEADER && r.level == level { c.i += 1; out += paragraph(&c, r); n += 1 }
            else if r.level == level { break }
            else { c.i += 1 }
        }
        return out
    }

    private static let extended: Set<Int> = [1, 2, 3, 11, 12, 14, 15, 16, 17, 18, 21, 22, 23]
    private static let inline: Set<Int> = [4, 5, 6, 7, 8, 19, 20]

    static func paragraph(_ c: inout Cursor, _ ph: Rec) -> [HwpBlock] {
        let lv = ph.level
        var text: [UInt16] = []
        var ctrlBlocks: [[HwpBlock]] = []
        var out: [HwpBlock] = []
        if (ph.data.count > 11 ? Int(ph.data[11]) : 0) & 4 != 0 { out.append(.pageBreak) }
        while let r = c.peek, r.level > lv {
            if r.level == lv + 1 {
                switch r.tag {
                case PARA_TEXT:
                    text = (0..<(r.data.count / 2)).map { UInt16(le16(r.data, $0 * 2)) }
                    c.i += 1
                case CTRL_HEADER:
                    c.i += 1
                    ctrlBlocks.append(control(&c, r))
                default:
                    c.i += 1
                }
            } else { c.i += 1 }
        }
        var s = ""
        var k = 0, ci = 0
        var hadTable = false
        while k < text.count {
            let ch = Int(text[k])
            switch ch {
            case 13: k += 1
            case 10: s += "\n"; k += 1
            case 9: s += "\t"; k += 8
            case 24: s += "-"; k += 1
            case 30, 31: s += " "; k += 1
            case _ where inline.contains(ch): k += 8
            case _ where extended.contains(ch):
                if ci < ctrlBlocks.count {
                    let bl = ctrlBlocks[ci]
                    if !bl.isEmpty {
                        if !s.trimmingCharacters(in: .whitespaces).isEmpty { out.append(.paragraph(s)); s = "" }
                        out += bl
                        hadTable = true
                    }
                }
                ci += 1
                k += 8
            case 0..<32: k += 1
            default:
                if let u = Unicode.Scalar(UInt32(ch)) { s.unicodeScalars.append(u) }
                k += 1
            }
        }
        if !hadTable || !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { out.append(.paragraph(s)) }
        return out
    }

    static func control(_ c: inout Cursor, _ ch: Rec) -> [HwpBlock] {
        let id = le32(ch.data, 0)
        let lv = ch.level
        if id == TBL { return [table(&c, ch)] }
        // 머리말·꼬리말·각주 등은 본문 흐름에서 건너뛴다
        while let r = c.peek, r.level > lv { c.i += 1 }
        return []
    }

    static func table(_ c: inout Cursor, _ ch: Rec) -> HwpBlock {
        let lv = ch.level
        var tb = TableBuilder()
        while let r = c.peek, r.level > lv {
            if r.tag == LIST_HEADER {
                c.i += 1
                let d = r.data
                let nPara = le16(d, 0)
                let col = le16(d, 8), row = le16(d, 10)
                let cs = max(1, le16(d, 12)), rs = max(1, le16(d, 14))
                let inner = paragraphs(&c, level: r.level, count: nPara)
                let text = inner.map { b -> String in
                    switch b {
                    case .paragraph(let t): return t
                    case .table(let rows, _): return rows.map { $0.map { $0.text }.joined(separator: " | ") }.joined(separator: "\n")
                    case .pageBreak: return ""
                    }
                }.joined(separator: "\n")
                tb.cells.append((row, HwpCell(text: text, col: col, colSpan: cs, rowSpan: rs)))
            } else {
                c.i += 1
            }
        }
        return tb.build()
    }
}
