import SwiftUI
import PDFKit
import UniformTypeIdentifiers

/// 내 문서에서 고르기 (+ 파일 앱에서 가져오기)
struct LibraryPicker: View {
    var title: String
    var pdfOnly = true
    var multiple = false
    let done: ([DocFile]) -> Void
    @EnvironmentObject var library: Library
    @Environment(\.dismiss) private var dismiss
    @State private var selected: [URL] = []
    @State private var importing = false

    private var items: [DocFile] { library.files.filter { !pdfOnly || DocKind.of($0.url) == .pdf } }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button { importing = true } label: { Label(L("파일 앱에서 가져오기", "Import from Files"), systemImage: "folder") }
                }
                Section(pdfOnly ? L("내 PDF", "My PDFs") : L("내 문서", "My documents")) {
                    if items.isEmpty { Text(verbatim: L("아직 문서가 없어요", "No documents yet")).foregroundStyle(.secondary) }
                    ForEach(items) { f in
                        Button {
                            if multiple {
                                if let i = selected.firstIndex(of: f.url) { selected.remove(at: i) } else { selected.append(f.url) }
                            } else { done([f]); dismiss() }
                        } label: {
                            HStack {
                                FileRow(file: f)
                                Spacer()
                                if multiple, let i = selected.firstIndex(of: f.url) {
                                    Text(verbatim: "\(i + 1)").font(.footnote.bold()).foregroundStyle(.white)
                                        .frame(width: 26, height: 26).background(Color.brand, in: Circle())
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L("취소", "Cancel")) { dismiss() } }
                if multiple {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(L("다음 (\(selected.count))", "Next (\(selected.count))")) {
                            let chosen = selected.compactMap { u in library.files.first { $0.url == u } }
                            done(chosen); dismiss()
                        }.disabled(selected.isEmpty)
                    }
                }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: pdfOnly ? [.pdf] : [.pdf, .data], allowsMultipleSelection: multiple) { r in
                guard case .success(let urls) = r else { return }
                for u in urls { library.importFile(u) }
                library.opened = nil
                let names = Set(urls.map { $0.lastPathComponent })
                for f in library.files where names.contains(f.name) && !selected.contains(f.url) { selected.append(f.url) }
                if !multiple, let first = selected.first, let f = library.files.first(where: { $0.url == first }) { done([f]); dismiss() }
            }
        }
    }
}

// MARK: - PDF 합치기

struct MergeView: View {
    @EnvironmentObject var library: Library
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var files: [DocFile] = []
    @State private var picking = true
    @State private var busy = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(files) { f in
                        HStack { FileRow(file: f); Spacer(); Text(verbatim: L("\(PdfTools.pageCount(f.url))쪽", "\(PdfTools.pageCount(f.url)) p")).font(.caption).foregroundStyle(.secondary) }
                    }
                    .onMove { files.move(fromOffsets: $0, toOffset: $1) }
                    .onDelete { files.remove(atOffsets: $0) }
                    Button { picking = true } label: { Label(L("파일 더하기", "Add files"), systemImage: "plus") }
                } footer: {
                    Text(verbatim: L("위에서부터 차례로 붙여요. 손잡이를 끌어 순서를 바꿀 수 있어요.", "Joined top to bottom. Drag the handles to reorder."))
                }
                Section {
                    Button { merge() } label: {
                        Text(verbatim: L("PDF \(files.count)개 합치기 · 모두 \(files.reduce(0) { $0 + PdfTools.pageCount($1.url) })쪽", "Merge \(files.count) PDFs")).font(.headline).frame(maxWidth: .infinity)
                    }.disabled(files.count < 2 || busy)
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle(L("PDF 합치기", "Merge PDFs"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L("닫기", "Close")) { dismiss() } } }
            .sheet(isPresented: $picking) {
                LibraryPicker(title: L("합칠 PDF 고르기", "Choose PDFs"), multiple: true) { chosen in
                    for f in chosen where !files.contains(f) { files.append(f) }
                }
            }
            .overlay { if busy { BusyOverlay(text: L("합치는 중…", "Merging…")) } }
        }
    }

    private func merge() {
        busy = true
        let urls = files.map(\.url)
        Task {
            let data = await Task.detached { PdfTools.merge(urls) }.value
            busy = false
            if let data {
                let name = (files.first?.url.deletingPathExtension().lastPathComponent ?? "PDF") + L(" 외 \(files.count - 1)개", " + \(files.count - 1)") + ".pdf"
                library.saveNew(data, name: name, source: .opened, open: true)
                dismiss()
            }
        }
    }
}

