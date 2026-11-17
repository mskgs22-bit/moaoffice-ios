import SwiftUI

/// 한 쪽 보정: 필터 · 자르기 · 돌리기 · 지우개(PRO) · 서명 · 글자 인식 · 삭제
struct PageEditorView: View {
    @ObservedObject var session: ScanSession
    @State var index: Int
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var sheet: EditorSheet?
    @State private var paywall = false
    @State private var busy: String?
    @State private var ocrText: String?

    enum EditorSheet: String, Identifiable { case crop, erase, sign; var id: String { rawValue } }

    private var page: ScanPage? { session.pages[safe: index] }

    var body: some View {
        VStack(spacing: 0) {
            if let page {
                TabView(selection: $index) {
                    ForEach(Array(session.pages.enumerated()), id: \.element.id) { i, p in
                        PagePreview(page: p).tag(i).padding(16)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .background(Color(.systemGray5))
                FilterStrip(page: page)
                toolbar(page)
            }
        }
        .navigationTitle(L("\(session.pages.count)쪽 중 \(index + 1)쪽", "Page \(index + 1) of \(session.pages.count)"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L("완료", "Done")) { dismiss() } } }
        .sheet(item: $sheet) { s in
            if let page {
                switch s {
                case .crop: CropView(page: page)
                case .erase: EraserView(page: page)
                case .sign: SignFlowView { sig, rect in page.base = ImageOps.overlay(page.base, sig, in: rect) } background: { page.rendered }
                }
            }
        }
        .sheet(isPresented: $paywall) { PaywallView().environmentObject(store) }
        .sheet(item: Binding(get: { ocrText.map { OcrResult(text: $0) } }, set: { ocrText = $0?.text })) { r in OcrResultView(text: r.text, suggestedName: session.name) }
        .overlay { if let b = busy { BusyOverlay(text: b) } }
    }

    @ViewBuilder private func toolbar(_ page: ScanPage) -> some View {
        HStack(spacing: 0) {
            tool("crop", L("자르기", "Crop")) { sheet = .crop }
            tool("rotate.right", L("돌리기", "Rotate")) { page.turns += 1 }
            tool("eraser", L("지우개", "Eraser"), pro: true) { if store.isPro { sheet = .erase } else { paywall = true } }
            tool("signature", L("서명", "Sign")) { sheet = .sign }
            tool("text.viewfinder", L("글자 인식", "Text")) {
                Task {
                    busy = L("글자를 읽는 중…", "Reading text…")
                    let t = OCR.text(await OCR.recognize(page.rendered))
                    busy = nil
                    ocrText = t.isEmpty ? L("읽을 수 있는 글자를 찾지 못했어요.", "No text found.") : t
                }
            }
            tool("trash", L("삭제", "Delete")) {
                session.remove(page)
                if session.pages.isEmpty { dismiss() } else { index = min(index, session.pages.count - 1) }
            }
        }
        .padding(.horizontal, 4).padding(.bottom, 6)
        .background(Color(.systemBackground))
    }

    private func tool(_ icon: String, _ title: String, pro: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 21))
                Text(verbatim: title).font(.system(size: 11.5))
            }
            .frame(maxWidth: .infinity, minHeight: 56)
            .overlay(alignment: .topTrailing) { if pro && !store.isPro { ProBadge().offset(x: -2, y: 2) } }
        }
        .foregroundStyle(.primary)
    }
}

struct PagePreview: View {
    @ObservedObject var page: ScanPage
    var body: some View {
        Image(uiImage: page.rendered).resizable().scaledToFit()
            .background(Color.white)
            .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct FilterStrip: View {
    @ObservedObject var page: ScanPage
    @State private var thumbs: [ScanFilter: UIImage] = [:]
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(ScanFilter.allCases) { f in
                    Button { page.filter = f } label: {
                        VStack(spacing: 5) {
                            Group {
                                if let t = thumbs[f] { Image(uiImage: t).resizable().scaledToFill() } else { Color(.systemGray5) }
                            }
                            .frame(width: 56, height: 72).clipped()
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(page.filter == f ? Color.brand : Color(.systemGray4), lineWidth: page.filter == f ? 2.5 : 1))
                            Text(verbatim: f.title).font(.system(size: 11.5, weight: page.filter == f ? .bold : .regular))
                                .foregroundStyle(page.filter == f ? Color.brandInk : .primary)
                        }
                    }
                    .accessibilityAddTraits(page.filter == f ? .isSelected : [])
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
        }
        .background(Color(.systemBackground))
        .task(id: page.id) {
            let small = ImageOps.downscale(page.base, maxSide: 220)
            var out: [ScanFilter: UIImage] = [:]
            for f in ScanFilter.allCases { out[f] = ImageOps.apply(f, to: small) }
            thumbs = out
        }
    }
}

// MARK: - 자르기 (모서리 4개)

