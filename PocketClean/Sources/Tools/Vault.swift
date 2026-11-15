import SwiftUI
import CryptoKit
import LocalAuthentication
import PhotosUI
import UniformTypeIdentifiers
import QuickLook
import Photos
import AVFoundation
import ImageIO

struct VaultItem: Identifiable, Codable, Hashable {
    let id: String
    var name: String
    let isVideo: Bool
    let size: Int64
    let added: Date
    let keyVersion: Int
    var originalAssetID: String?
    var originalRemoved: Bool
}

/// 비밀 보관함: 파일마다 AES-256-GCM, 키는 키체인(이 기기에서만). PIN은 화면 잠금용이며 원문을 저장하지 않는다.
@MainActor
final class Vault: ObservableObject {
    @Published private(set) var isUnlocked = false
    @Published private(set) var items: [VaultItem] = []
    @Published var hasPIN = Keychain.get("vaultPinHash") != nil
    @Published var lockedUntil: Date?
    @Published var working = false
    @Published var message: String?

    private var key: SymmetricKey { Keychain.symmetricKey("vaultRootKey_v1") }
    nonisolated static var dir: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Vault", isDirectory: true)
        if !FileManager.default.fileExists(atPath: d.path) {
            try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            var u = d; var rv = URLResourceValues(); rv.isExcludedFromBackup = true; try? u.setResourceValues(rv)
        }
        return d
    }
    nonisolated static var viewDir: URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("vault-view", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    // MARK: PIN·잠금
    func setPIN(_ pin: String) {
        let salt = Crypto.random(16)
        let hash = Crypto.pbkdf2(pin, salt: salt).withUnsafeBytes { Data($0) }
        Keychain.set("vaultPinSalt", salt); Keychain.set("vaultPinHash", hash)
        hasPIN = true; isUnlocked = true; loadIndex()
    }

    private var fails: Int {
        get { UserDefaults.standard.integer(forKey: "vaultFails") }
        set { UserDefaults.standard.set(newValue, forKey: "vaultFails") }
    }

    func unlock(pin: String) -> Bool {
        if let u = lockedUntil, u > Date() { return false }
        guard let salt = Keychain.get("vaultPinSalt"), let hash = Keychain.get("vaultPinHash") else { return false }
        let h = Crypto.pbkdf2(pin, salt: salt).withUnsafeBytes { Data($0) }
        if h == hash { fails = 0; lockedUntil = nil; isUnlocked = true; loadIndex(); return true }
        fails += 1
        if fails >= 5 { lockedUntil = Date().addingTimeInterval(30 * pow(2, Double(min(fails - 5, 6)))) }
        return false
    }

    func unlockBiometric() async {
        let ctx = LAContext()
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &err) else { return }
        if (try? await ctx.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: "비밀 보관함 열기")) == true {
            fails = 0; isUnlocked = true; loadIndex()
        }
    }

    var biometricName: String? {
        let ctx = LAContext()
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) else { return nil }
        return ctx.biometryType == .faceID ? "Face ID" : "Touch ID"
    }

    func lock() {
        isUnlocked = false
        try? FileManager.default.removeItem(at: Self.viewDir) // 열람용 임시 복호화 파일 즉시 삭제
    }

    // MARK: 목록(암호화 저장)
    private var indexURL: URL { Self.dir.appendingPathComponent("index.pcv") }
    func loadIndex() {
        guard let d = try? Data(contentsOf: indexURL), let plain = try? Crypto.open(d, key: key),
              let list = try? JSONDecoder().decode([VaultItem].self, from: plain) else { items = []; return }
        items = list.sorted { $0.added > $1.added }
    }
    private func saveIndex() {
        guard let plain = try? JSONEncoder().encode(items), let enc = try? Crypto.seal(plain, key: key) else { return }
        try? enc.write(to: indexURL, options: [.atomic, .completeFileProtection])
    }

    // MARK: 가져오기: 복사 → 암호화 → 복호화 확인 → 목록 등록 (원본 삭제는 따로 동의)
    func importFile(_ src: URL, isVideo: Bool, name: String, assetID: String?) -> Bool {
        guard let data = try? Data(contentsOf: src) else { return false }
        let id = UUID().uuidString
        let file = Self.dir.appendingPathComponent(id + ".bin")
        do {
            let enc = try Crypto.seal(data, key: key)
            try enc.write(to: file, options: [.atomic, .completeFileProtection])
            let check = try Crypto.open(Data(contentsOf: file), key: key)
            guard Crypto.sha256(check) == Crypto.sha256(data) else { try? FileManager.default.removeItem(at: file); return false }
        } catch { try? FileManager.default.removeItem(at: file); return false }
        if let t = Self.thumbnail(src, isVideo: isVideo), let te = try? Crypto.seal(t, key: key) {
            try? te.write(to: Self.dir.appendingPathComponent(id + ".thumb"), options: .completeFileProtection)
        }
        items.insert(VaultItem(id: id, name: name, isVideo: isVideo, size: Int64(data.count), added: Date(), keyVersion: 1,
                               originalAssetID: assetID, originalRemoved: false), at: 0)
        saveIndex()
        return true
    }

    nonisolated static func thumbnail(_ u: URL, isVideo: Bool) -> Data? {
        if isVideo {
            let g = AVAssetImageGenerator(asset: AVURLAsset(url: u)); g.appliesPreferredTrackTransform = true; g.maximumSize = CGSize(width: 300, height: 300)
            guard let cg = try? g.copyCGImage(at: CMTime(seconds: 0.5, preferredTimescale: 600), actualTime: nil) else { return nil }
            return UIImage(cgImage: cg).jpegData(compressionQuality: 0.7)
        }
        guard let src = CGImageSourceCreateWithURL(u as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 300, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary)
        else { return nil }
        return UIImage(cgImage: cg).jpegData(compressionQuality: 0.7)
    }

    func thumb(_ it: VaultItem) -> UIImage? {
        guard let d = try? Data(contentsOf: Self.dir.appendingPathComponent(it.id + ".thumb")), let p = try? Crypto.open(d, key: key) else { return nil }
        return UIImage(data: p)
    }

    /// 열람·내보내기용 임시 복호화 파일 (잠그면 지워짐)
    func decryptedURL(_ it: VaultItem) -> URL? {
        guard let d = try? Data(contentsOf: Self.dir.appendingPathComponent(it.id + ".bin")), let p = try? Crypto.open(d, key: key) else { return nil }
        let u = Self.viewDir.appendingPathComponent(it.id + "-" + it.name)
        try? p.write(to: u, options: .completeFileProtection)
        return u
    }

    func remove(_ it: VaultItem) {
        try? FileManager.default.removeItem(at: Self.dir.appendingPathComponent(it.id + ".bin"))
        try? FileManager.default.removeItem(at: Self.dir.appendingPathComponent(it.id + ".thumb"))
        items.removeAll { $0.id == it.id }; saveIndex()
    }

    func markOriginalRemoved(_ assetIDs: Set<String>) {
        for i in items.indices { if let a = items[i].originalAssetID, assetIDs.contains(a) { items[i].originalRemoved = true } }
        saveIndex()
    }

    func saveToPhotos(_ it: VaultItem) async -> Bool {
        guard let u = decryptedURL(it) else { return false }
        defer { try? FileManager.default.removeItem(at: u) }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                if it.isVideo { PHAssetCreationRequest.creationRequestForAssetFromVideo(atFileURL: u) }
                else { PHAssetCreationRequest.creationRequestForAssetFromImage(atFileURL: u) }
            }
            return true
        } catch { return false }
    }

    // MARK: 복구 파일 (복구 코드로만 열림, 코드는 서버로 보내지 않음)
    /// 형식: "PCVR1" + salt(16) + [4바이트 길이 + 암호화 레코드]... 첫 레코드는 목록(JSON)
    func exportRecovery(code: String) async -> URL? {
        working = true; defer { working = false }
        let salt = Crypto.random(16)
        let k = Crypto.pbkdf2(code, salt: salt, rounds: 100_000)
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("PocketClean_보관함복구_\(DateFormatter.dayKey.string(from: Date())).pcvault")
        FileManager.default.createFile(atPath: out.path, contents: nil)
        guard let h = try? FileHandle(forWritingTo: out) else { return nil }
        defer { try? h.close() }
        func write(_ d: Data) throws {
            let sealed = try Crypto.seal(d, key: k)
            var n = UInt32(sealed.count).bigEndian
            h.write(Data(bytes: &n, count: 4)); h.write(sealed)
        }
        do {
            h.write(Data("PCVR1".utf8)); h.write(salt)
            try write(JSONEncoder().encode(items))
            for it in items {
                guard let d = try? Data(contentsOf: Self.dir.appendingPathComponent(it.id + ".bin")) else { continue }
                try write(try Crypto.open(d, key: key))
            }
            return out
        } catch { try? FileManager.default.removeItem(at: out); return nil }
    }

    func importRecovery(_ u: URL, code: String) async -> Int? {
        working = true; defer { working = false }
        guard let all = try? Data(contentsOf: u), all.count > 21, all.prefix(5) == Data("PCVR1".utf8) else { return nil }
        let salt = all.subdata(in: 5..<21)
        let k = Crypto.pbkdf2(code.uppercased().trimmingCharacters(in: .whitespaces), salt: salt, rounds: 100_000)
        var pos = 21
        func next() -> Data? {
            guard pos + 4 <= all.count else { return nil }
            let n = all.subdata(in: pos..<pos + 4).withUnsafeBytes { Int(UInt32(bigEndian: $0.load(as: UInt32.self))) }
            pos += 4
            guard pos + n <= all.count else { return nil }
            defer { pos += n }
            return try? Crypto.open(all.subdata(in: pos..<pos + n), key: k)
        }
        guard let listData = next(), let list = try? JSONDecoder().decode([VaultItem].self, from: listData) else { return nil }
        var added = 0
        for it in list {
            guard let d = next() else { break }
            if items.contains(where: { $0.id == it.id }) { continue }
            let tmp = Self.viewDir.appendingPathComponent(it.id + "-" + it.name)
            try? d.write(to: tmp)
            if importFile(tmp, isVideo: it.isVideo, name: it.name, assetID: nil) { added += 1 }
            try? FileManager.default.removeItem(at: tmp)
        }
        return added
    }
}