// MARK: - 쪽 정리 (순서 · 돌리기 · 지우기)

struct PageOrganizerView: View {
    let file: DocFile
    @EnvironmentObject var library: Library
    @Environment(\.dismiss) private var dismiss
    @State private var doc: PDFDocument?
    @State private var pages: [PDFPage] = []
    @State private var selected: Set<Int> = []
    @State private var version = 0

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 14)], spacing: 14) {
                    ForEach(Array(pages.enumerated()), id: \.offset) { i, p in
                        Button {
                            if selected.contains(i) { selected.remove(i) } else { selected.insert(i) }
                        } label: {
                            VStack(spacing: 6) {
                                Image(uiImage: p.thumbnail(of: CGSize(width: 200, height: 270), for: .cropBox)).resizable().scaledToFit()
                                    .frame(width: 100, height: 136).background(Color.white)
                                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(selected.contains(i) ? Color.brand : Color(.systemGray4), lineWidth: selected.contains(i) ? 3 : 1))
                                Text(verbatim: "\(i + 1)").font(.caption).foregroundStyle(.secondary)
                            }
                        }.buttonStyle(.plain)
                    }
                }
                .padding()
                .id(version)
            }
            .background(Color.pageBG)
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 0) {
                    action("arrow.left", L("앞으로", "Earlier")) { shift(-1) }
                    action("arrow.right", L("뒤로", "Later")) { shift(1) }
                    action("rotate.right", L("돌리기", "Rotate")) { for i in selected { pages[i].rotation += 90 }; version += 1 }
                    action("trash", L("지우기", "Delete")) { pages = pages.enumerated().filter { !selected.contains($0.offset) }.map(\.element); selected = []; version += 1 }
                }
                .disabled(selected.isEmpty)
                .padding(.bottom, 4).background(.bar)
            }
            .navigationTitle(L("쪽 정리", "Organize pages"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L("취소", "Cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button(L("사본 저장", "Save copy")) { save() }.disabled(pages.isEmpty) }
            }
            .task {
                guard doc == nil, let d = PDFDocument(url: file.url) else { return }
                doc = d
                pages = (0..<d.pageCount).compactMap { d.page(at: $0) }
            }
        }
    }

    private func action(_ icon: String, _ t: String, _ f: @escaping () -> Void) -> some View {
        Button(action: f) { VStack(spacing: 4) { Image(systemName: icon).font(.title3); Text(verbatim: t).font(.caption) }.frame(maxWidth: .infinity, minHeight: 56) }
            .foregroundStyle(.primary)
    }

    private func shift(_ d: Int) {
        let order: [Int] = d < 0 ? selected.sorted() : selected.sorted(by: >)
        var newSel = Set<Int>()
        for i in order {
            let j = i + d
            guard pages.indices.contains(j), !newSel.contains(j) else { newSel.insert(i); continue }
            pages.swapAt(i, j); newSel.insert(j)
        }
        selected = newSel; version += 1
    }

    private func save() {
        let out = PDFDocument()
        for p in pages { if let c = p.copy() as? PDFPage { out.insert(c, at: out.pageCount) } }
        guard let data = out.dataRepresentation() else { return }
        library.saveNew(data, name: file.url.deletingPathExtension().lastPathComponent + L(" (정리)", " (organized)") + ".pdf", source: file.source, open: true)
        dismiss()
    }
}

// MARK: - 서명 넣기 (PDF)

struct PdfSignView: View {
    let file: DocFile
    var pageIndex = 0
    @EnvironmentObject var library: Library
    @Environment(\.dismiss) private var dismiss
    @State private var index = 0
    @State private var doc: PDFDocument?
    @State private var signing = false

