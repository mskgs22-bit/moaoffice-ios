import UIKit
import Vision

/// 글자 인식 (Vision, 기기 안에서만)
enum OCR {
    struct Line { let text: String; let box: CGRect } // box: 0~1, 왼쪽 위 기준

    static func recognize(_ img: UIImage) async -> [Line] {
        let n = ImageOps.normalized(img)
        guard let cg = n.cgImage else { return [] }
        return await Task.detached(priority: .userInitiated) { () -> [Line] in
            let req = VNRecognizeTextRequest()
            req.recognitionLevel = .accurate
            req.usesLanguageCorrection = true
            let wanted = ["ko-KR", "en-US"]
            if let supported = try? req.supportedRecognitionLanguages() {
                req.recognitionLanguages = wanted.filter { supported.contains($0) }
            } else { req.recognitionLanguages = wanted }
            try? VNImageRequestHandler(cgImage: cg).perform([req])
            return (req.results ?? []).compactMap { o in
                guard let t = o.topCandidates(1).first?.string else { return nil }
                let b = o.boundingBox
                return Line(text: t, box: CGRect(x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height))
            }
        }.value
    }

    static func text(_ lines: [Line]) -> String {
        // 위에서 아래로, 같은 줄은 왼쪽부터
        let sorted = lines.sorted { abs($0.box.midY - $1.box.midY) < 0.008 ? $0.box.minX < $1.box.minX : $0.box.midY < $1.box.midY }
        var out: [String] = []
        var lastY: CGFloat = -1
        for l in sorted {
            if lastY >= 0, l.box.minY - lastY > 0.035 { out.append("") }
            out.append(l.text); lastY = l.box.maxY
        }
        return out.joined(separator: "\n")
    }

    /// 주민등록번호 뒷자리 위치 (신분증 가리기)
    static func rrnBackBoxes(_ lines: [Line]) -> [CGRect] {
        let re = try! NSRegularExpression(pattern: "\\d{6}\\s?-\\s?\\d{7}")
        var out: [CGRect] = []
        for l in lines {
            let ns = l.text as NSString
            for m in re.matches(in: l.text, range: NSRange(location: 0, length: ns.length)) {
                // 하이픈 뒤 7자리가 차지하는 비율만큼 오른쪽을 가린다
                let full = ns.length
                guard full > 0 else { continue }
                let startFrac = CGFloat(m.range.location + m.range.length - 7) / CGFloat(full)
                let endFrac = CGFloat(m.range.location + m.range.length) / CGFloat(full)
                out.append(CGRect(x: l.box.minX + l.box.width * startFrac, y: l.box.minY - l.box.height * 0.15,
                                  width: l.box.width * (endFrac - startFrac) + 0.01, height: l.box.height * 1.3))
            }
        }
        return out
    }
}
