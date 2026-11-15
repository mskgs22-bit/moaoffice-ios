import Foundation
import Photos
import UIKit

struct AssetInfo: Identifiable, Hashable {
    let id: String
    let isVideo: Bool
    let size: Int64
    let date: Date?
    let duration: Double
    let width: Int
    let height: Int
    let isScreenshot: Bool
    let isFavorite: Bool
    let isLive: Bool
    let edited: Bool
    let burstID: String?
    let burstPicked: Bool
}

enum GroupKind: String, CaseIterable, Identifiable {
    case exactPhotos, similarPhotos, screenshots, bursts, exactVideos, similarVideos, largeVideos
    var id: String { rawValue }
    var title: String {
        switch self {
        case .exactPhotos: return "똑같은 사진"
        case .similarPhotos: return "비슷한 사진"
        case .screenshots: return "스크린샷"
        case .bursts: return "연속 촬영"
        case .exactVideos: return "똑같은 동영상"
        case .similarVideos: return "비슷한 동영상"
        case .largeVideos: return "큰 동영상"
        }
    }
    var icon: String {
        switch self {
        case .exactPhotos: return "doc.on.doc"
        case .similarPhotos: return "square.stack.3d.down.right"
        case .screenshots: return "iphone"
        case .bursts: return "square.stack"
        case .exactVideos: return "film.stack"
        case .similarVideos: return "rectangle.stack.badge.play"
        case .largeVideos: return "externaldrive"
        }
    }
    var note: String {
        switch self {
        case .exactPhotos: return "파일 내용이 완전히 같은 사진이에요. 묶음마다 1장은 남기도록 미리 골라 두었어요."
        case .similarPhotos: return "비슷해 보이는 사진 묶음이에요. 지울 사진은 직접 골라 주세요."
        case .screenshots: return "iOS가 스크린샷으로 분류한 사진이에요. 필요 없는지는 직접 확인해 주세요."
        case .bursts: return "연속 촬영 묶음이에요. 대표 사진만 남길 수 있어요."
        case .exactVideos: return "파일 내용이 완전히 같은 동영상이에요. 묶음마다 1개는 남기도록 골라 두었어요."
        case .similarVideos: return "길이·화면 비율·장면이 비슷한 동영상이에요. 재생해 보고 직접 골라 주세요."
        case .largeVideos: return "용량이 큰 동영상 순서예요. 압축하거나 정리할 수 있어요."
        }
    }
}

struct CandidateGroup: Identifiable, Hashable {
    let id = UUID()
    let kind: GroupKind
    var members: [String]
    var keeper: String?
    var reason: String
}

enum AnalysisPhase: Equatable {
    case idle
    case indexing(Double)
    case analyzing(String, Double)
    case done
}

@MainActor
final class MediaIndex: ObservableObject {
    @Published private(set) var auth: PHAuthorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @Published private(set) var assets: [String: AssetInfo] = [:]
    @Published private(set) var groups: [GroupKind: [CandidateGroup]] = [:]
    @Published private(set) var phase: AnalysisPhase = .idle
    @Published private(set) var lastAnalyzed: Date? = UserDefaults.standard.object(forKey: "lastAnalyzed") as? Date
    @Published var cloudSkipped = 0

    private var task: Task<Void, Never>?

    var isLimited: Bool { auth == .limited }
    var hasAccess: Bool { auth == .authorized || auth == .limited }
    var busy: Bool { if case .indexing = phase { return true }; if case .analyzing = phase { return true }; return false }

    func requestAccess() async {
        auth = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    }

    func refreshAuth() { auth = PHPhotoLibrary.authorizationStatus(for: .readWrite) }

    // MARK: 통계
    var photoCount: Int { assets.values.filter { !$0.isVideo }.count }
    var videoCount: Int { assets.values.filter { $0.isVideo }.count }
    var photoBytes: Int64 { assets.values.filter { !$0.isVideo }.reduce(0) { $0 + $1.size } }
    var videoBytes: Int64 { assets.values.filter { $0.isVideo }.reduce(0) { $0 + $1.size } }

    func count(_ k: GroupKind) -> Int {
        let gs = groups[k] ?? []
        switch k {
        case .screenshots, .largeVideos: return gs.first?.members.count ?? 0
        default: return gs.count
        }
    }

    /// 정리 후보 용량(예상): 남길 1개를 뺀 나머지 합계. 같은 사진이 여러 분류에 걸쳐도 한 번만 센다.
    func suggestedBytes(_ kinds: [GroupKind] = [.exactPhotos, .exactVideos, .similarPhotos, .bursts, .screenshots, .similarVideos]) -> Int64 {
        var ids = Set<String>()
        for k in kinds { for g in groups[k] ?? [] {
            for m in g.members where m != (g.keeper ?? (k == .screenshots ? nil : g.members.first)) { ids.insert(m) }
        } }
        return ids.reduce(0) { $0 + (assets[$1]?.size ?? 0) }
    }

