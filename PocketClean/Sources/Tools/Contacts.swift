import SwiftUI
import Contacts
import CryptoKit
import UniformTypeIdentifiers

struct ContactRow: Identifiable, Hashable {
    let id: String
    let name: String
    let phones: [String]
    let emails: [String]
    let org: String
    let container: String
    let fieldCount: Int
    var display: String { name.isEmpty ? (phones.first ?? emails.first ?? "이름 없음") : name }
}

struct ContactGroup: Identifiable, Hashable {
    let id = UUID()
    let members: [ContactRow]
    let reason: String
    let nameOnly: Bool
}

struct ContactBackupInfo: Identifiable, Codable, Hashable {
    let id: String
    let date: Date
    let count: Int
    let checksum: String
    let note: String
}

@MainActor
final class ContactsManager: ObservableObject {
    @Published var status = CNContactStore.authorizationStatus(for: .contacts)
    @Published var rows: [ContactRow] = []
    @Published var groups: [ContactGroup] = []
    @Published var empties: [ContactRow] = []
    @Published var loading = false
    @Published var backups: [ContactBackupInfo] = []
    @Published var message: String?

    let store = CNContactStore()

    nonisolated static var keys: [CNKeyDescriptor] {
        [CNContactVCardSerialization.descriptorForRequiredKeys(),
         CNContactIdentifierKey as CNKeyDescriptor, CNContactGivenNameKey as CNKeyDescriptor, CNContactFamilyNameKey as CNKeyDescriptor,
         CNContactOrganizationNameKey as CNKeyDescriptor, CNContactJobTitleKey as CNKeyDescriptor, CNContactPhoneNumbersKey as CNKeyDescriptor,
         CNContactEmailAddressesKey as CNKeyDescriptor, CNContactPostalAddressesKey as CNKeyDescriptor, CNContactUrlAddressesKey as CNKeyDescriptor,
         CNContactBirthdayKey as CNKeyDescriptor, CNContactImageDataKey as CNKeyDescriptor, CNContactImageDataAvailableKey as CNKeyDescriptor]
    }

    var hasAccess: Bool { status == .authorized || status.rawValue == 4 /* limited (iOS 18) */ }

    func request() async {
        _ = try? await store.requestAccess(for: .contacts)
        status = CNContactStore.authorizationStatus(for: .contacts)
        if hasAccess { await load() }
    }

    /// 국가번호·공백·기호 정리. 국가가 불분명한 짧은 번호는 nil(합치지 않음)
    nonisolated static func normalize(_ raw: String) -> String? {
        let plus = raw.trimmingCharacters(in: .whitespaces).hasPrefix("+")
        var d = raw.filter(\.isNumber)
        if plus {
            if d.hasPrefix("82") { d = "0" + d.dropFirst(2) } else { return d.count >= 8 ? "+" + d : nil }
        } else if d.hasPrefix("0082") { d = "0" + d.dropFirst(4) }
        guard d.count >= 9 else { return nil }
        return d
    }

    func fetchAll() async -> [CNContact] {
        let store = self.store
        return await Task.detached(priority: .userInitiated) { () -> [CNContact] in
            var out: [CNContact] = []
            let req = CNContactFetchRequest(keysToFetch: ContactsManager.keys)
            req.unifyResults = false
            try? store.enumerateContacts(with: req) { c, _ in out.append(c) }
            return out
        }.value
    }

    func containerMap() -> [String: String] {
        var map: [String: String] = [:]
        guard let cs = try? store.containers(matching: nil) else { return map }
        for c in cs {
            let label: String
            switch c.type { case .local: label = "이 iPhone"; case .exchange: label = "Exchange"; case .cardDAV: label = c.name.isEmpty ? "iCloud·Google" : c.name; default: label = c.name }
            let pred = CNContact.predicateForContactsInContainer(withIdentifier: c.identifier)
            if let list = try? store.unifiedContacts(matching: pred, keysToFetch: [CNContactIdentifierKey as CNKeyDescriptor]) {
                for x in list { map[x.identifier] = label }
            }
        }
        return map
    }

