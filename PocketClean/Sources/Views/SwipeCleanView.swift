import SwiftUI
import Photos

/// 스와이프 정리: 왼쪽 = 지울 후보, 오른쪽 = 남기기. 넘기는 순간에는 지우지 않고 마지막에 한 번에 확인.
struct SwipeCleanView: View {
    @EnvironmentObject var media: MediaIndex
    @EnvironmentObject var quota: Quota
    @EnvironmentObject var store: Store
    @State private var queue: [String] = []
    @State private var pos = 0
    @State private var decisions: [String: Bool] = [:] // true = 지울 후보
    @State private var history: [String] = []
    @State private var drag: CGSize = .zero
    @State private var review = false
    @State private var loaded = false

    private static let key = "swipeSession"

    private var trash: [String] { queue.filter { decisions[$0] == true } }

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Label("지울 후보 \(trash.count)개 · \(Fmt.bytes(media.bytes(of: trash)))", systemImage: "trash").font(.subheadline.bold()).foregroundColor(.red)
                Spacer()
                Text(queue.isEmpty ? "" : "\(min(pos + 1, queue.count)) / \(queue.count)").font(.subheadline).foregroundColor(.secondary)
            }.padding(.horizontal)

            ZStack {
                if pos < queue.count {
                    card(queue[pos])
                        .offset(drag)
                        .rotationEffect(.degrees(Double(drag.width / 20)))
                        .gesture(DragGesture()
                            .onChanged { drag = $0.translation }
                            .onEnded { v in
                                if v.translation.width < -110 { decide(true) }
                                else if v.translation.width > 110 { decide(false) }
                                withAnimation(.spring()) { drag = .zero }
                            })
                } else if loaded {
                    EmptyHint(icon: "checkmark.circle", title: "다 봤어요", sub: trash.isEmpty ? "지울 후보로 고른 사진이 없어요." : "아래 ‘검토하고 정리’를 눌러 마무리하세요.")
                } else { ProgressView() }
            }.frame(maxHeight: .infinity).padding(.horizontal)

            HStack(spacing: 24) {
                circleButton("xmark", .red, "지울 후보") { decide(true) }
                circleButton("arrow.uturn.backward", .gray, "되돌리기") { undo() }.disabled(history.isEmpty)
                circleButton("heart.fill", .green, "남기기") { decide(false) }
            }.disabled(pos >= queue.count && history.isEmpty)

            Button { review = true } label: {
                Text("검토하고 정리 (\(trash.count))").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 12)
            }.buttonStyle(.borderedProminent).disabled(trash.isEmpty).padding(.horizontal)
            Text("넘기는 순간에는 지워지지 않아요. 마지막에 확인한 것만 정리돼요.").font(.caption).foregroundColor(.secondary).padding(.bottom, 8)
        }
        .background(Color.pageBG)
        .navigationTitle("스와이프 정리").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .primaryAction) { Button("처음부터") { reset() } } }
        .task { if !loaded { load() } }
        .onDisappear { save() }
        .sheet(isPresented: $review) { SwipeReview(ids: trash) { gone in
            for g in gone { decisions[g] = nil }
            queue.removeAll { gone.contains($0) }
            pos = min(pos, queue.count)
            history.removeAll { gone.contains($0) }
            save()
        } }
    }

    private func card(_ id: String) -> some View {
        ZStack(alignment: .bottomLeading) {
            GeometryReader { g in Thumb(id: id, size: g.size.width) }
                .aspectRatio(3 / 4, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 24))
            if let i = media.assets[id] ?? info(id) {
                Text("\(Fmt.date(i.date)) · \(Fmt.bytes(i.size))\(i.isVideo ? " · 동영상 " + Fmt.duration(i.duration) : "")")
                    .font(.caption.bold()).padding(8).background(.black.opacity(0.5)).foregroundColor(.white).cornerRadius(10).padding(12)
            }
            if drag.width < -40 { stamp("지울 후보", .red).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing) }
            if drag.width > 40 { stamp("남기기", .green).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading) }
        }
        .shadow(radius: 6)
        .accessibilityLabel("사진 \(pos + 1)번째")
        .accessibilityAction(named: "지울 후보") { decide(true) }
        .accessibilityAction(named: "남기기") { decide(false) }
    }

    private func info(_ id: String) -> AssetInfo? {
        guard let a = MediaIndex.asset(id) else { return nil }
        return AssetInfo(id: id, isVideo: a.mediaType == .video, size: a.fileSize, date: a.creationDate, duration: a.duration,
                         width: a.pixelWidth, height: a.pixelHeight, isScreenshot: a.isScreenshot, isFavorite: a.isFavorite,
                         isLive: a.isLivePhoto, edited: false, burstID: nil, burstPicked: false)
    }

    private func stamp(_ t: String, _ c: Color) -> some View {
        Text(t).font(.title2.bold()).foregroundColor(c).padding(10)
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(c, lineWidth: 3)).padding(20)
    }

    private func circleButton(_ icon: String, _ c: Color, _ label: String, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            Image(systemName: icon).font(.title2.bold()).foregroundColor(c).frame(width: 64, height: 64).background(Color.card).clipShape(Circle()).shadow(radius: 3)
        }.accessibilityLabel(label)
    }

    private func decide(_ del: Bool) {
        guard pos < queue.count else { return }
        let id = queue[pos]
        decisions[id] = del; history.append(id); pos += 1
        if history.count % 10 == 0 { save() }
    }

    private func undo() {
        guard let last = history.popLast(), let i = queue.firstIndex(of: last) else { return }
        decisions[last] = nil; pos = i
    }

    private func load() {
        // 저장된 세션 복원 (사진이 남아 있는지 다시 확인)
        if let d = UserDefaults.standard.dictionary(forKey: Self.key), let q = d["queue"] as? [String], !q.isEmpty {
            let exists = PHAsset.fetchAssets(withLocalIdentifiers: q, options: nil)
            var ok = Set<String>(); exists.enumerateObjects { a, _, _ in ok.insert(a.localIdentifier) }
            queue = q.filter { ok.contains($0) }
            let dec = (d["dec"] as? [String: Bool]) ?? [:]
            decisions = dec.filter { ok.contains($0.key) }
            history = queue.filter { decisions[$0] != nil }
            pos = queue.firstIndex { decisions[$0] == nil } ?? queue.count
        } else {
            let o = PHFetchOptions()
            o.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            o.fetchLimit = 500
            let r = PHAsset.fetchAssets(with: o)
            var q: [String] = []; r.enumerateObjects { a, _, _ in q.append(a.localIdentifier) }
            queue = q; pos = 0; decisions = [:]; history = []
        }
        loaded = true
    }

    private func save() {
        let d: [String: Any] = ["queue": queue, "dec": decisions]
        UserDefaults.standard.set(d, forKey: Self.key)
    }

    private func reset() {
        UserDefaults.standard.removeObject(forKey: Self.key); loaded = false; load()
    }
}

