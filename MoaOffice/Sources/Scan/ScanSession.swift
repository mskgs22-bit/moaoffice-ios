import SwiftUI
import VisionKit
import PhotosUI

enum ScanMode: String, CaseIterable, Identifiable {
    case document, book, idCard, whiteboard
    var id: String { rawValue }
    var title: String {
        switch self {
        case .document: return L("문서", "Document")
        case .book: return L("책 펼침", "Book")
        case .idCard: return L("신분증", "ID card")
        case .whiteboard: return L("화이트보드", "Whiteboard")
        }
    }
}

/// 스캔한 한 쪽. base 는 자르기·지우개·서명이 반영된 그림, filter·turns 는 나중에 바꿀 수 있다
final class ScanPage: ObservableObject, Identifiable {
    let id = UUID()
    @Published var base: UIImage { didSet { cache = nil } }
    @Published var filter: ScanFilter { didSet { cache = nil } }
    @Published var turns: Int = 0 { didSet { cache = nil } }
    let source: UIImage
    private var cache: UIImage?

    init(_ img: UIImage, filter: ScanFilter) {
        let n = ImageOps.downscale(ImageOps.normalized(img), maxSide: 3000)
        self.source = n; self.base = n; self.filter = filter
    }

    var rendered: UIImage {
        if let cache { return cache }
        let r = ImageOps.rotate(ImageOps.apply(filter, to: base), quarterTurns: turns)
        cache = r
        return r
    }

    var thumb: UIImage { ImageOps.downscale(rendered, maxSide: 600) }
}

@MainActor
final class ScanSession: ObservableObject {
    @Published var pages: [ScanPage] = []
    @Published var mode: ScanMode
    @Published var name: String

    init(mode: ScanMode = .document) {
        self.mode = mode
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HHmm"
        name = L("스캔 ", "Scan ") + f.string(from: Date())
    }

    var defaultFilter: ScanFilter { mode == .whiteboard ? .whiteboard : .auto }

    func add(_ images: [UIImage]) {
        var list: [UIImage] = []
        for img in images { list.append(contentsOf: mode == .book ? ImageOps.splitBook(img) : [img]) }
        pages.append(contentsOf: list.map { ScanPage($0, filter: defaultFilter) })
    }

    /// 사진첩 사진: 문서 테두리를 찾으면 바로 반듯하게
    func addPhotos(_ images: [UIImage]) {
        add(images.map { img in
            if let q = ImageOps.detectQuad(img) { return ImageOps.perspective(img, quad: q) }
            return img
        })
    }

    func move(from: IndexSet, to: Int) { pages.move(fromOffsets: from, toOffset: to) }
    func remove(_ p: ScanPage) { pages.removeAll { $0.id == p.id } }

    /// 시뮬레이터·스크린샷용 예시 쪽
    static func demoImages() -> [UIImage] {
        (0..<3).map { i in
            let size = CGSize(width: 1240, height: 1754)
            let f = UIGraphicsImageRendererFormat(); f.scale = 1
            return UIGraphicsImageRenderer(size: size, format: f).image { c in
                UIColor(white: 0.97, alpha: 1).setFill(); c.fill(CGRect(origin: .zero, size: size))
                let title = [L("정기 회의록", "Meeting minutes"), L("견적서", "Quotation"), L("영수증", "Receipt")][i]
                NSAttributedString(string: title, attributes: [.font: UIFont.boldSystemFont(ofSize: 64), .foregroundColor: UIColor.darkGray]).draw(at: CGPoint(x: 110, y: 140))
                for l in 0..<22 {
                    let w = CGFloat([900, 760, 840, 620, 880, 700][l % 6])
                    UIColor(white: 0.78, alpha: 1).setFill()
                    c.fill(CGRect(x: 110, y: 300 + CGFloat(l) * 58, width: w, height: 18))
                }
            }
        }
    }
}

/// 애플 문서 스캐너 (테두리 자동 인식·원근 보정·여러 장 연속)
struct DocCamera: UIViewControllerRepresentable {
    let done: ([UIImage]) -> Void
    let cancel: () -> Void

    static var isAvailable: Bool { VNDocumentCameraViewController.isSupported }

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let c = VNDocumentCameraViewController()
        c.delegate = context.coordinator
        return c
    }
    func updateUIViewController(_ c: VNDocumentCameraViewController, context: Context) {}
    func makeCoordinator() -> Coord { Coord(self) }

    final class Coord: NSObject, VNDocumentCameraViewControllerDelegate {
        let parent: DocCamera
        init(_ p: DocCamera) { parent = p }
        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            parent.done((0..<scan.pageCount).map { scan.imageOfPage(at: $0) })
        }
        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) { parent.cancel() }
        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) { parent.cancel() }
    }
}

/// 사진첩에서 여러 장 고르기
struct PhotoPicker: UIViewControllerRepresentable {
    var limit: Int = 0
    var selfDismiss = true
    let done: ([UIImage]) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var c = PHPickerConfiguration(photoLibrary: .shared())
        c.filter = .images; c.selectionLimit = limit
        let p = PHPickerViewController(configuration: c)
        p.delegate = context.coordinator
        return p
    }
    func updateUIViewController(_ c: PHPickerViewController, context: Context) {}
    func makeCoordinator() -> Coord { Coord(done, selfDismiss: selfDismiss) }

    final class Coord: NSObject, PHPickerViewControllerDelegate {
        let done: ([UIImage]) -> Void
        let selfDismiss: Bool
        init(_ d: @escaping ([UIImage]) -> Void, selfDismiss: Bool) { done = d; self.selfDismiss = selfDismiss }
        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            if selfDismiss { picker.dismiss(animated: true) }
            guard !results.isEmpty else { done([]); return }
            let group = DispatchGroup()
            let box = ImageBox(count: results.count)
            for (i, r) in results.enumerated() where r.itemProvider.canLoadObject(ofClass: UIImage.self) {
                group.enter()
                r.itemProvider.loadObject(ofClass: UIImage.self) { obj, _ in
                    box.set(i, obj as? UIImage)
                    group.leave()
                }
            }
            let done = self.done
            group.notify(queue: .main) { done(box.all) }
        }
    }
}

/// 여러 스레드에서 채우는 그림 목록
final class ImageBox: @unchecked Sendable {
    private var items: [UIImage?]
    private let lock = NSLock()
    init(count: Int) { items = Array(repeating: nil, count: count) }
    func set(_ i: Int, _ img: UIImage?) { lock.lock(); items[i] = img; lock.unlock() }
    var all: [UIImage] { lock.lock(); defer { lock.unlock() }; return items.compactMap { $0 } }
}