    func bytes(of ids: some Sequence<String>) -> Int64 { Set(ids).reduce(0) { $0 + (assets[$1]?.size ?? 0) } }

    // MARK: 분석
    func analyze() {
        guard hasAccess, !busy else { return }
        task?.cancel()
        task = Task { await runAnalysis() }
    }

    func cancel() { task?.cancel(); phase = assets.isEmpty ? .idle : .done }

    private func runAnalysis() async {
        phase = .indexing(0)
        // 1) 메타데이터 인덱싱
        let infos: [AssetInfo] = await Task.detached(priority: .userInitiated) { () -> [AssetInfo] in
            let o = PHFetchOptions()
            o.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
            o.includeAllBurstAssets = true
            let r = PHAsset.fetchAssets(with: o)
            var out: [AssetInfo] = []; out.reserveCapacity(r.count)
            let total = max(1, r.count)
            r.enumerateObjects { a, i, stop in
                if Task.isCancelled { stop.pointee = true; return }
                guard a.mediaType == .image || a.mediaType == .video else { return }
                let rs = PHAssetResource.assetResources(for: a)
                let edited = rs.contains { $0.type == .adjustmentData || $0.type == .fullSizePhoto || $0.type == .fullSizeVideo }
                out.append(AssetInfo(id: a.localIdentifier, isVideo: a.mediaType == .video, size: a.fileSize, date: a.creationDate,
                                     duration: a.duration, width: a.pixelWidth, height: a.pixelHeight, isScreenshot: a.isScreenshot,
                                     isFavorite: a.isFavorite, isLive: a.isLivePhoto, edited: edited,
                                     burstID: a.burstIdentifier, burstPicked: a.burstSelectionTypes.contains(.userPick) || a.burstSelectionTypes.contains(.autoPick)))
                if i % 400 == 0 { let p = Double(i) / Double(total); Task { @MainActor in MediaIndexProgress.shared.value = p } }
            }
            return out
        }.value
        if Task.isCancelled { return }
        var map: [String: AssetInfo] = [:]
        for i in infos { map[i.id] = i }
        assets = map
        var result: [GroupKind: [CandidateGroup]] = [:]

        // 2) 스크린샷 · 연속 촬영 · 큰 동영상 (메타데이터만)
        let shots = infos.filter { $0.isScreenshot }.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        if !shots.isEmpty { result[.screenshots] = [CandidateGroup(kind: .screenshots, members: shots.map(\.id), keeper: nil, reason: "iOS 스크린샷 분류")] }
        var bursts: [String: [AssetInfo]] = [:]
        for i in infos { if let b = i.burstID { bursts[b, default: []].append(i) } }
        result[.bursts] = bursts.values.filter { $0.count > 1 }.map { m in
            let keep = m.first { $0.burstPicked }?.id ?? m.first { $0.isFavorite }?.id
            return CandidateGroup(kind: .bursts, members: m.map(\.id), keeper: keep, reason: keep == nil ? "대표 사진 정보 없음" : "대표로 고른 사진을 남겨요")
        }
        let big = infos.filter { $0.isVideo && $0.size >= 30_000_000 }.sorted { $0.size > $1.size }
        if !big.isEmpty { result[.largeVideos] = [CandidateGroup(kind: .largeVideos, members: big.map(\.id), keeper: nil, reason: "30MB 이상")] }
        groups = result

        // 3) 똑같은 사진·영상: 크기·해상도로 후보를 줄인 뒤 SHA-256
        phase = .analyzing("똑같은 사진·영상 찾는 중", 0)
        var cloud = 0
        for video in [false, true] {
            var buckets: [String: [AssetInfo]] = [:]
            for i in infos where i.isVideo == video && i.size > 0 {
                buckets["\(i.size)_\(i.width)x\(i.height)_\(Int(i.duration * 10))", default: []].append(i)
            }
            let cands = buckets.values.filter { $0.count > 1 }
            var found: [CandidateGroup] = []
            var done = 0; let total = max(1, cands.reduce(0) { $0 + $1.count })
            for b in cands {
                if Task.isCancelled { return }
                var byHash: [String: [AssetInfo]] = [:]
                for i in b {
                    guard let a = Self.asset(i.id) else { continue }
                    if let h = await Fingerprint.sha256(a) { byHash[h, default: []].append(i) } else { cloud += 1 }
                    done += 1
                    phase = .analyzing(video ? "똑같은 동영상 확인 중" : "똑같은 사진 확인 중", Double(done) / Double(total))
                }
                for (_, same) in byHash where same.count > 1 {
                    let keep = Self.bestKeeper(same) ?? same.first!
                    found.append(CandidateGroup(kind: video ? .exactVideos : .exactPhotos, members: same.map(\.id), keeper: keep.id,
                                                reason: Self.keeperReason(keep, in: same)))
                }
            }
            result[video ? .exactVideos : .exactPhotos] = found
            groups = result
        }
        cloudSkipped = cloud

        // 4) 비슷한 사진: 촬영 시간이 가까운 사진끼리 썸네일 지문 비교
        let exactExtras = Set((result[.exactPhotos] ?? []).flatMap { g in g.members.filter { $0 != g.keeper } })
        let photos = infos.filter { !$0.isVideo && !$0.isScreenshot && !exactExtras.contains($0.id) && $0.date != nil }
        var hashes: [String: UInt64] = [:]
        let ph: [(String, UInt64)] = await Task.detached(priority: .userInitiated) { () -> [(String, UInt64)] in
            var out: [(String, UInt64)] = []
            let total = max(1, photos.count)
            for (n, i) in photos.enumerated() {
                if Task.isCancelled { break }
                if let a = PHAsset.fetchAssets(withLocalIdentifiers: [i.id], options: nil).firstObject, let h = Fingerprint.photoHash(a) { out.append((i.id, h)) }
                if n % 50 == 0 { let p = Double(n) / Double(total); Task { @MainActor in MediaIndexProgress.shared.value = p } }
            }
            return out
        }.value
        if Task.isCancelled { return }
        for (k, v) in ph { hashes[k] = v }
        var parent: [String: String] = [:]
        func find(_ x: String) -> String { var r = x; while let p = parent[r], p != r { r = p }; return r }
        func union(_ a: String, _ b: String) {
            if parent[a] == nil { parent[a] = a }
            if parent[b] == nil { parent[b] = b }
            let ra = find(a), rb = find(b); if ra != rb { parent[ra] = rb }
        }
        for (i, a) in photos.enumerated() {
            guard let ha = hashes[a.id], let da = a.date else { continue }
            var j = i + 1
            while j < photos.count, let db = photos[j].date, db.timeIntervalSince(da) <= 180 {
                if let hb = hashes[photos[j].id], Fingerprint.distance(ha, hb) <= 10, photos[j].burstID == nil || photos[j].burstID != a.burstID {
                    union(a.id, photos[j].id)
                }
                j += 1
            }
        }
        var clusters: [String: [AssetInfo]] = [:]
        for p in photos where parent[p.id] != nil { clusters[find(p.id), default: []].append(p) }
        result[.similarPhotos] = clusters.values.filter { $0.count > 1 }.map { m in
            let keep = Self.bestKeeper(m)
            return CandidateGroup(kind: .similarPhotos, members: m.map(\.id), keeper: keep?.id,
                                  reason: keep.map { Self.keeperReason($0, in: m) } ?? "어느 사진이 나은지 판단하기 어려워 직접 골라 주세요")
        }.sorted { $0.members.count > $1.members.count }
        groups = result

        // 5) 비슷한 동영상: 길이·화면 비율이 비슷한 후보만 여러 장면 지문 비교
        phase = .analyzing("비슷한 동영상 비교 중", 0)
        let exactV = Set((result[.exactVideos] ?? []).flatMap { g in g.members.filter { $0 != g.keeper } })
        let vids = infos.filter { $0.isVideo && $0.duration >= 3 && !exactV.contains($0.id) }.sorted { $0.duration < $1.duration }
        var pairs: [(AssetInfo, AssetInfo)] = []
        for (i, a) in vids.enumerated() {
            var j = i + 1
            while j < vids.count, vids[j].duration <= a.duration * 1.05 + 1 {
                let b = vids[j]
                let ra = Double(a.width) / Double(max(1, a.height)), rb = Double(b.width) / Double(max(1, b.height))
                if abs(ra - rb) < 0.03 { pairs.append((a, b)) }
                j += 1
                if pairs.count >= 400 { break }
            }
            if pairs.count >= 400 { break }
        }
        var vframes: [String: [UInt64]] = [:]
        var vparent: [String: String] = [:]
        func vfind(_ x: String) -> String { var r = x; while let p = vparent[r], p != r { r = p }; return r }
        func vunion(_ a: String, _ b: String) {
            if vparent[a] == nil { vparent[a] = a }
            if vparent[b] == nil { vparent[b] = b }
            let ra = vfind(a), rb = vfind(b); if ra != rb { vparent[ra] = rb }
        }
        for (n, (a, b)) in pairs.enumerated() {
            if Task.isCancelled { return }
            for v in [a, b] where vframes[v.id] == nil {
                if let asset = Self.asset(v.id), let f = await Fingerprint.videoFrames(asset) { vframes[v.id] = f } else { vframes[v.id] = [] }
            }
            if let fa = vframes[a.id], let fb = vframes[b.id], fa.count == 3, fb.count == 3,
               zip(fa, fb).allSatisfy({ Fingerprint.distance($0.0, $0.1) <= 10 }) {
                vunion(a.id, b.id)
            }
            phase = .analyzing("비슷한 동영상 비교 중", Double(n + 1) / Double(max(1, pairs.count)))
        }
        var vclusters: [String: [AssetInfo]] = [:]
        for v in vids where vparent[v.id] != nil { vclusters[vfind(v.id), default: []].append(v) }
        result[.similarVideos] = vclusters.values.filter { $0.count > 1 }.map { m in
            CandidateGroup(kind: .similarVideos, members: m.map(\.id), keeper: nil, reason: "재생해 보고 남길 영상을 직접 골라 주세요")
        }
        groups = result
        phase = .done
        lastAnalyzed = Date()
        UserDefaults.standard.set(lastAnalyzed, forKey: "lastAnalyzed")
    }

