import UIKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Vision

/// 스캔한 쪽 보정 (모두 기기 안 CoreImage)
enum ScanFilter: String, CaseIterable, Identifiable, Codable {
    case original, auto, sharp, mono, gray, bright, whiteboard
    var id: String { rawValue }
    var title: String {
        switch self {
        case .original: return L("원본", "Original")
        case .auto: return L("자동", "Auto")
        case .sharp: return L("선명하게", "Sharp")
        case .mono: return L("흑백", "B&W")
        case .gray: return L("회색조", "Grayscale")
        case .bright: return L("밝게", "Bright")
        case .whiteboard: return L("화이트보드", "Whiteboard")
        }
    }
}

enum ImageOps {
    static let ctx = CIContext(options: [.useSoftwareRenderer: false])

    /// 방향 정보를 반영한 CIImage
    static func ci(_ img: UIImage) -> CIImage? {
        if let c = img.cgImage { return CIImage(cgImage: c).oriented(CGImagePropertyOrientation(img.imageOrientation)) }
        return CIImage(image: img)
    }

    static func ui(_ ci: CIImage, scale: CGFloat = 1) -> UIImage? {
        guard let cg = ctx.createCGImage(ci, from: ci.extent.integral) else { return nil }
        return UIImage(cgImage: cg, scale: scale, orientation: .up)
    }

    /// 방향을 실제 픽셀에 굽는다
    static func normalized(_ img: UIImage) -> UIImage {
        if img.imageOrientation == .up, img.cgImage != nil { return img }
        let r = UIGraphicsImageRenderer(size: img.size, format: { let f = UIGraphicsImageRendererFormat(); f.scale = 1; return f }())
        return r.image { _ in img.draw(in: CGRect(origin: .zero, size: img.size)) }
    }

    static func apply(_ f: ScanFilter, to img: UIImage) -> UIImage {
        guard f != .original, let input = ci(img) else { return img }
        var out = input
        switch f {
        case .original: break
        case .auto:
            for filt in input.autoAdjustmentFilters(options: [.redEye: false]) { filt.setValue(out, forKey: kCIInputImageKey); out = filt.outputImage ?? out }
            out = out.applyingFilter("CIColorControls", parameters: ["inputContrast": 1.08, "inputSaturation": 1.0])
        case .sharp:
            out = out.applyingFilter("CIColorControls", parameters: ["inputContrast": 1.25, "inputBrightness": 0.04])
                .applyingFilter("CISharpenLuminance", parameters: ["inputSharpness": 0.7])
        case .mono:
            let g = out.applyingFilter("CIPhotoEffectNoir")
            out = g.applyingFilter("CIColorControls", parameters: ["inputContrast": 1.9, "inputBrightness": 0.12])
        case .gray:
            out = out.applyingFilter("CIPhotoEffectMono").applyingFilter("CIColorControls", parameters: ["inputContrast": 1.15])
        case .bright:
            out = out.applyingFilter("CIExposureAdjust", parameters: ["inputEV": 0.6]).applyingFilter("CIColorControls", parameters: ["inputContrast": 1.05])
        case .whiteboard:
            // 배경을 하얗게, 글씨는 진하게
            out = out.applyingFilter("CIExposureAdjust", parameters: ["inputEV": 0.9])
                .applyingFilter("CIColorControls", parameters: ["inputContrast": 1.6, "inputSaturation": 1.3])
                .applyingFilter("CISharpenLuminance", parameters: ["inputSharpness": 0.5])
        }
        return ui(out.cropped(to: input.extent)) ?? img
    }

    static func rotate(_ img: UIImage, quarterTurns: Int) -> UIImage {
        let t = ((quarterTurns % 4) + 4) % 4
        guard t != 0, let input = ci(img) else { return img }
        let o: CGImagePropertyOrientation = t == 1 ? .right : (t == 2 ? .down : .left)
        return ui(input.oriented(o)) ?? img
    }

    /// 네 모서리(이미지 좌표 0~1, 왼쪽 위 기준)로 원근 보정
    static func perspective(_ img: UIImage, quad: [CGPoint]) -> UIImage {
        guard quad.count == 4, let input = ci(img) else { return img }
        let W = input.extent.width, H = input.extent.height
        func v(_ p: CGPoint) -> CIVector { CIVector(x: p.x * W, y: (1 - p.y) * H) }
        let out = input.applyingFilter("CIPerspectiveCorrection", parameters: [
            "inputTopLeft": v(quad[0]), "inputTopRight": v(quad[1]), "inputBottomRight": v(quad[2]), "inputBottomLeft": v(quad[3])])
        return ui(out) ?? img
    }

