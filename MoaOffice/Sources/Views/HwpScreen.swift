import SwiftUI
import UIKit

struct HwpScreen: View {
    let url: URL
    @EnvironmentObject var library: Library
    @State private var doc: HwpDocument?
    @State private var error: String?
    @State private var fontSize: CGFloat = 15
    @State private var exported: String?

    var body: some View {
        Group {
            if let doc {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(doc.blocks.enumerated()), id: \.offset) { _, b in
                            BlockView(block: b, fontSize: fontSize)
                        }
                    }
                    .textSelection(.enabled)
                    .padding(22)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.white)
                    .foregroundStyle(Color.black)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
                    .padding(12)
                }
                .background(Color(.secondarySystemBackground))
                .accessibilityIdentifier("hwp-content")
                .safeAreaInset(edge: .bottom) { toolbar }
            } else if let error {
                ContentUnavailableCompat(title: LocalizedStringKey(error), system: "exclamationmark.triangle")
            } else {
                ProgressView()
            }
        }
        .task {
            let u = url
            do { doc = try await Task.detached { try HwpDocument.open(u) }.value }
            catch { self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
        }
        .alert(exported ?? "", isPresented: Binding(get: { exported != nil }, set: { if !$0 { exported = nil } })) {
            Button("OK", role: .cancel) {}
        }
    }

    private var toolbar: some View {
        HStack(spacing: 22) {
            Button { fontSize = max(10, fontSize - 2) } label: { Image(systemName: "textformat.size.smaller") }
            Button { fontSize = min(30, fontSize + 2) } label: { Image(systemName: "textformat.size.larger") }
            Spacer()
            Button { exportPdf() } label: { Label("Export PDF", systemImage: "doc.richtext") }
                .accessibilityIdentifier("export-pdf")
        }
        .font(.title3)
        .padding(.horizontal, 20).padding(.vertical, 10)
        .background(.bar)
    }

    private func exportPdf() {
        guard let doc else { return }
        let base = url.deletingPathExtension().lastPathComponent
        var dest = Library.folder.appendingPathComponent(base + ".pdf")
        var n = 2
        while FileManager.default.fileExists(atPath: dest.path) {
            dest = Library.folder.appendingPathComponent("\(base) (\(n)).pdf"); n += 1
        }
        do {
            try PdfExporter.render(doc).write(to: dest)
            library.reload()
            exported = String(format: String(localized: "Saved as %@"), dest.lastPathComponent)
        } catch {
            exported = String(localized: "Could not export PDF.")
        }
    }
}

struct BlockView: View {
    let block: HwpBlock
    let fontSize: CGFloat

    var body: some View {
        switch block {
        case .paragraph(let t):
            Text(t.isEmpty ? " " : t).font(.system(size: fontSize)).fixedSize(horizontal: false, vertical: true)
        case .pageBreak:
            Divider().padding(.vertical, 10)
        case .table(let rows, let columns):
            Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(Array(layout(row, columns).enumerated()), id: \.offset) { _, slot in
                            if let cell = slot {
                                Text(cell.text)
                                    .font(.system(size: fontSize * 0.88))
                                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                                    .padding(5)
                                    .border(Color.gray.opacity(0.6), width: 0.5)
                                    .gridCellColumns(cell.colSpan)
                            } else {
                                Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity).border(Color.gray.opacity(0.25), width: 0.5)
                            }
                        }
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    /// 열 위치에 맞춰 셀을 배치하고, 병합으로 덮인 칸은 빈칸(nil)으로 채운다
    private func layout(_ row: [HwpCell], _ columns: Int) -> [HwpCell?] {
        var out: [HwpCell?] = []
        var col = 0
        var cells = row.sorted { $0.col < $1.col }[...]
        while col < columns {
            if let c = cells.first, c.col <= col {
                cells = cells.dropFirst()
                let span = min(c.colSpan, columns - col)
                out.append(HwpCell(text: c.text, col: col, colSpan: max(1, span), rowSpan: c.rowSpan))
                col += max(1, span)
            } else {
                out.append(nil)
                col += 1
            }
        }
        return out
    }
}

/// HWP → PDF (표 포함, HTML 인쇄 엔진 사용, 기기 안에서만 처리)
enum PdfExporter {
    @MainActor static func render(_ doc: HwpDocument) -> Data {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\n", with: "<br>")
                .replacingOccurrences(of: "\t", with: "&emsp;")
        }
        var html = "<html><head><meta charset='utf-8'><style>body{font-family:-apple-system,'Apple SD Gothic Neo';font-size:11pt;line-height:1.5}table{border-collapse:collapse;width:100%;margin:6px 0}td{border:0.5pt solid #777;padding:4px;vertical-align:top;font-size:10pt}p{margin:0 0 4px 0}</style></head><body>"
        for b in doc.blocks {
            switch b {
            case .paragraph(let t): html += "<p>\(t.isEmpty ? "&nbsp;" : esc(t))</p>"
            case .pageBreak: html += "<div style='page-break-after:always'></div>"
            case .table(let rows, _):
                html += "<table>"
                for r in rows {
                    html += "<tr>" + r.map { "<td colspan='\($0.colSpan)' rowspan='\($0.rowSpan)'>\(esc($0.text))</td>" }.joined() + "</tr>"
                }
                html += "</table>"
            }
        }
        html += "</body></html>"

        let fmt = UIMarkupTextPrintFormatter(markupText: html)
        let renderer = UIPrintPageRenderer()
        renderer.addPrintFormatter(fmt, startingAtPageAt: 0)
        let a4 = CGRect(x: 0, y: 0, width: 595.2, height: 841.8)
        renderer.setValue(NSValue(cgRect: a4), forKey: "paperRect")
        renderer.setValue(NSValue(cgRect: a4.insetBy(dx: 50, dy: 56)), forKey: "printableRect")
        let data = NSMutableData()
        UIGraphicsBeginPDFContextToData(data, a4, [kCGPDFContextCreator as String: "MoaOffice"])
        renderer.prepare(forDrawingPages: NSRange(location: 0, length: renderer.numberOfPages))
        for i in 0..<renderer.numberOfPages {
            UIGraphicsBeginPDFPage()
            renderer.drawPage(at: i, in: UIGraphicsGetPDFContextBounds())
        }
        UIGraphicsEndPDFContext()
        return data as Data
    }
}