    nonisolated static func asset(_ id: String) -> PHAsset? { PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject }

    /// 남길 사진 추천: 즐겨찾기 > 해상도 > 용량 > 오래된 것. 차이가 없으면 nil(자동 선택 안 함)
    nonisolated static func bestKeeper(_ m: [AssetInfo]) -> AssetInfo? {
        if let f = m.first(where: { $0.isFavorite }) { return f }
        let sorted = m.sorted { ($0.width * $0.height, $0.size) > ($1.width * $1.height, $1.size) }
        guard let top = sorted.first else { return nil }
        if sorted.count > 1, sorted[1].width * sorted[1].height == top.width * top.height, sorted[1].size == top.size {
            return m.min { ($0.date ?? .distantFuture) < ($1.date ?? .distantFuture) }
        }
        return top
    }

    nonisolated static func keeperReason(_ k: AssetInfo, in m: [AssetInfo]) -> String {
        if k.isFavorite { return "즐겨찾기한 사진을 남겨요" }
        if m.contains(where: { $0.width * $0.height < k.width * k.height }) { return "해상도가 가장 높은 것을 남겨요" }
        if m.contains(where: { $0.size < k.size }) { return "용량이 가장 큰(원본에 가까운) 것을 남겨요" }
        return "가장 먼저 저장된 것을 남겨요"
    }

