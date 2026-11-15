import SwiftUI
import AVFoundation
import Photos
import AVKit

enum CompressPreset: String, CaseIterable, Identifiable {
    case small, balanced, high
    var id: String { rawValue }
    var title: String { switch self { case .small: return "저용량"; case .balanced: return "균형"; case .high: return "고화질" } }
    var sub: String {
        switch self {
        case .small: return "540p · 메신저 공유용"
        case .balanced: return "1080p HEVC · 화질과 용량의 균형"
        case .high: return "원본 해상도 HEVC · 화질 저하 최소화"
        }
    }
    var avPreset: String {
        switch self {
        case .small: return AVAssetExportPreset960x540
        case .balanced: return AVAssetExportPresetHEVC1920x1080
        case .high: return AVAssetExportPresetHEVCHighestQuality
        }
    }
    /// 대략적인 초당 비트수(예상 용량 표시용)
    var estBitsPerSec: Double { switch self { case .small: return 1.6e6; case .balanced: return 5e6; case .high: return 0 } }
}

struct CompressJob: Identifiable {
    enum State: Equatable { case queued, inspecting, processing, verifying, waitingUser, saved, failed(String), canceled }
    let id = UUID()
    let assetID: String
    let preset: CompressPreset
    let fps: Int?            // 고급: 프레임레이트 제한
    var state: State = .queued
    var progress: Double = 0
    var inputSize: Int64 = 0
    var outputURL: URL?
    var outputSize: Int64 = 0
    var duration: Double = 0
    var outDuration: Double = 0
    var resolution = ""
    var outResolution = ""
    var hdrNote = false
}

@MainActor
final class CompressQueue: ObservableObject {
    static let shared = CompressQueue()
    @Published var jobs: [CompressJob] = []
    private var running = false
    private var session: AVAssetExportSession?
    var allowNetwork = false

    var busyFiles: Set<URL> { Set(jobs.compactMap { $0.state == .saved || $0.state == .canceled ? nil : $0.outputURL }) }

    func add(_ assetID: String, _ preset: CompressPreset, fps: Int? = nil) {
        jobs.append(CompressJob(assetID: assetID, preset: preset, fps: fps))
        Task { await runNext() }
    }

