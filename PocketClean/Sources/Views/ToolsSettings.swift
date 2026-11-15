import SwiftUI
import StoreKit
import AppTrackingTransparency
import Photos
import Contacts

struct ToolsView: View {
    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink { CompressHome() } label: { row("film", "동영상 압축", "큰 동영상 용량 줄이기 · 결과 비교 후 저장") }
                    NavigationLink { ContactsHome() } label: { row("person.2", "연락처 정리", "중복 합치기 · 백업 · 복원") }
                    NavigationLink { VaultHome() } label: { row("lock.shield", "비밀 보관함", "사진·동영상을 암호화해 보관") }
                }
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: "envelope").font(.title3).foregroundColor(.secondary).frame(width: 36)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("메일함 정리").font(.subheadline.bold())
                            Text("준비 중이에요. Gmail·Outlook 연결은 각 회사의 보안 심사를 마친 뒤 열 예정이에요.").font(.caption).foregroundColor(.secondary)
                        }
                    }
                }
                Section { AdBannerBar() }
            }
            .navigationTitle("도구")
        }
    }
    private func row(_ i: String, _ t: String, _ s: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: i).font(.title3).foregroundColor(.brand).frame(width: 36, height: 36).background(Color.brandSoft).cornerRadius(10)
            VStack(alignment: .leading, spacing: 2) { Text(t).font(.subheadline.bold()); Text(s).font(.caption).foregroundColor(.secondary) }
        }.padding(.vertical, 4)
    }
}

struct SettingsView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var media: MediaIndex
    @State private var showPay = false
    @State private var tempSize = AppTemp.size()

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button { showPay = true } label: {
                        HStack(spacing: 12) {
                            Image(systemName: store.isPremium ? "checkmark.seal.fill" : "sparkles").font(.title2).foregroundColor(.brand)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(store.isPremium ? "프리미엄 이용 중" : "프리미엄 시작하기").font(.headline).foregroundColor(.primary)
                                Text(store.isPremium ? "광고 없음 · 하루 처리 제한 해제" : "월간·연간 구독 · 광고 제거 · 제한 해제").font(.caption).foregroundColor(.secondary)
                            }
                        }
                    }
                    Button("구매 복원") { Task { await store.restore() } }
                    Button("구독 관리·해지") { Task { await store.manage() } }
                } header: { Text("구독") }

                Section {
                    LabeledContent("사진", value: photoStatus)
                    LabeledContent("연락처", value: contactStatus)
                    LabeledContent("광고 추적", value: attStatus)
                    Button("iOS 설정에서 권한 바꾸기") { if let u = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(u) } }
                } header: { Text("권한·광고 개인정보") } footer: {
                    Text("광고 추적을 허용하지 않아도 모든 정리 기능을 쓸 수 있어요. 사진·연락처·파일 정보는 광고에 쓰이지 않아요.")
                }

                Section {
                    HStack { Text("앱 임시 파일"); Spacer(); Text(Fmt.bytes(tempSize)).foregroundColor(.secondary) }
                    Button("임시 파일 비우기") { _ = AppTemp.clean(keeping: CompressQueue.shared.busyFiles); tempSize = AppTemp.size() }.disabled(tempSize == 0)
                } header: { Text("저장공간") }

                Section {
                    Text("사진은 정리해도 30일간 ‘최근 삭제된 항목’에 남아요. 연락처는 정리 전 자동 백업돼요. 비밀 보관함은 ‘복구 파일’을 따로 보관해야 기기를 바꿔도 되살릴 수 있어요.").font(.footnote)
                } header: { Text("백업 안내") }

                Section {
                    Link("개인정보처리방침", destination: Links.privacy)
                    Link("이용약관(EULA)", destination: Links.terms)
                    Button("문의하기") { if let u = URL(string: "mailto:\(Links.support)?subject=Pocket%20Clean%20문의") { UIApplication.shared.open(u) } }
                    LabeledContent("버전", value: (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "1.0.0")
                } header: { Text("정보") } footer: { Text("Pocket Clean · SEVIO\n사진·연락처·파일은 휴대폰 안에서만 처리하며 서버로 보내지 않아요.") }
            }
            .navigationTitle("설정")
            .sheet(isPresented: $showPay) { PaywallView() }
            .onAppear { tempSize = AppTemp.size(); media.refreshAuth() }
            .alert("알림", isPresented: Binding(get: { store.message != nil && !showPay }, set: { if !$0 { store.message = nil } })) {
                Button("확인") { store.message = nil }
            } message: { Text(store.message ?? "") }
        }
    }

    private var photoStatus: String {
        switch media.auth {
        case .authorized: return "전체 허용"
        case .limited: return "일부만 허용"
        case .denied, .restricted: return "꺼짐"
        default: return "묻지 않음"
        }
    }
    private var contactStatus: String {
        let s = CNContactStore.authorizationStatus(for: .contacts)
        if s == .authorized { return "허용" }
        if s.rawValue == 4 { return "일부만 허용" }
        if s == .notDetermined { return "묻지 않음" }
        return "꺼짐"
    }
    private var attStatus: String {
        switch ATTrackingManager.trackingAuthorizationStatus {
        case .authorized: return "허용(맞춤 광고)"
        case .notDetermined: return "묻지 않음"
        default: return "허용 안 함(비맞춤 광고)"
        }
    }
}
