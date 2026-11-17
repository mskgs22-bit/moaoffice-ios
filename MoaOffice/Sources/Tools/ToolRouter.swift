import SwiftUI

enum ToolID: String, CaseIterable, Identifiable {
    case scan, book, idCard, idPhoto, whiteboard, importPhotos
    case img2pdf, pdf2img, compress, ocr
    case merge, organize, sign, watermark, dateStamp, eraser
    case print, qrScan, qrMake, lock

    var id: String { rawValue }

    var title: String {
        switch self {
        case .scan: return L("문서 스캔", "Scan")
        case .book: return L("책 펼침", "Book")
        case .idCard: return L("신분증 복사", "ID copy")
        case .idPhoto: return L("증명사진", "ID photo")
        case .whiteboard: return L("화이트보드", "Whiteboard")
        case .importPhotos: return L("사진 가져오기", "From photos")
        case .img2pdf: return L("사진→PDF", "Images→PDF")
        case .pdf2img: return L("PDF→사진", "PDF→Images")
        case .compress: return L("PDF 압축", "Compress")
        case .ocr: return L("글자 인식", "Text (OCR)")
        case .merge: return L("PDF 합치기", "Merge PDFs")
        case .organize: return L("쪽 정리", "Pages")
        case .sign: return L("서명", "Sign")
        case .watermark: return L("워터마크", "Watermark")
        case .dateStamp: return L("날짜 도장", "Date stamp")
        case .eraser: return L("지우개", "Eraser")
        case .print: return L("인쇄", "Print")
        case .qrScan: return L("QR 스캔", "Scan QR")
        case .qrMake: return L("QR 만들기", "Make QR")
        case .lock: return L("PDF 암호", "Lock PDF")
        }
    }

    var icon: String {
        switch self {
        case .scan: return "doc.viewfinder"
        case .book: return "book"
        case .idCard: return "person.text.rectangle"
        case .idPhoto: return "person.crop.square"
        case .whiteboard: return "rectangle.and.pencil.and.ellipsis"
        case .importPhotos: return "photo.on.rectangle"
        case .img2pdf: return "photo.badge.arrow.down"
        case .pdf2img: return "photo.stack"
        case .compress: return "arrow.down.right.and.arrow.up.left"
        case .ocr: return "text.viewfinder"
        case .merge: return "doc.on.doc"
        case .organize: return "square.grid.2x2"
        case .sign: return "signature"
        case .watermark: return "drop"
        case .dateStamp: return "calendar.badge.clock"
        case .eraser: return "eraser"
        case .print: return "printer"
        case .qrScan: return "qrcode.viewfinder"
        case .qrMake: return "qrcode"
        case .lock: return "lock.doc"
        }
    }

    var isPro: Bool { [.idPhoto, .compress, .eraser, .lock].contains(self) }

    static let sections: [(String, [ToolID])] = [
        (L("스캔", "Scan"), [.scan, .book, .idCard, .idPhoto, .whiteboard, .importPhotos]),
        (L("변환", "Convert"), [.img2pdf, .pdf2img, .compress, .ocr]),
        (L("PDF 편집", "Edit PDF"), [.merge, .organize, .sign, .watermark, .dateStamp, .eraser]),
        (L("유틸리티", "Utilities"), [.print, .qrScan, .qrMake, .lock])
    ]
}

/// 도구 화면 열기 (파일·사진 고르기를 거쳐)
@MainActor
final class ToolRouter: ObservableObject {
    enum Route: Identifiable {
        case scan(ScanMode), scanImages([UIImage], Bool), idCard, idPhoto, ocr, merge, qr, paywall
        case pickPDF(ToolID), pickDoc(ToolID), pickPhotos(ToolID)
        case withFile(ToolID, DocFile)

