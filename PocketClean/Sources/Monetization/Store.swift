import Foundation
import StoreKit
import UIKit

/// 월간·연간 프리미엄 구독 (StoreKit 2 — 서버 없이 기기에서 Apple 서명 검증)
@MainActor
final class Store: ObservableObject {
    static let monthlyID = "kr.pocketclean.premium.monthly"
    static let yearlyID = "kr.pocketclean.premium.yearly"

    @Published private(set) var products: [Product] = []
    @Published private(set) var isPremium = false
    @Published private(set) var activeProductID: String?
    @Published private(set) var expiresAt: Date?
    @Published var busy = false
    @Published var message: String?

    private var updates: Task<Void, Never>?

    init() {
        // 마지막으로 확인한 상태를 짧게 기억(오프라인 대비): 만료 시각 또는 확인 후 72시간 중 빠른 때까지
        let until = UserDefaults.standard.double(forKey: "premiumOfflineUntil")
        isPremium = until > Date().timeIntervalSince1970
        updates = Task { [weak self] in
            for await result in Transaction.updates {
                if case .verified(let t) = result { await t.finish() }
                await self?.refresh()
            }
        }
        Task { await load(); await refresh() }
    }

    var monthly: Product? { products.first { $0.id == Self.monthlyID } }
    var yearly: Product? { products.first { $0.id == Self.yearlyID } }

    func load() async {
        do { products = try await Product.products(for: [Self.monthlyID, Self.yearlyID]) } catch { products = [] }
    }

    func refresh() async {
        var active = false; var pid: String?; var exp: Date?
        for await result in Transaction.currentEntitlements {
            guard case .verified(let t) = result, t.revocationDate == nil,
                  t.productID == Self.monthlyID || t.productID == Self.yearlyID else { continue }
            if let e = t.expirationDate, e < Date() { continue }
            active = true; pid = t.productID; exp = t.expirationDate
        }
        isPremium = active; activeProductID = pid; expiresAt = exp
        let cap = Date().addingTimeInterval(72 * 3600)
        let until = active ? min(exp ?? cap, cap) : Date(timeIntervalSince1970: 0)
        UserDefaults.standard.set(until.timeIntervalSince1970, forKey: "premiumOfflineUntil")
    }

    func buy(_ p: Product) async {
        busy = true; defer { busy = false }
        do {
            switch try await p.purchase() {
            case .success(let v):
                if case .verified(let t) = v { await t.finish() }
                await refresh()
                if isPremium { message = "프리미엄이 시작됐어요. 광고가 사라지고 하루 처리 제한이 풀려요." }
            case .pending:
                message = "구매 승인을 기다리고 있어요. 승인되면 자동으로 적용돼요."
            default: break
            }
        } catch {
            message = "결제를 완료하지 못했어요. 잠시 후 다시 시도해 주세요."
        }
    }

    func restore() async {
        busy = true; defer { busy = false }
        try? await AppStore.sync()
        await refresh()
        message = isPremium ? "구독을 복원했어요." : "복원할 구독이 없어요."
    }

    func manage() async {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        try? await AppStore.showManageSubscriptions(in: scene)
        await refresh()
    }
}
