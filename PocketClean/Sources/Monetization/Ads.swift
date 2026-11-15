import SwiftUI
import UIKit
import GoogleMobileAds

enum AdIDs {
    static func info(_ k: String) -> String { Bundle.main.object(forInfoDictionaryKey: k) as? String ?? "" }
    static var banner: String { info("GADBannerID") }
    static var interstitial: String { info("GADInterstitialID") }
    static var rewarded: String { info("GADRewardedID") }
    /// UI 테스트(스크린샷) 중에는 광고를 띄우지 않는다
    static var disabled: Bool { CommandLine.arguments.contains("-noads") }
}

struct BannerAd: UIViewRepresentable {
    func makeUIView(context: Context) -> BannerView {
        let v = BannerView(adSize: AdSizeBanner)
        v.adUnitID = AdIDs.banner
        v.rootViewController = UIApplication.shared.topViewController
        v.load(GoogleMobileAds.Request())
        return v
    }
    func updateUIView(_ uiView: BannerView, context: Context) {}
}

/// 홈·결과 화면 아래 배너(프리미엄이면 숨김). 삭제·승인 버튼과 떨어진 곳에만 둔다.
struct AdBannerBar: View {
    @EnvironmentObject var store: Store
    var body: some View {
        if !store.isPremium && !AdIDs.disabled {
            VStack(spacing: 2) {
                Text("광고").font(.caption2).foregroundColor(.secondary)
                BannerAd().frame(width: 320, height: 50)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 6)
        }
    }
}

/// 전면 광고: 정리 작업이 끝난 뒤에만, 5분 간격·하루 3회까지
@MainActor
final class Interstitials {
    static let shared = Interstitials()
    private var ad: InterstitialAd?
    private var last = Date.distantPast

    func preload() {
        guard !AdIDs.disabled, ad == nil else { return }
        InterstitialAd.load(with: AdIDs.interstitial, request: GoogleMobileAds.Request()) { [weak self] ad, _ in
            Task { @MainActor in self?.ad = ad }
        }
    }

    func afterTaskCompleted(premium: Bool) {
        guard !premium, !AdIDs.disabled else { return }
        let c = AppConfig.shared
        let k = "inter_" + DateFormatter.dayKey.string(from: Date())
        let shown = UserDefaults.standard.integer(forKey: k)
        guard shown < c.interstitialMaxPerDay, Date().timeIntervalSince(last) >= Double(c.interstitialGapSec) else { preload(); return }
        if let ad, let vc = UIApplication.shared.topViewController {
            // 결과 화면이 먼저 보이도록 잠깐 뒤에 띄운다
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                ad.present(from: vc)
            }
            self.ad = nil; last = Date()
            UserDefaults.standard.set(shown + 1, forKey: k)
        }
        preload()
    }
}

/// 보상형 광고: 사용자가 직접 눌렀을 때만. 끝까지 보면 오늘 정리 한도 +100
@MainActor
final class Rewarded: ObservableObject {
    static let shared = Rewarded()
    @Published private(set) var ready = false
    private var ad: RewardedAd?

    func preload() {
        guard !AdIDs.disabled, ad == nil else { return }
        RewardedAd.load(with: AdIDs.rewarded, request: GoogleMobileAds.Request()) { [weak self] ad, _ in
            Task { @MainActor in self?.ad = ad; self?.ready = ad != nil }
        }
    }

    /// 시청 완료 시 true
    func show() async -> Bool {
        guard let ad, let vc = UIApplication.shared.topViewController else { preload(); return false }
        self.ad = nil; ready = false
        let earned: Bool = await withCheckedContinuation { cont in
            var done = false
            let delegate = RewardDelegate { if !done { done = true; cont.resume(returning: false) } }
            ad.fullScreenContentDelegate = delegate
            objc_setAssociatedObject(ad, &RewardDelegate.key, delegate, .OBJC_ASSOCIATION_RETAIN)
            ad.present(from: vc) {
                if !done { done = true; cont.resume(returning: true) }
            }
        }
        preload()
        return earned
    }
}

private final class RewardDelegate: NSObject, FullScreenContentDelegate {
    static var key = 0
    let onDismissWithoutReward: () -> Void
    init(_ f: @escaping () -> Void) { onDismissWithoutReward = f }
    func adDidDismissFullScreenContent(_ ad: FullScreenPresentingAd) { onDismissWithoutReward() }
    func ad(_ ad: FullScreenPresentingAd, didFailToPresentFullScreenContentWithError error: Error) { onDismissWithoutReward() }
}

extension DateFormatter {
    static let dayKey: DateFormatter = {
        let f = DateFormatter(); f.calendar = Calendar(identifier: .gregorian); f.dateFormat = "yyyyMMdd"; return f
    }()
}

extension UIApplication {
    var topViewController: UIViewController? {
        let scene = connectedScenes.compactMap { $0 as? UIWindowScene }.first
        var vc = scene?.windows.first { $0.isKeyWindow }?.rootViewController ?? scene?.windows.first?.rootViewController
        while let p = vc?.presentedViewController { vc = p }
        return vc
    }
}