    func load() async {
        guard hasAccess else { return }
        loading = true
        let all = await fetchAll()
        let cmap = containerMap()
        rows = all.map { c in
            let name = [c.familyName, c.givenName].filter { !$0.isEmpty }.joined()
            let fields = c.phoneNumbers.count + c.emailAddresses.count + c.postalAddresses.count + c.urlAddresses.count
                + (c.organizationName.isEmpty ? 0 : 1) + (c.birthday == nil ? 0 : 1) + (c.imageDataAvailable ? 1 : 0)
            return ContactRow(id: c.identifier, name: name, phones: c.phoneNumbers.map { $0.value.stringValue },
                              emails: c.emailAddresses.map { ($0.value as String) }, org: c.organizationName,
                              container: cmap[c.identifier] ?? "", fieldCount: fields)
        }
        analyze()
        loadBackups()
        loading = false
    }

    private func analyze() {
        var parent: [String: String] = [:]
        func find(_ x: String) -> String { var r = x; while let p = parent[r], p != r { r = p }; return r }
        func union(_ a: String, _ b: String) {
            if parent[a] == nil { parent[a] = a }; if parent[b] == nil { parent[b] = b }
            let ra = find(a), rb = find(b); if ra != rb { parent[ra] = rb }
        }
        var byKey: [String: String] = [:]
        var reason: [String: String] = [:]
        for r in rows {
            for p in r.phones { if let k = Self.normalize(p) {
                if let o = byKey["p" + k] { union(o, r.id); reason[r.id] = "같은 전화번호"; reason[o] = "같은 전화번호" } else { byKey["p" + k] = r.id }
            } }
            for e in r.emails {
                let k = "e" + e.lowercased().trimmingCharacters(in: .whitespaces)
                if let o = byKey[k] { union(o, r.id); reason[r.id] = reason[r.id] ?? "같은 이메일"; reason[o] = reason[o] ?? "같은 이메일" } else { byKey[k] = r.id }
            }
        }
        var clusters: [String: [ContactRow]] = [:]
        for r in rows where parent[r.id] != nil { clusters[find(r.id), default: []].append(r) }
        var gs = clusters.values.filter { $0.count > 1 }.map { m in
            ContactGroup(members: m.sorted { $0.fieldCount > $1.fieldCount }, reason: reason[m[0].id] ?? "같은 번호·이메일", nameOnly: false)
        }
        // 이름만 같은 후보(자동 합치기 안 함)
        let grouped = Set(gs.flatMap { $0.members.map(\.id) })
        let byName = Dictionary(grouping: rows.filter { !$0.name.isEmpty && !grouped.contains($0.id) }, by: \.name)
        gs += byName.values.filter { $0.count > 1 }.map { ContactGroup(members: $0, reason: "이름만 같아요 — 다른 사람일 수 있어요", nameOnly: true) }
        groups = gs.sorted { !$0.nameOnly && $1.nameOnly }
        // 이름·번호·이메일이 모두 없는 연락처(회사·주소 등 다른 정보가 있으면 제외)
        empties = rows.filter { $0.name.isEmpty && $0.phones.isEmpty && $0.emails.isEmpty && $0.fieldCount == 0 && $0.org.isEmpty }
    }

    // MARK: 백업 (암호화, 이 기기 키체인 키)
    static var backupDir: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ContactBackups", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    private var backupKey: SymmetricKey { Keychain.symmetricKey("contactsBackupKey") }

    func loadBackups() {
        let idx = Self.backupDir.appendingPathComponent("index.json")
        backups = ((try? JSONDecoder().decode([ContactBackupInfo].self, from: Data(contentsOf: idx))) ?? []).sorted { $0.date > $1.date }
    }
    private func saveIndex() {
        try? JSONEncoder().encode(backups).write(to: Self.backupDir.appendingPathComponent("index.json"), options: .completeFileProtection)
    }

