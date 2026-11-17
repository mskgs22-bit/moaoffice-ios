import Foundation

/// 글자만 담은 아주 작은 워드(.docx) 문서 (압축 없는 ZIP)
enum DocxWriter {
    static func make(text: String) -> Data {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        }
        let paras = text.components(separatedBy: "\n").map { line -> String in
            line.isEmpty ? "<w:p/>" : "<w:p><w:r><w:rPr><w:rFonts w:eastAsia=\"맑은 고딕\"/></w:rPr><w:t xml:space=\"preserve\">\(esc(line))</w:t></w:r></w:p>"
        }.joined()
        let doc = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>\(paras)<w:sectPr><w:pgSz w:w="11906" w:h="16838"/><w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440" w:header="851" w:footer="992" w:gutter="0"/></w:sectPr></w:body></w:document>
        """
        let types = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>
        """
        let rels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>
        """
        return zip([("[Content_Types].xml", Data(types.utf8)), ("_rels/.rels", Data(rels.utf8)), ("word/document.xml", Data(doc.utf8))])
    }

    private static let crcTable: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
        return c
    }
    static func crc32(_ d: Data) -> UInt32 {
        var c: UInt32 = 0xFFFFFFFF
        for b in d { c = crcTable[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFFFFFF
    }

    static func zip(_ entries: [(String, Data)]) -> Data {
        var out = Data()
        var central = Data()
        func u16(_ d: inout Data, _ v: Int) { var x = UInt16(v).littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        func u32(_ d: inout Data, _ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        for (name, data) in entries {
            let n = Data(name.utf8)
            let crc = crc32(data)
            let off = UInt32(out.count)
            let size = UInt32(data.count)
            // 로컬 헤더
            u32(&out, 0x04034b50); u16(&out, 20); u16(&out, 0x0800); u16(&out, 0); u16(&out, 0); u16(&out, 0x21)
            u32(&out, crc); u32(&out, size); u32(&out, size); u16(&out, n.count); u16(&out, 0)
            out.append(n); out.append(data)
            // 중앙 디렉터리
            u32(&central, 0x02014b50); u16(&central, 20); u16(&central, 20); u16(&central, 0x0800); u16(&central, 0); u16(&central, 0); u16(&central, 0x21)
            u32(&central, crc); u32(&central, size); u32(&central, size); u16(&central, n.count); u16(&central, 0); u16(&central, 0)
            u16(&central, 0); u16(&central, 0); u32(&central, 0); u32(&central, off)
            central.append(n)
        }
        let cdOff = UInt32(out.count)
        let cdSize = UInt32(central.count)
        out.append(central)
        u32(&out, 0x06054b50); u16(&out, 0); u16(&out, 0); u16(&out, entries.count); u16(&out, entries.count)
        u32(&out, cdSize); u32(&out, cdOff); u16(&out, 0)
        return out
    }
}