struct CropView: View {
    @ObservedObject var page: ScanPage
    @Environment(\.dismiss) private var dismiss
    @State private var quad: [CGPoint] = [CGPoint(x: 0.05, y: 0.05), CGPoint(x: 0.95, y: 0.05), CGPoint(x: 0.95, y: 0.95), CGPoint(x: 0.05, y: 0.95)]
    @State private var image: UIImage?

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                let img = image ?? page.base
                let fit = AVMakeRectSize(img.size, in: CGSize(width: geo.size.width - 40, height: geo.size.height - 40))
                ZStack {
                    Color(.systemGray6)
                    ZStack(alignment: .topLeading) {
                        Image(uiImage: img).resizable().frame(width: fit.width, height: fit.height)
                        Path { p in
                            p.addLines(quad.map { CGPoint(x: $0.x * fit.width, y: $0.y * fit.height) }); p.closeSubpath()
                        }
                        .fill(Color.brand.opacity(0.12))
                        Path { p in
                            p.addLines(quad.map { CGPoint(x: $0.x * fit.width, y: $0.y * fit.height) }); p.closeSubpath()
                        }
                        .stroke(Color.brand, lineWidth: 2.5)
                        ForEach(0..<4, id: \.self) { i in
                            Circle().fill(.white).frame(width: 28, height: 28)
                                .overlay(Circle().stroke(Color.brand, lineWidth: 3))
                                .frame(width: 48, height: 48).contentShape(Rectangle())
                                .position(x: quad[i].x * fit.width, y: quad[i].y * fit.height)
                                .gesture(DragGesture().onChanged { v in
                                    quad[i] = CGPoint(x: min(1, max(0, v.location.x / fit.width)), y: min(1, max(0, v.location.y / fit.height)))
                                })
                                .accessibilityLabel(Text(verbatim: L("모서리 \(i + 1)", "Corner \(i + 1)")))
                        }
                    }
                    .frame(width: fit.width, height: fit.height)
                }
            }
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 0) {
                    Button { if let q = ImageOps.detectQuad(page.base) { quad = q } } label: { label("viewfinder", L("자동 감지", "Detect")) }
                    Button { quad = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)] } label: { label("rectangle.dashed", L("전체", "Full")) }
                    Button { page.base = page.source; image = page.source } label: { label("arrow.uturn.backward", L("처음 상태", "Original")) }
                }
                .foregroundStyle(.primary).padding(.bottom, 4).background(.bar)
            }
            .navigationTitle(L("모서리 맞추기", "Adjust corners"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L("취소", "Cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("적용", "Apply")) { page.base = ImageOps.perspective(page.base, quad: quad); dismiss() }
                }
            }
        }
    }

    private func label(_ icon: String, _ t: String) -> some View {
        VStack(spacing: 4) { Image(systemName: icon).font(.title3); Text(verbatim: t).font(.caption) }.frame(maxWidth: .infinity, minHeight: 56)
    }
}

func AVMakeRectSize(_ aspect: CGSize, in box: CGSize) -> CGSize {
    guard aspect.width > 0, aspect.height > 0 else { return box }
    let k = min(box.width / aspect.width, box.height / aspect.height)
    return CGSize(width: aspect.width * k, height: aspect.height * k)
}

// MARK: - 지우개

struct EraserView: View {
    @ObservedObject var page: ScanPage
    @Environment(\.dismiss) private var dismiss
    @State private var strokes: [[CGPoint]] = []
    @State private var current: [CGPoint] = []
    @State private var brush: CGFloat = 0.03

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                let img = page.base
                let fit = AVMakeRectSize(img.size, in: CGSize(width: geo.size.width - 24, height: geo.size.height - 24))
                ZStack {
                    Color(.systemGray6)
                    ZStack(alignment: .topLeading) {
                        Image(uiImage: img).resizable().frame(width: fit.width, height: fit.height)
                        Path { p in
                            for s in strokes + [current] where !s.isEmpty {
                                p.move(to: CGPoint(x: s[0].x * fit.width, y: s[0].y * fit.height))
                                for q in s { p.addLine(to: CGPoint(x: q.x * fit.width, y: q.y * fit.height)) }
                            }
                        }
                        .stroke(Color.brand.opacity(0.45), style: StrokeStyle(lineWidth: brush * fit.width, lineCap: .round, lineJoin: .round))
                    }
                    .frame(width: fit.width, height: fit.height)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                        current.append(CGPoint(x: v.location.x / fit.width, y: v.location.y / fit.height))
                    }.onEnded { _ in strokes.append(current); current = [] })
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 6) {
                    HStack { Text(verbatim: L("굵기", "Size")).font(.subheadline); Slider(value: $brush, in: 0.01...0.08) }
                    Text(verbatim: L("지울 곳을 문질러 주세요. 종이 색으로 덮어요.", "Rub over what to remove. It is covered with the paper color.")).font(.caption).foregroundStyle(.secondary)
                }.padding().background(.bar)
            }
            .navigationTitle(L("지우개", "Eraser"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L("취소", "Cancel")) { dismiss() } }
                ToolbarItem(placement: .principal) {
                    Button { _ = strokes.popLast() } label: { Image(systemName: "arrow.uturn.backward") }.disabled(strokes.isEmpty)
                        .accessibilityLabel(Text(verbatim: L("되돌리기", "Undo")))
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("적용", "Apply")) { page.base = ImageOps.erase(page.base, strokes: strokes, width: brush); dismiss() }.disabled(strokes.isEmpty)
                }
            }
        }
    }
}