    // MARK: 삭제 (iOS 확인창을 거친다)
    struct DeleteResult { var deleted: Int; var failed: Int; var bytes: Int64; var canceled: Bool }

    func delete(_ ids: [String]) async -> DeleteResult {
        let unique = Array(Set(ids))
        let fetched = PHAsset.fetchAssets(withLocalIdentifiers: unique, options: nil)
        var list: [PHAsset] = []
        fetched.enumerateObjects { a, _, _ in list.append(a) }
        let missingBefore = unique.count - list.count
        guard !list.isEmpty else { return DeleteResult(deleted: 0, failed: missingBefore, bytes: 0, canceled: false) }
        var canceled = false
        do {
            try await PHPhotoLibrary.shared().performChanges { PHAssetChangeRequest.deleteAssets(list as NSArray) }
        } catch {
            canceled = true
        }
        let still = PHAsset.fetchAssets(withLocalIdentifiers: list.map(\.localIdentifier), options: nil)
        var remain = Set<String>()
        still.enumerateObjects { a, _, _ in remain.insert(a.localIdentifier) }
        let gone = list.map(\.localIdentifier).filter { !remain.contains($0) }
        let freed = bytes(of: gone)
        for g in gone { assets[g] = nil }
        for k in GroupKind.allCases {
            groups[k] = (groups[k] ?? []).compactMap { g in
                var g = g; g.members.removeAll { gone.contains($0) }
                if let kp = g.keeper, gone.contains(kp) { g.keeper = nil }
                let minCount = (k == .screenshots || k == .largeVideos) ? 1 : 2
                return g.members.count >= minCount ? g : nil
            }
        }
        return DeleteResult(deleted: gone.count, failed: canceled ? 0 : remain.count + missingBefore, bytes: freed, canceled: canceled && gone.isEmpty)
    }
}

/// 인덱싱 진행률(백그라운드 작업에서 갱신)
@MainActor
final class MediaIndexProgress: ObservableObject {
    static let shared = MediaIndexProgress()
    @Published var value: Double = 0
}