    @discardableResult
    func backup(_ contacts: [CNContact]? = nil, note: String) async -> ContactBackupInfo? {
        let list: [CNContact]
        if let contacts { list = contacts } else { list = await fetchAll() }
        guard let vcf = try? CNContactVCardSerialization.data(with: list) else { message = "백업을 만들지 못했어요"; return nil }
        guard let enc = try? Crypto.seal(vcf, key: backupKey) else { return nil }
        let info = ContactBackupInfo(id: UUID().uuidString, date: Date(), count: list.count, checksum: Crypto.sha256(vcf), note: note)
        do { try enc.write(to: Self.backupDir.appendingPathComponent(info.id + ".pcb"), options: .completeFileProtection) } catch { message = "백업을 저장하지 못했어요(공간 부족?)"; return nil }
        backups.insert(info, at: 0); saveIndex()
        return info
    }

    func vcardData(of b: ContactBackupInfo) -> Data? {
        guard let enc = try? Data(contentsOf: Self.backupDir.appendingPathComponent(b.id + ".pcb")),
              let vcf = try? Crypto.open(enc, key: backupKey), Crypto.sha256(vcf) == b.checksum else { return nil }
        return vcf
    }

    func deleteBackup(_ b: ContactBackupInfo) {
        try? FileManager.default.removeItem(at: Self.backupDir.appendingPathComponent(b.id + ".pcb"))
        backups.removeAll { $0.id == b.id }; saveIndex()
    }

    /// 암호로 잠근 백업 파일(다른 기기·앱 재설치 후 복원용)
    func exportProtected(_ vcf: Data, password: String) -> URL? {
        let salt = Crypto.random(16)
        guard let enc = try? Crypto.seal(vcf, key: Crypto.pbkdf2(password, salt: salt)) else { return nil }
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("연락처백업_\(DateFormatter.dayKey.string(from: Date())).pcbackup")
        try? (Data("PCB1".utf8) + salt + enc).write(to: u)
        return u
    }

    nonisolated static func openProtected(_ d: Data, password: String) -> Data? {
        guard d.count > 20, d.prefix(4) == Data("PCB1".utf8) else { return nil }
        let salt = d.subdata(in: 4..<20)
        return try? Crypto.open(d.subdata(in: 20..<d.count), key: Crypto.pbkdf2(password, salt: salt))
    }

    // MARK: 복원 — 덮어쓰지 않고 추가(중복은 건너뜀)
    func restore(vcf: Data, skipDuplicates: Bool) async -> (added: Int, skipped: Int, failed: Int) {
        guard let parsed = try? CNContactVCardSerialization.contacts(with: vcf) else { return (0, 0, 0) }
        var existing = Set<String>()
        for r in rows { for p in r.phones { if let k = Self.normalize(p) { existing.insert("p" + k) } }; for e in r.emails { existing.insert("e" + e.lowercased()) }
            if r.phones.isEmpty && r.emails.isEmpty && !r.name.isEmpty { existing.insert("n" + r.name) } }
        var added = 0, skipped = 0, failed = 0
        for c in parsed {
            let keys = c.phoneNumbers.compactMap { Self.normalize($0.value.stringValue).map { "p" + $0 } } + c.emailAddresses.map { "e" + ($0.value as String).lowercased() }
            let nameKey = "n" + [c.familyName, c.givenName].joined()
            if skipDuplicates && (keys.contains { existing.contains($0) } || (keys.isEmpty && existing.contains(nameKey))) { skipped += 1; continue }
            guard let m = c.mutableCopy() as? CNMutableContact else { failed += 1; continue }
            let req = CNSaveRequest(); req.add(m, toContainerWithIdentifier: nil)
            do { try store.execute(req); added += 1; keys.forEach { existing.insert($0) } } catch { failed += 1 }
        }
        await load()
        return (added, skipped, failed)
    }

