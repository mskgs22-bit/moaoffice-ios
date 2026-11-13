import SwiftUI
import PDFKit

@MainActor
final class PdfController: ObservableObject {
    let view = PDFView()
    let url: URL
    @Published var locked = false
    @Published var failed = false
    @Published var dirty = false
    @Published var pageLabel = ""
    @Published var toast: String?

    init(url: URL) {
        self.url = url
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.backgroundColor = .secondarySystemBackground
        if let doc = PDFDocument(url: url) {
            view.document = doc
            locked = doc.isLocked
        } else {
            failed = true
        }
        NotificationCenter.default.addObserver(forName: .PDFViewPageChanged, object: view, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.updatePage() }
        }
        updatePage()
    }

    func updatePage() {
        guard let doc = view.document, let p = view.currentPage else { return }
        pageLabel = "\(doc.index(for: p) + 1) / \(doc.pageCount)"
    }

    func unlock(_ pw: String) -> Bool {
        guard let doc = view.document, doc.unlock(withPassword: pw) else { return false }
        locked = false
        view.document = doc
        updatePage()
        return true
    }

    func mark(_ type: PDFAnnotationSubtype, color: UIColor) {
        guard let sel = view.currentSelection else {
            toast = String(localized: "Select text first, then tap the tool.")
            return
        }
        for line in sel.selectionsByLine() {
            for page in line.pages {
                let a = PDFAnnotation(bounds: line.bounds(for: page), forType: type, withProperties: nil)
                a.color = color
                a.userName = "MoaOffice"
                page.addAnnotation(a)
            }
        }
        view.clearSelection()
        dirty = true
    }

    func save() {
        guard let doc = view.document else { return }
        if doc.write(to: url) {
            dirty = false
            toast = String(localized: "Saved")
        } else {
            toast = String(localized: "Could not save this PDF.")
        }
    }
}

struct PdfKitView: UIViewRepresentable {
    let view: PDFView
    func makeUIView(context: Context) -> PDFView { view }
    func updateUIView(_ uiView: PDFView, context: Context) {}
}

struct PdfScreen: View {
    @StateObject private var c: PdfController
    @State private var password = ""
    @State private var wrong = false

    init(url: URL) { _c = StateObject(wrappedValue: PdfController(url: url)) }

    var body: some View {
        Group {
            if c.failed {
                ContentUnavailableCompat(title: "This file seems to be damaged.", system: "exclamationmark.triangle")
            } else if c.locked {
                VStack(spacing: 16) {
                    Image(systemName: "lock.fill").font(.largeTitle).foregroundStyle(Color.brand)
                    Text("This PDF is password protected.")
                    SecureField("Password", text: $password).textFieldStyle(.roundedBorder).frame(maxWidth: 280)
                    if wrong { Text("Wrong password").foregroundStyle(.red).font(.footnote) }
                    Button("Open") { wrong = !c.unlock(password) }.buttonStyle(.borderedProminent)
                }.padding()
            } else {
                PdfKitView(view: c.view)
                    .overlay(alignment: .top) {
                        if !c.pageLabel.isEmpty {
                            Text(c.pageLabel).font(.caption.monospacedDigit()).padding(.horizontal, 10).padding(.vertical, 4)
                                .background(.ultraThinMaterial, in: Capsule()).padding(.top, 8)
                        }
                    }
                    .overlay(alignment: .bottom) {
                        if let t = c.toast {
                            Text(t).font(.footnote).padding(10).background(.black.opacity(0.75), in: Capsule()).foregroundStyle(.white)
                                .padding(.bottom, 70)
                                .task { try? await Task.sleep(nanoseconds: 2_000_000_000); c.toast = nil }
                        }
                    }
                    .safeAreaInset(edge: .bottom) { toolbar }
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 22) {
            Button { c.mark(.highlight, color: UIColor.systemYellow.withAlphaComponent(0.5)) } label: { Label("Highlight", systemImage: "highlighter") }
            Button { c.mark(.underline, color: .systemRed) } label: { Label("Underline", systemImage: "underline") }
            Button { c.mark(.strikeOut, color: .systemRed) } label: { Label("Strike", systemImage: "strikethrough") }
            Spacer()
            Button { c.save() } label: { Label("Save", systemImage: "square.and.arrow.down") }
                .disabled(!c.dirty)
        }
        .labelStyle(.iconOnly)
        .font(.title3)
        .padding(.horizontal, 20).padding(.vertical, 10)
        .background(.bar)
    }
}

/// iOS 16 호환 빈 상태 화면
struct ContentUnavailableCompat: View {
    let title: LocalizedStringKey
    let system: String
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: system).font(.system(size: 44)).foregroundStyle(.secondary)
            Text(title).multilineTextAlignment(.center)
        }.padding()
    }
}
