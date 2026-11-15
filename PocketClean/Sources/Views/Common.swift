import SwiftUI
import Photos
import AVKit

enum Fmt {
    static func bytes(_ b: Int64) -> String {
        let f = ByteCountFormatter(); f.countStyle = .file; f.allowedUnits = [.useMB, .useGB, .useKB]
        return f.string(fromByteCount: b)
    }
    static func duration(_ s: Double) -> String {
        let t = Int(s.rounded()); return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
    }
    static func date(_ d: Date?) -> String { d.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "-" }
}

/// 사진 썸네일 (기기에 있는 것만, 네트워크 사용 안 함)
struct Thumb: View {
    let id: String
    var size: CGFloat = 100
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Color(.tertiarySystemFill)
            if let image { Image(uiImage: image).resizable().scaledToFill() }
            else { Image(systemName: "photo").foregroundColor(.secondary) }
        }
        .frame(width: size, height: size).clipped()
        .task(id: id) { image = await Self.load(id, side: size * 2) }
    }

    static func load(_ id: String, side: CGFloat) async -> UIImage? {
        guard let a = MediaIndex.asset(id) else { return nil }
        let o = PHImageRequestOptions()
        o.deliveryMode = .highQualityFormat; o.isNetworkAccessAllowed = side > 600; o.resizeMode = .fast
        return await withCheckedContinuation { cont in
            var done = false
            PHImageManager.default().requestImage(for: a, targetSize: CGSize(width: side, height: side), contentMode: .aspectFill, options: o) { img, _ in
                if !done { done = true; cont.resume(returning: img) }
            }
        }
    }
}

/// 큰 미리보기 (사진은 이미지, 영상은 재생)
struct AssetPreview: View {
    let id: String
    @State private var image: UIImage?
    @State private var player: AVPlayer?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if let player { VideoPlayer(player: player) }
                else if let image { Image(uiImage: image).resizable().scaledToFit() }
                else { ProgressView().tint(.white) }
            }
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("닫기") { player?.pause(); dismiss() } } }
            .task {
                guard let a = MediaIndex.asset(id) else { return }
                if a.mediaType == .video {
                    let o = PHVideoRequestOptions(); o.isNetworkAccessAllowed = true
                    let item: AVPlayerItem? = await withCheckedContinuation { c in
                        PHImageManager.default().requestPlayerItem(forVideo: a, options: o) { it, _ in c.resume(returning: it) }
                    }
                    if let item { player = AVPlayer(playerItem: item); player?.play() }
                } else {
                    image = await Thumb.load(id, side: 1600)
                }
            }
        }
    }
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View { content.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(Color.card).cornerRadius(18) }
}

/// 권한이 없거나 일부만 허용된 상태 안내
struct PhotoAccessBanner: View {
    @EnvironmentObject var media: MediaIndex
    var body: some View {
        if media.auth == .notDetermined {
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    Label("사진 접근을 허용해 주세요", systemImage: "photo.badge.exclamationmark").font(.headline)
                    Text("중복·비슷한 사진과 큰 동영상을 찾으려면 사진 접근이 필요해요. 분석은 휴대폰 안에서만 이루어져요.").font(.subheadline).foregroundColor(.secondary)
                    Button("사진 접근 허용") { Task { await media.requestAccess(); media.analyze() } }.buttonStyle(.borderedProminent)
                }
            }
        } else if media.auth == .denied || media.auth == .restricted {
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    Label("사진 접근이 꺼져 있어요", systemImage: "lock.slash").font(.headline)
                    Text("설정 › Pocket Clean › 사진에서 ‘전체 접근’을 켜 주세요.").font(.subheadline).foregroundColor(.secondary)
                    Button("설정 열기") { if let u = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(u) } }.buttonStyle(.bordered)
                }
            }
        } else if media.isLimited {
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    Label("일부 사진만 허용됐어요", systemImage: "exclamationmark.triangle").font(.headline).foregroundColor(.orange)
                    Text("허용한 사진만 분석해요. 전체 사진을 분석한 결과가 아니에요.").font(.subheadline).foregroundColor(.secondary)
                    HStack {
                        Button("사진 더 선택") {
                            if let vc = UIApplication.shared.topViewController { PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: vc) }
                        }.buttonStyle(.bordered)
                        Button("전체 접근 켜기") { if let u = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(u) } }.buttonStyle(.bordered)
                    }
                }
            }
        }
    }
}

/// 진행 중 표시
struct AnalysisProgress: View {
    @EnvironmentObject var media: MediaIndex
    @ObservedObject private var p = MediaIndexProgress.shared
    var body: some View {
        switch media.phase {
        case .indexing:
            Card { VStack(alignment: .leading, spacing: 8) {
                Text("사진·동영상 목록을 읽는 중…").font(.subheadline.bold())
                ProgressView(value: p.value)
                Button("취소") { media.cancel() }.font(.footnote)
            } }
        case .analyzing(let s, let v):
            Card { VStack(alignment: .leading, spacing: 8) {
                Text(s + "…").font(.subheadline.bold())
                ProgressView(value: v)
                Text("결과는 찾는 대로 아래에 나타나요. 다른 화면으로 가도 계속돼요.").font(.caption).foregroundColor(.secondary)
                Button("취소") { media.cancel() }.font(.footnote)
            } }
        default: EmptyView()
        }
    }
}

/// 정리 결과 요약 (성공/실패/건너뜀과 실제 확보 용량)
struct ResultBanner: View {
    let deleted: Int
    let failed: Int
    let bytes: Int64
    var trashNote = true
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                Label("\(deleted)개 정리 완료", systemImage: "checkmark.circle.fill").font(.headline).foregroundColor(.green)
                if failed > 0 { Text("\(failed)개는 정리하지 못했어요(이미 없거나 iOS가 거부).").font(.subheadline).foregroundColor(.orange) }
                Text("확보 예정 용량: \(Fmt.bytes(bytes))").font(.subheadline)
                if trashNote { Text("지운 사진은 ‘최근 삭제된 항목’에 30일간 보관돼요. 바로 공간을 비우려면 사진 앱에서 그 앨범을 비워 주세요.").font(.caption).foregroundColor(.secondary) }
            }
        }
    }
}

struct EmptyHint: View {
    let icon: String; let title: String; let sub: String
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 40)).foregroundColor(.secondary)
            Text(title).font(.headline)
            Text(sub).font(.subheadline).foregroundColor(.secondary).multilineTextAlignment(.center)
        }.frame(maxWidth: .infinity).padding(.vertical, 40)
    }
}
