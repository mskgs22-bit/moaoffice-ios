import SwiftUI
import PDFKit

struct DocumentScreen: View {
    let file: DocFile
    @EnvironmentObject var library: Library
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var sheet: DocSheet?
    @State private var busy: String?
    @State private var ocrText: String?
    @State private var paywall = false

    enum DocSheet: String, Identifiable { case sign, append, organize, watermark, stamp, compress, lock; var id: String { rawValue } }

    private var isPDF: Bool { DocKind.of(file.url) == .pdf }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(file.name)
                .navigationBarTitleDisplayMode(.inline)
                .safeAreaInset(edge: .top, spacing: 0) {
                    if file.source == .received {
                        HStack(spacing: 8) {
                            Image(systemName: "tray.and.arrow.down")
                            Text(verbatim: isPDF ? L("받은 파일이에요. 고치면 원본은 두고 사본으로 저장해요.", "Received file. Edits are saved as a copy.") : L("다른 앱에서 받은 파일이에요.", "Received from another app."))
                            Spacer(minLength: 0)
                        }
                        .font(.footnote).foregroundStyle(Color(red: 0.42, green: 0.29, blue: 0))
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .background(Color(red: 1, green: 0.97, blue: 0.91))
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button { dismiss() } label: { Image(systemName: "xmark") }
                            .accessibilityIdentifier("close")
                    }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        HStack(spacing: 16) {
                            if isPDF {
                                Menu {
                                    Button { sheet = .sign } label: { Label(L("서명하기", "Sign"), systemImage: "signature") }
                                    Button { sheet = .append } label: { Label(L("스캔해서 쪽 더하기", "Add scanned pages"), systemImage: "doc.viewfinder") }
                                    Button { readText() } label: { Label(L("글자 인식", "Recognize text"), systemImage: "text.viewfinder") }
                                    Button { sheet = .organize } label: { Label(L("쪽 정리", "Organize pages"), systemImage: "square.grid.2x2") }
                                    Button { sheet = .watermark } label: { Label(L("워터마크", "Watermark"), systemImage: "drop") }
                                    Button { sheet = .stamp } label: { Label(L("날짜 도장", "Date stamp"), systemImage: "calendar.badge.clock") }
                                    Button { pro(.compress) } label: { Label(L("PDF 압축", "Compress") + (store.isPro ? "" : " · PRO"), systemImage: "arrow.down.right.and.arrow.up.left") }
                                    Button { pro(.lock) } label: { Label(L("암호 걸기", "Add password") + (store.isPro ? "" : " · PRO"), systemImage: "lock.doc") }
                                } label: { Image(systemName: "wand.and.stars") }
                                .accessibilityLabel(Text(verbatim: L("도구", "Tools")))
                                .accessibilityIdentifier("doc-tools")
                            }
                            Button { DocPrinter.print(file.url) } label: { Image(systemName: "printer") }
                                .accessibilityLabel(Text("Print"))
                                .accessibilityIdentifier("print")
                            ShareLink(item: file.url) { Image(systemName: "square.and.arrow.up") }
                        }
                    }
                }
                .safeAreaInset(edge: .bottom) { AdBannerBar() }
                .overlay { if let b = busy { BusyOverlay(text: b) } }
        }
        .sheet(item: $sheet) { s in
            Group {
                switch s {
                case .sign: PdfSignView(file: file)
                case .append: ScanAppendView(file: file)
                case .organize: PageOrganizerView(file: file)
                case .watermark: StampView(file: file, style: .diagonal)
                case .stamp: StampView(file: file, style: .corner)
                case .compress: CompressView(file: file)
                case .lock: PasswordView(file: file)
                }
            }
            .environmentObject(library).environmentObject(store)
        }
        .sheet(item: Binding(get: { ocrText.map { OcrResult(text: $0) } }, set: { ocrText = $0?.text })) { r in
            OcrResultView(text: r.text, suggestedName: file.url.deletingPathExtension().lastPathComponent).environmentObject(library)
        }
        .sheet(isPresented: $paywall) { PaywallView().environmentObject(store) }
        .onAppear { Interstitials.shared.documentOpened(adFree: store.isAdFree) }
        .onDisappear { library.reload() }
    }

    private func pro(_ s: DocSheet) { if store.isPro { sheet = s } else { paywall = true } }

    private func readText() {
        busy = L("글자를 읽는 중…", "Reading text…")
        let u = file.url
        Task {
            let imgs = await Task.detached { Array(PdfTools.images(of: u, maxSide: 2200).prefix(20)) }.value
            var parts: [String] = []
            for i in imgs { parts.append(OCR.text(await OCR.recognize(i))) }
            busy = nil
            let t = parts.filter { !$0.isEmpty }.joined(separator: "\n\n")
            ocrText = t.isEmpty ? L("읽을 수 있는 글자를 찾지 못했어요.", "No text found.") : t
        }
    }

    @ViewBuilder private var content: some View {
        switch DocKind.of(file.url) {
        case .pdf: PdfScreen(url: file.url, received: file.source == .received)
        case .hwp: HwpScreen(url: file.url)
        case .image: ImageScreen(url: file.url)
        case .office where file.url.pathExtension.lowercased() == "csv": CsvScreen(url: file.url)
        default: QuickLookView(url: file.url).ignoresSafeArea(edges: .bottom)
        }
    }
}

/// 열어 둔 PDF 뒤에 스캔한 쪽을 붙인다 (받은 파일은 사본으로)
struct ScanAppendView: View {
    let file: DocFile
    @EnvironmentObject var library: Library
    @Environment(\.dismiss) private var dismiss
    @State private var camera = DocCamera.isAvailable
    @State private var picking = !DocCamera.isAvailable

    var body: some View {
        Color.black.opacity(0.001)
            .fullScreenCover(isPresented: $camera) {
                DocCamera(done: { imgs in camera = false; append(imgs) }, cancel: { camera = false; dismiss() }).ignoresSafeArea()
            }
            .sheet(isPresented: $picking, onDismiss: { }) {
                PhotoPicker { imgs in if imgs.isEmpty { dismiss() } else { append(imgs.map { img in ImageOps.detectQuad(img).map { q in ImageOps.perspective(img, quad: q) } ?? img }) } }.ignoresSafeArea()
            }
    }

    private func append(_ imgs: [UIImage]) {
        guard !imgs.isEmpty, let doc = PDFDocument(url: file.url),
              let extra = PDFDocument(data: PdfTools.pdf(from: imgs.map { ImageOps.apply(.auto, to: $0) })) else { dismiss(); return }
        for i in 0..<extra.pageCount { if let p = extra.page(at: i) { doc.insert(p, at: doc.pageCount) } }
        guard let data = doc.dataRepresentation() else { dismiss(); return }
        if file.source == .received {
            library.saveNew(data, name: file.url.deletingPathExtension().lastPathComponent + L(" (쪽 추가)", " (pages added)") + ".pdf", source: .received, open: true)
        } else {
            try? data.write(to: file.url, options: .atomic)
            library.reload()
            library.opened = nil
            Task { try? await Task.sleep(nanoseconds: 500_000_000); library.opened = library.files.first { $0.url == file.url } }
        }
        dismiss()
    }
}
