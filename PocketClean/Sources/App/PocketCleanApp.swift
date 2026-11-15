import SwiftUI
import GoogleMobileAds
import AppTrackingTransparency

@main
struct PocketCleanApp: App {
    @StateObject private var store = Store()
    @StateObject private var quota = Quota.shared
    @StateObject private var media = MediaIndex()
    @StateObject private var vault = Vault()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(quota)
                .environmentObject(media)
                .environmentObject(vault)
                .tint(.brand)
                .task {
                    let s = store
                    quota.isPremium = { [weak s] in s?.isPremium ?? false }
                    await AppConfig.shared.refresh()
                    await AdsBootstrap.start(premium: store.isPremium)
                }
                .onChange(of: phase) { p in
                    if p != .active { vault.lock() }
                    if p == .active { Task { await store.refresh() } }
                }
        }
    }
}

extension Color {
    /// 아이콘 파랑 #0011EF
    static let brand = Color(red: 0, green: 17 / 255, blue: 239 / 255)
    static let brandSoft = Color(red: 0.90, green: 0.92, blue: 1.0)
    static let card = Color(.secondarySystemGroupedBackground)
    static let pageBG = Color(.systemGroupedBackground)
}

enum Tab: Hashable { case home, media, files, tools, settings }

struct RootView: View {
    @State private var tab: Tab = .home
    @EnvironmentObject var vault: Vault
    @Environment(\.scenePhase) private var phase

    var body: some View {
        ZStack {
            TabView(selection: $tab) {
                HomeView(tab: $tab).tabItem { Label("홈", systemImage: "house") }.tag(Tab.home)
                MediaHubView().tabItem { Label("사진·영상", systemImage: "photo.on.rectangle") }.tag(Tab.media)
                FilesView().tabItem { Label("파일", systemImage: "folder") }.tag(Tab.files)
                ToolsView().tabItem { Label("도구", systemImage: "wrench.and.screwdriver") }.tag(Tab.tools)
                SettingsView().tabItem { Label("설정", systemImage: "gearshape") }.tag(Tab.settings)
            }
            // 앱 전환 화면에서 보관함 내용이 보이지 않게 가림
            if phase != .active && vault.isUnlocked {
                Color.pageBG.ignoresSafeArea().overlay(Image(systemName: "lock.fill").font(.largeTitle).foregroundColor(.brand))
            }
        }
    }
}

/// 광고 시작 전 App Tracking Transparency 동의를 한 번 묻는다(거부해도 비개인화 광고로 동작).
enum AdsBootstrap {
    @MainActor static func start(premium: Bool) async {
        if AdIDs.disabled || premium { return }
        if ATTrackingManager.trackingAuthorizationStatus == .notDetermined {
            try? await Task.sleep(nanoseconds: 900_000_000)
            _ = await ATTrackingManager.requestTrackingAuthorization()
        }
        MobileAds.shared.start(completionHandler: nil)
        Interstitials.shared.preload()
        Rewarded.shared.preload()
    }
}