    var body: some View {
        NavigationStack {
            VStack {
                if let d = doc, let p = d.page(at: index) {
                    Image(uiImage: PdfTools.renderPage(p, maxSide: 1400)).resizable().scaledToFit().background(Color.white).padding()
                    Stepper(L("\(d.pageCount)쪽 중 \(index + 1)쪽", "Page \(index + 1) of \(d.pageCount)"), value: $index, in: 0...max(0, d.pageCount - 1)).padding(.horizontal)
                    Button { signing = true } label: { Label(L("이 쪽에 서명하기", "Sign this page"), systemImage: "signature").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 12) }
                        .buttonStyle(.borderedProminent).padding()
                } else { ProgressView() }
            }
            .background(Color.pageBG)
            .navigationTitle(L("서명", "Sign"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L("닫기", "Close")) { dismiss() } } }
            .task { if doc == nil { doc = PDFDocument(url: file.url); index = pageIndex } }
            .sheet(isPresented: $signing) {
                if let d = doc, let p = d.page(at: index) {
                    SignFlowView(apply: { sig, rect in
                        let data = PdfTools.addImage(sig, to: d, page: index, rect: rect)
                        let name = file.url.deletingPathExtension().lastPathComponent + L(" (서명)", " (signed)") + ".pdf"
                        library.saveNew(data, name: name, source: file.source, open: true)
                        dismiss()
                    }, background: { PdfTools.renderPage(p, maxSide: 1600) })
                }
            }
        }
    }
}

// MARK: - 워터마크 · 날짜 도장

struct StampView: View {
    let file: DocFile
    let style: PdfTools.StampStyle
    @EnvironmentObject var library: Library
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var busy = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(style == .diagonal ? L("예: 사본 · 제출용", "e.g. COPY") : L("도장 글자", "Stamp text"), text: $text)
                } header: { Text(verbatim: style == .diagonal ? L("워터마크 글자", "Watermark text") : L("날짜 도장", "Date stamp")) }
                  footer: { Text(verbatim: style == .diagonal ? L("모든 쪽 가운데에 옅게 비스듬히 넣어요.", "Added faintly across every page.") : L("모든 쪽 오른쪽 위에 넣어요.", "Added at the top right of every page.")) }
                Section {
                    Button { apply() } label: { Text(verbatim: L("사본으로 저장", "Save as copy")).font(.headline).frame(maxWidth: .infinity) }.disabled(text.isEmpty || busy)
                }
            }
            .navigationTitle(style == .diagonal ? L("워터마크", "Watermark") : L("날짜 도장", "Date stamp"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L("닫기", "Close")) { dismiss() } } }
            .onAppear {
                if text.isEmpty, style == .corner {
                    let f = DateFormatter(); f.dateFormat = isKorean ? "yyyy. M. d. a h:mm" : "yyyy-MM-dd h:mm a"
                    if isKorean { f.locale = Locale(identifier: "ko_KR") }
                    text = f.string(from: Date())
                }
            }
            .overlay { if busy { BusyOverlay(text: L("만드는 중…", "Working…")) } }
        }
    }

    private func apply() {
        busy = true
        let u = file.url, t = text, st = style
        Task {
            let data = await Task.detached { PdfTools.stamp(u, text: t, style: st, color: st == .diagonal ? .systemRed : .darkGray) }.value
            busy = false
            if let data {
                library.saveNew(data, name: u.deletingPathExtension().lastPathComponent + (st == .diagonal ? L(" (워터마크)", " (watermark)") : L(" (도장)", " (stamped)")) + ".pdf", source: file.source, open: true)
                dismiss()
            }
        }
    }
}

// MARK: - PDF 압축 (PRO)

