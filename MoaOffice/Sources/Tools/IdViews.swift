import SwiftUI

// MARK: - 신분증 복사 (앞·뒤를 A4 한 장에)

struct IdCardView: View {
    @EnvironmentObject var library: Library
    @Environment(\.dismiss) private var dismiss
    @State private var front: UIImage?
    @State private var back: UIImage?
    @State private var capturing: Side?
    @State private var picking: Side?
    @State private var mask = true
    @State private var purpose = ""
    @State private var busy = false
    @State private var toast: String?

    enum Side: String, Identifiable { case front, back; var id: String { rawValue } }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    HStack(spacing: 10) { slot(.front); slot(.back) }
                    preview
                    VStack(spacing: 0) {
                        Toggle(L("주민번호 뒷자리 가리기", "Hide ID number digits"), isOn: $mask).padding(14)
                        Divider()
                        HStack {
                            Text(verbatim: L("사용 목적 표시", "Purpose")).font(.body)
                            TextField(L("예: 은행 제출용", "e.g. For bank"), text: $purpose).multilineTextAlignment(.trailing)
                        }.padding(14)
                    }
                    .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 14))
                    Text(verbatim: L("목적을 적으면 모든 곳에 옅게 찍혀서 다른 곳에 쓰이는 걸 막아요.", "The purpose is printed faintly so the copy can’t be reused elsewhere."))
                        .font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding()
            }
            .background(Color.pageBG)
            .safeAreaInset(edge: .bottom) {
                Button { Task { await save() } } label: { Text(verbatim: L("PDF로 저장", "Save as PDF")).font(.headline).frame(maxWidth: .infinity).padding(.vertical, 12) }
                    .buttonStyle(.borderedProminent).disabled(front == nil || busy).padding().background(.bar)
            }
            .navigationTitle(L("신분증 복사", "ID copy"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L("닫기", "Close")) { dismiss() } } }
            .fullScreenCover(item: $capturing) { side in
                DocCamera(done: { imgs in setIfAny(side, imgs.first); capturing = nil }, cancel: { capturing = nil }).ignoresSafeArea()
            }
            .sheet(item: $picking) { side in PhotoPicker(limit: 1) { imgs in setIfAny(side, imgs.first.map { img in ImageOps.detectQuad(img).map { ImageOps.perspective(img, quad: $0) } ?? img }) }.ignoresSafeArea() }
            .overlay { if busy { BusyOverlay(text: L("만드는 중…", "Working…")) } }
            .toast($toast)
        }
    }

    private func set(_ s: Side, _ img: UIImage?) { if s == .front { front = img } else { back = img } }
    private func setIfAny(_ s: Side, _ img: UIImage?) { if let img { set(s, img) } }

    private func slot(_ s: Side) -> some View {
        let done = (s == .front ? front : back) != nil
        return Menu {
            if DocCamera.isAvailable { Button { capturing = s } label: { Label(L("찍기", "Scan"), systemImage: "camera") } }
            Button { picking = s } label: { Label(L("사진에서 고르기", "From photos"), systemImage: "photo") }
            if done { Button(role: .destructive) { set(s, nil) } label: { Label(L("지우기", "Remove"), systemImage: "trash") } }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: done ? "checkmark.circle.fill" : "camera.circle.fill").font(.title3).foregroundStyle(done ? .green : Color.brand)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: s == .front ? L("앞면", "Front") : L("뒷면", "Back")).font(.subheadline.bold())
                    Text(verbatim: done ? L("다시 찍기", "Retake") : L("찍기", "Scan")).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(12).frame(maxWidth: .infinity)
            .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 12))
        }
        .foregroundStyle(.primary)
    }

    private var preview: some View {
        VStack(spacing: 18) {
            card(front, L("앞면 자리", "Front"))
            card(back, L("뒷면 자리", "Back"))
        }
        .padding(28)
        .frame(maxWidth: .infinity)
        .aspectRatio(210 / 297, contentMode: .fit)
        .background(Color.white)
        .overlay {
            if !purpose.isEmpty {
                Text(verbatim: purpose).font(.title3.bold()).foregroundStyle(Color.brand.opacity(0.3)).rotationEffect(.degrees(-30))
            }
        }
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
    }

    private func card(_ img: UIImage?, _ placeholder: String) -> some View {
        Group {
            if let img { Image(uiImage: img).resizable().scaledToFill() }
            else { Text(verbatim: placeholder).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity).overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5])).foregroundStyle(Color(.systemGray3))) }
        }
        .frame(width: 150, height: 95).clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func save() async {
        guard var f = front else { return }
        busy = true
        var b = back
        if mask {
            let lines = await OCR.recognize(f)
            let boxes = OCR.rrnBackBoxes(lines)
            if boxes.isEmpty { toast = L("가릴 번호를 찾지 못했어요. 결과를 꼭 확인해 주세요.", "No ID number found to hide. Please check the result.") }
            f = Self.cover(f, boxes)
            if let bb = b { b = Self.cover(bb, OCR.rrnBackBoxes(await OCR.recognize(bb))) }
        }
        let data = Self.compose(front: f, back: b, purpose: purpose)
        busy = false
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd"
        library.saveNew(data, name: L("신분증 사본 ", "ID copy ") + fmt.string(from: Date()) + ".pdf", source: .scanned, open: true)
        dismiss()
    }

    static func cover(_ img: UIImage, _ boxes: [CGRect]) -> UIImage {
        guard !boxes.isEmpty else { return img }
        let base = ImageOps.normalized(img)
        let f = UIGraphicsImageRendererFormat(); f.scale = 1
        return UIGraphicsImageRenderer(size: base.size, format: f).image { c in
            base.draw(at: .zero)
            UIColor.black.setFill()
            for r in boxes { c.fill(CGRect(x: r.minX * base.size.width, y: r.minY * base.size.height, width: r.width * base.size.width, height: r.height * base.size.height)) }
        }
    }

    /// A4 한 장: 실제 신분증 크기(85.6×54mm)로 위·아래
    static func compose(front: UIImage, back: UIImage?, purpose: String) -> Data {
        let page = CGRect(origin: .zero, size: PdfTools.a4)
        let mm: CGFloat = 72 / 25.4
        let cw = 85.6 * mm, ch = 54 * mm
        let out = NSMutableData()
        UIGraphicsBeginPDFContextToData(out, page, nil)
        UIGraphicsBeginPDFPage()
        let gap: CGFloat = 40
        let total = back == nil ? ch : ch * 2 + gap
        var y = (page.height - total) / 2
        for img in [front, back].compactMap({ $0 }) {
            let jpg = UIImage(data: ImageOps.downscale(img, maxSide: 1600).jpegData(compressionQuality: 0.85) ?? Data()) ?? img
            jpg.draw(in: CGRect(x: (page.width - cw) / 2, y: y, width: cw, height: ch))
            y += ch + gap
        }
        if !purpose.isEmpty, let g = UIGraphicsGetCurrentContext() {
            let s = NSAttributedString(string: purpose, attributes: [.font: UIFont.boldSystemFont(ofSize: 26), .foregroundColor: UIColor.systemRed.withAlphaComponent(0.28)])
            let w = s.size()
            for k in -2...2 {
                g.saveGState()
                g.translateBy(x: page.midX, y: page.midY + CGFloat(k) * 150)
                g.rotate(by: -.pi / 7)
                s.draw(at: CGPoint(x: -w.width / 2, y: -w.height / 2))
                g.restoreGState()
            }
        }
        UIGraphicsEndPDFContext()
        return out as Data
    }
}

