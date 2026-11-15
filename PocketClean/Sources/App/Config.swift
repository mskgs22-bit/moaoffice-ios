import Foundation

/// 무료 한도 등 운영 설정. 기본값은 앱에 들어 있고, sevio.co.kr 의 설정 파일이 있으면 그 값으로 바꾼다(서버 없음, 정적 파일).
@MainActor
final class AppConfig: ObservableObject {
    static let shared = AppConfig()
    static let remoteURL = URL(string: "https://sevio.co.kr/pocketclean/config.json")!

    @Published var freeDeletesPerDay = 50
    @Published var rewardDeletes = 100
    @Published var rewardMaxPerDay = 3
    @Published var freeCompressPerDay = 1
    @Published var freeContactChangesPerDay = 10
    @Published var freeVaultImports = 30
    @Published var interstitialGapSec = 300
    @Published var interstitialMaxPerDay = 3
    @Published var notice: String?

    private struct Remote: Decodable {
        var freeDeletesPerDay: Int?; var rewardDeletes: Int?; var rewardMaxPerDay: Int?
        var freeCompressPerDay: Int?; var freeContactChangesPerDay: Int?; var freeVaultImports: Int?
        var interstitialGapSec: Int?; var interstitialMaxPerDay: Int?; var notice: String?
    }

    func refresh() async {
        if let d = UserDefaults.standard.data(forKey: "remoteConfig") { apply(d) }
        var req = URLRequest(url: Self.remoteURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        req.httpMethod = "GET"
        guard let res = try? await URLSession.shared.data(for: req),
              (res.1 as? HTTPURLResponse)?.statusCode == 200 else { return }
        if apply(res.0) { UserDefaults.standard.set(res.0, forKey: "remoteConfig") }
    }

    @discardableResult private func apply(_ data: Data) -> Bool {
        guard let r = try? JSONDecoder().decode(Remote.self, from: data) else { return false }
        if let v = r.freeDeletesPerDay, v >= 0 { freeDeletesPerDay = v }
        if let v = r.rewardDeletes, v >= 0 { rewardDeletes = v }
        if let v = r.rewardMaxPerDay, v >= 0 { rewardMaxPerDay = v }
        if let v = r.freeCompressPerDay, v >= 0 { freeCompressPerDay = v }
        if let v = r.freeContactChangesPerDay, v >= 0 { freeContactChangesPerDay = v }
        if let v = r.freeVaultImports, v >= 0 { freeVaultImports = v }
        if let v = r.interstitialGapSec, v >= 60 { interstitialGapSec = v }
        if let v = r.interstitialMaxPerDay, v >= 0 { interstitialMaxPerDay = v }
        notice = r.notice?.isEmpty == false ? r.notice : nil
        return true
    }
}

enum Feature: String { case delete, compress, contacts, vault }

/// 기능별 하루 사용량(기기 기준). 프리미엄이면 한도 없음.
@MainActor
final class Quota: ObservableObject {
    static let shared = Quota()
    var isPremium: @MainActor () -> Bool = { false }
    @Published private(set) var tick = 0

    private let d = UserDefaults.standard
    private var today: String {
        let f = DateFormatter(); f.calendar = Calendar(identifier: .gregorian); f.dateFormat = "yyyyMMdd"
        return f.string(from: Date())
    }
    private func key(_ f: Feature, _ s: String) -> String { "q_\(f.rawValue)_\(s)_\(today)" }

    func used(_ f: Feature) -> Int { f == .vault ? d.integer(forKey: "vault_imports_total") : d.integer(forKey: key(f, "used")) }
    var rewardsToday: Int { d.integer(forKey: key(.delete, "rewards")) }

    func limit(_ f: Feature) -> Int {
        let c = AppConfig.shared
        switch f {
        case .delete: return c.freeDeletesPerDay + rewardsToday * c.rewardDeletes
        case .compress: return c.freeCompressPerDay
        case .contacts: return c.freeContactChangesPerDay
        case .vault: return c.freeVaultImports
        }
    }

    /// 남은 개수. 프리미엄이면 nil(제한 없음)
    func remaining(_ f: Feature) -> Int? { isPremium() ? nil : max(0, limit(f) - used(f)) }

    func canUse(_ f: Feature, count: Int = 1) -> Bool { remaining(f).map { $0 >= count } ?? true }

    func consume(_ f: Feature, _ n: Int) {
        guard !isPremium(), n > 0 else { return }
        if f == .vault { d.set(used(.vault) + n, forKey: "vault_imports_total") }
        else { d.set(used(f) + n, forKey: key(f, "used")) }
        tick += 1
    }

    var canWatchReward: Bool { !isPremium() && rewardsToday < AppConfig.shared.rewardMaxPerDay }

    func grantReward() {
        d.set(rewardsToday + 1, forKey: key(.delete, "rewards"))
        tick += 1
    }
}
