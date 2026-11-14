import UIKit
import WebKit

/// 모든 형식 인쇄 (AirPrint). 문서는 기기 안에서 인쇄용으로 바뀌어 사용자가 고른 프린터로만 간다.
@MainActor
enum DocPrinter {
    private static var webPrinter: WebPrintLoader?

    static func print(_ url: URL) {
        let info = UIPrintInfo(dictionary: nil)
        info.jobName = url.lastPathComponent
        info.outputType = .general
        let pc = UIPrintInteractionController.shared
        pc.printInfo = info
        pc.printingItem = nil
        pc.printFormatter = nil

        switch DocKind.of(url) {
        case .pdf:
            pc.printingItem = (try? Data(contentsOf: url)) ?? url
            present(pc)
        case .hwp:
            Task {
                let u = url
                guard let doc = try? await Task.detached(operation: { try HwpDocument.open(u) }).value else { return }
                pc.printingItem = PdfExporter.render(doc)
                present(pc)
            }
        case .image:
            if let img = UIImage(contentsOfFile: url.path) { pc.printingItem = img; present(pc) }
        case .office where url.pathExtension.lowercased() == "csv":
            pc.printFormatter = UIMarkupTextPrintFormatter(markupText: csvHTML(url))
            present(pc)
        default:
            // DOC·DOCX·XLS·XLSX: WebKit 이 오프라인으로 그린 결과를 인쇄
            let loader = WebPrintLoader(url: url) { web in
                pc.printFormatter = web.viewPrintFormatter()
                present(pc)
                webPrinter = nil
            }
            webPrinter = loader
            loader.start()
        }
    }

    private static func present(_ pc: UIPrintInteractionController) {
        pc.present(animated: true) { _, _, _ in }
    }

    private static func csvHTML(_ url: URL) -> String {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        }
        let rows = CsvScreen.parse(url).prefix(5000)
        var h = "<html><head><meta charset='utf-8'><style>table{border-collapse:collapse;font-family:-apple-system;font-size:9pt}td{border:0.5pt solid #888;padding:3px 5px}tr:first-child td{font-weight:bold;background:#f3f3f3}</style></head><body><table>"
        for r in rows { h += "<tr>" + r.map { "<td>\(esc($0))</td>" }.joined() + "</tr>" }
        return h + "</table></body></html>"
    }
}

final class WebPrintLoader: NSObject, WKNavigationDelegate {
    let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 1100))
    let url: URL
    let done: (WKWebView) -> Void

    init(url: URL, done: @escaping (WKWebView) -> Void) {
        self.url = url
        self.done = done
    }

    func start() {
        web.navigationDelegate = self
        web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.done(webView) }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { done(webView) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { done(webView) }
}
