import SwiftUI

/// 저장한 서명 (기기 안 Application Support/Signatures)
enum SignatureStore {
    static var dir: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Signatures", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    static func all() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.creationDateKey])) ?? [])
            .filter { $0.pathExtension == "png" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }
    static func save(_ img: UIImage) { if let d = img.pngData() { try? d.write(to: dir.appendingPathComponent("\(Int(Date().timeIntervalSince1970 * 1000)).png")) } }
    static func delete(_ u: URL) { try? FileManager.default.removeItem(at: u) }
}

/// 서명 고르기(또는 새로 그리기) → 문서 위에 놓기
struct SignFlowView: View {
    let apply: (UIImage, CGRect) -> Void
    let background: () -> UIImage
    @Environment(\.dismiss) private var dismiss
    @State private var saved = SignatureStore.all()
    @State private var drawing = false
    @State private var chosen: UIImage?

    var body: some View {
        NavigationStack {
            Group {
                if let chosen {
                    SignPlaceView(signature: chosen, background: background()) { rect in apply(chosen, rect); dismiss() }
                } else {
                    List {
                        Section {
                            Button { drawing = true } label: { Label(L("새 서명 그리기", "Draw new signature"), systemImage: "pencil.tip") }
                        }
                        if !saved.isEmpty {
                            Section(L("저장한 서명", "Saved signatures")) {
                                ForEach(saved, id: \.self) { u in
                                    Button { chosen = UIImage(contentsOfFile: u.path) } label: {
                                        if let img = UIImage(contentsOfFile: u.path) { Image(uiImage: img).resizable().scaledToFit().frame(height: 60).frame(maxWidth: .infinity, alignment: .leading) }
                                    }
                                }
                                .onDelete { idx in idx.map { saved[$0] }.forEach(SignatureStore.delete); saved = SignatureStore.all() }
                            }
                        }
                    }
                }
            }
            .navigationTitle(L("서명", "Signature"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L("취소", "Cancel")) { dismiss() } } }
            .sheet(isPresented: $drawing) {
                SignaturePad { img in SignatureStore.save(img); saved = SignatureStore.all(); chosen = img }
            }
        }
    }
}

/// 손가락으로 서명 그리기 → 투명 배경 PNG
struct SignaturePad: View {
    let done: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var strokes: [[CGPoint]] = []
    @State private var current: [CGPoint] = []
    @State private var ink: Color = .black

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                GeometryReader { geo in
                    ZStack {
                        RoundedRectangle(cornerRadius: 14).fill(Color.white)
                        RoundedRectangle(cornerRadius: 14).strokeBorder(Color(.systemGray4))
                        Rectangle().fill(Color(.systemGray4)).frame(height: 1).padding(.horizontal, 24).offset(y: geo.size.height * 0.22)
                        path.stroke(ink, style: StrokeStyle(lineWidth: 3.5, lineCap: .round, lineJoin: .round))
                    }
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { current.append($0.location) }.onEnded { _ in strokes.append(current); current = [] })
                    .onAppear { size = geo.size }
                    .onChange(of: geo.size) { size = $0 }
                }
                .frame(height: 260)
                HStack(spacing: 14) {
                    ForEach([Color.black, Color(red: 0.11, green: 0.31, blue: 0.77), Color.brandInk], id: \.self) { c in
                        Button { ink = c } label: { Circle().fill(c).frame(width: 30, height: 30).overlay(Circle().stroke(ink == c ? Color.primary : .clear, lineWidth: 2).padding(-4)) }
                            .frame(width: 44, height: 44)
                    }
                    Spacer()
                    Button(L("지우기", "Clear")) { strokes = []; current = [] }
                }
                Spacer()
            }
            .padding()
            .navigationTitle(L("서명 그리기", "Draw signature"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L("취소", "Cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button(L("저장", "Save")) { if let img = render() { done(img) }; dismiss() }.disabled(strokes.isEmpty) }
            }
        }
    }

    @State private var size: CGSize = .zero

    private var path: Path {
        Path { p in
            for s in strokes + [current] where !s.isEmpty {
                p.move(to: s[0]); for q in s { p.addLine(to: q) }
            }
        }
    }

    /// 그린 부분만 잘라 3배 크기 PNG
    private func render() -> UIImage? {
        let pts = strokes.flatMap { $0 }
        guard let minX = pts.map(\.x).min(), let maxX = pts.map(\.x).max(), let minY = pts.map(\.y).min(), let maxY = pts.map(\.y).max() else { return nil }
        let pad: CGFloat = 8
        let box = CGRect(x: minX - pad, y: minY - pad, width: maxX - minX + pad * 2, height: maxY - minY + pad * 2)
        let f = UIGraphicsImageRendererFormat(); f.scale = 3; f.opaque = false
        let color = UIColor(ink)
        return UIGraphicsImageRenderer(size: box.size, format: f).image { c in
            let g = c.cgContext
            g.setStrokeColor(color.cgColor); g.setLineWidth(3.5); g.setLineCap(.round); g.setLineJoin(.round)
            for s in strokes where !s.isEmpty {
                g.beginPath(); g.move(to: CGPoint(x: s[0].x - box.minX, y: s[0].y - box.minY))
                for q in s { g.addLine(to: CGPoint(x: q.x - box.minX, y: q.y - box.minY)) }
                g.strokePath()
            }
        }
    }
}

/// 서명을 끌어서 놓고, 두 손가락으로 크기 조절
struct SignPlaceView: View {
    let signature: UIImage
    let background: UIImage
    let place: (CGRect) -> Void
    @State private var center = CGPoint(x: 0.65, y: 0.85)
    @State private var width: CGFloat = 0.32
    @State private var baseWidth: CGFloat = 0.32

    var body: some View {
        GeometryReader { geo in
            let fit = AVMakeRectSize(background.size, in: CGSize(width: geo.size.width - 24, height: geo.size.height - 24))
            let aspect = signature.size.height / max(1, signature.size.width)
            ZStack {
                Color(.systemGray6)
                ZStack(alignment: .topLeading) {
                    Image(uiImage: background).resizable().frame(width: fit.width, height: fit.height)
                    Image(uiImage: signature).resizable()
                        .frame(width: width * fit.width, height: width * fit.width * aspect)
                        .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(Color.brand, style: StrokeStyle(lineWidth: 1.5, dash: [5])))
                        .position(x: center.x * fit.width, y: center.y * fit.height)
                        .gesture(DragGesture().onChanged { v in center = CGPoint(x: min(1, max(0, v.location.x / fit.width)), y: min(1, max(0, v.location.y / fit.height))) })
                        .simultaneousGesture(MagnificationGesture().onChanged { width = min(0.9, max(0.08, baseWidth * $0)) }.onEnded { _ in baseWidth = width })
                }
                .frame(width: fit.width, height: fit.height)
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 8) {
                    HStack { Text(verbatim: L("크기", "Size")).font(.subheadline); Slider(value: Binding(get: { width }, set: { width = $0; baseWidth = $0 }), in: 0.08...0.9) }
                    Button {
                        let h = width * fit.width * aspect / fit.height
                        place(CGRect(x: center.x - width / 2, y: center.y - h / 2, width: width, height: h))
                    } label: { Text(verbatim: L("여기에 서명 넣기", "Place signature here")).font(.headline).frame(maxWidth: .infinity).padding(.vertical, 12) }
                    .buttonStyle(.borderedProminent)
                }.padding().background(.bar)
            }
        }
    }
}
