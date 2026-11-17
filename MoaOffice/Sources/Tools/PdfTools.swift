import AVFoundation
import UIKit
import PDFKit

/// PDF 만들기·고치기 (PDFKit + UIGraphicsPDFRenderer, 모두 기기 안)
enum PdfTools {
    static let a4 = CGSize(width: 595.2, height: 841.8)

    /// 사진들 → PDF. fit: A4 에 맞춤 / false 면 사진 크기 그대로
    static func pdf(from images: [UIImage], jpegQuality: CGFloat = 0.82, maxSide: CGFloat = 2400, fitA4: Bool = false, textLayers: [[OCR.Line]]? = nil) -> Data {
        let out = NSMutableData()
        UIGraphicsBeginPDFContextToData(out, .zero, nil)
        for (i, raw) in images.enumerated() {
            let img0 = ImageOps.downscale(ImageOps.normalized(raw), maxSide: maxSide)
            let img = UIImage(data: img0.jpegData(compressionQuality: jpegQuality) ?? Data()) ?? img0
            let pageSize: CGSize
            if fitA4 { pageSize = img.size.width > img.size.height ? CGSize(width: a4.height, height: a4.width) : a4 }
            else {
                let k = a4.width / max(1, min(img.size.width, img.size.height)) // 짧은 변을 A4 폭(약 72dpi 기준)으로
                pageSize = CGSize(width: img.size.width * k, height: img.size.height * k)
            }
            let page = CGRect(origin: .zero, size: pageSize)
            UIGraphicsBeginPDFPageWithInfo(page, nil)
            let r = AVMakeRect(aspectRatio: img.size, insideRect: page)
            if let layer = textLayers?[safe: i] { drawInvisibleText(layer, in: r) }
            img.draw(in: r)
        }
        UIGraphicsEndPDFContext()
        return out as Data
    }

    /// 글자 검색되는 PDF: 그림 아래에 투명 글자를 깐다
    private static func drawInvisibleText(_ lines: [OCR.Line], in r: CGRect) {
        guard let g = UIGraphicsGetCurrentContext() else { return }
        g.saveGState()
        g.setTextDrawingMode(.invisible)
        for l in lines {
            let box = CGRect(x: r.minX + l.box.minX * r.width, y: r.minY + l.box.minY * r.height, width: l.box.width * r.width, height: l.box.height * r.height)
            let font = UIFont.systemFont(ofSize: max(4, box.height * 0.8))
            let s = NSAttributedString(string: l.text, attributes: [.font: font, .foregroundColor: UIColor.clear])
            let w = s.size().width
            g.saveGState()
            g.translateBy(x: box.minX, y: box.minY)
            if w > 0 { g.scaleBy(x: box.width / w, y: 1) }
            s.draw(at: .zero)
            g.restoreGState()
        }
        g.restoreGState()
    }

    static func merge(_ urls: [URL]) -> Data? {
        let out = PDFDocument()
        for u in urls {
            if DocKind.of(u) == .pdf, let d = PDFDocument(url: u) {
                for i in 0..<d.pageCount { if let p = d.page(at: i) { out.insert(p, at: out.pageCount) } }
            } else if let img = UIImage(contentsOfFile: u.path), let d = PDFDocument(data: pdf(from: [img], fitA4: true)), let p = d.page(at: 0) {
                out.insert(p, at: out.pageCount)
            }
        }
        return out.pageCount > 0 ? out.dataRepresentation() : nil
    }

    static func renderPage(_ page: PDFPage, maxSide: CGFloat = 2000) -> UIImage {
        let b = page.bounds(for: .mediaBox)
        let rot = page.rotation % 180 != 0
        let size0 = rot ? CGSize(width: b.height, height: b.width) : b.size
        let k = min(4, maxSide / max(size0.width, size0.height))
        return page.thumbnail(of: CGSize(width: size0.width * k, height: size0.height * k), for: .mediaBox)
    }

    static func images(of url: URL, maxSide: CGFloat = 2000) -> [UIImage] {
        guard let d = PDFDocument(url: url) else { return [] }
        return (0..<d.pageCount).compactMap { d.page(at: $0) }.map { renderPage($0, maxSide: maxSide) }
    }