// MARK: - 화면

struct VaultHome: View {
    @EnvironmentObject var vault: Vault
    var body: some View {
        Group {
            if !vault.hasPIN { PINSetup() }
            else if !vault.isUnlocked { VaultLock() }
            else { VaultList() }
        }.navigationTitle("비밀 보관함")
    }
}

struct PINSetup: View {
    @EnvironmentObject var vault: Vault
    @State private var pin = ""
    @State private var pin2 = ""
    @State private var agreed = false
    var body: some View {
        Form {
            Section {
                Text("사진·동영상을 이 iPhone 안에 암호화해 보관해요. 키는 이 기기의 키체인에만 있고 서버로 보내지 않아요.").font(.subheadline)
                Text("앱을 지우거나 기기를 바꾸면 보관함을 열 수 없어요. 꼭 ‘복구 파일 내보내기’로 따로 보관하세요. 키와 복구 코드를 모두 잃으면 운영자도 복원할 수 없어요.").font(.subheadline).foregroundColor(.orange)
                Toggle("위 내용을 이해했어요", isOn: $agreed)
            }
            Section("보관함 PIN (6자리)") {
                SecureField("PIN", text: $pin).keyboardType(.numberPad)
                SecureField("PIN 확인", text: $pin2).keyboardType(.numberPad)
                Button("보관함 만들기") { vault.setPIN(pin) }
                    .disabled(!agreed || pin.count != 6 || pin != pin2 || !pin.allSatisfy(\.isNumber))
            }
        }
    }
}

