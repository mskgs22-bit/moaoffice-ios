import Foundation
import StoreKit

/// 광고 제거 구독 (StoreKit 2, 서버 없음 — 기기에서 영수증 검증)
@MainActor
final class Store: ObservableObject {
    static let monthlyID = "com.moaoffice.app.adfree.monthly"
    static let yearlyID = "com.moaoffice.app.adfree.yearly"

    @Published private(set) var products: [Product] = []
    @Published private(set) var isAdFree = false
    @Published var busy = false
    @Published var message: String?

    private var updates: Task<Void, Never>?

    init() {
        isAdFree = UserDefaults.standard.bool(forKey: "adFree")
        updates = Task { [weak self] in
            for await result in Transaction.updates {
                if case .verified(let t) = result { await t.finish() }
                await self?.refresh()
            }
        }
        Task { await load(); await refresh() }
    }


    func load() async {
        do {
            products = try await Product.products(for: [Self.monthlyID, Self.yearlyID])
                .sorted { $0.price < $1.price }
        } catch { products = [] }
    }

    func refresh() async {
        var active = false
        for await result in Transaction.currentEntitlements {
            if case .verified(let t) = result, t.revocationDate == nil,
               t.productID == Self.monthlyID || t.productID == Self.yearlyID {
                active = true
            }
        }
        isAdFree = active
        UserDefaults.standard.set(active, forKey: "adFree")
    }

    func buy(_ p: Product) async {
        busy = true; defer { busy = false }
        do {
            switch try await p.purchase() {
            case .success(let v):
                if case .verified(let t) = v { await t.finish() }
                await refresh()
                if isAdFree { message = String(localized: "Thank you! Ads are now removed.") }
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