    // MARK: 합치기 — 변경 전 자동 백업, 정보는 최대한 보존
    func merge(_ g: ContactGroup, keeperID: String) async -> (ok: Bool, changed: Int, note: String) {
        let ids = g.members.map(\.id)
        let pred = CNContact.predicateForContacts(withIdentifiers: ids)
        guard let full = try? store.unifiedContacts(matching: pred, keysToFetch: Self.keys), full.count == ids.count,
              let keep = full.first(where: { $0.identifier == keeperID }), let m = keep.mutableCopy() as? CNMutableContact else {
            return (false, 0, "연락처를 다시 읽지 못했어요. 목록을 새로 고쳐 주세요.")
        }
        guard await backup(full, note: "합치기 전 자동 백업 (\(g.members.first?.display ?? ""))") != nil else { return (false, 0, "백업을 만들지 못해 합치지 않았어요.") }
        var phones = Set(m.phoneNumbers.compactMap { Self.normalize($0.value.stringValue) ?? $0.value.stringValue })
        var emails = Set(m.emailAddresses.map { ($0.value as String).lowercased() })
        var addrs = Set(m.postalAddresses.map { CNPostalAddressFormatter.string(from: $0.value, style: .mailingAddress) })
        var urls = Set(m.urlAddresses.map { ($0.value as String) })
        let others = full.filter { $0.identifier != keeperID }
        for o in others {
            for p in o.phoneNumbers { let k = Self.normalize(p.value.stringValue) ?? p.value.stringValue; if !phones.contains(k) { phones.insert(k); m.phoneNumbers.append(p) } }
            for e in o.emailAddresses { let k = (e.value as String).lowercased(); if !emails.contains(k) { emails.insert(k); m.emailAddresses.append(e) } }
            for a in o.postalAddresses { let k = CNPostalAddressFormatter.string(from: a.value, style: .mailingAddress); if !addrs.contains(k) { addrs.insert(k); m.postalAddresses.append(a) } }
            for u in o.urlAddresses { let k = (u.value as String); if !urls.contains(k) { urls.insert(k); m.urlAddresses.append(u) } }
            if m.organizationName.isEmpty { m.organizationName = o.organizationName }
            if m.jobTitle.isEmpty { m.jobTitle = o.jobTitle }
            if m.birthday == nil { m.birthday = o.birthday }
            if m.givenName.isEmpty && m.familyName.isEmpty { m.givenName = o.givenName; m.familyName = o.familyName }
            if m.imageData == nil, let img = o.imageData { m.imageData = img }
        }
        let req = CNSaveRequest()
        req.update(m)
        for o in others { if let d = o.mutableCopy() as? CNMutableContact { req.delete(d) } }
        do {
            try store.execute(req)
            await load()
            return (true, others.count + 1, "합쳤어요. 문제가 있으면 ‘백업’에서 합치기 전 상태를 다시 추가할 수 있어요.")
        } catch {
            return (false, 0, "합치지 못했어요. 읽기 전용 계정(Exchange·회사 계정 등)의 연락처는 수정할 수 없어요.")
        }
    }

    func deleteContacts(_ ids: [String]) async -> Int {
        let pred = CNContact.predicateForContacts(withIdentifiers: ids)
        guard let list = try? store.unifiedContacts(matching: pred, keysToFetch: Self.keys) else { return 0 }
        await backup(list, note: "빈 연락처 정리 전 자동 백업")
        let req = CNSaveRequest()
        for c in list { if let m = c.mutableCopy() as? CNMutableContact { req.delete(m) } }
        do { try store.execute(req); await load(); return list.count } catch { return 0 }
    }
}


// MARK: - 화면

