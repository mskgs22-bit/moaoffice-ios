import SwiftUI

/// 사진·영상 탭: 분류 목록
struct MediaHubView: View {
    @EnvironmentObject var media: MediaIndex

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 10) {
                    PhotoAccessBanner()
                    AnalysisProgress()
                    if media.hasAccess {
                        NavigationLink { SwipeCleanView() } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "hand.draw").font(.title3).foregroundColor(.white).frame(width: 40, height: 40).background(Color.brand).cornerRadius(12)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("스와이프 정리").font(.subheadline.bold()).foregroundColor(.primary)
                                    Text("한 장씩 넘기며 남길 사진·지울 사진 고르기").font(.caption).foregroundColor(.secondary)
                                }
                                Spacer(); Image(systemName: "chevron.right").foregroundColor(.secondary)
                            }.padding(12).background(Color.card).cornerRadius(16)
                        }.buttonStyle(.plain)
                        if media.assets.isEmpty && !media.busy {
                            Button { media.analyze() } label: { Text("분석하기").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 10) }
                                .buttonStyle(.borderedProminent)
                        }
                        Text("사진").font(.headline).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                        ForEach([GroupKind.exactPhotos, .similarPhotos, .screenshots, .bursts], id: \.self) { k in
                            NavigationLink(value: k) { SuggestionRow(kind: k) }.buttonStyle(.plain)
                        }
                        Text("동영상").font(.headline).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                        ForEach([GroupKind.exactVideos, .similarVideos, .largeVideos], id: \.self) { k in
                            NavigationLink(value: k) { SuggestionRow(kind: k) }.buttonStyle(.plain)
                        }
                    }
                }.padding(16)
            }
            .background(Color.pageBG)
            .navigationTitle("사진·영상")
            .navigationDestination(for: GroupKind.self) { GroupScreen(kind: $0) }
        }
    }
}

/// 한 분류의 묶음 목록 + 선택 + 정리
struct GroupScreen: View {
    let kind: GroupKind
    @EnvironmentObject var media: MediaIndex
    @EnvironmentObject var quota: Quota
    @EnvironmentObject var store: Store
    @State private var selected = Set<String>()
    @State private var preview: String?
    @State private var confirm = false
    @State private var limit = false
    @State private var result: MediaIndex.DeleteResult?
    @State private var warnKeeper = false
    @State private var compressTarget: String?
    @State private var didInit = false

