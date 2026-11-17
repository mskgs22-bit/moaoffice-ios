import Foundation
import SwiftUI

enum DocKind {
    case pdf, hwp, office, image

    static func of(_ url: URL) -> DocKind? {
        switch url.pathExtension.lowercased() {
        case "pdf", "ai": return .pdf
        case "hwp", "hwpx": return .hwp
        case "doc", "docx", "xls", "xlsx", "csv": return .office
        case "psd", "psb": return .image
        default: return nil
        }
    }

    static let extensions = ["pdf", "ai", "hwp", "hwpx", "doc", "docx", "xls", "xlsx", "csv", "psd", "psb"]
}

/// 문서가 어디서 왔는지 (다른 앱에서 받은 것 / 스캔 / 직접 연 것)
enum DocSource: String { case received, scanned, opened }

struct DocFile: Identifiable, Hashable {
    let url: URL
    let modified: Date
    let size: Int
    var source: DocSource = .opened
    var id: URL { url }
    var name: String { url.lastPathComponent }
    var ext: String { url.pathExtension.uppercased() }
}

/// 앱 Documents 폴더가 곧 "내 문서" 목록이다. 파일은 기기 밖으로 나가지 않는다.
@MainActor
final class Library: ObservableObject {
    @Published private(set) var files: [DocFile] = []
    @Published var opened: DocFile?
    @Published var lastError: String?

    nonisolated static var folder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    init() { reload() }

    func reload() {
        let fm = FileManager.default
        let urls = (try? fm.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey], options: [.skipsHiddenFiles])) ?? []
        files = urls.compactMap { u -> DocFile? in
            guard DocKind.of(u) != nil else { return nil }
            let v = try? u.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            return DocFile(url: u, modified: v?.contentModificationDate ?? .distantPast, size: v?.fileSize ?? 0, source: source(of: u.lastPathComponent))
        }.sorted { $0.modified > $1.modified }
    }

    // MARK: 출처 기록 (파일 이름 → 출처, 기기 안에만 저장)
    private var sources: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: "docSources") as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "docSources") }
    }
    func source(of name: String) -> DocSource { DocSource(rawValue: sources[name] ?? "") ?? .opened }
    func setSource(_ s: DocSource, for name: String) { Self.recordSource(s, name: name) }
    nonisolated static func recordSource(_ s: DocSource, name: String) {
        var d = UserDefaults.standard.dictionary(forKey: "docSources") as? [String: String] ?? [:]
        d[name] = s.rawValue
        UserDefaults.standard.set(d, forKey: "docSources")
    }

    /// 이름이 겹치지 않는 새 파일 위치
    nonisolated static func uniqueURL(_ name: String) -> URL {
        let fm = FileManager.default
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        var dest = folder.appendingPathComponent(name)
        var n = 2
        while fm.fileExists(atPath: dest.path) { dest = folder.appendingPathComponent("\(base) (\(n)).\(ext)"); n += 1 }
        return dest
    }

    /// 앱에서 만든 문서(스캔·합치기 등)를 저장하고 목록에 올린다
    @discardableResult
    func saveNew(_ data: Data, name: String, source: DocSource, open: Bool = false) -> DocFile? {
        let dest = Self.uniqueURL(name)
        do { try data.write(to: dest, options: .atomic) } catch { lastError = error.localizedDescription; return nil }
        setSource(source, for: dest.lastPathComponent)
        reload()
        let f = files.first { $0.url.standardizedFileURL == dest.standardizedFileURL }
        if open { opened = f }
        return f
    }

    /// 다른 앱에서 "모아오피스로 열기"로 받은 파일
    func receiveFile(_ src: URL) { importFile(src, received: true) }

    /// 외부(파일 앱·공유)에서 받은 파일을 복사해 열기
    func importFile(_ src: URL, received: Bool = false) {
        let scoped = src.startAccessingSecurityScopedResource()
        defer { if scoped { src.stopAccessingSecurityScopedResource() } }
        guard DocKind.of(src) != nil else { lastError = String(localized: "This file type is not supported."); return }
        let fm = FileManager.default
        var dest = Self.folder.appendingPathComponent(src.lastPathComponent)
        if src.standardizedFileURL.path != dest.standardizedFileURL.path {
            var n = 2
            let base = src.deletingPathExtension().lastPathComponent, ext = src.pathExtension
            while fm.fileExists(atPath: dest.path) {
                dest = Self.folder.appendingPathComponent("\(base) (\(n)).\(ext)"); n += 1
            }
            do { try fm.copyItem(at: src, to: dest) } catch { lastError = error.localizedDescription; return }
        }
        try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: dest.path)
        if received { setSource(.received, for: dest.lastPathComponent) }
        reload()
        opened = files.first { $0.url.standardizedFileURL == dest.standardizedFileURL }
    }

    func touch(_ f: DocFile) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: f.url.path)
    }

    func rename(_ f: DocFile, to newName: String) {
        let clean = newName.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "/", with: "-")
        guard !clean.isEmpty else { return }
        let ext = f.url.pathExtension
        let target = Self.uniqueURL(clean.hasSuffix("." + ext) ? clean : clean + "." + ext)
        do { try FileManager.default.moveItem(at: f.url, to: target) } catch { lastError = error.localizedDescription; return }
        setSource(f.source, for: target.lastPathComponent)
        reload()
    }

    func delete(_ f: DocFile) {
        try? FileManager.default.removeItem(at: f.url)
        reload()
    }

    /// UI 테스트·스토어 스크린샷용 예제 문서
    nonisolated static func installDemoFiles() {
        guard let demo = Bundle.main.url(forResource: "Demo", withExtension: nil) else { return }
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(at: demo, includingPropertiesForKeys: nil)) ?? []
        for (i, u) in items.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).enumerated() {
            let dest = folder.appendingPathComponent(u.lastPathComponent)
            if !fm.fileExists(atPath: dest.path) { try? fm.copyItem(at: u, to: dest) }
            try? fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -Double(i) * 3600)], ofItemAtPath: dest.path)
            if ["Guide.pdf", "Report.hwp", "Budget.xlsx"].contains(u.lastPathComponent) { recordSource(.received, name: u.lastPathComponent) }
        }
    }
}
