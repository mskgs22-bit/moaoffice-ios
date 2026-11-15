import SwiftUI
import StoreKit

struct PaywallView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var pick = Store.yearlyID

    private let perks: [(String, String)] = [
        ("infinity", "사진·파일 정리의 하루 처리 제한 해제"),
        ("film", "동영상 압축 제한 해제 · 대기열 · 고급 설정"),
        ("person.2", "연락처 합치기 제한 해제"),
        ("lock.shield", "비밀 보관함 가져오기 개수 제한 해제"),
        ("nosign", "모든 광고 제거")
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    Image(systemName: "sparkles").font(.system(size: 44)).foregroundColor(.brand).padding(.top, 8)
                    Text("Pocket Clean 프리미엄").font(.title2.bold())
                    Text("분석 정확도와 삭제 안전장치는 무료와 같아요.\n처리량과 편의 기능이 늘어나요.")
                        .font(.subheadline).foregroundColor(.secondary).multilineTextAlignment(.center)
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(perks.indices, id: \.self) { i in
                            let p = perks[i]
                            HStack(spacing: 12) {
                                Image(systemName: p.0).frame(width: 26).foregroundColor(.brand)
                                Text(p.1).font(.subheadline)
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding().background(Color.card).cornerRadius(16)

                    if store.isPremium {
                        VStack(spacing: 6) {
                            Label("프리미엄 이용 중", systemImage: "checkmark.seal.fill").font(.headline).foregroundColor(.brand)
                            if let e = store.expiresAt { Text("다음 갱신·만료: \(e.formatted(date: .long, time: .omitted))").font(.footnote).foregroundColor(.secondary) }
                            Button("구독 관리·해지") { Task { await store.manage() } }.padding(.top, 4)
                        }.padding().frame(maxWidth: .infinity).background(Color.brandSoft).cornerRadius(16)
                    } else if store.products.isEmpty {
                        ProgressView("상품 정보를 불러오는 중…").padding()
                        Button("다시 불러오기") { Task { await store.load() } }
                    } else {
                        if let y = store.yearly { planRow(y, title: "연간", sub: yearlySub(y)) }
                        if let m = store.monthly { planRow(m, title: "월간", sub: "매월 \(m.displayPrice) 자동 결제") }
                        Button {
                            if let p = store.products.first(where: { $0.id == pick }) { Task { await store.buy(p) } }
                        } label: {
                            Text(store.busy ? "처리 중…" : "구독 시작하기").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 14)
                        }
                        .buttonStyle(.borderedProminent).disabled(store.busy)
                    }

                    Button("구매 복원") { Task { await store.restore() } }.disabled(store.busy)

                    Text("결제는 구매 확인 시 Apple ID 계정으로 청구됩니다. 현재 기간이 끝나기 최소 24시간 전에 해지하지 않으면 같은 기간·가격으로 자동 갱신되며, 갱신 요금은 기간 종료 전 24시간 이내에 청구됩니다. 구독은 App Store 계정 설정에서 관리하거나 해지할 수 있습니다. ‘제한 해제’는 앱 자체의 하루 처리 제한을 없앤다는 뜻이며, 기기 용량과 iOS 제한은 그대로 적용됩니다.")
                        .font(.caption).foregroundColor(.secondary).multilineTextAlignment(.center)
                    HStack(spacing: 18) {
                        Link("이용약관(EULA)", destination: Links.terms)
                        Link("개인정보처리방침", destination: Links.privacy)
                    }.font(.caption)
                }.padding(20)
            }
            .background(Color.pageBG)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("닫기") { dismiss() } } }
            .alert("알림", isPresented: Binding(get: { store.message != nil }, set: { if !$0 { store.message = nil } })) {
                Button("확인") { store.message = nil }
            } message: { Text(store.message ?? "") }
        }
    }

    private func yearlySub(_ y: Product) -> String {
        let perText = (y.price / 12).formatted(y.priceFormatStyle)
        return "1년 \(y.displayPrice)을 한 번에 결제 · 월 약 \(perText)"
    }

    private func planRow(_ p: Product, title: String, sub: String) -> some View {
        Button { pick = p.id } label: {
            HStack(spacing: 12) {
                Image(systemName: pick == p.id ? "largecircle.fill.circle" : "circle").foregroundColor(.brand).font(.title3)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline).foregroundColor(.primary)
                    Text(sub).font(.caption).foregroundColor(.secondary)
                }
                Spacer()
                Text(p.displayPrice).font(.headline).foregroundColor(.primary)
            }
            .padding().background(pick == p.id ? Color.brandSoft : Color.card)
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(pick == p.id ? Color.brand : Color.clear, lineWidth: 2))
            .cornerRadius(16)
        }.buttonStyle(.plain)
    }
}

