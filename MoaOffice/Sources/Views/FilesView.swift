import SwiftUI

struct FilesView: View {
    @EnvironmentObject var library: Library
    @State private var filter: Filter = .all
    @State private var query = ""
    @State private var sortByName = false
    @State private var importing = false
    @State private var renaming: DocFile?
    @State private var newName = ""
    @State private var howTo = false

    enum Filter: String, CaseIterable, Identifiable {
        case all, received, scanned, pdf, hwp, word, excel
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: return L("전체", "All")
            case .received: return L("받은 파일", "Received")
            case .scanned: return L("스캔", "Scans")
            case .pdf: return "PDF"
            case .hwp: return L("한글", "HWP")
            case .word: return L("워드", "Word")
            case .excel: return L("엑셀", "Excel")
            }
        }
        func match(_ f: DocFile) -> Bool {
            let e = f.url.pathExtension.lowercased()
            switch self {
            case .all: return true
            case .received: return f.source == .received
            case .scanned: return f.source == .scanned
            case .pdf: return e == "pdf" || e == "ai"
            case .hwp: return e == "hwp" || e == "hwpx"
            case .word: return e == "doc" || e == "docx"
            case .excel: return e == "xls" || e == "xlsx" || e == "csv"
            }
        }
    }

    private var items: [DocFile] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let l = library.files.filter { filter.match($0) && (q.isEmpty || $0.name.localizedCaseInsensitiveContains(q)) }
        return sortByName ? l.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } : l
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(Filter.allCases) { f in
                                Button { filter = f } label: {
                                    Text(verbatim: f.title).font(.subheadline.weight(.semibold))
                                        .padding(.horizontal, 14).frame(height: 34)
                                        .foregroundStyle(filter == f ? Color.white : .primary)
                                        .background(filter == f ? Color.primary : Color(.systemBackground), in: Capsule())
                                        .overlay(Capsule().strokeBorder(Color(.systemGray4), lineWidth: filter == f ? 0 : 1))
                                }
                                .buttonStyle(.plain)
                                .accessibilityAddTraits(filter == f ? .isSelected : [])
                                .accessibilityIdentifier("filter-\(f.rawValue)")
                            }
                        }.padding(.vertical, 2)
                    }
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                    .listRowBackground(Color.clear)
                }
                if filter == .received {
                    Section {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "tray.and.arrow.down").foregroundStyle(Color(red: 0.11, green: 0.31, blue: 0.77))
                            Text(verbatim: L("카카오톡·메일·문자에서 받은 문서를 공유 → 모아오피스로 열면 여기에 모여요.", "Documents you open in MoaOffice from Messages, Mail or other apps show up here."))
                                .font(.subheadline)
                            Spacer(minLength: 0)
                        }
                        Button(L("방법 보기", "How")) { howTo = true }.font(.subheadline.weight(.semibold))
                    }
                }
                Section {
                    if items.isEmpty {
                        Text(verbatim: L("문서가 없어요", "No documents")).foregroundStyle(.secondary)
                    }
                    ForEach(items) { f in
                        Button { library.touch(f); library.opened = f } label: { FileRow(file: f).contentShape(Rectangle()) }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("file-\(f.name)")
                            .contextMenu {
                                Button { newName = f.url.deletingPathExtension().lastPathComponent; renaming = f } label: { Label(L("이름 바꾸기", "Rename"), systemImage: "pencil") }
                                ShareLink(item: f.url) { Label(L("공유", "Share"), systemImage: "square.and.arrow.up") }
                                Button(role: .destructive) { library.delete(f) } label: { Label(L("삭제", "Delete"), systemImage: "trash") }
                            }
                    }
                    .onDelete { idx in idx.map { items[$0] }.forEach(library.delete) }
                }
            }
            .searchable(text: $query, prompt: Text(verbatim: L("파일 이름 검색", "Search files")))
            .navigationTitle(L("파일", "Files"))
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Menu {
                        Picker(L("정렬", "Sort"), selection: $sortByName) {
                            Text(verbatim: L("최근 순", "Recent")).tag(false)
                            Text(verbatim: L("이름 순", "Name")).tag(true)
                        }
                    } label: { Image(systemName: "arrow.up.arrow.down") }
                    .accessibilityLabel(Text(verbatim: L("정렬", "Sort")))
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { importing = true } label: { Label(String(localized: "Open a document"), systemImage: "plus") }
                }
            }
            .refreshable { library.reload() }
            .safeAreaInset(edge: .bottom) { AdBannerBar() }
            .fileImporter(isPresented: $importing, allowedContentTypes: openableTypes, allowsMultipleSelection: false) { r in
                if case .success(let urls) = r, let u = urls.first { library.importFile(u) }
            }
            .alert(L("이름 바꾸기", "Rename"), isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField(L("이름", "Name"), text: $newName)
                Button(L("취소", "Cancel"), role: .cancel) {}
                Button(L("바꾸기", "Rename")) { if let f = renaming { library.rename(f, to: newName) } }
            }
            .alert(L("받은 파일 여는 법", "Opening received files"), isPresented: $howTo) {
                Button(L("확인", "OK"), role: .cancel) {}
            } message: {
                Text(verbatim: L("1. 카카오톡·메일에서 파일을 눌러 열어요.\n2. 공유 버튼을 눌러요.\n3. 앱 목록에서 모아오피스를 골라요. (안 보이면 '더 보기')", "1. Open the file in the other app.\n2. Tap Share.\n3. Choose MoaOffice (or More)."))
            }
        }
    }
}

struct ToolsView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var router: ToolRouter
    private let cols = Array(repeating: GridItem(.flexible(), spacing: 4), count: 4)

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(ToolID.sections, id: \.0) { sec in
                        VStack(alignment: .leading, spacing: 12) {
                            Text(verbatim: sec.0).font(.headline).padding(.leading, 8)
                            LazyVGrid(columns: cols, spacing: 14) {
                                ForEach(sec.1) { t in ToolTile(tool: t, pro: store.isPro) { router.open(t, isPro: store.isPro) } }
                            }
                        }
                        .padding(.vertical, 14).padding(.horizontal, 6)
                        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 16))
                    }
                    Text(verbatim: L("모든 처리는 휴대폰 안에서 해요. 파일이 어디에도 올라가지 않아요.", "Everything runs on your phone. Nothing is uploaded."))
                        .font(.footnote).foregroundStyle(.secondary).padding(.top, 4)
                }
                .padding(16)
            }
            .background(Color.pageBG)
            .navigationTitle(L("도구", "Tools"))
            .safeAreaInset(edge: .bottom) { AdBannerBar() }
        }
    }
}