    func cancel(_ id: UUID) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        if jobs[i].state == .processing { session?.cancelExport() }
        if let u = jobs[i].outputURL { try? FileManager.default.removeItem(at: u) }
        jobs[i].state = .canceled
    }

    func retry(_ id: UUID) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        let j = jobs[i]; jobs.remove(at: i)
        add(j.assetID, j.preset, fps: j.fps)
    }

    func remove(_ id: UUID) {
        if let i = jobs.firstIndex(where: { $0.id == id }) {
            if let u = jobs[i].outputURL, jobs[i].state != .saved { try? FileManager.default.removeItem(at: u) }
            jobs.remove(at: i)
        }
    }

    private func set(_ id: UUID, _ f: (inout CompressJob) -> Void) {
        if let i = jobs.firstIndex(where: { $0.id == id }) { f(&jobs[i]) }
    }

    private func runNext() async {
        guard !running, let job = jobs.first(where: { $0.state == .queued }) else { return }
        running = true
        await process(job)
        running = false
        await runNext()
    }

    private func process(_ job: CompressJob) async {
        let id = job.id
        set(id) { $0.state = .inspecting }
        guard let ph = MediaIndex.asset(job.assetID) else { set(id) { $0.state = .failed("원본 동영상을 찾을 수 없어요") }; return }
        let inSize = ph.fileSize
        set(id) { $0.inputSize = inSize; $0.duration = ph.duration; $0.resolution = "\(ph.pixelWidth)×\(ph.pixelHeight)" }

        let o = PHVideoRequestOptions(); o.isNetworkAccessAllowed = allowNetwork; o.deliveryMode = .highQualityFormat; o.version = .current
        let av: AVAsset? = await withCheckedContinuation { c in
            PHImageManager.default().requestAVAsset(forVideo: ph, options: o) { a, _, _ in c.resume(returning: a) }
        }
        guard let asset = av else {
            set(id) { $0.state = .failed("iCloud에만 있는 동영상이에요. ‘iCloud 원본 내려받기 허용’을 켜고 다시 시도해 주세요(데이터와 기기 공간을 써요).") }; return
        }
        // 지원 여부 사전 확인
        guard let vt = try? await asset.loadTracks(withMediaType: .video).first else {
            set(id) { $0.state = .failed("영상 트랙이 없어 압축할 수 없어요") }; return
        }
        let chars = (try? await vt.load(.mediaCharacteristics)) ?? []
        let isHDR = chars.contains(.containsHDRVideo)
        set(id) { $0.hdrNote = isHDR && job.preset == .small }
        let compatible = await AVAssetExportSession.compatibility(ofExportPreset: job.preset.avPreset, with: asset, outputFileType: .mp4)
        guard compatible else { set(id) { $0.state = .failed("이 동영상 형식은 선택한 설정으로 압축할 수 없어요. 다른 설정을 골라 주세요.") }; return }

        // 공간 확인(출력·임시 파일)
        let free = DeviceSpace.read().free
        if free < Int64(Double(inSize) * 1.2) + 200_000_000 {
            set(id) { $0.state = .failed("기기 여유 공간이 부족해요. 공간을 \(Fmt.bytes(Int64(Double(inSize) * 1.2)))쯤 확보한 뒤 다시 시도해 주세요.") }; return
        }

        guard let ex = AVAssetExportSession(asset: asset, presetName: job.preset.avPreset) else {
            set(id) { $0.state = .failed("압축을 시작할 수 없어요") }; return
        }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("compress-\(id.uuidString).mp4")
        try? FileManager.default.removeItem(at: out)
        ex.outputURL = out
        ex.outputFileType = .mp4
        ex.shouldOptimizeForNetworkUse = true
        if let fps = job.fps, let vc = try? await AVMutableVideoComposition.videoComposition(withPropertiesOf: asset) {
            vc.frameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))
            ex.videoComposition = vc
        }
        session = ex
        set(id) { $0.state = .processing; $0.outputURL = out }
        let poll = Task { @MainActor in
            while !Task.isCancelled { set(id) { $0.progress = Double(ex.progress) }; try? await Task.sleep(nanoseconds: 300_000_000) }
        }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in ex.exportAsynchronously { c.resume() } }
        poll.cancel(); session = nil

        if ex.status == .cancelled { set(id) { $0.state = .canceled }; try? FileManager.default.removeItem(at: out); return }
        guard ex.status == .completed else {
            try? FileManager.default.removeItem(at: out)
            set(id) { $0.state = .failed("압축 중 오류가 났어요(기기 온도·저전력 모드·앱 전환 때문일 수 있어요). 다시 시도해 주세요.") }; return
        }

        // 출력 검사: 길이·영상/소리 트랙·재생 가능 여부
        set(id) { $0.state = .verifying; $0.progress = 1 }
        let outAsset = AVURLAsset(url: out)
        let outDur = (try? await outAsset.load(.duration).seconds) ?? 0
        let outV = (try? await outAsset.loadTracks(withMediaType: .video)) ?? []
        let inA = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
        let outA = (try? await outAsset.loadTracks(withMediaType: .audio)) ?? []
        let playable = (try? await outAsset.load(.isPlayable)) ?? false
        var outRes = ""
        if let t = outV.first, let s = try? await t.load(.naturalSize), let tf = try? await t.load(.preferredTransform) {
            let r = s.applying(tf); outRes = "\(Int(abs(r.width)))×\(Int(abs(r.height)))"
        }
        let size = Int64((try? out.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        guard playable, !outV.isEmpty, abs(outDur - ph.duration) < max(1.5, ph.duration * 0.02), inA.isEmpty || !outA.isEmpty else {
            try? FileManager.default.removeItem(at: out)
            set(id) { $0.state = .failed("압축 결과를 확인하지 못했어요(길이·소리 불일치). 원본은 그대로예요.") }; return
        }
        set(id) { $0.outputSize = size; $0.outDuration = outDur; $0.outResolution = outRes; $0.state = .waitingUser }
        Quota.shared.consume(.compress, 1)
    }

    /// 사용자 확인 후 사진첩에 저장
    func saveToPhotos(_ id: UUID) async -> Bool {
        guard let j = jobs.first(where: { $0.id == id }), let u = j.outputURL else { return false }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.creationRequestForAssetFromVideo(atFileURL: u)
            }
            try? FileManager.default.removeItem(at: u)
            set(id) { $0.state = .saved }
            return true
        } catch { return false }
    }
}

