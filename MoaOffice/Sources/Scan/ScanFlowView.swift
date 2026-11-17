import SwiftUI
import Photos

/// 스캔 전체 흐름: 촬영(애플 문서 스캐너) → 쪽 모아 보기 → 쪽 보정 → 저장
struct ScanFlowView: View {
    @StateObject private var session: ScanSession
    @EnvironmentObject var library: Library
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var camera: Bool
    @State private var picking = false
    private let openEditorFirst: Bool

    init(mode: ScanMode = .document, images: [UIImage] = [], editFirst: Bool = false) {
        let s = ScanSession(mode: mode)
        if !images.isEmpty { s.addPhotos(images) }
        if images.isEmpty, CommandLine.arguments.contains("-demo"), !DocCamera.isAvailable { s.add(ScanSession.demoImages()) }
        _session = StateObject(wrappedValue: s)
        _camera = State(initialValue: images.isEmpty && DocCamera.isAvailable)
        openEditorFirst = editFirst
    }

    var body: some View {
        NavigationStack {
            ScanReviewView(session: session, addFromCamera: { camera = true }, addFromPhotos: { picking = true }, openEditorFirst: openEditorFirst) {
                dismiss()
            }
        }
        .fullScreenCover(isPresented: $camera) {
            DocCamera(done: { imgs in
                session.add(imgs); camera = false
            }, cancel: {
                camera = false
                if session.pages.isEmpty { dismiss() }
            }).ignoresSafeArea()
        }
        .sheet(isPresented: $picking) { PhotoPicker { session.addPhotos($0) }.ignoresSafeArea() }
    }
}

struct ScanReviewView: View {
    @ObservedObject var session: ScanSession
    let addFromCamera: () -> Void
    let addFromPhotos: () -> Void
    var openEditorFirst = false
    let close: () -> Void
    @EnvironmentObject var library: Library
    @EnvironmentObject var store: Store
    @State private var editIndex: Int?
    @State private var saving = false
    @State private var reorder = false
    @State private var renaming = false
    @State private var didOpen = false

    private let cols = [GridItem(.adaptive(minimum: 100), spacing: 14)]

    var body: some View {
        Group {
            if session.pages.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "doc.viewfinder").font(.system(size: 52)).foregroundStyle(.secondary)
                    Text(verbatim: L("아직 찍은 쪽이 없어요", "No pages yet")).font(.headline)
                    HStack(spacing: 12) {
                        if DocCamera.isAvailable { Button(L("찍기", "Scan"), action: addFromCamera).buttonStyle(.borderedProminent) }
                        Button(L("사진에서 가져오기", "From photos"), action: addFromPhotos).buttonStyle(.bordered)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    Picker(L("모드", "Mode"), selection: $session.mode) {
                        ForEach(ScanMode.allCases.filter { $0 != .idCard }) { Text(verbatim: $0.title).tag($0) }
                    }
                    .pickerStyle(.segmented).padding(.horizontal).padding(.top, 8)
                    .accessibilityHint(Text(verbatim: L("다음에 찍는 쪽부터 적용돼요", "Applies to the next pages you scan")))

                    LazyVGrid(columns: cols, spacing: 16) {
                        ForEach(Array(session.pages.enumerated()), id: \.element.id) { i, p in
                            Button { editIndex = i } label: { PageThumb(page: p, number: i + 1) }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("page-\(i + 1)")
                        }
                        Menu {
                            if DocCamera.isAvailable { Button { addFromCamera() } label: { Label(L("카메라로 찍기", "Scan with camera"), systemImage: "camera") } }
                            Button { addFromPhotos() } label: { Label(L("사진에서 가져오기", "From photos"), systemImage: "photo") }
                        } label: {
                            VStack(spacing: 6) { Image(systemName: "plus").font(.title2); Text(verbatim: L("쪽 더하기", "Add page")).font(.footnote) }
                                .foregroundStyle(.secondary)
                                .frame(width: 100, height: 136)
                                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [6])).foregroundStyle(Color(.systemGray3)))
                        }
                    }
                    .padding()
                }
                .background(Color.pageBG)
                .safeAreaInset(edge: .bottom) {
                    Button { saving = true } label: {
                        Text(verbatim: L("저장 · \(session.pages.count)쪽", "Save · \(session.pages.count) pages")).font(.headline).frame(maxWidth: .infinity).padding(.vertical, 14)
                    }
                    .buttonStyle(.borderedProminent).padding(.horizontal).padding(.bottom, 8)
                    .accessibilityIdentifier("scan-save")
                    .background(.bar)
                }
            }
        }
        .navigationTitle(session.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) { Button(L("닫기", "Close"), action: close).accessibilityIdentifier("scan-close") }
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button { renaming = true } label: { Image(systemName: "pencil") }.accessibilityLabel(Text(verbatim: L("이름 바꾸기", "Rename")))
                if session.pages.count > 1 { Button { reorder = true } label: { Image(systemName: "arrow.up.arrow.down") }.accessibilityLabel(Text(verbatim: L("순서 바꾸기", "Reorder"))) }
            }
        }
        .navigationDestination(isPresented: Binding(get: { editIndex != nil }, set: { if !$0 { editIndex = nil } })) {
            if let i = editIndex { PageEditorView(session: session, index: i) }
        }
        .sheet(isPresented: $saving) { ScanSaveSheet(session: session) { close() } }
        .sheet(isPresented: $reorder) { ReorderView(session: session) }
        .alert(L("문서 이름", "Document name"), isPresented: $renaming) {
            TextField(L("이름", "Name"), text: $session.name)
            Button(L("확인", "OK")) {}
        }
        .onAppear { if openEditorFirst, !didOpen, !session.pages.isEmpty { didOpen = true; editIndex = 0 } }
    }
}