struct VaultLock: View {
    @EnvironmentObject var vault: Vault
    @State private var pin = ""
    @State private var wrong = false
    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "lock.shield.fill").font(.system(size: 54)).foregroundColor(.brand).padding(.top, 40)
            Text("보관함이 잠겨 있어요").font(.title3.bold())
            SecureField("PIN 6자리", text: $pin).keyboardType(.numberPad).multilineTextAlignment(.center)
                .font(.title2).padding().background(Color.card).cornerRadius(14).frame(maxWidth: 240)
                .onChange(of: pin) { v in if v.count == 6 { wrong = !vault.unlock(pin: v); pin = "" } }
            if wrong { Text("PIN이 맞지 않아요").foregroundColor(.red).font(.subheadline) }
            if let u = vault.lockedUntil, u > Date() { Text("여러 번 틀려서 \(u.formatted(date: .omitted, time: .shortened))까지 잠겼어요").foregroundColor(.orange).font(.subheadline) }
            if let b = vault.biometricName { Button("\(b)로 열기") { Task { await vault.unlockBiometric() } }.buttonStyle(.bordered) }
            Spacer()
        }.frame(maxWidth: .infinity).background(Color.pageBG)
        .task { if vault.biometricName != nil { await vault.unlockBiometric() } }
    }
}

