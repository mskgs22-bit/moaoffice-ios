import SwiftUI
import UniformTypeIdentifiers
import CryptoKit
import QuickLook

struct FileItem: Identifiable, Hashable {
    let id: URL
    var url: URL { id }
    let size: Int64
    let modified: Date?
    let kind: String
    var name: String { url.lastPathComponent }
}

/// 사용자가 고른 폴더(파일 앱) 안에서만 큰 파일·중복 파일·오래된 파일을 찾는다
@MainActor
final class FileScanner: ObservableObject {
    @Published var folder: URL?
    @Published var items: [FileItem] = []
    @Published var dupGroups: [[FileItem]] = []
    @Published var scanning = false
    @Published var progress: String = ""
    @Published var truncated = false

    private let bookmarkKey = "fileFolderBookmark"

    init() {
        if let d = UserDefaults.standard.data(forKey: bookmarkKey) {
            var stale = false
            if let u = try? URL(resolvingBookmarkData: d, bookmarkDataIsStale: &stale) { folder = u }
        }
    }

    func setFolder(_ u: URL) {
        guard u.startAccessingSecurityScopedResource() else { return }
        if let d = try? u.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(d, forKey: bookmarkKey)
        }
        folder = u
        Task { await scan() }
    }

    nonisolated static func kind(_ u: URL) -> String {
        guard let t = UTType(filenameExtension: u.pathExtension.lowercased()) else { return "기타" }
        if t.conforms(to: .movie) { return "동영상" }
        if t.conforms(to: .image) { return "사진" }
        if t.conforms(to: .audio) { return "오디오" }
        if t.conforms(to: .pdf) || t.conforms(to: .text) || t.conforms(to: .spreadsheet) || t.conforms(to: .presentation) || ["hwp", "hwpx", "doc", "docx"].contains(u.pathExtension.lowercased()) { return "문서" }
        if t.conforms(to: .archive) { return "압축 파일" }
        return "기타"
    }

    func scan() async {
        guard let root = folder else { return }
        scanning = true; truncated = false; progress = "파일 목록을 읽는 중…"
        _ = root.startAccessingSecurityScopedResource()
        let found: ([FileItem], Bool) = await Task.detached(priority: .userInitiated) { () -> ([FileItem], Bool) in
            var out: [FileItem] = []
            let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey, .isPackageKey]
            guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return ([], false) }
            for case let u as URL in en {
                if out.count >= 20000 { return (out, true) }
                guard let v = try? u.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
                out.append(FileItem(id: u, size: Int64(v.fileSize ?? 0), modified: v.contentModificationDate, kind: FileScanner.kind(u)))
            }
            return (out, false)
        }.value
        items = found.0.sorted { $0.size > $1.size }
        truncated = found.1
        progress = "똑같은 파일 확인 중…"
        // 크기가 같은 파일만 SHA-256으로 비교(파일 이름은 보지 않음)
        let bySize = Dictionary(grouping: items.filter { $0.size > 0 }, by: \.size).values.filter { $0.count > 1 }
        let groups: [[FileItem]] = await Task.detached(priority: .userInitiated) { () -> [[FileItem]] in
            var res: [[FileItem]] = []
            for b in bySize {
                var byHash: [String: [FileItem]] = [:]
                for f in b { if let h = FileScanner.sha256(f.url) { byHash[h, default: []].append(f) } }
                res += byHash.values.filter { $0.count > 1 }
            }
            return res.sorted { ($0.first?.size ?? 0) * Int64($0.count) > ($1.first?.size ?? 0) * Int64($1.count) }
        }.value
        dupGroups = groups
        scanning = false; progress = ""
    }

    nonisolated static func sha256(_ u: URL) -> String? {
        guard let h = try? FileHandle(forReadingFrom: u) else { return nil }
        defer { try? h.close() }
        var hasher = SHA256()
        while true {
            guard let d = try? h.read(upToCount: 1 << 20), !d.isEmpty else { break }
            hasher.update(data: d)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// 실제로 지워진 것만 성공으로 센다
    func delete(_ list: [FileItem]) -> (ok: Int, failed: Int, bytes: Int64) {
        var ok = 0, failed = 0, bytes: Int64 = 0
        for f in list {
            do { try FileManager.default.removeItem(at: f.url); ok += 1; bytes += f.size }
            catch { failed += 1 }
        }
        let gone = Set(list.map(\.url).filter { !FileManager.default.fileExists(atPath: $0.path) })
        items.removeAll { gone.contains($0.url) }
        dupGroups = dupGroups.map { $0.filter { !gone.contains($0.url) } }.filter { $0.count > 1 }
        return (ok, failed, bytes)
    }
}

/// 앱 자체 임시 파일(압축 중간 파일, 미리보기 캐시 등)
enum AppTemp {
    static var dirs: [URL] {
        var d = [FileManager.default.temporaryDirectory]
        if let c = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first { d.append(c) }
        return d
    }
    static func size() -> Int64 {
        var t: Int64 = 0
        for d in dirs {
            guard let en = FileManager.default.enumerator(at: d, includingPropertiesForKeys: [.fileSizeKey]) else { continue }
            for case let u as URL in en { t += Int64((try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        }
        return t
    }
    /// 진행 중인 압축 작업 파일은 남긴다
    static func clean(keeping busy: Set<URL>) -> Int64 {
        var freed: Int64 = 0
        for d in dirs {
            guard let list = try? FileManager.default.contentsOfDirectory(at: d, includingPropertiesForKeys: [.fileSizeKey]) else { continue }
            for u in list where !busy.contains(u) && !u.lastPathComponent.hasPrefix("com.apple") {
                let s = AppTemp.treeSize(u)
                if (try? FileManager.default.removeItem(at: u)) != nil { freed += s }
            }
        }
        return freed
    }
    static func treeSize(_ u: URL) -> Int64 {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir)
        if !isDir.boolValue { return Int64((try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        var t: Int64 = 0
        if let en = FileManager.default.enumerator(at: u, includingPropertiesForKeys: [.fileSizeKey]) {
            for case let f as URL in en { t += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        }
        return t
    }
}

struct FilesView: View {
    @StateObject private var scanner = FileScanner()
    @State private var picking = false
    @State private var filter = "전체"
    @State private var mode = 0 // 0 큰 파일, 1 중복, 2 오래된 파일
    @State private var selected = Set<URL>()
    @State private var confirm = false
    @State private var limit = false
    @State private var resultText: String?
    @State private var tempSize: Int64 = AppTemp.size()
    @State private var quick: URL?
    @EnvironmentObject var quota: Quota
    @EnvironmentObject var store: Store

    private let kinds = ["전체", "동영상", "사진", "문서", "압축 파일", "오디오", "기타"]

    private var list: [FileItem] {
        let base: [FileItem]
        switch mode {
        case 1: base = scanner.dupGroups.flatMap { $0 }
        case 2: base = scanner.items.filter { ($0.modified ?? Date()) < Date().addingTimeInterval(-180 * 86400) }
        default: base = scanner.items
        }
        return filter == "전체" ? base : base.filter { $0.kind == filter }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if let f = scanner.folder {
                        Label(f.lastPathComponent, systemImage: "folder.fill")
                        Text("이 폴더 안에서만 찾아요. iOS는 다른 앱의 내부 파일이나 아이폰 전체를 검사하도록 허용하지 않아요.").font(.caption).foregroundColor(.secondary)
                    } else {
                        Text("파일 앱에서 정리할 폴더를 골라 주세요(예: ‘나의 iPhone’, ‘다운로드’, iCloud Drive 폴더).").font(.subheadline)
                    }
                    Button(scanner.folder == nil ? "폴더 고르기" : "다른 폴더 고르기") { picking = true }
                    if scanner.folder != nil { Button("다시 검사") { Task { await scanner.scan() } }.disabled(scanner.scanning) }
                } header: { Text("검사할 위치") }

                Section {
                    HStack {
                        VStack(alignment: .leading) {
                            Text("앱 임시 파일").font(.subheadline)
                            Text(Fmt.bytes(tempSize)).font(.caption).foregroundColor(.secondary)
                        }
                        Spacer()
                        Button("비우기") {
                            let f = AppTemp.clean(keeping: CompressQueue.shared.busyFiles)
                            tempSize = AppTemp.size(); resultText = "앱 임시 파일 \(Fmt.bytes(f))를 비웠어요."
                        }.disabled(tempSize == 0)
                    }
                    Text("다른 앱의 캐시는 iOS가 직접 관리해요. 설정 › 일반 › iPhone 저장 공간에서 앱별 용량을 확인하고 ‘앱 정리하기’를 쓸 수 있어요.").font(.caption).foregroundColor(.secondary)
                } header: { Text("정크 정리") }

                if let r = resultText { Section { Label(r, systemImage: "checkmark.circle.fill").foregroundColor(.green) } }

                if scanner.scanning {
                    Section { HStack { ProgressView(); Text(scanner.progress).font(.subheadline) } }
                } else if scanner.folder != nil {
                    Section {
                        Picker("보기", selection: $mode) {
                            Text("큰 파일").tag(0); Text("똑같은 파일").tag(1); Text("오래된 파일").tag(2)
                        }.pickerStyle(.segmented)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack { ForEach(kinds, id: \.self) { k in
                                Button(k) { filter = k }.buttonStyle(.bordered).tint(filter == k ? .brand : .gray)
                            } }
                        }
                        if scanner.truncated { Text("파일이 너무 많아 2만 개까지만 검사했어요.").font(.caption).foregroundColor(.orange) }
                        if mode == 1 { Text("크기와 내용(SHA-256)이 완전히 같은 파일이에요. 이름만 같은 파일은 포함하지 않아요.").font(.caption).foregroundColor(.secondary) }
                        if mode == 2 { Text("180일 넘게 수정되지 않은 파일이에요. 오래됐다고 필요 없는 것은 아니니 직접 확인해 주세요.").font(.caption).foregroundColor(.secondary) }
                    }
                    Section {
                        if list.isEmpty { Text("해당하는 파일이 없어요.").foregroundColor(.secondary) }
                        ForEach(list.prefix(500)) { f in row(f) }
                    } header: { Text("\(list.count)개 · \(Fmt.bytes(list.reduce(0) { $0 + $1.size }))") }
                }
                Section { AdBannerBar() }
            }
            .navigationTitle("파일")
            .safeAreaInset(edge: .bottom) {
                if !selected.isEmpty {
                    let sel = scanner.items.filter { selected.contains($0.url) }
                    Button { if quota.canUse(.delete, count: sel.count) { confirm = true } else { limit = true } } label: {
                        Text("\(sel.count)개 삭제 · \(Fmt.bytes(sel.reduce(0) { $0 + $1.size }))").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 12)
                    }.buttonStyle(.borderedProminent).tint(.red).padding().background(.ultraThinMaterial)
                }
            }
            .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { r in
                if case .success(let u) = r { selected.removeAll(); scanner.setFolder(u) }
            }
            .alert("파일을 삭제할까요?", isPresented: $confirm) {
                Button("취소", role: .cancel) {}
                Button("삭제", role: .destructive) {
                    let sel = scanner.items.filter { selected.contains($0.url) }
                    let r = scanner.delete(sel)
                    quota.consume(.delete, r.ok)
                    selected.removeAll()
                    resultText = "\(r.ok)개 삭제, \(Fmt.bytes(r.bytes)) 확보" + (r.failed > 0 ? " · \(r.failed)개 실패" : "")
                    if r.ok > 0 { Interstitials.shared.afterTaskCompleted(premium: store.isPremium) }
                }
            } message: { Text("파일 앱에서 지운 파일은 위치에 따라 ‘최근 삭제된 항목’에 남거나 바로 지워질 수 있어요. 되돌릴 수 없을 수도 있어요.") }
            .sheet(isPresented: $limit) { LimitSheet(feature: .delete) }
            .quickLookPreview($quick)
            .onAppear { tempSize = AppTemp.size() }
        }
    }

    private func row(_ f: FileItem) -> some View {
        let on = selected.contains(f.url)
        return HStack(spacing: 10) {
            Button { if on { selected.remove(f.url) } else { selected.insert(f.url) } } label: {
                Image(systemName: on ? "checkmark.circle.fill" : "circle").foregroundColor(on ? .red : .secondary).font(.title3)
            }.buttonStyle(.plain).accessibilityLabel(on ? "선택됨" : "선택")
            VStack(alignment: .leading, spacing: 2) {
                Text(f.name).font(.subheadline).lineLimit(1)
                Text("\(f.kind) · \(Fmt.bytes(f.size)) · \(f.modified.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "-")").font(.caption).foregroundColor(.secondary)
                if let p = parentPath(f) { Text(p).font(.caption2).foregroundColor(.secondary).lineLimit(1) }
            }
            Spacer()
            Button { quick = f.url } label: { Image(systemName: "eye") }.buttonStyle(.plain).foregroundColor(.brand)
        }
    }

    private func parentPath(_ f: FileItem) -> String? {
        guard let root = scanner.folder else { return nil }
        let p = f.url.deletingLastPathComponent().path.replacingOccurrences(of: root.path, with: "")
        return p.isEmpty ? nil : "…" + p
    }
}