struct PageThumb: View {
    @ObservedObject var page: ScanPage
    let number: Int
    var body: some View {
        VStack(spacing: 6) {
            Image(uiImage: page.thumb).resizable().scaledToFit()
                .frame(width: 100, height: 136)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
            Text(verbatim: "\(number)").font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct ReorderView: View {
    @ObservedObject var session: ScanSession
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                ForEach(Array(session.pages.enumerated()), id: \.element.id) { i, p in
                    HStack(spacing: 12) {
                        Image(uiImage: p.thumb).resizable().scaledToFit().frame(width: 44, height: 60).background(Color.white)
                        Text(verbatim: L("\(i + 1)쪽", "Page \(i + 1)"))
                    }
                }
                .onMove { session.move(from: $0, to: $1) }
                .onDelete { idx in idx.map { session.pages[$0] }.forEach(session.remove) }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle(L("순서 바꾸기", "Reorder"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L("완료", "Done")) { dismiss() } } }
        }
    }
}

/// 저장: PDF / JPG(사진첩) / 글자
struct ScanSaveSheet: View {
    @ObservedObject var session: ScanSession
    let finished: () -> Void
    @EnvironmentObject var library: Library
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    enum Format: String, CaseIterable { case pdf, jpg, text }
    @State private var format: Format = .pdf
    @State private var small = false
    @State private var searchable = false
    @State private var usePassword = false
    @State private var password = ""
    @State private var busy: String?
    @State private var paywall = false
    @State private var ocrText: String?
    @State private var toast: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker(L("저장 형식", "Format"), selection: $format) {
                        Text(verbatim: "PDF").tag(Format.pdf)
                        Text(verbatim: L("사진(JPG)", "Photos (JPG)")).tag(Format.jpg)
                        Text(verbatim: L("글자", "Text")).tag(Format.text)
                    }.pickerStyle(.segmented)
                } footer: { Text(verbatim: footer) }
                if format == .pdf {
                    Section {
                        Picker(L("파일 크기", "File size"), selection: $small) {
                            Text(verbatim: L("보통", "Normal")).tag(false)
                            Text(verbatim: L("작게", "Small")).tag(true)
                        }
                        Toggle(isOn: proBinding($searchable)) { HStack { Text(verbatim: L("글자 검색되는 PDF", "Searchable PDF")); ProBadge() } }
                        Toggle(isOn: proBinding($usePassword)) { HStack { Text(verbatim: L("암호 걸기", "Password")); ProBadge() } }
                        if usePassword { SecureField(L("암호", "Password"), text: $password) }
                    }
                }
                Section {
                    Button { Task { await save() } } label: {
                        Text(verbatim: buttonTitle).font(.headline).frame(maxWidth: .infinity)
                    }
                    .disabled(busy != nil || (usePassword && password.isEmpty))
                    .accessibilityIdentifier("scan-save-confirm")
                } footer: { Text(verbatim: L("휴대폰 안에서 만들어요. 어디에도 올라가지 않아요.", "Made on your phone. Nothing is uploaded.")) }
            }
            .navigationTitle(L("저장하기", "Save"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L("취소", "Cancel")) { dismiss() } } }
            .overlay { if let b = busy { BusyOverlay(text: b) } }
            .sheet(isPresented: $paywall) { PaywallView().environmentObject(store) }
            .sheet(item: Binding(get: { ocrText.map { OcrResult(text: $0) } }, set: { ocrText = $0?.text })) { r in
                OcrResultView(text: r.text, suggestedName: session.name)
            }
            .toast($toast)
        }
        .presentationDetents([.medium, .large])
    }

    private var footer: String {
        switch format {
        case .pdf: return L("문서 1개로 저장하고 바로 열어요.", "Saves one document and opens it.")
        case .jpg: return L("쪽마다 사진첩에 저장해요.", "Saves each page to Photos.")
        case .text: return L("쪽의 글자를 읽어서 보여 줘요.", "Reads the text on each page.")
        }
    }

    private var buttonTitle: String {
        switch format {
        case .pdf: return L("PDF로 저장 · \(session.pages.count)쪽", "Save PDF · \(session.pages.count) pages")
        case .jpg: return L("사진첩에 \(session.pages.count)장 저장", "Save \(session.pages.count) photos")
        case .text: return L("글자 읽기", "Read text")
        }
    }

    private func proBinding(_ b: Binding<Bool>) -> Binding<Bool> {
        Binding(get: { b.wrappedValue }, set: { v in if v && !store.isPro { paywall = true } else { b.wrappedValue = v } })
    }

    private func save() async {
        let imgs = session.pages.map { $0.rendered }
        switch format {
        case .pdf:
            busy = L("PDF를 만드는 중…", "Making PDF…")
            var layers: [[OCR.Line]]? = nil
            if searchable && store.isPro {
                busy = L("글자를 읽는 중…", "Reading text…")
                var all: [[OCR.Line]] = []
                for img in imgs { all.append(await OCR.recognize(img)) }
                layers = all
            }
            let isSmall = small
            let pwd = usePassword && store.isPro ? password : nil
            let data: Data? = await Task.detached { () -> Data? in
                let d = PdfTools.pdf(from: imgs, jpegQuality: isSmall ? 0.55 : 0.82, maxSide: isSmall ? 1500 : 2400, textLayers: layers)
                if let pwd { return PdfTools.encrypt(d, password: pwd) }
                return d
            }.value
            busy = nil
            guard let data else { toast = L("저장하지 못했어요", "Could not save"); return }
            library.saveNew(data, name: session.name + ".pdf", source: .scanned, open: true)
            Interstitials.shared.documentOpened(adFree: store.isAdFree)
            dismiss(); finished()
        case .jpg:
            busy = L("사진첩에 저장하는 중…", "Saving to Photos…")
            let ok = await PhotoSaver.save(imgs)
            busy = nil
            toast = ok ? L("사진첩에 저장했어요", "Saved to Photos") : L("사진 접근을 허용해 주세요 (설정 › 모아오피스)", "Allow Photos access in Settings")
        case .text:
            busy = L("글자를 읽는 중…", "Reading text…")
            var parts: [String] = []
            for img in imgs { parts.append(OCR.text(await OCR.recognize(img))) }
            busy = nil
            ocrText = parts.joined(separator: "\n\n")
        }
    }
}

struct OcrResult: Identifiable { let text: String; var id: String { text } }

enum PhotoSaver {
    static func save(_ images: [UIImage]) async -> Bool {
        let st = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard st == .authorized || st == .limited else { return false }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                for img in images { PHAssetChangeRequest.creationRequestForAsset(from: img) }
            }
            return true
        } catch { return false }
    }
}