    /// 압축: 쪽을 그림으로 다시 그려 JPEG 로 (글자 선택은 사라짐)
    static func compress(_ url: URL, level: CompressLevel) -> Data? {
        let imgs = images(of: url, maxSide: level.maxSide)
        guard !imgs.isEmpty else { return nil }
        return pdf(from: imgs, jpegQuality: level.quality, maxSide: level.maxSide, fitA4: false)
    }

    enum CompressLevel: CaseIterable, Identifiable {
        case light, normal, strong
        var id: Self { self }
        var maxSide: CGFloat { self == .light ? 2200 : (self == .normal ? 1600 : 1100) }
        var quality: CGFloat { self == .light ? 0.75 : (self == .normal ? 0.6 : 0.45) }
        var title: String { self == .light ? L("조금", "Light") : (self == .normal ? L("보통", "Normal") : L("많이", "Strong")) }
    }

    /// 쪽을 그대로(벡터) 다시 그리고 그 위에 덧그린다. draw 는 UIKit 좌표(왼쪽 위 원점, 쪽 크기 pt)
    static func rewrite(_ doc: PDFDocument, overlay: (Int, CGRect) -> Void) -> Data {
        let out = NSMutableData()
        UIGraphicsBeginPDFContextToData(out, .zero, nil)
        for i in 0..<doc.pageCount {
            guard let p = doc.page(at: i) else { continue }
            let b = p.bounds(for: .cropBox)
            let rot = ((p.rotation % 360) + 360) % 360
            let size = (rot == 90 || rot == 270) ? CGSize(width: b.height, height: b.width) : b.size
            let rect = CGRect(origin: .zero, size: size)
            UIGraphicsBeginPDFPageWithInfo(rect, nil)
            guard let g = UIGraphicsGetCurrentContext() else { continue }
            g.saveGState()
            g.translateBy(x: 0, y: size.height); g.scaleBy(x: 1, y: -1)
            p.draw(with: .cropBox, to: g)
            g.restoreGState()
            overlay(i, rect)
        }
        UIGraphicsEndPDFContext()
        return out as Data
    }

    enum StampStyle { case diagonal, corner }

    /// 쪽마다 글자를 얹는다 (워터마크·날짜 도장)
    static func stamp(_ url: URL, text: String, style: StampStyle, color: UIColor) -> Data? {
        guard let d = PDFDocument(url: url), d.pageCount > 0 else { return nil }
        return rewrite(d) { _, r in
            guard let g = UIGraphicsGetCurrentContext() else { return }
            switch style {
            case .diagonal:
                let size = min(r.width, r.height) / 9
                let s = NSAttributedString(string: text, attributes: [.font: UIFont.boldSystemFont(ofSize: size), .foregroundColor: color.withAlphaComponent(0.22)])
                let w = s.size()
                g.saveGState(); g.translateBy(x: r.midX, y: r.midY); g.rotate(by: -.pi / 5)
                s.draw(at: CGPoint(x: -w.width / 2, y: -w.height / 2)); g.restoreGState()
            case .corner:
                let s = NSAttributedString(string: text, attributes: [.font: UIFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: color])
                let w = s.size()
                s.draw(at: CGPoint(x: r.maxX - w.width - 24, y: 24))
            }
        }
    }

    /// 그림(서명)을 한 쪽 위에 얹는다. rect 는 0~1 (왼쪽 위 기준)
    static func addImage(_ img: UIImage, to doc: PDFDocument, page index: Int, rect: CGRect) -> Data {
        rewrite(doc) { i, r in
            guard i == index else { return }
            img.draw(in: CGRect(x: r.minX + rect.minX * r.width, y: r.minY + rect.minY * r.height, width: rect.width * r.width, height: rect.height * r.height))
        }
    }

    static func encrypt(_ data: Data, password: String) -> Data? {
        guard let d = PDFDocument(data: data) else { return nil }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        defer { try? FileManager.default.removeItem(at: tmp) }
        guard d.write(to: tmp, withOptions: [.userPasswordOption: password, .ownerPasswordOption: password]) else { return nil }
        return try? Data(contentsOf: tmp)
    }

    static func pageCount(_ url: URL) -> Int { PDFDocument(url: url)?.pageCount ?? 0 }
}


extension Array { subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil } }
