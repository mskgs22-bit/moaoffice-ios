import SwiftUI

struct DocumentScreen: View {
    let file: DocFile
    @EnvironmentObject var library: Library
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(file.name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button { dismiss() } label: { Image(systemName: "xmark") }
                            .accessibilityIdentifier("close")
                    }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        ShareLink(item: file.url) { Image(systemName: "square.and.arrow.up") }
                    }
                }
                .safeAreaInset(edge: .bottom) { AdBannerBar() }
        }
        .onAppear { Interstitials.shared.documentOpened(adFree: store.isAdFree) }
        .onDisappear { library.reload() }
    }

    @ViewBuilder private var content: some View {
        switch DocKind.of(file.url) {
        case .pdf: PdfScreen(url: file.url)
        case .hwp: HwpScreen(url: file.url)
        case .image: ImageScreen(url: file.url)
        case .office where file.url.pathExtension.lowercased() == "csv": CsvScreen(url: file.url)
        default: QuickLookView(url: file.url).ignoresSafeArea(edges: .bottom)
        }
    }
}
