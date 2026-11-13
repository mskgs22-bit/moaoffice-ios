import SwiftUI
import UIKit
import GoogleMobileAds

enum AdIDs {
    static var banner: String { Bundle.main.object(forInfoDictionaryKey: "GADBannerID") as? String ?? "" }
    static var interstitial: String { Bundle.main.object(forInfoDictionaryKey: "GADInterstitialID") as? String ?? "" }
    /// UI 테스트(스크린샷) 실행 중에는 광고를 띄우지 않는다
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

/// 하단 배너 (구독 중이면 숨김)
struct AdBannerBar: View {
    @EnvironmentObject var store: Store
    var body: some View {
        if !store.isAdFree && !AdIDs.disabled {
            BannerAd().frame(width: 320, height: 50).frame(maxWidth: .infinity).background(Color(.secondarySystemBackground))
        }
    }
}

/// 문서를 몇 번 연 뒤 한 번씩 전면 광고 (Android 와 같은 빈도: 3회마다)
@MainActor
final class Interstitials {
    static let shared = Interstitials()
    private var ad: InterstitialAd?
    private var opens = 0

    func preload() {
        guard !AdIDs.disabled, ad == nil else { return }
        InterstitialAd.load(with: AdIDs.interstitial, request: GoogleMobileAds.Request()) { [weak self] ad, _ in
            Task { @MainActor in self?.ad = ad }
        }
    }

    func documentOpened(adFree: Bool) {
        guard !adFree, !AdIDs.disabled else { return }
        opens += 1
        if opens % 3 == 0, let ad, let vc = UIApplication.shared.topViewController {
            ad.present(from: vc)
            self.ad = nil
        }
        preload()
    }
}

extension UIApplication {
    var topViewController: UIViewController? {
        let scene = connectedScenes.compactMap { $0 as? UIWindowScene }.first
        var vc = scene?.windows.first { $0.isKeyWindow }?.rootViewController ?? scene?.windows.first?.rootViewController
        while let p = vc?.presentedViewController { vc = p }
        return vc
    }
}