struct ContactsHome: View {
    @StateObject private var cm = ContactsManager()
    @EnvironmentObject var quota: Quota
    @EnvironmentObject var store: Store
    @State private var mergeTarget: ContactGroup?
    @State private var limit = false
    @State private var showBackups = false
    @State private var confirmEmpty = false

    var body: some View {
        List {
            if !cm.hasAccess {
                Section {
                    Text(cm.status == .notDetermined ? "중복 연락처를 찾으려면 연락처 접근이 필요해요. 연락처는 휴대폰 밖으로 나가지 않아요." : "연락처 접근이 꺼져 있어요. 설정 › Pocket Clean › 연락처를 켜 주세요.").font(.subheadline)
                    if cm.status == .notDetermined { Button("연락처 접근 허용") { Task { await cm.request() } } }
                    else { Button("설정 열기") { if let u = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(u) } } }
                }
            } else {
                Section {
                    HStack { Text("전체 연락처"); Spacer(); Text("\(cm.rows.count)개").foregroundColor(.secondary) }
                    Button { showBackups = true } label: { Label("백업·복원·내보내기", systemImage: "externaldrive.badge.timemachine") }
                    if let r = quota.remaining(.contacts) { Text("오늘 무료로 \(r)개 더 정리할 수 있어요.").font(.caption).foregroundColor(.secondary) }
                }
                if cm.loading { Section { HStack { ProgressView(); Text("연락처 확인 중…") } } }
                Section {
                    if cm.groups.isEmpty && !cm.loading { Text("중복 후보가 없어요.").foregroundColor(.secondary) }
                    ForEach(cm.groups) { g in
                        Button { mergeTarget = g } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(g.members.first?.display ?? "").font(.subheadline.bold()).foregroundColor(.primary)
                                    Text("외 \(g.members.count - 1)개").font(.caption).foregroundColor(.secondary)
                                    Spacer()
                                    Text(g.reason).font(.caption2).foregroundColor(g.nameOnly ? .orange : .brand)
                                }
                                Text(g.members.flatMap(\.phones).prefix(2).joined(separator: ", ")).font(.caption).foregroundColor(.secondary)
                            }
                        }
                    }
                } header: { Text("중복 후보 \(cm.groups.filter { !$0.nameOnly }.count) · 이름만 같음 \(cm.groups.filter(\.nameOnly).count)") }
                if !cm.empties.isEmpty {
                    Section {
                        ForEach(cm.empties) { e in Text("빈 연락처 (\(e.container))").foregroundColor(.secondary) }
                        Button("빈 연락처 \(cm.empties.count)개 정리", role: .destructive) {
                            if quota.canUse(.contacts, count: cm.empties.count) { confirmEmpty = true } else { limit = true }
                        }
                    } header: { Text("정보가 하나도 없는 연락처") } footer: { Text("이름·번호·이메일·회사·주소가 모두 없는 연락처만 보여요.") }
                }
            }
            if let m = cm.message { Section { Text(m).foregroundColor(.brand) } }
        }
        .navigationTitle("연락처 정리")
        .task { if cm.hasAccess && cm.rows.isEmpty { await cm.load() } }
        .refreshable { await cm.load() }
        .sheet(item: $mergeTarget) { g in MergeSheet(group: g, cm: cm, limit: $limit) }
        .sheet(isPresented: $limit) { LimitSheet(feature: .contacts) }
        .sheet(isPresented: $showBackups) { NavigationStack { BackupView(cm: cm) } }
        .alert("빈 연락처를 정리할까요?", isPresented: $confirmEmpty) {
            Button("취소", role: .cancel) {}
            Button("정리", role: .destructive) { Task {
                let n = await cm.deleteContacts(cm.empties.map(\.id))
                quota.consume(.contacts, n)
                cm.message = "\(n)개를 정리했어요. 정리 전 상태는 백업에 저장돼 있어요."
            } }
        } message: { Text("정리 전에 자동으로 백업을 만들어요.") }
    }
}

