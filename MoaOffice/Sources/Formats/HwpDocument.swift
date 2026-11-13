// 본 제품은 한글과컴퓨터의 한/글 문서 파일(.hwp) 공개 문서를 참고하여 개발하였습니다.
// HWPX: 개방형 워드프로세서 마크업 언어(OWPML) 문서 구조 KS X 6101 을 참고하였습니다.
import Foundation

struct HwpCell: Hashable {
    var text: String
    var col: Int
    var colSpan: Int
    var rowSpan: Int
}

enum HwpBlock: Hashable {
    case paragraph(String)
    case table(rows: [[HwpCell]], columns: Int)
    case pageBreak
}

struct HwpDocument {
    var blocks: [HwpBlock]

    /// 표는 탭으로 이어 붙인 일반 텍스트 (PDF 내보내기·검색용)
    var plainText: String {
        blocks.map { block -> String in
            switch block {
            case .paragraph(let t): return t
            case .pageBreak: return ""
            case .table(let rows, _):
                return rows.map { $0.map { $0.text.replacingOccurrences(of: "\n", with: " ") }.joined(separator: "\t") }.joined(separator: "\n")
            }
        }.joined(separator: "\n")
    }

    static func open(_ url: URL) throws -> HwpDocument {
        let data = try Data(contentsOf: url)
        switch url.pathExtension.lowercased() {
        case "hwpx": return try HwpxParser.parse(data)
        default: return try Hwp5Parser.parse(data)
        }
    }
}

// MARK: - 표 조립 공통

struct TableBuilder {
    var cells: [(row: Int, cell: HwpCell)] = []
    var nextRow = 0
    var nextCol = 0

    func build() -> HwpBlock {
        let nRows = (cells.map { $0.row }.max() ?? -1) + 1
        var cols = 0
        for c in cells { cols = max(cols, c.cell.col + c.cell.colSpan) }
        let rows = (0..<nRows).map { r in cells.filter { $0.row == r }.map { $0.cell }.sorted { $0.col < $1.col } }
        return .table(rows: rows, columns: max(cols, 1))
    }
}

// MARK: - HWPX (OWPML, ZIP + XML)

final class HwpxParser: NSObject, XMLParserDelegate {
    static func parse(_ data: Data) throws -> HwpDocument {
        let zip = try ZipReader(data)
        let sections = zip.names
            .filter { $0.hasPrefix("Contents/section") && $0.hasSuffix(".xml") }
            .sorted { sectionIndex($0) < sectionIndex($1) }
        guard !sections.isEmpty else { throw DocError.corrupted("hwpx_no_section") }
        if zip.entries["META-INF/manifest.xml"] != nil,
           let manifest = try zip.read("META-INF/manifest.xml"),
           String(decoding: manifest, as: UTF8.self).contains("encryption-data") {
            throw DocError.encrypted
        }
        var blocks: [HwpBlock] = []
        for name in sections {
            guard let xml = try zip.read(name) else { continue }
            let p = HwpxParser()
            let parser = XMLParser(data: Data(xml))
            parser.delegate = p
            guard parser.parse() else { throw DocError.corrupted("hwpx_xml") }
            if !blocks.isEmpty { blocks.append(.pageBreak) }
            blocks += p.blocks
        }
        return HwpDocument(blocks: blocks)
    }

    private static func sectionIndex(_ s: String) -> Int {
        Int(s.dropFirst("Contents/section".count).dropLast(4)) ?? 0
    }

    // 상태
    private(set) var blocks: [HwpBlock] = []
    private var paraStack: [String] = []
    private var paraHadTable: [Bool] = []
    private var tables: [TableBuilder] = []
    private var cellStack: [(text: [String], col: Int, row: Int, colSpan: Int, rowSpan: Int)] = []
    private var inText = 0

    private func local(_ name: String) -> String {
        if let i = name.lastIndex(of: ":") { return String(name[name.index(after: i)...]) }
        return name
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes a: [String: String] = [:]) {
        switch local(elementName) {
        case "p":
            paraStack.append("")
            paraHadTable.append(false)
        case "t":
            inText += 1
        case "tab":
            if !paraStack.isEmpty { paraStack[paraStack.count - 1] += "\t" }
        case "lineBreak":
            if !paraStack.isEmpty { paraStack[paraStack.count - 1] += "\n" }
        case "tbl":
            tables.append(TableBuilder())
            if !paraHadTable.isEmpty { paraHadTable[paraHadTable.count - 1] = true }
        case "tr":
            if !tables.isEmpty { tables[tables.count - 1].nextCol = 0 }
        case "tc":
            let row = tables.last?.nextRow ?? 0
            cellStack.append(([], tables.last?.nextCol ?? 0, row, 1, 1))
        case "cellAddr":
            if !cellStack.isEmpty {
                if let c = a["colAddr"].flatMap(Int.init) { cellStack[cellStack.count - 1].col = c }
                if let r = a["rowAddr"].flatMap(Int.init) { cellStack[cellStack.count - 1].row = r }
            }
        case "cellSpan":
            if !cellStack.isEmpty {
                cellStack[cellStack.count - 1].colSpan = max(1, a["colSpan"].flatMap(Int.init) ?? 1)
                cellStack[cellStack.count - 1].rowSpan = max(1, a["rowSpan"].flatMap(Int.init) ?? 1)
            }
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inText > 0, !paraStack.isEmpty { paraStack[paraStack.count - 1] += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        switch local(elementName) {
        case "t":
            inText = max(0, inText - 1)
        case "p":
            guard let text = paraStack.popLast() else { return }
            let hadTable = paraHadTable.popLast() ?? false
            if !cellStack.isEmpty && cellStack.count >= tables.count && !tables.isEmpty {
                cellStack[cellStack.count - 1].text.append(text)
            } else if !(hadTable && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                blocks.append(.paragraph(text))
            }
        case "tc":
            guard let c = cellStack.popLast(), !tables.isEmpty else { return }
            let text = c.text.joined(separator: "\n")
            tables[tables.count - 1].cells.append((c.row, HwpCell(text: text, col: c.col, colSpan: c.colSpan, rowSpan: c.rowSpan)))
            tables[tables.count - 1].nextCol = c.col + c.colSpan
        case "tr":
            if !tables.isEmpty { tables[tables.count - 1].nextRow += 1 }
        case "tbl":
            guard let t = tables.popLast() else { return }
            let block = t.build()
            if !cellStack.isEmpty, cellStack.count > tables.count {
                // 표 안의 표: 셀 텍스트로 평탄화
                if case .table(let rows, _) = block {
                    let flat = rows.map { $0.map { $0.text }.joined(separator: " | ") }.joined(separator: "\n")
                    cellStack[cellStack.count - 1].text.append(flat)
                }
            } else {
                blocks.append(block)
            }
        default: break
        }
    }
}
