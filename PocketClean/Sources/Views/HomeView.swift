import SwiftUI

struct DeviceSpace {
    var total: Int64 = 0
    var free: Int64 = 0
    var used: Int64 { max(0, total - free) }
    static func read() -> DeviceSpace {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        let v = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
        return DeviceSpace(total: Int64(v?.volumeTotalCapacity ?? 0), free: v?.volumeAvailableCapacityForImportantUsage ?? 0)
    }
}

struct HomeView: View {
    @Binding var tab: Tab
    @EnvironmentObject var media: MediaIndex
    @EnvironmentObject var store: Store
    @ObservedObject private var config = AppConfig.shared
    @State private var space = DeviceSpace.read()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    if let n = config.notice { Card { Label(n, systemImage: "megaphone").font(.subheadline) } }
                    spaceCard
                    PhotoAccessBanner()
                    AnalysisProgress()
                    if media.hasAccess { analyzeCard }
                    if media.hasAccess && !media.assets.isEmpty { suggestions }
                    tools
                    AdBannerBar()
                }.padding(16)
            }
            .background(Color.pageBG)
            .navigationTitle("Pocket Clean")
            .refreshable { space = DeviceSpace.read() }
            .onAppear { space = DeviceSpace.read(); media.refreshAuth() }
            .navigationDestination(for: GroupKind.self) { GroupScreen(kind: $0) }
        }
    }

    private var spaceCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Text("기기 저장공간").font(.subheadline).foregroundColor(.secondary)
                HStack(alignment: .firstTextBaseline) {
                    Text(Fmt.bytes(space.used)).font(.system(size: 30, weight: .bold))
                    Text("/ \(Fmt.bytes(space.total)) 사용").foregroundColor(.secondary)
                }
                GeometryReader { g in
                    let r = space.total > 0 ? CGFloat(space.used) / CGFloat(space.total) : 0
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color(.tertiarySystemFill))
                        Capsule().fill(Color.brand).frame(width: g.size.width * r)
                    }
                }.frame(height: 10)
                HStack {
                    Label("여유 \(Fmt.bytes(space.free))", systemImage: "circle.fill").font(.caption).foregroundColor(.secondary)
                    Spacer()
                    if !media.assets.isEmpty {
                        Text("사진 \(Fmt.bytes(media.photoBytes)) · 동영상 \(Fmt.bytes(media.videoBytes))").font(.caption).foregroundColor(.secondary)
                    }
                }
            }
        }
    }

    private var analyzeCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                if media.assets.isEmpty {
                    Text("사진·동영상을 분석해 정리할 것을 찾아요").font(.headline)
                    Text("분석만으로는 아무것도 지워지지 않아요. 찾은 결과를 확인하고 직접 고른 것만 정리해요.").font(.subheadline).foregroundColor(.secondary)
                } else {
                    let est = media.suggestedBytes()
                    Text("정리 후보 약 \(Fmt.bytes(est))").font(.title3.bold())
                    Text("예상치예요. 실제로 확보되는 용량은 고른 항목과 ‘최근 삭제된 항목’ 비우기에 따라 달라요.").font(.caption).foregroundColor(.secondary)
                    if let d = media.lastAnalyzed { Text("마지막 분석: \(Fmt.date(d))").font(.caption).foregroundColor(.secondary) }
                    if media.cloudSkipped > 0 { Text("iCloud에만 있는 \(media.cloudSkipped)개는 내려받지 않아 ‘똑같은 항목’ 비교에서 빠졌어요.").font(.caption).foregroundColor(.orange) }
                }
                Button { media.analyze() } label: {
                    Text(media.assets.isEmpty ? "분석하기" : "다시 분석하기").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 10)
                }.buttonStyle(.borderedProminent).disabled(media.busy)
            }
        }
    }

    private var suggestions: some View {
        VStack(spacing: 10) {
            ForEach([GroupKind.exactPhotos, .similarPhotos, .screenshots, .largeVideos], id: \.self) { k in
                NavigationLink(value: k) { SuggestionRow(kind: k) }.buttonStyle(.plain)
            }
            Button { tab = .media } label: { Text("사진·영상 전체 분류 보기").font(.subheadline) }
        }
    }

    private var tools: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Text("도구").font(.headline)
                HStack {
                    ToolChip(icon: "film", title: "동영상 압축") { tab = .tools }
                    ToolChip(icon: "person.2", title: "연락처") { tab = .tools }
                    ToolChip(icon: "lock.shield", title: "비밀 보관함") { tab = .tools }
                    ToolChip(icon: "folder", title: "파일") { tab = .files }
                }
            }
        }
    }
}

struct SuggestionRow: View {
    let kind: GroupKind
    @EnvironmentObject var media: MediaIndex
    var body: some View {
        let ids = (media.groups[kind] ?? []).flatMap(\.members)
        HStack(spacing: 12) {
            Image(systemName: kind.icon).font(.title3).foregroundColor(.brand).frame(width: 40, height: 40).background(Color.brandSoft).cornerRadius(12)
            VStack(alignment: .leading, spacing: 2) {
                Text(kind.title).font(.subheadline.bold()).foregroundColor(.primary)
                Text(media.count(kind) == 0 ? "찾은 항목 없음" : "\(countText) · \(Fmt.bytes(media.bytes(of: ids)))").font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            if let f = ids.first { Thumb(id: f, size: 44).cornerRadius(8) }
            Image(systemName: "chevron.right").foregroundColor(.secondary)
        }.padding(12).background(Color.card).cornerRadius(16)
    }
    private var countText: String {
        switch kind {
        case .screenshots, .largeVideos: return "\(media.count(kind))개"
        default: return "\(media.count(kind))묶음"
        }
    }
}

struct ToolChip: View {
    let icon: String; let title: String; let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon).font(.title3).foregroundColor(.brand)
                Text(title).font(.caption).foregroundColor(.primary).lineLimit(1).minimumScaleFactor(0.8)
            }.frame(maxWidth: .infinity).padding(.vertical, 10).background(Color.brandSoft.opacity(0.6)).cornerRadius(14)
        }.buttonStyle(.plain)
    }
}