struct MergeSheet: View {
    let group: ContactGroup
    @ObservedObject var cm: ContactsManager
    @Binding var limit: Bool
    @EnvironmentObject var quota: Quota
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var keeper: String = ""
    @State private var understood = false
    @State private var working = false
    @State private var result: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(group.members) { r in
                        Button { keeper = r.id } label: {
                            HStack(alignment: .top) {
                                Image(systemName: keeper == r.id ? "largecircle.fill.circle" : "circle").foregroundColor(.brand)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(r.display).font(.subheadline.bold()).foregroundColor(.primary)
                                    if !r.phones.isEmpty { Text(r.phones.joined(separator: ", ")).font(.caption) }
                                    if !r.emails.isEmpty { Text(r.emails.joined(separator: ", ")).font(.caption) }
                                    if !r.org.isEmpty { Text(r.org).font(.caption) }
                                    Text("저장 위치: \(r.container.isEmpty ? "알 수 없음" : r.container) · 정보 \(r.fieldCount)개").font(.caption2).foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                } header: { Text("남길 연락처를 고르세요") } footer: {
                    Text("다른 연락처의 번호·이메일·주소·회사·생일·사진을 남길 연락처로 옮긴 뒤 나머지를 지워요. 메모 등 iOS가 앱에 열어 주지 않는 일부 항목은 옮겨지지 않을 수 있어요. 합치기 전에 자동으로 백업해요.")
                }
                if group.nameOnly {
                    Section { Toggle("같은 사람인 것을 확인했어요", isOn: $understood) } footer: { Text("이름만 같고 번호·이메일이 달라요. 다른 사람일 수 있어요.").foregroundColor(.orange) }
                }
                if let r = result { Section { Text(r) } }
            }
            .navigationTitle("연락처 합치기").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("닫기") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(working ? "합치는 중…" : "합치기") {
                        if !quota.canUse(.contacts, count: group.members.count) { dismiss(); limit = true; return }
                        working = true
                        Task {
                            let r = await cm.merge(group, keeperID: keeper)
                            working = false; result = r.note
                            if r.ok { quota.consume(.contacts, r.changed); Interstitials.shared.afterTaskCompleted(premium: store.isPremium) }
                        }
                    }.disabled(keeper.isEmpty || working || (group.nameOnly && !understood) || result != nil)
                }
            }
            .onAppear { if keeper.isEmpty && !group.nameOnly { keeper = group.members.first?.id ?? "" } }
        }
    }
}

struct BackupView: View {
    @ObservedObject var cm: ContactsManager
    @Environment(\.dismiss) private var dismiss
    @State private var shareURL: URL?
    @State private var askPassword: ContactBackupInfo?
    @State private var password = ""
    @State private var importing = false
    @State private var importData: Data?
    @State private var importNeedsPassword = false
    @State private var restoreFrom: ContactBackupInfo?
    @State private var note: String?