    /// 문서 테두리 자동 찾기 → 모서리 4개 (0~1, 왼쪽 위 기준, 시계 방향)
    static func detectQuad(_ img: UIImage) -> [CGPoint]? {
        guard let cg = normalized(img).cgImage else { return nil }
        let req = VNDetectRectanglesRequest()
        req.minimumAspectRatio = 0.3; req.maximumAspectRatio = 1.0; req.minimumSize = 0.25
        req.minimumConfidence = 0.6; req.maximumObservations = 1; req.quadratureTolerance = 30
        try? VNImageRequestHandler(cgImage: cg).perform([req])
        guard let r = req.results?.first else { return nil }
        func f(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x, y: 1 - p.y) }
        return [f(r.topLeft), f(r.topRight), f(r.bottomRight), f(r.bottomLeft)]
    }

    /// 펼친 책 한 장을 왼쪽·오른쪽 두 쪽으로
    static func splitBook(_ img: UIImage) -> [UIImage] {
        let n = normalized(img)
        guard let cg = n.cgImage else { return [img] }
        let w = cg.width / 2
        let l = cg.cropping(to: CGRect(x: 0, y: 0, width: w, height: cg.height))
        let r = cg.cropping(to: CGRect(x: w, y: 0, width: cg.width - w, height: cg.height))
        return [l, r].compactMap { $0 }.map { UIImage(cgImage: $0) }
    }

    /// 지우개: 칠한 선을 바탕색(주변 밝은 색)으로 덮는다
    static func erase(_ img: UIImage, strokes: [[CGPoint]], width: CGFloat) -> UIImage {
        let base = normalized(img)
        let f = UIGraphicsImageRendererFormat(); f.scale = 1
        return UIGraphicsImageRenderer(size: base.size, format: f).image { c in
            base.draw(at: .zero)
            let g = c.cgContext
            g.setStrokeColor(paperColor(base).cgColor)
            g.setLineWidth(width * base.size.width); g.setLineCap(.round); g.setLineJoin(.round)
            for s in strokes where !s.isEmpty {
                g.beginPath(); g.move(to: CGPoint(x: s[0].x * base.size.width, y: s[0].y * base.size.height))
                for p in s.dropFirst() { g.addLine(to: CGPoint(x: p.x * base.size.width, y: p.y * base.size.height)) }
                if s.count == 1 { g.addLine(to: CGPoint(x: s[0].x * base.size.width + 0.5, y: s[0].y * base.size.height)) }
                g.strokePath()
            }
        }
    }

    /// 종이 바탕색 추정 (가장자리 평균보다 밝은 쪽)
    static func paperColor(_ img: UIImage) -> UIColor {
        guard let input = ci(img) else { return .white }
        let avg = input.applyingFilter("CIAreaMaximum", parameters: [kCIInputExtentKey: CIVector(cgRect: input.extent)])
        var px = [UInt8](repeating: 0, count: 4)
        ctx.render(avg, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        let k: CGFloat = 0.97
        return UIColor(red: CGFloat(px[0]) / 255 * k, green: CGFloat(px[1]) / 255 * k, blue: CGFloat(px[2]) / 255 * k, alpha: 1)
    }

    /// 긴 변 기준 축소 (저장 크기 줄이기)
    static func downscale(_ img: UIImage, maxSide: CGFloat) -> UIImage {
        let s = max(img.size.width, img.size.height)
        guard s > maxSide else { return img }
        let k = maxSide / s
        let size = CGSize(width: (img.size.width * k).rounded(), height: (img.size.height * k).rounded())
        let f = UIGraphicsImageRendererFormat(); f.scale = 1
        return UIGraphicsImageRenderer(size: size, format: f).image { _ in img.draw(in: CGRect(origin: .zero, size: size)) }
    }

    /// 서명·도장 같은 그림을 위에 얹기 (rect 는 0~1)
    static func overlay(_ img: UIImage, _ top: UIImage, in rect: CGRect) -> UIImage {
        let base = normalized(img)
        let f = UIGraphicsImageRendererFormat(); f.scale = 1
        return UIGraphicsImageRenderer(size: base.size, format: f).image { _ in
            base.draw(at: .zero)
            top.draw(in: CGRect(x: rect.minX * base.size.width, y: rect.minY * base.size.height, width: rect.width * base.size.width, height: rect.height * base.size.height))
        }
    }
}

extension CGImagePropertyOrientation {
    init(_ o: UIImage.Orientation) {
        switch o {
        case .up: self = .up
        case .down: self = .down
        case .left: self = .left
        case .right: self = .right
        case .upMirrored: self = .upMirrored
        case .downMirrored: self = .downMirrored
        case .leftMirrored: self = .leftMirrored
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}
