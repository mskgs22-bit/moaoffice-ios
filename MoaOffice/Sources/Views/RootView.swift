import SwiftUI

enum MainTab: Hashable { case home, files, scan, tools, settings }

struct RootView: View {
    @EnvironmentObject var library: Library
    @EnvironmentObject var store: Store
    @StateObject private var router = ToolRouter()
    @State private var tab: MainTab = .home

    var body: some View {
        TabView(selection: Binding(get: { tab }, set: { t in
            if t == .scan { router.open(.scan, isPro: store.isPro) } else { tab = t }
        })) {
            HomeView(tab: $tab).tabItem { Label(L("홈", "Home"), systemImage: "house") }.tag(MainTab.home)
            FilesView().tabItem { Label(L("파일", "Files"), systemImage: "folder") }.tag(MainTab.files)
            Color.clear.tabItem { Label(L("스캔", "Scan"), systemImage: "camera.fill") }.tag(MainTab.scan)
            ToolsView().tabItem { Label(L("도구", "Tools"), systemImage: "square.grid.2x2") }.tag(MainTab.tools)
            SettingsView(inTab: true).tabItem { Label(L("설정", "Settings"), systemImage: "gearshape") }.tag(MainTab.settings)
        }
        .environmentObject(router)
        .modifier(ToolHost(router: router))
        .fullScreenCover(item: $library.opened) { f in
            DocumentScreen(file: f).environmentObject(library).environmentObject(store).environmentObject(router)
        }
        .alert(library.lastError ?? "", isPresented: Binding(get: { library.lastError != nil }, set: { if !$0 { library.lastError = nil } })) {
            Button("OK", role: .cancel) {}
        }
        .onAppear { Interstitials.shared.preload() }
    }
}