/// 스와이프로 고른 지울 후보 최종 검토
struct SwipeReview: View {
    let ids: [String]
    let onDeleted: ([String]) -> Void
    @EnvironmentObject var media: MediaIndex
    @EnvironmentObject var quota: Quota
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var keep = Set<String>()
    @State private var limit = false
    @State private var confirm = false
    @State private var result: MediaIndex.DeleteResult?

    private var toDelete: [String] { ids.filter { !keep.contains($0) } }

    var body: some View {
        NavigationStack {
            ScrollView {
                if let r = result { ResultBanner(deleted: r.deleted, failed: r.failed, bytes: r.bytes).padding() }
                Text("눌러서 빼면 남겨요").font(.caption).foregroundColor(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 6)], spacing: 6) {
                    ForEach(ids, id: \.self) { id in
                        Thumb(id: id, size: 100).cornerRadius(10).opacity(keep.contains(id) ? 0.35 : 1)
                            .overlay(alignment: .topTrailing) {
                                Image(systemName: keep.contains(id) ? "arrow.uturn.backward.circle.fill" : "trash.circle.fill")
                                    .foregroundColor(keep.contains(id) ? .green : .red).font(.title3).padding(4)
                            }
                            .onTapGesture { if keep.contains(id) { keep.remove(id) } else { keep.insert(id) } }
                    }
                }.padding()
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    if !quota.canUse(.delete, count: toDelete.count) { limit = true } else { confirm = true }
                } label: {
                    Text("\(toDelete.count)개 정리하기 · \(Fmt.bytes(media.bytes(of: toDelete)))").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 12)
                }.buttonStyle(.borderedProminent).tint(.red).disabled(toDelete.isEmpty).padding().background(.ultraThinMaterial)
            }
            .navigationTitle("검토").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("닫기") { dismiss() } } }
            .sheet(isPresented: $limit) { LimitSheet(feature: .delete) }
            .sheet(isPresented: $confirm) {
                DeleteConfirmSheet(ids: toDelete) { r in
                    result = r
                    if r.deleted > 0 {
                        quota.consume(.delete, r.deleted)
                        let gone = toDelete.filter { MediaIndex.asset($0) == nil }
                        onDeleted(gone)
                        Interstitials.shared.afterTaskCompleted(premium: store.isPremium)
                    }
                }
            }
        }
    }
}
