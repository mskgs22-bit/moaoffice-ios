import Foundation
import StoreKit

/// 구독 (StoreKit 2, 서버 없음 — 기기에서 영수증 검증)
/// - 프리미엄: 광고 제거
/// - 프로: 광고 제거 + 스캔·PDF 고급 기능 (같은 구독 그룹 → Apple 이 업그레이드·다운그레이드 처리)
@MainActor
final class Store: ObservableObject {
    static let monthlyID = "com.moaoffice.app.adfree.monthly"
    static let yearlyID = "com.moaoffice.app.adfree.yearly"
    static let proMonthlyID = "com.moaoffice.app.pro.monthly"
    static let proYearlyID = "com.moaoffice.app.pro.yearly"
    static let premiumIDs: Set<String> = [monthlyID, yearlyID]
    static let proIDs: Set<String> = [proMonthlyID, proYearlyID]

    @Published private(set) var products: [Product] = []
    @Published private(set) var isAdFree = false
    @Published private(set) var isPro = false
    @Published var busy = false
    @Published var message: String?

    private var updates: Task<Void, Never>?

    init() {
        isAdFree = UserDefaults.standard.bool(forKey: "adFree")
        isPro = UserDefaults.standard.bool(forKey: "pro")
        if CommandLine.arguments.contains("-pro") { isPro = true; isAdFree = true }
        updates = Task { [weak self] in
            for await result in Transaction.updates {
                if case .verified(let t) = result { await t.finish() }
                await self?.refresh()
            }
        }
        Task { await load(); await refresh() }
    }

    var premiumProducts: [Product] { products.filter { Self.premiumIDs.contains($0.id) }.sorted { $0.price < $1.price } }
    var proProducts: [Product] { products.filter { Self.proIDs.contains($0.id) }.sorted { $0.price < $1.price } }

    func load() async {
        do {
            products = try await Product.products(for: Self.premiumIDs.union(Self.proIDs)).sorted { $0.price < $1.price }
        } catch { products = [] }
    }

    func refresh() async {
        if CommandLine.arguments.contains("-pro") { return }
        var premium = false, pro = false
        for await result in Transaction.currentEntitlements {
            if case .verified(let t) = result, t.revocationDate == nil {
                if Self.premiumIDs.contains(t.productID) { premium = true }
                if Self.proIDs.contains(t.productID) { pro = true }
            }
        }
        isPro = pro
        isAdFree = premium || pro
        UserDefaults.standard.set(isAdFree, forKey: "adFree")
        UserDefaults.standard.set(isPro, forKey: "pro")
    }

    func buy(_ p: Product) async {
        busy = true; defer { busy = false }
        do {
            switch try await p.purchase() {
            case .success(let v):
                if case .verified(let t) = v { await t.finish() }
                await refresh()
                if isPro { message = L("프로가 시작됐어요. 모든 기능을 쓸 수 있어요.", "Pro is active. Every feature is unlocked.") }
                else if isAdFree { message = String(localized: "Thank you! Ads are now removed.") }
            case .pending:
                message = String(localized: "Purchase is pending approval.")
            default: break
            }
        } catch {
            message = error.localizedDescription
        }
    }

    func restore() async {
        busy = true; defer { busy = false }
        try? await AppStore.sync()
        await refresh()
        message = isAdFree ? String(localized: "Subscription restored.") : String(localized: "No active subscription found.")
    }
}