struct VaultList: View {
    @EnvironmentObject var vault: Vault
    @EnvironmentObject var quota: Quota
    @EnvironmentObject var media: MediaIndex
    @State private var picking = false
    @State private var limit = false
    @State private var viewURL: URL?
    @State private var pendingRemove: [String] = []
    @State private var askRemove = false
    @State private var confirmRemove = false
    @State private var recoveryCode: String?
    @State private var shareURL: URL?
    @State private var importingRecovery = false
    @State private var recoveryFile: URL?
    @State private var codeInput = ""
    @State private var captured = UIScreen.main.isCaptured

    var body: some View {
        List {
            Section {
                Button { if quota.canUse(.vault) { picking = true } else { limit = true } } label: { Label("사진·동영상 넣기", systemImage: "plus.circle.fill") }
                if let r = quota.remaining(.vault) { Text("무료로 \(r)개 더 넣을 수 있어요. 이미 넣은 파일은 언제든 열고 내보낼 수 있어요.").font(.caption).foregroundColor(.secondary) }
                if vault.working { HStack { ProgressView(); Text("처리 중…") } }
                if let m = vault.message { Text(m).font(.subheadline).foregroundColor(.brand) }
            }
            Section("보관 중 \(vault.items.count)개") {
                if vault.items.isEmpty { Text("아직 보관한 파일이 없어요.").foregroundColor(.secondary) }
                ForEach(vault.items) { it in
                    HStack(spacing: 12) {
                        VaultThumb(item: it)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(it.name).font(.subheadline).lineLimit(1)
                            Text("\(Fmt.bytes(it.size)) · \(it.added.formatted(date: .abbreviated, time: .omitted))").font(.caption).foregroundColor(.secondary)
                            if it.originalAssetID != nil && !it.originalRemoved { Text("원본이 사진첩에 남아 있어요").font(.caption2).foregroundColor(.orange) }
                        }
                        Spacer()
                        Menu {
                            Button { viewURL = vault.decryptedURL(it) } label: { Label("열기", systemImage: "eye") }
                            Button { Task { vault.message = await vault.saveToPhotos(it) ? "사진첩에 저장했어요." : "저장하지 못했어요." } } label: { Label("사진첩으로 내보내기", systemImage: "square.and.arrow.down") }
                            Button { shareURL = vault.decryptedURL(it) } label: { Label("공유·파일로 내보내기", systemImage: "square.and.arrow.up") }
                            Button(role: .destructive) { vault.remove(it) } label: { Label("보관함에서 삭제", systemImage: "trash") }
                        } label: { Image(systemName: "ellipsis.circle").font(.title3) }
                    }
                }
            }
            Section {
                Button { recoveryCode = Crypto.recoveryCode() } label: { Label("복구 파일 내보내기", systemImage: "key") }
                Button { importingRecovery = true } label: { Label("복구 파일로 되살리기", systemImage: "arrow.counterclockwise") }
                Button { vault.lock() } label: { Label("지금 잠그기", systemImage: "lock") }
            } footer: { Text("앱을 다른 화면으로 넘기면 자동으로 잠겨요. 화면 캡처는 iOS가 허용하는 범위에서만 막을 수 있어요.") }
        }
        .overlay { if captured { Color.pageBG.overlay(Text("화면 녹화 중에는 보관함을 가려요").font(.headline)) } }
        .onReceive(NotificationCenter.default.publisher(for: UIScreen.capturedDidChangeNotification)) { _ in captured = UIScreen.main.isCaptured }
        .sheet(isPresented: $picking) {
            VaultPicker { results in Task { await importPicked(results) } }
        }
        .sheet(isPresented: $limit) { LimitSheet(feature: .vault) }
        .quickLookPreview($viewURL)
        .sheet(item: Binding(get: { shareURL.map { URLBox(id: $0) } }, set: { shareURL = $0?.id })) { ShareSheet(items: [$0.id]) }
        .alert("원본도 사진첩에서 정리할까요?", isPresented: $askRemove) {
            Button("남겨 두기", role: .cancel) { pendingRemove = [] }
            Button("정리하기", role: .destructive) { confirmRemove = true }
        } message: { Text("보관함에 안전하게 들어간 것을 확인했어요. 사진첩 원본은 ‘최근 삭제된 항목’으로 옮겨져요. iCloud 사진에 남은 복사본까지 지워지는지는 iCloud 설정에 따라 달라요.") }
        .sheet(isPresented: $confirmRemove) {
            DeleteConfirmSheet(ids: pendingRemove) { r in
                let gone = Set(pendingRemove.filter { MediaIndex.asset($0) == nil })
                vault.markOriginalRemoved(gone); pendingRemove = []
                if r.deleted > 0 { quota.consume(.delete, r.deleted) }
            }
        }
        .sheet(item: Binding(get: { recoveryCode.map { CodeBox(id: $0) } }, set: { recoveryCode = $0?.id })) { c in
            RecoveryCodeSheet(code: c.id) { u in shareURL = u }
        }
        .fileImporter(isPresented: $importingRecovery, allowedContentTypes: [.data]) { r in
            if case .success(let u) = r { recoveryFile = u }
        }
        .alert("복구 코드 입력", isPresented: Binding(get: { recoveryFile != nil }, set: { if !$0 { recoveryFile = nil } })) {
            TextField("XXXX-XXXX-XXXX-XXXX-XXXX-XXXX", text: $codeInput).textInputAutocapitalization(.characters)
            Button("취소", role: .cancel) { codeInput = ""; recoveryFile = nil }
            Button("되살리기") {
                guard let u = recoveryFile else { return }
                let code = codeInput; codeInput = ""
                Task {
                    _ = u.startAccessingSecurityScopedResource(); defer { u.stopAccessingSecurityScopedResource() }
                    if let n = await vault.importRecovery(u, code: code) { vault.message = "\(n)개를 되살렸어요." } else { vault.message = "복구 코드가 맞지 않거나 파일이 손상됐어요." }
                }
            }
        }
    }

    private func importPicked(_ results: [PHPickerResult]) async {
        vault.working = true; defer { vault.working = false }
        var ok = 0, fail = 0
        var ids: [String] = []
        for r in results {
            if !quota.canUse(.vault) { limit = true; break }
            let p = r.itemProvider
            let isVideo = p.hasItemConformingToTypeIdentifier(UTType.movie.identifier)
            let type = isVideo ? UTType.movie.identifier : UTType.image.identifier
            let url: URL? = await withCheckedContinuation { c in
                p.loadFileRepresentation(forTypeIdentifier: type) { u, _ in
                    guard let u else { c.resume(returning: nil); return }
                    let dst = Vault.viewDir.appendingPathComponent(UUID().uuidString + "-" + u.lastPathComponent)
                    try? FileManager.default.copyItem(at: u, to: dst)
                    c.resume(returning: dst)
                }
            }
            guard let u = url else { fail += 1; continue }
            if vault.importFile(u, isVideo: isVideo, name: String(u.lastPathComponent.dropFirst(37)), assetID: r.assetIdentifier) {
                ok += 1; quota.consume(.vault, 1)
                if let a = r.assetIdentifier { ids.append(a) }
            } else { fail += 1 }
            try? FileManager.default.removeItem(at: u)
        }
        vault.message = "\(ok)개를 보관함에 넣었어요" + (fail > 0 ? " · \(fail)개 실패" : "")
        if !ids.isEmpty { pendingRemove = ids; askRemove = true }
    }
}

