import SwiftUI

/// 1.1 화면 글자: 한국어/영어를 한 곳에서 고른다 (앱 언어가 한국어면 한국어).
let isKorean: Bool = (Bundle.main.preferredLocalizations.first ?? "en").hasPrefix("ko")
@inline(__always) func L(_ ko: String, _ en: String) -> String { isKorean ? ko : en }

extension Color {
    static let brandInk = Color(red: 0xC4 / 255, green: 0x1C / 255, blue: 0x1F / 255)
    static let brandTint = Color(red: 0xFD / 255, green: 0xEC / 255, blue: 0xEC / 255)
    static let pageBG = Color(.systemGroupedBackground)
}

/// 작은 "PRO" 표시
struct ProBadge: View {
    var body: some View {
        Text(verbatim: "PRO").font(.system(size: 10, weight: .heavy)).foregroundStyle(Color.brandInk)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Color.brandTint, in: RoundedRectangle(cornerRadius: 5))
    }
}

/// 잠깐 보이는 안내
struct ToastModifier: ViewModifier {
    @Binding var text: String?
    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if let t = text {
                Text(verbatim: t).font(.footnote.weight(.semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(.black.opacity(0.8), in: Capsule())
                    .padding(.bottom, 90)
                    .task(id: t) { try? await Task.sleep(nanoseconds: 2_200_000_000); text = nil }
            }
        }
    }
}
extension View { func toast(_ t: Binding<String?>) -> some View { modifier(ToastModifier(text: t)) } }

/// 오래 걸리는 작업 동안 덮개
struct BusyOverlay: View {
    let text: String
    var body: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea()
            VStack(spacing: 12) { ProgressView().tint(.white); Text(verbatim: text).foregroundStyle(.white).font(.subheadline.weight(.semibold)) }
                .padding(24).background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 16))
        }
    }
}

/// UIKit 공유 시트
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: items, applicationActivities: nil) }
    func updateUIViewController(_ c: UIActivityViewController, context: Context) {}
}

struct IdentifiedURL: Identifiable { let url: URL; var id: URL { url } }
struct IdentifiedURLs: Identifiable { let urls: [URL]; let id = UUID() }
