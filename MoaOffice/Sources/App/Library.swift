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

struct DocFile: Identifiable, Hashable {
    let url: URL
    let modified: Date
    let size: Int
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
            return DocFile(url: u, modified: v?.contentModificationDate ?? .distantPast, size: v?.fileSize ?? 0)
        }.sorted { $0.modified > $1.modified }
    }

    /// 외부(파일 앱·공유)에서 받은 파일을 복사해 열기
    func importFile(_ src: URL) {
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
        reload()
        opened = files.first { $0.url.standardizedFileURL == dest.standardizedFileURL }
    }

    func touch(_ f: DocFile) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: f.url.path)
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
        }
    }
}
