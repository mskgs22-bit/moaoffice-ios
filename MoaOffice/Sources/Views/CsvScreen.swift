import SwiftUI

/// CSV 는 표로 직접 그린다 (QuickLook 은 휴대폰에서 너무 작게 보임)
struct CsvScreen: View {
    let url: URL
    @State private var rows: [[String]] = []
    @State private var loaded = false

    var body: some View {
        Group {
            if !loaded { ProgressView() }
            else if rows.isEmpty { ContentUnavailableCompat(title: "This file seems to be damaged.", system: "tablecells") }
            else {
                GeometryReader { geo in
                ScrollView([.horizontal, .vertical]) {
                    Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                        ForEach(Array(rows.prefix(5000).enumerated()), id: \.offset) { r, row in
                            GridRow {
                                Text("\(r + 1)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                                    .frame(minWidth: 34, minHeight: 32).background(Color(.secondarySystemBackground))
                                ForEach(0..<width, id: \.self) { c in
                                    Text(c < row.count ? row[c] : "")
                                        .font(r == 0 ? .subheadline.bold() : .subheadline)
                                        .lineLimit(2)
                                        .frame(minWidth: 90, maxWidth: 220, minHeight: 32, alignment: .leading)
                                        .padding(.horizontal, 6)
                                        .background(r == 0 ? Color.brand.opacity(0.08) : Color(.systemBackground))
                                        .border(Color.gray.opacity(0.3), width: 0.5)
                                }
                            }
                        }
                    }
                    .textSelection(.enabled)
                    .frame(minWidth: geo.size.width, minHeight: geo.size.height, alignment: .topLeading)
                }
                }
            }
        }
        .task {
            let u = url
            rows = await Task.detached { CsvScreen.parse(u) }.value
            loaded = true
        }
    }

    private var width: Int { rows.map(\.count).max() ?? 0 }

    nonisolated static func parse(_ url: URL) -> [[String]] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        var text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.EUC_KR.rawValue))))
            ?? String(decoding: data, as: UTF8.self)
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        let sep: Character = text.prefix(2000).filter { $0 == ";" }.count > text.prefix(2000).filter { $0 == "," }.count ? ";" : ","
        var rows: [[String]] = [], row: [String] = [], field = ""
        var quoted = false
        var it = Array(text).makeIterator()
        var pending: Character? = nil
        while let ch = pending ?? it.next() {
            pending = nil
            if quoted {
                if ch == "\"" {
                    if let n = it.next() { if n == "\"" { field.append("\"") } else { quoted = false; pending = n } }
                    else { quoted = false }
                } else { field.append(ch) }
            } else if ch == "\"" { quoted = true }
            else if ch == sep { row.append(field); field = "" }
            else if ch == "\n" || ch == "\r\n" || ch == "\r" { row.append(field); rows.append(row); row = []; field = "" }
            else { field.append(ch) }
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }
}
