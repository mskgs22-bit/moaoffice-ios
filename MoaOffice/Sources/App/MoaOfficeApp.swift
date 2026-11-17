import SwiftUI
import GoogleMobileAds
import AppTrackingTransparency

@main
struct MoaOfficeApp: App {
    @StateObject private var library = Library()
    @StateObject private var store = Store()

    init() {
        if CommandLine.arguments.contains("-demo") { Library.installDemoFiles() }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(library)
                .environmentObject(store)
                .tint(.brand)
                .onOpenURL { url in library.receiveFile(url) }
                .task { await AdsBootstrap.start() }
        }
    }
}

extension Color {
    static let brand = Color(red: 0xE5 / 255, green: 0x26 / 255, blue: 0x28 / 255)
}

/// 광고 시작 전 App Tracking Transparency 동의를 한 번 묻는다(거부해도 비개인화 광고로 정상 동작).
enum AdsBootstrap {
    @MainActor static func start() async {
        if !CommandLine.arguments.contains("-noads"), ATTrackingManager.trackingAuthorizationStatus == .notDetermined {
            try? await Task.sleep(nanoseconds: 800_000_000)
            _ = await ATTrackingManager.requestTrackingAuthorization()
        }
        MobileAds.shared.start(completionHandler: nil)
        Interstitials.shared.preload()
    }
}