// MARK: - 증명사진 (PRO)

struct IdPhotoView: View {
    enum Preset: String, CaseIterable, Identifiable {
        case half, passport, card
        var id: String { rawValue }
        var title: String { self == .half ? L("반명함 3×4", "3×4 cm") : (self == .passport ? L("여권 3.5×4.5", "Passport 3.5×4.5") : L("명함판 5×7", "5×7 cm")) }
        var mm: CGSize { self == .half ? CGSize(width: 30, height: 40) : (self == .passport ? CGSize(width: 35, height: 45) : CGSize(width: 50, height: 70)) }
    }
    @EnvironmentObject var library: Library
    @Environment(\.dismiss) private var dismiss
    @State private var photo: UIImage?
    @State private var picking = true
    @State private var preset: Preset = .half
    @State private var zoom: CGFloat = 1
    @State private var baseZoom: CGFloat = 1
    @State private var offset: CGSize = .zero      // 틀 너비에 대한 비율
    @State private var baseOffset: CGSize = .zero
    @State private var toast: String?
    @State private var a4 = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                Picker(L("크기", "Size"), selection: $preset) { ForEach(Preset.allCases) { Text(verbatim: $0.title).tag($0) } }.pickerStyle(.segmented)
                GeometryReader { geo in
                    let frame = AVMakeRectSize(preset.mm, in: CGSize(width: geo.size.width * 0.8, height: geo.size.height))
                    ZStack {
                        if let photo {
                            let fill = fillSize(photo.size, frame)
                            Image(uiImage: photo).resizable().frame(width: fill.width * zoom, height: fill.height * zoom)
                                .offset(x: offset.width * frame.width, y: offset.height * frame.width)
                                .frame(width: frame.width, height: frame.height).clipped()
                                .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(Color.brand, lineWidth: 2))
                                .overlay { Ellipse().strokeBorder(.white.opacity(0.8), style: StrokeStyle(lineWidth: 1.5, dash: [6])).frame(width: frame.width * 0.55, height: frame.height * 0.55).offset(y: -frame.height * 0.06) }
                                .gesture(DragGesture().onChanged { v in offset = CGSize(width: baseOffset.width + v.translation.width / frame.width, height: baseOffset.height + v.translation.height / frame.width) }.onEnded { _ in baseOffset = offset })
                                .simultaneousGesture(MagnificationGesture().onChanged { zoom = max(1, baseZoom * $0) }.onEnded { _ in baseZoom = zoom })
                        } else {
                            Button(L("사진 고르기", "Choose photo")) { picking = true }.buttonStyle(.borderedProminent)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                Text(verbatim: L("얼굴이 점선 안에 오도록 끌고, 두 손가락으로 크기를 맞추세요.", "Drag and pinch so the face fits the dashed oval.")).font(.footnote).foregroundStyle(.secondary)
                Picker(L("인화 용지", "Print sheet"), selection: $a4) {
                    Text(verbatim: L("4×6 인화지", "4×6 in photo")).tag(false)
                    Text(verbatim: "A4").tag(true)
                }.pickerStyle(.segmented)
                Button { Task { await save() } } label: { Text(verbatim: L("인화용으로 저장", "Save for printing")).font(.headline).frame(maxWidth: .infinity).padding(.vertical, 12) }
                    .buttonStyle(.borderedProminent).disabled(photo == nil)
            }
            .padding()
            .background(Color.pageBG)
            .navigationTitle(L("증명사진", "ID photo"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L("닫기", "Close")) { dismiss() } }
                ToolbarItem(placement: .primaryAction) { Button(L("다른 사진", "Change")) { picking = true } }
            }
            .sheet(isPresented: $picking) { PhotoPicker(limit: 1) { if let p = $0.first { photo = ImageOps.normalized(p); zoom = 1; baseZoom = 1; offset = .zero; baseOffset = .zero } }.ignoresSafeArea() }
            .onChange(of: preset) { _ in zoom = 1; baseZoom = 1; offset = .zero; baseOffset = .zero }
            .toast($toast)
        }
    }

    private func fillSize(_ img: CGSize, _ box: CGSize) -> CGSize {
        let k = max(box.width / img.width, box.height / img.height)
        return CGSize(width: img.width * k, height: img.height * k)
    }

    /// 틀(너비 1 기준) → 원본 사진에서 잘라낼 영역
    private func cropped(_ photo: UIImage) -> UIImage {
        let fw: CGFloat = 1, fh = preset.mm.height / preset.mm.width
        let k = max(fw / photo.size.width, fh / photo.size.height) * zoom // 사진 px → 틀 단위
        let w = fw / k, h = fh / k
        let cx = photo.size.width / 2 - offset.width / k
        let cy = photo.size.height / 2 - offset.height / k
        let rect = CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h).integral
        guard let cg = photo.cgImage?.cropping(to: rect) else { return photo }
        return UIImage(cgImage: cg)
    }

    private func save() async {
        guard let photo else { return }
        let face = cropped(photo)
        let dpi: CGFloat = 300
        let mm = preset.mm
        let px = CGSize(width: mm.width / 25.4 * dpi, height: mm.height / 25.4 * dpi)
        let sheet = a4 ? CGSize(width: 210 / 25.4 * dpi, height: 297 / 25.4 * dpi) : CGSize(width: 6 * dpi, height: 4 * dpi)
        let gap: CGFloat = 0.12 * dpi
        let cols = max(1, Int((sheet.width - gap) / (px.width + gap)))
        let rows = max(1, Int((sheet.height - gap) / (px.height + gap)))
        let f = UIGraphicsImageRendererFormat(); f.scale = 1
        let img = UIGraphicsImageRenderer(size: sheet, format: f).image { c in
            UIColor.white.setFill(); c.fill(CGRect(origin: .zero, size: sheet))
            let usedW = CGFloat(cols) * px.width + CGFloat(cols - 1) * gap
            let usedH = CGFloat(rows) * px.height + CGFloat(rows - 1) * gap
            for r in 0..<rows { for col in 0..<cols {
                let rect = CGRect(x: (sheet.width - usedW) / 2 + CGFloat(col) * (px.width + gap), y: (sheet.height - usedH) / 2 + CGFloat(r) * (px.height + gap), width: px.width, height: px.height)
                face.draw(in: rect)
                UIColor(white: 0.85, alpha: 1).setStroke(); UIBezierPath(rect: rect).stroke()
            } }
        }
        let ok = await PhotoSaver.save([img])
        toast = ok ? L("사진첩에 저장했어요 · \(cols * rows)장 배치", "Saved to Photos · \(cols * rows) copies") : L("사진 접근을 허용해 주세요", "Allow Photos access")
    }
}
