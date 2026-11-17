import SwiftUI
import AVFoundation
import CoreImage.CIFilterBuiltins

struct QRView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var tab = 0
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $tab) {
                    Text(verbatim: L("QR 스캔", "Scan QR")).tag(0)
                    Text(verbatim: L("QR 만들기", "Make QR")).tag(1)
                }
                .pickerStyle(.segmented).padding()
                if tab == 0 { QRScanView() } else { QRMakeView() }
            }
            .navigationTitle("QR")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L("닫기", "Close")) { dismiss() } } }
        }
    }
}

struct QRScanView: View {
    @State private var result: String?
    @State private var denied = false
    @State private var toast: String?
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black
                if denied {
                    Text(verbatim: L("카메라 접근을 허용해 주세요 (설정 › 모아오피스)", "Allow camera access in Settings")).foregroundStyle(.white).padding()
                } else {
                    CodeScanner { code in if result != code { result = code; UIImpactFeedbackGenerator(style: .light).impactOccurred() } } denied: { denied = true }
                    RoundedRectangle(cornerRadius: 16).strokeBorder(.white, lineWidth: 3).frame(width: 240, height: 240)
                }
            }
            if let r = result {
                VStack(alignment: .leading, spacing: 12) {
                    Text(verbatim: isURL(r) ? L("웹 주소", "Link") : L("내용", "Content")).font(.caption).foregroundStyle(.secondary)
                    Text(verbatim: r).font(.body.weight(.semibold)).lineLimit(4).textSelection(.enabled)
                    HStack {
                        Button { UIPasteboard.general.string = r; toast = L("복사했어요", "Copied") } label: { Text(verbatim: L("복사", "Copy")).frame(maxWidth: .infinity).padding(.vertical, 10) }.buttonStyle(.bordered)
                        if isURL(r), let u = URL(string: r) {
                            Button { openURL(u) } label: { Text(verbatim: L("사파리로 열기", "Open in Safari")).frame(maxWidth: .infinity).padding(.vertical, 10) }.buttonStyle(.borderedProminent)
                        }
                    }
                    if isURL(r) { Text(verbatim: L("모르는 곳에서 받은 QR은 주소를 꼭 확인하고 여세요.", "Check the address before opening unknown QR codes.")).font(.caption).foregroundStyle(.secondary) }
                }
                .padding().frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.systemBackground))
            } else {
                Text(verbatim: L("네모 안에 QR 코드나 바코드를 비춰 주세요", "Point the camera at a QR code or barcode")).font(.subheadline).foregroundStyle(.secondary).padding()
            }
        }
        .toast($toast)
    }

    private func isURL(_ s: String) -> Bool { s.lowercased().hasPrefix("http://") || s.lowercased().hasPrefix("https://") }
}

/// 카메라로 QR·바코드 읽기 (AVFoundation)
struct CodeScanner: UIViewRepresentable {
    let found: (String) -> Void
    let denied: () -> Void

    func makeUIView(context: Context) -> PreviewView {
        let v = PreviewView()
        context.coordinator.start(in: v)
        return v
    }
    func updateUIView(_ uiView: PreviewView, context: Context) {}
    static func dismantleUIView(_ uiView: PreviewView, coordinator: Coord) { coordinator.stop() }
    func makeCoordinator() -> Coord { Coord(found: found, denied: denied) }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var preview: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    final class Coord: NSObject, AVCaptureMetadataOutputObjectsDelegate {
        let session = AVCaptureSession()
        let found: (String) -> Void
        let denied: () -> Void
        init(found: @escaping (String) -> Void, denied: @escaping () -> Void) { self.found = found; self.denied = denied }

        func start(in v: PreviewView) {
            AVCaptureDevice.requestAccess(for: .video) { ok in
                DispatchQueue.main.async {
                    guard ok, let dev = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: dev) else { self.denied(); return }
                    let out = AVCaptureMetadataOutput()
                    guard self.session.canAddInput(input), self.session.canAddOutput(out) else { return }
                    self.session.addInput(input); self.session.addOutput(out)
                    out.setMetadataObjectsDelegate(self, queue: .main)
                    out.metadataObjectTypes = [.qr, .ean13, .ean8, .upce, .code128, .code39, .pdf417, .dataMatrix].filter { out.availableMetadataObjectTypes.contains($0) }
                    v.preview.session = self.session
                    v.preview.videoGravity = .resizeAspectFill
                    let s = self.session
                    DispatchQueue.global(qos: .userInitiated).async { s.startRunning() }
                }
            }
        }
        func stop() { let s = session; DispatchQueue.global().async { s.stopRunning() } }
        func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from connection: AVCaptureConnection) {
            if let o = objects.first as? AVMetadataMachineReadableCodeObject, let s = o.stringValue { found(s) }
        }
    }
}

struct QRMakeView: View {
    @State private var text = ""
    @State private var share = false
    @State private var toast: String?
    @FocusState private var focused: Bool

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                TextField(L("웹 주소나 글자를 넣으세요", "Enter a link or text"), text: $text, axis: .vertical)
                    .lineLimit(1...4).focused($focused)
                    .padding(12).background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color(.systemGray4)))
                if let img = Self.qr(text) {
                    Image(uiImage: img).interpolation(.none).resizable().scaledToFit().frame(width: 240, height: 240)
                        .padding(16).background(Color.white, in: RoundedRectangle(cornerRadius: 16))
                        .accessibilityLabel(Text(verbatim: L("만든 QR 코드", "Generated QR code")))
                    HStack {
                        Button { share = true } label: { Label(L("공유", "Share"), systemImage: "square.and.arrow.up").frame(maxWidth: .infinity).padding(.vertical, 10) }.buttonStyle(.bordered)
                        Button { Task { toast = await PhotoSaver.save([img]) ? L("사진첩에 저장했어요", "Saved to Photos") : L("사진 접근을 허용해 주세요", "Allow Photos access") } } label: {
                            Label(L("사진첩에 저장", "Save"), systemImage: "square.and.arrow.down").frame(maxWidth: .infinity).padding(.vertical, 10)
                        }.buttonStyle(.borderedProminent)
                    }
                    .sheet(isPresented: $share) { ShareSheet(items: [img]) }
                }
            }
            .padding()
        }
        .background(Color.pageBG)
        .toast($toast)
    }

    static func qr(_ s: String) -> UIImage? {
        guard !s.isEmpty else { return nil }
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(s.utf8); f.correctionLevel = "M"
        guard let out = f.outputImage?.transformed(by: CGAffineTransform(scaleX: 16, y: 16)),
              let cg = ImageOps.ctx.createCGImage(out, from: out.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}
