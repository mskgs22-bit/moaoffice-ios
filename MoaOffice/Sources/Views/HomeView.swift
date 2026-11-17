import SwiftUI
import UniformTypeIdentifiers

/// 문서를 열 수 있는 형식 (파일 앱에서 고를 때)
let openableTypes: [UTType] = DocKind.extensions.compactMap { UTType(filenameExtension: $0) } + [.pdf, .commaSeparatedText, .data]

struct HomeView: View {
    @Binding var tab: MainTab
    @EnvironmentObject var library: Library
    @EnvironmentObject var store: Store
    @EnvironmentObject var router: ToolRouter
    @State private var importing = false
    @State private var query = ""
    @State private var paywall = false

    private let quick: [ToolID] = [.scan, .idCard, .merge, .img2pdf, .sign, .ocr, .qrScan]
    private let cols = Array(repeating: GridItem(.flexible(), spacing: 4), count: 4)

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField(L("문서 이름 검색", "Search documents"), text: $query)
                    }
                    .padding(.horizontal, 12).frame(height: 44)
                    .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 12))

                    if query.isEmpty {
                        Button { router.open(.scan, isPro: store.isPro) } label: {
                            HStack(spacing: 14) {
                                Image(systemName: "doc.viewfinder").font(.system(size: 28, weight: .semibold))
                                    .frame(width: 52, height: 52).background(.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 14))
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(verbatim: L("문서 스캔", "Scan a document")).font(.title3.bold())
                                    Text(verbatim: L("찍으면 테두리를 맞춰 바로 PDF로 만들어요", "Edges are fixed and a PDF is made right away")).font(.subheadline).opacity(0.9)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.headline)
                            }
                            .foregroundStyle(.white).padding(18)
                            .background(Color.brand, in: RoundedRectangle(cornerRadius: 18))
                        }
                        .accessibilityIdentifier("home-scan")

                        LazyVGrid(columns: cols, spacing: 14) {
                            ForEach(quick) { t in ToolTile(tool: t, pro: store.isPro) { router.open(t, isPro: store.isPro) } }
                            ToolTile(icon: "square.grid.2x2", title: L("모든 도구", "All tools"), showPro: false) { tab = .tools }
                        }
                        .padding(.vertical, 16).padding(.horizontal, 6)
                        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 16))

                        if !store.isAdFree {
                            Button { paywall = true } label: {
                                HStack {
                                    Image(systemName: "sparkles")
                                    Text(verbatim: L("광고 없이 쓰기 · 프로", "Go ad-free · Pro")).bold()
                                    Spacer(); Image(systemName: "chevron.right")
                                }
                                .foregroundStyle(Color.brandInk).padding(14)
                                .background(Color.brandTint, in: RoundedRectangle(cornerRadius: 14))
                            }
                            .accessibilityIdentifier("remove-ads")
                        }
                    }

                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            Text(verbatim: query.isEmpty ? String(localized: "Recent documents") : L("검색 결과", "Results")).font(.headline)
                            Spacer()
                            if query.isEmpty { Button(L("모두 보기", "See all")) { tab = .files }.font(.subheadline.weight(.semibold)) }
                        }
                        .padding(.bottom, 6)
                        let list = filtered
                        if list.isEmpty {
                            VStack(spacing: 10) {
                                Text(verbatim: query.isEmpty ? L("아직 문서가 없어요", "No documents yet") : L("찾는 문서가 없어요", "Nothing found")).foregroundStyle(.secondary)
                                if query.isEmpty { Button(String(localized: "Open a document")) { importing = true }.buttonStyle(.bordered) }
                            }.frame(maxWidth: .infinity).padding(.vertical, 24)
                        }
                        ForEach(list) { f in
                            Button { library.touch(f); library.opened = f } label: { FileRow(file: f).contentShape(Rectangle()) }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("file-\(f.name)")
                            Divider()
                        }
                    }
                    .padding(16)
                    .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 16))
                }
                .padding(16)
            }
            .background(Color.pageBG)
            .navigationTitle(isKorean ? "모아오피스" : "MoaOffice")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { importing = true } label: { Image(systemName: "plus.circle.fill").font(.title3) }
                        .accessibilityLabel(String(localized: "Open a document"))
                        .accessibilityIdentifier("open")
                }
            }
            .safeAreaInset(edge: .bottom) { AdBannerBar() }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: openableTypes, allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let u = urls.first { library.importFile(u) }
        }
        .sheet(isPresented: $paywall) { PaywallView().environmentObject(store) }
    }

    private var filtered: [DocFile] {
        let q = query.trimmingCharacters(in: .whitespaces)
        if q.isEmpty { return Array(library.files.prefix(8)) }
        return library.files.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }
}

struct ToolTile: View {
    let icon: String
    let title: String
    var showPro = false
    let action: () -> Void

    init(icon: String, title: String, showPro: Bool, action: @escaping () -> Void) {
        self.icon = icon; self.title = title; self.showPro = showPro; self.action = action
    }
    init(tool: ToolID, pro: Bool, action: @escaping () -> Void) {
        self.init(icon: tool.icon, title: tool.title, showPro: tool.isPro && !pro, action: action)
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                Image(systemName: icon).font(.system(size: 22)).foregroundStyle(Color.brandInk)
                    .frame(width: 52, height: 52).background(Color.brandTint, in: RoundedRectangle(cornerRadius: 16))
                Text(verbatim: title).font(.system(size: 12.5)).foregroundStyle(.primary).lineLimit(2).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .overlay(alignment: .topTrailing) { if showPro { ProBadge().offset(x: -6, y: -4) } }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("tool-\(icon)")
    }
}

struct FileRow: View {
    let file: DocFile
    var body: some View {
        HStack(spacing: 14) {
            Text(file.ext.prefix(4))
                .font(.system(size: 11, weight: .heavy))
                .foregroundStyle(.white)
                .frame(width: 44, height: 52)
                .background(RoundedRectangle(cornerRadius: 8).fill(color))
            VStack(alignment: .leading, spacing: 4) {
                Text(file.name).font(.body).foregroundStyle(.primary).lineLimit(2)
                HStack(spacing: 6) {
                    if file.source == .received {
                        Label(L("받은 파일", "Received"), systemImage: "tray.and.arrow.down").font(.caption2.weight(.semibold))
                            .foregroundStyle(Color(red: 0.11, green: 0.31, blue: 0.77))
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Color(red: 0.9, green: 0.94, blue: 1), in: RoundedRectangle(cornerRadius: 5))
                    } else if file.source == .scanned {
                        Label(L("스캔", "Scan"), systemImage: "doc.viewfinder").font(.caption2.weight(.semibold))
                            .foregroundStyle(Color.brandInk)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Color.brandTint, in: RoundedRectangle(cornerRadius: 5))
                    }
                    Text("\(file.modified.formatted(date: .abbreviated, time: .shortened)) · \(ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file))")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var color: Color {
        switch file.ext.lowercased() {
        case "pdf", "ai": return Color.brand
        case "hwp", "hwpx": return Color(red: 0.13, green: 0.47, blue: 0.85)
        case "doc", "docx": return Color(red: 0.16, green: 0.33, blue: 0.65)
        case "xls", "xlsx", "csv": return Color(red: 0.13, green: 0.55, blue: 0.29)
        default: return Color(red: 0.2, green: 0.25, blue: 0.4)
        }
    }
}