/// 한 동영상을 압축하는 화면(설정 → 대기열 → 결과 비교)
struct CompressSheet: View {
    let assetID: String
    @EnvironmentObject var store: Store
    @EnvironmentObject var quota: Quota
    @EnvironmentObject var media: MediaIndex
    @ObservedObject private var q = CompressQueue.shared
    @Environment(\.dismiss) private var dismiss
    @State private var preset: CompressPreset = .balanced
    @State private var fps: Int? = nil
    @State private var jobID: UUID?
    @State private var limit = false
    @State private var showPay = false
    @State private var deleteOriginal = false
    @State private var saveMsg: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 12) {
                        Thumb(id: assetID, size: 84).cornerRadius(12)
                        if let a = MediaIndex.asset(assetID) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(Fmt.bytes(a.fileSize)).font(.title3.bold())
                                Text("\(a.pixelWidth)×\(a.pixelHeight) · \(Fmt.duration(a.duration))").font(.subheadline).foregroundColor(.secondary)
                            }
                        }
                    }
                    if let j = job { jobView(j) } else { settings }
                }.padding(16)
            }
            .background(Color.pageBG)
            .navigationTitle("동영상 압축").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("닫기") { dismiss() } } }
            .sheet(isPresented: $limit) { LimitSheet(feature: .compress) }
            .sheet(isPresented: $showPay) { PaywallView() }
            .sheet(isPresented: $deleteOriginal) {
                DeleteConfirmSheet(ids: [assetID]) { r in if r.deleted > 0 { quota.consume(.delete, r.deleted) } }
            }
        }
    }

    private var job: CompressJob? { jobID.flatMap { id in q.jobs.first { $0.id == id } } }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("압축 설정").font(.headline)
            ForEach(CompressPreset.allCases) { p in
                let locked = !store.isPremium && p != .balanced
                Button { if locked { showPay = true } else { preset = p } } label: {
                    HStack {
                        Image(systemName: preset == p ? "largecircle.fill.circle" : "circle").foregroundColor(.brand)
                        VStack(alignment: .leading) {
                            Text(p.title).font(.subheadline.bold()).foregroundColor(.primary)
                            Text(p.sub).font(.caption).foregroundColor(.secondary)
                        }
                        Spacer()
                        if locked { Text("프리미엄").font(.caption2.bold()).padding(4).background(Color.brandSoft).cornerRadius(6) }
                        else if let e = estimate(p) { Text("예상 \(e)").font(.caption).foregroundColor(.secondary) }
                    }.padding(12).background(Color.card).cornerRadius(14)
                }.buttonStyle(.plain)
            }
            if store.isPremium {
                Text("고급: 프레임레이트").font(.subheadline.bold()).padding(.top, 4)
                Picker("프레임레이트", selection: $fps) { Text("원본").tag(Int?.none); Text("30fps").tag(Int?.some(30)); Text("24fps").tag(Int?.some(24)) }.pickerStyle(.segmented)
            }
            Toggle("iCloud 원본 내려받기 허용", isOn: Binding(get: { q.allowNetwork }, set: { q.allowNetwork = $0 })).font(.subheadline)
            Text("화질 저하를 줄이도록 압축하지만 원본과 완전히 같지는 않아요. 예상 용량은 추정치예요. 원본은 자동으로 지우지 않아요.").font(.caption).foregroundColor(.secondary)
            Button {
                if !quota.canUse(.compress) { limit = true; return }
                q.add(assetID, preset, fps: fps)
                jobID = q.jobs.last?.id
            } label: { Text("압축 시작").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 12) }
                .buttonStyle(.borderedProminent)
        }
    }

    private func estimate(_ p: CompressPreset) -> String? {
        guard let a = MediaIndex.asset(assetID), p.estBitsPerSec > 0 else { return nil }
        return Fmt.bytes(Int64(p.estBitsPerSec * a.duration / 8))
    }

    @ViewBuilder private func jobView(_ j: CompressJob) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                switch j.state {
                case .queued: Label("대기 중", systemImage: "clock")
                case .inspecting: Label("동영상 확인 중…", systemImage: "magnifyingglass")
                case .processing:
                    Text("압축 중 \(Int(j.progress * 100))%").font(.headline)
                    ProgressView(value: j.progress)
                    Text("앱을 열어 둔 채로 기다려 주세요. 다른 앱으로 가면 iOS가 작업을 멈출 수 있어요.").font(.caption).foregroundColor(.secondary)
                    Button("취소", role: .destructive) { q.cancel(j.id) }
                case .verifying: Label("결과 확인 중…", systemImage: "checkmark.shield")
                case .waitingUser, .saved:
                    Text("압축 결과").font(.headline)
                    compareRow("용량", Fmt.bytes(j.inputSize), Fmt.bytes(j.outputSize))
                    compareRow("길이", Fmt.duration(j.duration), Fmt.duration(j.outDuration))
                    compareRow("해상도", j.resolution, j.outResolution)
                    let saved = j.inputSize > 0 ? Double(j.inputSize - j.outputSize) / Double(j.inputSize) : 0
                    if j.outputSize >= j.inputSize {
                        Text("압축 결과가 원본보다 커요. 원본을 그대로 두는 걸 권해요.").font(.subheadline).foregroundColor(.orange)
                    } else {
                        Text("\(Int(saved * 100))% 줄었어요").font(.title3.bold()).foregroundColor(.green)
                    }
                    if j.hdrNote { Text("HDR 영상이 일반(SDR) 화면으로 바뀌었을 수 있어요.").font(.caption).foregroundColor(.orange) }
                    if let u = j.outputURL, j.state == .waitingUser {
                        NavigationLink { PlayerView(url: u) } label: { Label("결과 재생해 보기", systemImage: "play.circle") }
                    }
                    if j.state == .waitingUser {
                        Button { Task { saveMsg = await q.saveToPhotos(j.id) ? "사진첩에 저장했어요." : "저장하지 못했어요. 사진 접근 권한을 확인해 주세요." } } label: {
                            Text("사진첩에 저장").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 10)
                        }.buttonStyle(.borderedProminent)
                        Button("저장하지 않고 버리기", role: .destructive) { q.remove(j.id); jobID = nil }
                    } else {
                        Label("사진첩에 저장했어요", systemImage: "checkmark.circle.fill").foregroundColor(.green)
                        if j.outputSize < j.inputSize && MediaIndex.asset(assetID) != nil {
                            Button("원본 동영상 정리하기…") { deleteOriginal = true }
                            Text("원본은 사용자가 확인한 뒤에만 지워요.").font(.caption).foregroundColor(.secondary)
                        }
                    }
                    if let m = saveMsg { Text(m).font(.footnote).foregroundColor(.brand) }
                case .failed(let why):
                    Label("압축하지 못했어요", systemImage: "exclamationmark.triangle.fill").foregroundColor(.orange).font(.headline)
                    Text(why).font(.subheadline)
                    Text("원본은 그대로예요.").font(.caption).foregroundColor(.secondary)
                    Button("다시 시도") { q.retry(j.id); jobID = q.jobs.last?.id }
                case .canceled:
                    Label("취소했어요. 원본은 그대로예요.", systemImage: "xmark.circle")
                    Button("다시 설정") { q.remove(j.id); jobID = nil }
                }
            }
        }
    }

    private func compareRow(_ t: String, _ a: String, _ b: String) -> some View {
        HStack { Text(t).foregroundColor(.secondary).frame(width: 60, alignment: .leading); Text(a); Image(systemName: "arrow.right").font(.caption); Text(b).bold() }.font(.subheadline)
    }
}

