import SwiftUI
import UniformTypeIdentifiers

struct HomeView: View {
    @EnvironmentObject var library: Library
    @EnvironmentObject var store: Store
    @State private var importing = false
    @State private var showSettings = false
    @State private var showPaywall = false

    private var types: [UTType] {
        DocKind.extensions.compactMap { UTType(filenameExtension: $0) } + [.pdf, .commaSeparatedText, .data]
    }

    var body: some View {
        NavigationStack {
            Group {
                if library.files.isEmpty { empty } else { list }
            }
            .navigationTitle("MoaOffice")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityIdentifier("settings")
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { importing = true } label: { Image(systemName: "plus.circle.fill").font(.title3) }
                        .accessibilityIdentifier("open")
                }
            }
            .safeAreaInset(edge: .bottom) { AdBannerBar() }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: types, allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let u = urls.first { library.importFile(u) }
        }
        .fullScreenCover(item: $library.opened) { f in
            DocumentScreen(file: f).environmentObject(library).environmentObject(store)
        }
        .sheet(isPresented: $showSettings) { SettingsView().environmentObject(store) }
        .sheet(isPresented: $showPaywall) { PaywallView().environmentObject(store) }
        .alert(library.lastError ?? "", isPresented: Binding(get: { library.lastError != nil }, set: { if !$0 { library.lastError = nil } })) {
            Button("OK", role: .cancel) {}
        }
        .onAppear { Interstitials.shared.preload() }
    }

    private var empty: some View {
        VStack(spacing: 18) {
            Image(systemName: "doc.on.doc.fill").font(.system(size: 64)).foregroundStyle(Color.brand)
            Text("All your documents in one app").font(.title3.bold())
            Text("PDF · HWP · HWPX · DOC · DOCX · XLS · XLSX · CSV").font(.footnote).foregroundStyle(.secondary)
            Button { importing = true } label: {
                Label("Open a document", systemImage: "folder").font(.headline).padding(.horizontal, 24).padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            Text("Files stay on your device. Nothing is uploaded.").font(.caption).foregroundStyle(.secondary)
        }
        .padding()
    }

    private var list: some View {
        List {
            if !store.isAdFree {
                Button { showPaywall = true } label: {
                    HStack {
                        Image(systemName: "sparkles").foregroundStyle(.white)
                        Text("Remove ads").foregroundStyle(.white).bold()
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.white.opacity(0.8))
                    }
                }
                .listRowBackground(Color.brand)
            }
            Section("Recent documents") {
                ForEach(library.files) { f in
                    Button { library.touch(f); library.opened = f } label: { FileRow(file: f).contentShape(Rectangle()) }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("file-\(f.name)")
                }
                .onDelete { idx in idx.map { library.files[$0] }.forEach(library.delete) }
            }
        }
        .refreshable { library.reload() }
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
                Text("\(file.modified.formatted(date: .abbreviated, time: .shortened)) · \(ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file))")
                    .font(.caption).foregroundStyle(.secondary)
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