enum Links {
    static let privacy = URL(string: "https://sevio.co.kr/pocketclean/privacy")!
    static let terms = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!
    static let support = "sevio2848@gmail.com"
}

/// 하루 한도에 걸렸을 때: 보상형 광고(자발적) 또는 프리미엄
struct LimitSheet: View {
    let feature: Feature
    var onGranted: () -> Void = {}
    @EnvironmentObject var quota: Quota
    @EnvironmentObject var store: Store
    @ObservedObject private var rewarded = Rewarded.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showPay = false
    @State private var loading = false
    @State private var note: String?

    var body: some View {
        VStack(spacing: 16) {
            Capsule().fill(Color.secondary.opacity(0.3)).frame(width: 40, height: 5).padding(.top, 8)
            Image(systemName: "hourglass").font(.system(size: 36)).foregroundColor(.brand)
            Text("오늘 무료 한도를 다 썼어요").font(.title3.bold())
            Text(desc).font(.subheadline).foregroundColor(.secondary).multilineTextAlignment(.center)
            if feature == .delete && quota.canWatchReward {
                Button {
                    Task {
                        loading = true
                        if await rewarded.show() { quota.grantReward(); note = "오늘 \(AppConfig.shared.rewardDeletes)개를 더 정리할 수 있어요."; onGranted() }
                        else { note = "광고를 끝까지 보지 않았거나 불러오지 못했어요. 이미 가능한 기능은 그대로 쓸 수 있어요." }
                        loading = false
                    }
                } label: {
                    VStack(spacing: 2) {
                        Text("광고 보고 \(AppConfig.shared.rewardDeletes)개 더 정리하기").font(.headline)
                        Text("오늘만 유효 · 하루 \(AppConfig.shared.rewardMaxPerDay)회까지 · 현금성 보상 없음").font(.caption2)
                    }.frame(maxWidth: .infinity).padding(.vertical, 10)
                }
                .buttonStyle(.bordered).disabled(loading || !rewarded.ready)
                if !rewarded.ready { Text("광고를 준비하는 중이에요…").font(.caption).foregroundColor(.secondary).onAppear { rewarded.preload() } }
            }
            Button { showPay = true } label: {
                Text("프리미엄으로 제한 없이 쓰기").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 12)
            }.buttonStyle(.borderedProminent)
            if let note { Text(note).font(.footnote).foregroundColor(.brand).multilineTextAlignment(.center) }
            Button("닫기") { dismiss() }.padding(.bottom, 8)
        }
        .padding(.horizontal, 24)
        .sheet(isPresented: $showPay) { PaywallView() }
        .presentationDetents([.medium, .large])
    }

    private var desc: String {
        switch feature {
        case .delete: return "무료로는 하루 \(AppConfig.shared.freeDeletesPerDay)개까지 정리할 수 있어요. 분석과 미리보기는 계속 무료예요."
        case .compress: return "무료로는 하루 \(AppConfig.shared.freeCompressPerDay)개까지 ‘균형’ 설정으로 압축할 수 있어요."
        case .contacts: return "무료로는 하루 \(AppConfig.shared.freeContactChangesPerDay)개 연락처까지 합치거나 정리할 수 있어요. 백업·복원은 무료예요."
        case .vault: return "무료로는 보관함에 \(AppConfig.shared.freeVaultImports)개까지 새로 넣을 수 있어요. 이미 넣은 파일은 언제든 열고 내보낼 수 있어요."
        }
    }
}