struct CompressView: View {
    let file: DocFile
    @EnvironmentObject var library: Library
    @Environment(\.dismiss) private var dismiss
    @State private var level: PdfTools.CompressLevel = .normal
    @State private var busy = false
    @State private var result: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack { Text(verbatim: L("지금 크기", "Current size")); Spacer(); Text(verbatim: ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file)).foregroundStyle(.secondary) }
                    Picker(L("줄이는 정도", "Level"), selection: $level) { ForEach(PdfTools.CompressLevel.allCases) { Text(verbatim: $0.title).tag($0) } }.pickerStyle(.segmented)
                } footer: { Text(verbatim: L("쪽을 그림으로 다시 만들어 줄여요. 글자 선택·검색은 안 될 수 있어요. 원본은 그대로 둬요.", "Pages are re-made as images. Text selection may be lost. The original is kept.")) }
                Section { Button { run() } label: { Text(verbatim: L("압축해서 사본 저장", "Compress and save copy")).font(.headline).frame(maxWidth: .infinity) }.disabled(busy) }
                if let r = result { Section { Text(verbatim: r) } }
            }
            .navigationTitle(L("PDF 압축", "Compress PDF"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L("닫기", "Close")) { dismiss() } } }
            .overlay { if busy { BusyOverlay(text: L("줄이는 중…", "Compressing…")) } }
        }
    }

    private func run() {
        busy = true
        let u = file.url, lv = level
        Task {
            let data = await Task.detached { PdfTools.compress(u, level: lv) }.value
            busy = false
            guard let data else { result = L("이 PDF는 줄이지 못했어요.", "Could not compress this PDF."); return }
            if data.count >= file.size {
                result = L("더 작아지지 않아요. 이미 작게 저장된 PDF예요.", "It would not get smaller.")
                return
            }
            library.saveNew(data, name: u.deletingPathExtension().lastPathComponent + L(" (압축)", " (compressed)") + ".pdf", source: file.source, open: true)
            dismiss()
        }
    }
}

// MARK: - PDF 암호 (PRO)

struct PasswordView: View {
    let file: DocFile
    @EnvironmentObject var library: Library
    @Environment(\.dismiss) private var dismiss
    @State private var pw = ""
    @State private var pw2 = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField(L("암호", "Password"), text: $pw)
                    SecureField(L("암호 확인", "Confirm"), text: $pw2)
                } footer: { Text(verbatim: L("암호를 잊으면 열 수 없어요. 원본은 그대로 두고 사본에 걸어요.", "If you forget it, the file can’t be opened. A copy is protected; the original is kept.")) }
                Section {
                    Button {
                        guard let d = try? Data(contentsOf: file.url), let out = PdfTools.encrypt(d, password: pw) else { return }
                        library.saveNew(out, name: file.url.deletingPathExtension().lastPathComponent + L(" (암호)", " (locked)") + ".pdf", source: file.source, open: false)
                        dismiss()
                    } label: { Text(verbatim: L("암호 건 사본 저장", "Save protected copy")).font(.headline).frame(maxWidth: .infinity) }
                    .disabled(pw.count < 4 || pw != pw2)
                }
            }
            .navigationTitle(L("PDF 암호", "PDF password"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L("닫기", "Close")) { dismiss() } } }
        }
    }
}

// MARK: - PDF → 사진

struct PdfToImagesView: View {
    let file: DocFile
    @Environment(\.dismiss) private var dismiss
    @State private var images: [UIImage] = []
    @State private var toast: String?
    @State private var share = false

    var body: some View {
        NavigationStack {
            ScrollView {
                if images.isEmpty { ProgressView().padding(40) }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 12)], spacing: 12) {
                    ForEach(Array(images.enumerated()), id: \.offset) { _, img in
                        Image(uiImage: img).resizable().scaledToFit().frame(height: 136).background(Color.white)
                    }
                }.padding()
            }
            .background(Color.pageBG)
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Button { share = true } label: { Label(L("공유", "Share"), systemImage: "square.and.arrow.up").frame(maxWidth: .infinity).padding(.vertical, 10) }.buttonStyle(.bordered)
                    Button { Task { toast = await PhotoSaver.save(images) ? L("사진첩에 \(images.count)장 저장했어요", "Saved \(images.count) photos") : L("사진 접근을 허용해 주세요", "Allow Photos access") } } label: {
                        Label(L("사진첩에 저장", "Save to Photos"), systemImage: "photo.on.rectangle").frame(maxWidth: .infinity).padding(.vertical, 10)
                    }.buttonStyle(.borderedProminent)
                }.padding().background(.bar).disabled(images.isEmpty)
            }
            .navigationTitle(L("PDF → 사진", "PDF to images"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L("닫기", "Close")) { dismiss() } } }
            .task { let u = file.url; images = await Task.detached { PdfTools.images(of: u, maxSide: 2000) }.value }
            .sheet(isPresented: $share) { ShareSheet(items: images) }
            .toast($toast)
        }
    }
}
