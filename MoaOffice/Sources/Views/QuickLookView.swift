import SwiftUI
import QuickLook

/// DOC·DOCX·XLS·XLSX·CSV 등은 iOS 내장 QuickLook 엔진으로 표시 (오프라인)
struct QuickLookView: UIViewControllerRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let c = QLPreviewController()
        c.dataSource = context.coordinator
        return c
    }

    func updateUIViewController(_ c: QLPreviewController, context: Context) {}

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { url as NSURL }
    }
}

/// PSD·PSB: ImageIO 로 합성 이미지를 읽고, 안 되면 QuickLook
struct ImageScreen: View {
    let url: URL
    @State private var image: UIImage?
    @State private var tried = false
    @State private var scale: CGFloat = 1

    var body: some View {
        Group {
            if let image {
                ScrollView([.horizontal, .vertical]) {
                    Image(uiImage: image).resizable().scaledToFit()
                        .frame(width: UIScreen.main.bounds.width * scale)
                }
                .gesture(MagnificationGesture().onChanged { scale = min(6, max(1, $0)) })
                .background(Color(.secondarySystemBackground))
            } else if tried {
                QuickLookView(url: url)
            } else {
                ProgressView()
            }
        }
        .task {
            let u = url
            image = await Task.detached { UIImage(contentsOfFile: u.path) }.value
            tried = true
        }
    }
}