    private var groups: [CandidateGroup] { media.groups[kind] ?? [] }
    private var isFlat: Bool { kind == .screenshots || kind == .largeVideos }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                Text(kind.note).font(.subheadline).foregroundColor(.secondary)
                if let r = result { ResultBanner(deleted: r.deleted, failed: r.failed, bytes: r.bytes) }
                if groups.isEmpty {
                    EmptyHint(icon: "checkmark.seal", title: "찾은 항목이 없어요", sub: media.assets.isEmpty ? "먼저 홈에서 분석해 주세요." : "정리할 \(kind.title)이(가) 없어요.")
                } else if isFlat {
                    flatGrid(groups[0])
                } else {
                    ForEach(groups) { g in groupCard(g) }
                }
                if !selected.isEmpty { Color.clear.frame(height: 80) }
                AdBannerBar()
            }.padding(16)
        }
        .background(Color.pageBG)
        .navigationTitle(kind.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    if !isFlat { Button("추천대로 선택(남길 것 제외)") { selectSuggested() } }
                    if isFlat { Button("모두 선택") { selected = Set(groups.first?.members ?? []) } }
                    Button("선택 해제") { selected.removeAll() }
                } label: { Image(systemName: "checklist") }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if !selected.isEmpty {
                VStack(spacing: 6) {
                    Text("\(selected.count)개 선택 · \(Fmt.bytes(media.bytes(of: selected)))").font(.subheadline.bold())
                    Button { tryDelete() } label: {
                        Text("선택한 항목 정리하기").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 12)
                    }.buttonStyle(.borderedProminent).tint(.red)
                }.padding(.horizontal, 16).padding(.vertical, 10).background(.ultraThinMaterial)
            }
        }
        .sheet(item: Binding(get: { preview.map { IDBox(id: $0) } }, set: { preview = $0?.id })) { AssetPreview(id: $0.id) }
        .sheet(isPresented: $confirm) {
            DeleteConfirmSheet(ids: Array(selected)) { r in
                result = r
                if r.deleted > 0 {
                    quota.consume(.delete, r.deleted)
                    selected.subtract(selected.filter { media.assets[$0] == nil })
                    Interstitials.shared.afterTaskCompleted(premium: store.isPremium)
                }
            }
        }
        .sheet(isPresented: $limit) { LimitSheet(feature: .delete) }
        .sheet(item: Binding(get: { compressTarget.map { IDBox(id: $0) } }, set: { compressTarget = $0?.id })) { CompressSheet(assetID: $0.id) }
        .alert("모두 지우게 돼요", isPresented: $warnKeeper) {
            Button("취소", role: .cancel) {}
            Button("그래도 진행", role: .destructive) { proceed() }
        } message: { Text("한 묶음의 사진·영상을 모두 선택했어요. 남는 것이 없어요.") }
        .onAppear {
            if !didInit { didInit = true; if kind == .exactPhotos || kind == .exactVideos { selectSuggested() } }
        }
    }

    private func selectSuggested() {
        var s = Set<String>()
        for g in groups { if let k = g.keeper { s.formUnion(g.members.filter { $0 != k }) } }
        selected = s
    }

    private func tryDelete() {
        if !isFlat, groups.contains(where: { g in g.members.allSatisfy { selected.contains($0) } }) { warnKeeper = true; return }
        proceed()
    }

    private func proceed() {
        if !quota.canUse(.delete, count: selected.count) { limit = true; return }
        confirm = true
    }

    @ViewBuilder private func groupCard(_ g: CandidateGroup) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("\(g.members.count)개 · \(Fmt.bytes(media.bytes(of: g.members)))").font(.subheadline.bold())
                    Spacer()
                    Text(g.reason).font(.caption).foregroundColor(.secondary).lineLimit(2).multilineTextAlignment(.trailing)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(g.members, id: \.self) { id in tile(id, keeper: g.keeper == id) }
                    }
                }
            }
        }
    }

    private func flatGrid(_ g: CandidateGroup) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 8)], spacing: 8) {
            ForEach(g.members, id: \.self) { id in tile(id, keeper: false) }
        }
    }

    private func tile(_ id: String, keeper: Bool) -> some View {
        let info = media.assets[id]
        let on = selected.contains(id)
        return ZStack(alignment: .topTrailing) {
            Thumb(id: id, size: 104).cornerRadius(12)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(on ? Color.red : (keeper ? Color.brand : .clear), lineWidth: 3))
                .onTapGesture { if on { selected.remove(id) } else { selected.insert(id) } }
                .onLongPressGesture { preview = id }
            Image(systemName: on ? "checkmark.circle.fill" : "circle").font(.title3)
                .foregroundColor(on ? .red : .white).shadow(radius: 2).padding(6)
                .accessibilityLabel(on ? "선택됨" : "선택 안 됨")
        }
        .overlay(alignment: .bottomLeading) {
            VStack(alignment: .leading, spacing: 2) {
                if keeper { Text("남길 것").font(.caption2.bold()).padding(.horizontal, 6).padding(.vertical, 2).background(Color.brand).foregroundColor(.white).cornerRadius(6) }
                if let i = info {
                    Text(i.isVideo ? "\(Fmt.duration(i.duration)) · \(Fmt.bytes(i.size))" : Fmt.bytes(i.size))
                        .font(.caption2.bold()).padding(.horizontal, 5).padding(.vertical, 2).background(.black.opacity(0.55)).foregroundColor(.white).cornerRadius(5)
                    if i.isFavorite { Image(systemName: "heart.fill").font(.caption2).foregroundColor(.pink) }
                }
            }.padding(5)
        }
        .contextMenu {
            Button { preview = id } label: { Label("크게 보기", systemImage: "eye") }
            if info?.isVideo == true { Button { compressTarget = id } label: { Label("압축하기", systemImage: "film") } }
        }
        .accessibilityElement(children: .combine)
    }
}

struct IDBox: Identifiable { let id: String }

/// 정리 전 마지막 확인: 개수·용량·미리보기 → iOS 확인창 → 결과
struct DeleteConfirmSheet: View {
    let ids: [String]
    let onDone: (MediaIndex.DeleteResult) -> Void
    @EnvironmentObject var media: MediaIndex
    @Environment(\.dismiss) private var dismiss
    @State private var working = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) { ForEach(ids.prefix(30), id: \.self) { Thumb(id: $0, size: 72).cornerRadius(10) } }
                }.padding(.horizontal)
                VStack(spacing: 6) {
                    Text("\(ids.count)개 · \(Fmt.bytes(media.bytes(of: ids)))").font(.title2.bold())
                    Text("다음 화면에서 iOS가 한 번 더 확인해요. 지운 항목은 사진 앱의 ‘최근 삭제된 항목’으로 옮겨지고 30일 뒤 완전히 지워져요.")
                        .font(.subheadline).foregroundColor(.secondary).multilineTextAlignment(.center).padding(.horizontal)
                    if media.isLimited { Text("일부 사진만 허용된 상태예요. 허용한 사진 중에서만 정리돼요.").font(.caption).foregroundColor(.orange) }
                }
                Spacer()
                Button {
                    working = true
                    Task {
                        let r = await media.delete(ids)
                        working = false
                        onDone(r); dismiss()
                    }
                } label: {
                    Text(working ? "처리 중…" : "정리하기").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 12)
                }.buttonStyle(.borderedProminent).tint(.red).disabled(working).padding(.horizontal)
                Button("취소") { dismiss() }.padding(.bottom)
            }
            .padding(.top)
            .navigationTitle("정리 확인").navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium])
    }
}
