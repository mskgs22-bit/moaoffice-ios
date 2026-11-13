import SwiftUI
import GoogleMobileAds

@main
struct MoaOfficeApp: App {
    @StateObject private var library = Library()
    @StateObject private var store = Store()

    init() {
        if CommandLine.arguments.contains("-demo") { Library.installDemoFiles() }
        MobileAds.shared.start(completionHandler: nil)
    }

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environmentObject(library)
                .environmentObject(store)
                .tint(.brand)
                .onOpenURL { url in library.importFile(url) }
        }
    }
}

extension Color {
    static let brand = Color(red: 0xE5 / 255, green: 0x26 / 255, blue: 0x28 / 255)
}