struct CodeBox: Identifiable { let id: String }

struct VaultThumb: View {
    let item: VaultItem
    @EnvironmentObject var vault: Vault
    @State private var img: UIImage?
    var body: some View {
        ZStack {
            Color(.tertiarySystemFill)
            if let img { Image(uiImage: img).resizable().scaledToFill() } else { Image(systemName: item.isVideo ? "film" : "photo").foregroundColor(.secondary) }
            if item.isVideo { Image(systemName: "play.circle.fill").foregroundColor(.white).shadow(radius: 2) }
        }.frame(width: 52, height: 52).clipped().cornerRadius(8)
        .task { img = vault.thumb(item) }
    }
}

struct RecoveryCodeSheet: View {
    let code: String
    let onFile: (URL) -> Void
    @EnvironmentObject var vault: Vault
    @Environment(\.dismiss) private var dismiss
    @State private var wrote = false
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(code).font(.system(.title3, design: .monospaced).bold()).textSelection(.enabled)
                } header: { Text("복구 코드") } footer: {
                    Text("이 코드를 종이에 적거나 안전한 곳에 보관하세요. 복구 파일은 이 코드로만 열려요. 코드는 다시 볼 수 없고, 운영자도 알 수 없어요.")
                }
                Section { Toggle("코드를 따로 적어 두었어요", isOn: $wrote) }
                Section {
                    Button(vault.working ? "만드는 중…" : "복구 파일 만들기") {
                        Task { if let u = await vault.exportRecovery(code: code) { dismiss(); onFile(u) } }
                    }.disabled(!wrote || vault.working)
                } footer: { Text("만든 파일을 ‘파일에 저장’으로 iCloud Drive 등에 보관하세요. 보관함 전체가 들어 있어 용량이 클 수 있어요.") }
            }
            .navigationTitle("복구 파일").toolbar { ToolbarItem(placement: .cancellationAction) { Button("닫기") { dismiss() } } }
        }
    }
}

struct VaultPicker: UIViewControllerRepresentable {
    let done: ([PHPickerResult]) -> Void
    func makeUIViewController(context: Context) -> PHPickerViewController {
        var c = PHPickerConfiguration(photoLibrary: .shared())
        c.selectionLimit = 0
        c.filter = .any(of: [.images, .videos])
        c.preferredAssetRepresentationMode = .current
        let p = PHPickerViewController(configuration: c)
        p.delegate = context.coordinator
        return p
    }
    func updateUIViewController(_ c: PHPickerViewController, context: Context) {}
    func makeCoordinator() -> Coord { Coord(done) }
    final class Coord: NSObject, PHPickerViewControllerDelegate {
        let done: ([PHPickerResult]) -> Void
        init(_ d: @escaping ([PHPickerResult]) -> Void) { done = d }
        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true); if !results.isEmpty { done(results) }
        }
    }
}