        var id: String {
            switch self {
            case .scan(let m): return "scan-\(m.rawValue)"
            case .scanImages(_, let e): return "scanImages-\(e)"
            case .idCard: return "idCard"
            case .idPhoto: return "idPhoto"
            case .ocr: return "ocr"
            case .merge: return "merge"
            case .qr: return "qr"
            case .paywall: return "paywall"
            case .pickPDF(let t): return "pickPDF-\(t.rawValue)"
            case .pickDoc(let t): return "pickDoc-\(t.rawValue)"
            case .pickPhotos(let t): return "pickPhotos-\(t.rawValue)"
            case .withFile(let t, let f): return "file-\(t.rawValue)-\(f.url.path)"
            }
        }
    }

    @Published var route: Route?

    func open(_ t: ToolID, isPro: Bool) {
        if t.isPro && !isPro { route = .paywall; return }
        switch t {
        case .scan: route = .scan(.document)
        case .book: route = .scan(.book)
        case .whiteboard: route = .scan(.whiteboard)
        case .idCard: route = .idCard
        case .idPhoto: route = .idPhoto
        case .ocr: route = .ocr
        case .merge: route = .merge
        case .qrScan, .qrMake: route = .qr
        case .importPhotos, .img2pdf, .eraser: route = .pickPhotos(t)
        case .print: route = .pickDoc(t)
        case .pdf2img, .compress, .organize, .sign, .watermark, .dateStamp, .lock: route = .pickPDF(t)
        }
    }

    /// 고르기 화면이 닫힌 뒤 다음 화면을 연다
    func next(_ r: Route?) {
        route = nil
        guard let r else { return }
        Task { try? await Task.sleep(nanoseconds: 450_000_000); route = r }
    }
}

struct ToolHost: ViewModifier {
    @ObservedObject var router: ToolRouter
    @EnvironmentObject var library: Library
    @EnvironmentObject var store: Store

    func body(content: Content) -> some View {
        content.fullScreenCover(item: $router.route) { r in
            Group { screen(r) }
                .environmentObject(library).environmentObject(store)
        }
    }

    @ViewBuilder private func screen(_ r: ToolRouter.Route) -> some View {
        switch r {
        case .scan(let m): ScanFlowView(mode: m)
        case .scanImages(let imgs, let edit): ScanFlowView(mode: .document, images: imgs, editFirst: edit)
        case .idCard: IdCardView()
        case .idPhoto: IdPhotoView()
        case .ocr: OcrToolView()
        case .merge: MergeView()
        case .qr: QRView()
        case .paywall: PaywallView()
        case .pickPDF(let t):
            LibraryPicker(title: t.title) { files in router.next(files.first.map { .withFile(t, $0) }) }
        case .pickDoc(let t):
            LibraryPicker(title: t.title, pdfOnly: false) { files in
                if t == .print, let f = files.first { router.route = nil; Task { try? await Task.sleep(nanoseconds: 450_000_000); DocPrinter.print(f.url) } }
            }
        case .pickPhotos(let t):
            PhotoPicker(selfDismiss: false) { imgs in
                guard !imgs.isEmpty else { router.route = nil; return }
                switch t {
                case .img2pdf:
                    let data = PdfTools.pdf(from: imgs, fitA4: true)
                    library.saveNew(data, name: L("사진 PDF ", "Photos ") + Date().formatted(date: .numeric, time: .omitted).replacingOccurrences(of: "/", with: "-") + ".pdf", source: .opened, open: true)
                    router.route = nil
                case .eraser: router.next(.scanImages(imgs, true))
                default: router.next(.scanImages(imgs, false))
                }
            }
            .ignoresSafeArea()
        case .withFile(let t, let f):
            switch t {
            case .pdf2img: PdfToImagesView(file: f)
            case .compress: CompressView(file: f)
            case .organize: PageOrganizerView(file: f)
            case .sign: PdfSignView(file: f)
            case .watermark: StampView(file: f, style: .diagonal)
            case .dateStamp: StampView(file: f, style: .corner)
            case .lock: PasswordView(file: f)
            default: EmptyView()
            }
        }
    }
}
