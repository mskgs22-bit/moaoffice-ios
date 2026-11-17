import SwiftUI

/// 읽은 글자: 고치기 · 복사 · 공유 · 워드 문서로 저장
struct OcrResultView: View {
    @State var text: String
    let suggestedName: String
    @EnvironmentObject var library: Library
    @Environment(\.dismiss) private var dismiss
    @State private var toast: String?
    @State private var share = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 10) {
                Text(verbatim: L("휴대폰 안에서 읽었어요 · 한국어 + 영어", "Read on your phone · Korean + English")).font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $text)
                    .font(.body)
                    .padding(8)
                    .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color(.systemGray4)))
                    .accessibilityLabel(Text(verbatim: L("인식한 글자", "Recognized text")))
                HStack(spacing: 10) {
                    Button { UIPasteboard.general.string = text; toast = L("복사했어요", "Copied") } label: {
                        Label(L("복사", "Copy"), systemImage: "doc.on.doc").frame(maxWidth: .infinity).padding(.vertical, 10)
                    }.buttonStyle(.bordered)
                    Button {
                        library.saveNew(DocxWriter.make(text: text), name: suggestedName + ".docx", source: .scanned, open: false)
                        toast = L("워드 문서로 저장했어요", "Saved as a Word document")
                    } label: {
                        Label(L("워드 문서로 저장", "Save as Word"), systemImage: "doc.text").frame(maxWidth: .infinity).padding(.vertical, 10)
                    }.buttonStyle(.borderedProminent)
                }
            }
            .padding()
            .background(Color.pageBG)
            .navigationTitle(L("글자 인식", "Text recognition"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L("닫기", "Close")) { dismiss() } }
                ToolbarItem(placement: .primaryAction) { Button { share = true } label: { Image(systemName: "square.and.arrow.up") }.accessibilityLabel(Text(verbatim: L("공유", "Share"))) }
            }
            .sheet(isPresented: $share) { ShareSheet(items: [text]) }
            .toast($toast)
        }
    }
}

/// 사진 한 장을 골라 바로 글자 읽기
struct OcrToolView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var picking = !CommandLine.arguments.contains("-demo")
    @State private var text: String?
    @State private var busy = false
    @State private var camera = false

    var body: some View {
        if let t = text {
            OcrResultView(text: t, suggestedName: L("글자 인식", "Text") + " " + Date().formatted(date: .numeric, time: .omitted).replacingOccurrences(of: "/", with: "-"))
        } else {
            NavigationStack {
                VStack(spacing: 14) {
                    if busy { ProgressView(); Text(verbatim: L("글자를 읽는 중…", "Reading text…")) }
                    else {
                        Image(systemName: "text.viewfinder").font(.system(size: 52)).foregroundStyle(Color.brand)
                        Text(verbatim: L("글자를 읽을 사진을 고르세요", "Pick a photo to read")).font(.headline)
                        HStack {
                            if DocCamera.isAvailable { Button(L("찍기", "Scan")) { camera = true }.buttonStyle(.borderedProminent) }
                            Button(L("사진 고르기", "Choose photo")) { picking = true }.buttonStyle(.bordered)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L("닫기", "Close")) { dismiss() } } }
            }
            .sheet(isPresented: $picking) { PhotoPicker(limit: 1) { read($0) }.ignoresSafeArea() }
            .fullScreenCover(isPresented: $camera) { DocCamera(done: { camera = false; read($0) }, cancel: { camera = false }).ignoresSafeArea() }
        }
    }

    private func read(_ imgs: [UIImage]) {
        guard !imgs.isEmpty else { return }
        busy = true
        Task {
            var parts: [String] = []
            for i in imgs { parts.append(OCR.text(await OCR.recognize(i))) }
            busy = false
            let t = parts.joined(separator: "\n\n")
            text = t.isEmpty ? L("읽을 수 있는 글자를 찾지 못했어요.", "No text found.") : t
        }
    }
}