struct PlayerView: View {
    let url: URL
    var body: some View { AVPlayerControllerView(url: url).ignoresSafeArea().navigationTitle("미리보기") }
}

struct AVPlayerControllerView: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let c = AVPlayerViewController(); c.player = AVPlayer(url: url); return c
    }
    func updateUIViewController(_ c: AVPlayerViewController, context: Context) {}
}

/// 도구 › 동영상 압축: 큰 동영상 목록 + 대기열
struct CompressHome: View {
    @EnvironmentObject var media: MediaIndex
    @EnvironmentObject var store: Store
    @ObservedObject private var q = CompressQueue.shared
    @State private var target: String?

    var body: some View {
        List {
            if !q.jobs.isEmpty {
                Section("작업") {
                    ForEach(q.jobs) { j in
                        HStack {
                            Thumb(id: j.assetID, size: 44).cornerRadius(8)
                            VStack(alignment: .leading) {
                                Text(j.preset.title).font(.subheadline)
                                Text(stateText(j)).font(.caption).foregroundColor(.secondary)
                            }
                            Spacer()
                            if j.state == .processing { ProgressView(value: j.progress).frame(width: 60) }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { target = j.assetID }
                    }
                }
            }
            Section {
                let vids = media.assets.values.filter { $0.isVideo }.sorted { $0.size > $1.size }.prefix(60)
                if media.assets.isEmpty {
                    Text("홈에서 분석하면 큰 동영상이 여기에 나타나요.").foregroundColor(.secondary)
                    Button("분석하기") { media.analyze() }.disabled(!media.hasAccess || media.busy)
                }
                ForEach(Array(vids)) { v in
                    Button { target = v.id } label: {
                        HStack(spacing: 10) {
                            Thumb(id: v.id, size: 56).cornerRadius(10)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(Fmt.bytes(v.size)).font(.subheadline.bold()).foregroundColor(.primary)
                                Text("\(v.width)×\(v.height) · \(Fmt.duration(v.duration)) · \(Fmt.date(v.date))").font(.caption).foregroundColor(.secondary)
                            }
                            Spacer(); Image(systemName: "chevron.right").foregroundColor(.secondary)
                        }
                    }
                }
            } header: { Text("큰 동영상") } footer: {
                Text(store.isPremium ? "여러 개를 대기열에 넣어 차례로 압축할 수 있어요." : "무료는 하루 \(AppConfig.shared.freeCompressPerDay)개, ‘균형’ 설정으로 압축할 수 있어요.")
            }
        }
        .navigationTitle("동영상 압축")
        .sheet(item: Binding(get: { target.map { IDBox(id: $0) } }, set: { target = $0?.id })) { CompressSheet(assetID: $0.id) }
    }

    private func stateText(_ j: CompressJob) -> String {
        switch j.state {
        case .queued: return "대기 중"
        case .inspecting: return "확인 중"
        case .processing: return "압축 중 \(Int(j.progress * 100))%"
        case .verifying: return "결과 확인 중"
        case .waitingUser: return "완료 · 저장 대기 (\(Fmt.bytes(j.inputSize)) → \(Fmt.bytes(j.outputSize)))"
        case .saved: return "사진첩에 저장됨"
        case .failed(let w): return "실패: \(w)"
        case .canceled: return "취소됨"
        }
    }
}
