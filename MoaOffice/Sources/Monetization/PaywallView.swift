import SwiftUI
import StoreKit

struct PaywallView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    Image(systemName: "sparkles").font(.system(size: 52)).foregroundStyle(Color.brand).padding(.top, 20)
                    Text("MoaOffice Ad-free").font(.title.bold())
                    VStack(alignment: .leading, spacing: 10) {
                        Label("No banner or full-screen ads", systemImage: "checkmark.circle.fill")
                        Label("Same features, cleaner screen", systemImage: "checkmark.circle.fill")
                        Label("Cancel anytime in App Store settings", systemImage: "checkmark.circle.fill")
                    }
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding().background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))

                    if store.isAdFree {
                        Text("You are subscribed. Thank you!").font(.headline).foregroundStyle(Color.brand)
                    } else if store.products.isEmpty {
                        ProgressView().task { await store.load() }
                    } else {
                        ForEach(store.products, id: \.id) { p in
                            Button { Task { await store.buy(p) } } label: {
                                VStack(spacing: 2) {
                                    Text(p.displayName).font(.headline)
                                    Text(priceLine(p)).font(.subheadline)
                                }
                                .frame(maxWidth: .infinity).padding(.vertical, 12)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(store.busy)
                        }
                    }
                    Button("Restore purchases") { Task { await store.restore() } }.disabled(store.busy)
                    Text("Subscriptions renew automatically unless cancelled at least 24 hours before the end of the current period. Payment is charged to your Apple ID account. Manage or cancel in your App Store account settings.")
                        .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    HStack(spacing: 16) {
                        Link("Terms of Use", destination: URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!)
                        Link("Privacy Policy", destination: URL(string: "https://sevio.co.kr/moaoffice/privacy")!)
                    }.font(.footnote)
                }
                .padding()
            }
            .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button("Close") { dismiss() } } }
            .alert(store.message ?? "", isPresented: Binding(get: { store.message != nil }, set: { if !$0 { store.message = nil } })) {
                Button("OK", role: .cancel) {}
            }
        }
    }

    private func priceLine(_ p: Product) -> String {
        let period: String
        switch p.subscription?.subscriptionPeriod.unit {
        case .year: period = String(localized: "per year")
        case .month: period = String(localized: "per month")
        default: period = ""
        }
        return "\(p.displayPrice) \(period)"
    }
}

struct SettingsView: View {
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
                        Label(store.isAdFree ? LocalizedStringKey("Ad-free: active") : LocalizedStringKey("Remove ads"), systemImage: "sparkles")
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
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button("Close") { dismiss() } } }
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