    var body: some View {
        List {
            Section {
                Button { Task { if let b = await cm.backup(note: "직접 만든 백업") { note = "\(b.count)개 연락처를 백업했어요." } } } label: { Label("지금 백업하기", systemImage: "plus.circle") }
                Button { importing = true } label: { Label("백업 파일 가져와서 복원", systemImage: "square.and.arrow.down") }
            } footer: { Text("백업은 이 iPhone 안에 암호화해 저장돼요. 앱을 지우면 함께 지워지니, 중요한 백업은 ‘암호로 잠근 파일’로 내보내 파일 앱 등에 보관하세요.") }
            Section("저장된 백업") {
                if cm.backups.isEmpty { Text("백업이 없어요.").foregroundColor(.secondary) }
                ForEach(cm.backups) { b in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(b.date.formatted(date: .abbreviated, time: .shortened)).font(.subheadline.bold())
                        Text("\(b.count)개 · \(b.note)").font(.caption).foregroundColor(.secondary)
                        HStack {
                            Button("복원") { restoreFrom = b }.buttonStyle(.bordered)
                            Menu("내보내기") {
                                Button("암호로 잠근 백업 파일") { askPassword = b }
                                Button("vCard(.vcf) — 암호 없음") {
                                    if let v = cm.vcardData(of: b) {
                                        let u = FileManager.default.temporaryDirectory.appendingPathComponent("연락처_\(DateFormatter.dayKey.string(from: b.date)).vcf")
                                        try? v.write(to: u); shareURL = u
                                    }
                                }
                            }.buttonStyle(.bordered)
                            Spacer()
                            Button(role: .destructive) { cm.deleteBackup(b) } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                        }
                    }
                }
            }
            if let n = note { Section { Text(n).foregroundColor(.brand) } }
        }
        .navigationTitle("백업·복원")
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("닫기") { dismiss() } } }
        .onAppear { cm.loadBackups() }
        .sheet(item: Binding(get: { shareURL.map { URLBox(id: $0) } }, set: { shareURL = $0?.id })) { ShareSheet(items: [$0.id]) }
        .alert("백업 파일 암호", isPresented: Binding(get: { askPassword != nil }, set: { if !$0 { askPassword = nil } })) {
            SecureField("암호(8자 이상)", text: $password)
            Button("취소", role: .cancel) { password = "" }
            Button("만들기") {
                if password.count >= 8, let b = askPassword, let v = cm.vcardData(of: b), let u = cm.exportProtected(v, password: password) { shareURL = u }
                else { note = "암호는 8자 이상이어야 해요." }
                password = ""
            }
        } message: { Text("이 암호를 잊으면 파일을 열 수 없어요. 운영자도 대신 열 수 없어요.") }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.vCard, .data]) { r in
            guard case .success(let u) = r else { return }
            _ = u.startAccessingSecurityScopedResource(); defer { u.stopAccessingSecurityScopedResource() }
            guard let d = try? Data(contentsOf: u) else { note = "파일을 읽지 못했어요."; return }
            if d.prefix(4) == Data("PCB1".utf8) { importData = d; importNeedsPassword = true }
            else { Task { let r = await cm.restore(vcf: d, skipDuplicates: true); note = "추가 \(r.added) · 중복 건너뜀 \(r.skipped) · 실패 \(r.failed)" } }
        }
        .alert("백업 파일 암호", isPresented: $importNeedsPassword) {
            SecureField("암호", text: $password)
            Button("취소", role: .cancel) { password = ""; importData = nil }
            Button("복원") {
                if let d = importData, let v = ContactsManager.openProtected(d, password: password) {
                    Task { let r = await cm.restore(vcf: v, skipDuplicates: true); note = "추가 \(r.added) · 중복 건너뜀 \(r.skipped) · 실패 \(r.failed)" }
                } else { note = "암호가 맞지 않거나 파일이 손상됐어요." }
                password = ""; importData = nil
            }
        }
        .confirmationDialog("복원 방식", isPresented: Binding(get: { restoreFrom != nil }, set: { if !$0 { restoreFrom = nil } })) {
            Button("없는 연락처만 추가(권장)") { run(skip: true) }
            Button("모두 추가(중복 생길 수 있음)") { run(skip: false) }
        } message: { Text("기존 연락처를 지우거나 덮어쓰지 않아요.") }
    }

    private func run(skip: Bool) {
        guard let b = restoreFrom, let v = cm.vcardData(of: b) else { note = "백업을 열지 못했어요."; return }
        Task { let r = await cm.restore(vcf: v, skipDuplicates: skip); note = "추가 \(r.added) · 중복 건너뜀 \(r.skipped) · 실패 \(r.failed)" }
    }
}

struct URLBox: Identifiable { let id: URL }

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: items, applicationActivities: nil) }
    func updateUIViewController(_ c: UIActivityViewController, context: Context) {}
}
