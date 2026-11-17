import SwiftUI
import StoreKit

struct PaywallView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var yearly = true
    @State private var tier: Tier = .pro
    enum Tier { case premium, pro }

    private let rows: [(String, Bool, Bool)] = [
        (L("모든 광고 제거", "No ads"), true, true),
        (L("문서 보기 · 인쇄 · 주석", "View · print · annotate"), true, true),
        (L("문서 스캔 · PDF 저장", "Scan · save PDF"), true, true),
        (L("글자 검색되는 PDF · 암호", "Searchable PDF · password"), false, true),
        (L("지우개 · 증명사진", "Eraser · ID photo"), false, true),
        (L("PDF 압축 · 잠그기", "Compress · lock PDF"), false, true)
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    VStack(spacing: 6) {
                        Text(verbatim: L("모아오피스 프로", "MoaOffice Pro")).font(.title.bold())
                        Text(verbatim: L("문서 보기부터 스캔까지, 광고 없이", "From viewing to scanning, without ads")).font(.subheadline).foregroundStyle(.secondary)
                    }.padding(.top, 8)

                    if store.isPro {
                        Label(L("프로 이용 중이에요", "Pro is active"), systemImage: "checkmark.seal.fill").font(.headline).foregroundStyle(Color.brandInk)
                            .padding().frame(maxWidth: .infinity).background(Color.brandTint, in: RoundedRectangle(cornerRadius: 14))
                    } else {
                        Picker("", selection: $yearly) {
                            Text(verbatim: L("월간", "Monthly")).tag(false)
                            Text(verbatim: L("연간 · 할인", "Yearly · save")).tag(true)
                        }.pickerStyle(.segmented)

                        HStack(spacing: 10) {
                            planCard(.premium, title: L("프리미엄", "Premium"), sub: L("광고만 없애요", "Ads removed"), product: product(premium: true))
                            planCard(.pro, title: L("프로", "Pro"), sub: L("스캔 기능까지 전부", "Everything incl. scan tools"), product: product(premium: false))
                        }
                    }

                    VStack(spacing: 0) {
                        HStack {
                            Text(verbatim: L("무엇이 달라요?", "What’s included")).font(.caption.bold()).foregroundStyle(.secondary)
                            Spacer()
                            Text(verbatim: L("프리미엄", "Premium")).font(.caption.bold()).foregroundStyle(.secondary).frame(width: 64)
                            Text(verbatim: L("프로", "Pro")).font(.caption.bold()).foregroundStyle(Color.brandInk).frame(width: 52)
                        }.padding(.horizontal, 14).padding(.vertical, 10)
                        ForEach(rows, id: \.0) { r in
                            Divider()
                            HStack {
                                Text(verbatim: r.0).font(.subheadline)
                                Spacer()
                                Image(systemName: r.1 ? "checkmark" : "minus").foregroundStyle(r.1 ? Color.secondary : Color(.systemGray3)).frame(width: 64)
                                Image(systemName: "checkmark").foregroundStyle(Color.brandInk).frame(width: 52)
                            }.padding(.horizontal, 14).padding(.vertical, 10)
                        }
                    }
                    .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 16))

                    if !store.isPro {
                        Button { if let p = selectedProduct { Task { await store.buy(p) } } } label: {
                            Text(verbatim: tier == .pro ? L("프로 시작하기", "Start Pro") : L("프리미엄 시작하기", "Start Premium")).font(.headline).frame(maxWidth: .infinity).padding(.vertical, 14)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(store.busy || selectedProduct == nil)
                        .accessibilityIdentifier("paywall-buy")
                    }
                    Button(String(localized: "Restore purchases")) { Task { await store.restore() } }.disabled(store.busy)
                    Text("Subscriptions renew automatically unless cancelled at least 24 hours before the end of the current period. Payment is charged to your Apple ID account. Manage or cancel in your App Store account settings.")
                        .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    HStack(spacing: 16) {
                        Link("Terms of Use", destination: URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!)
                        Link("Privacy Policy", destination: URL(string: "https://sevio.co.kr/moaoffice/privacy")!)
                    }.font(.footnote)
                }
                .padding()
            }
            .background(Color.pageBG)
            .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button("Close") { dismiss() }.accessibilityIdentifier("paywall-close") } }
            .alert(store.message ?? "", isPresented: Binding(get: { store.message != nil }, set: { if !$0 { store.message = nil } })) {
                Button("OK", role: .cancel) {}
            }
            .task { if store.products.isEmpty { await store.load() } }
        }
    }

    private func product(premium: Bool) -> Product? {
        let id = premium ? (yearly ? Store.yearlyID : Store.monthlyID) : (yearly ? Store.proYearlyID : Store.proMonthlyID)
        return store.products.first { $0.id == id }
    }
    private var selectedProduct: Product? { product(premium: tier == .premium) }

    private func planCard(_ t: Tier, title: String, sub: String, product: Product?) -> some View {
        let on = tier == t
        return Button { tier = t } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: title).font(.headline).foregroundStyle(on ? Color.brandInk : .primary)
                Text(verbatim: sub).font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 6)
                Text(verbatim: product?.displayPrice ?? "—").font(.title3.bold()).foregroundStyle(.primary)
                Text(verbatim: yearly ? L("1년", "per year") : L("1개월", "per month")).font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 120, alignment: .leading)
            .padding(14)
            .background(on ? Color.brandTint : Color(.systemBackground), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(on ? Color.brand : Color(.systemGray4), lineWidth: on ? 2 : 1))
            .overlay(alignment: .topTrailing) {
                if t == .pro { Text(verbatim: L("추천", "Best")).font(.caption2.bold()).foregroundStyle(.white).padding(.horizontal, 8).padding(.vertical, 3).background(Color.brand, in: Capsule()).offset(x: -10, y: -10) }
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

struct SettingsView: View {
    var inTab = false
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var paywall = false

    private var version: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        return "\(v) (\(b))"
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button { paywall = true } label: {
                        Label(store.isPro ? L("프로 이용 중", "Pro: active") : (store.isAdFree ? String(localized: "Ad-free: active") : L("프로 · 광고 제거", "Pro · Remove ads")), systemImage: "sparkles")
                    }
                    Button { Task { await store.restore() } } label: { Label("Restore purchases", systemImage: "arrow.clockwise") }
                }
                Section {
                    Link(destination: URL(string: "https://sevio.co.kr/moaoffice/privacy")!) { Label("Privacy Policy", systemImage: "hand.raised") }
                    Link(destination: URL(string: "mailto:sevio2848@gmail.com")!) { Label("Contact us", systemImage: "envelope") }
                    NavigationLink { NoticesView() } label: { Label("Open source & notices", systemImage: "doc.text") }
                }
                Section {
                    HStack { Text("Version"); Spacer(); Text(version).foregroundStyle(.secondary) }
                    HStack { Text("Developer"); Spacer(); Text("SEVIO").foregroundStyle(.secondary) }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(inTab ? .large : .inline)
            .toolbar { if !inTab { ToolbarItem(placement: .navigationBarTrailing) { Button("Close") { dismiss() } } } }
            .sheet(isPresented: $paywall) { PaywallView().environmentObject(store) }
            .alert(store.message ?? "", isPresented: Binding(get: { store.message != nil && !paywall }, set: { if !$0 { store.message = nil } })) {
                Button("OK", role: .cancel) {}
            }
        }
    }
}

struct NoticesView: View {
    var body: some View {
        ScrollView {
            Text(verbatim: """
            본 제품은 한글과컴퓨터의 한/글 문서 파일(.hwp) 공개 문서를 참고하여 개발하였습니다.
            This product was developed with reference to the published Hancom HWP document file format.

            HWPX: 개방형 워드프로세서 마크업 언어(OWPML) 문서 구조 KS X 6101 을 참고하였습니다.

            Google Mobile Ads SDK — Copyright Google LLC. Licensed under the Google Mobile Ads SDK terms.

            PDF, Word, Excel and CSV previews are rendered by Apple's built-in PDFKit and Quick Look frameworks on your device.
            """)
            .font(.footnote).padding()
        }
        .navigationTitle("Notices")
    }
}
