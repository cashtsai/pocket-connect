import Foundation

// 桌面端自動更新的可測核心:版本比較 + GitHub Releases JSON 解析。
// 不引 Sparkle —— 這個 App 刻意零外部依賴,而且發行物本來就是
// GitHub Release 上的公證 DMG,releases/latest 的 API 回應就是現成的
// appcast。網路/掛載/換包等有副作用的部分在 App 殼(Updater.swift),
// 這裡只放純函式,單元測試釘行為。
public enum UpdateFeed {

    /// 一筆可更新的發行:版本、說明、DMG 與(可選)sha256 資產位置。
    public struct Release: Equatable {
        public let version: String     // 去掉 "v" 前綴的 tag,如 "0.4.1"
        public let notes: String       // release body(給更新對話框看)
        public let dmgURL: URL
        public let sha256URL: URL?
        public init(version: String, notes: String, dmgURL: URL, sha256URL: URL?) {
            self.version = version; self.notes = notes
            self.dmgURL = dmgURL; self.sha256URL = sha256URL
        }
    }

    /// 數字分段比較(0.4.1 vs 0.10.0 → 後者新;缺段補 0;非數字段忽略尾綴)。
    /// 回傳 true = `candidate` 比 `current` 新。
    public static func isNewer(candidate: String, than current: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            s.split(separator: ".").map { seg in
                Int(seg.prefix(while: { $0.isNumber })) ?? 0
            }
        }
        let a = parts(candidate), b = parts(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// 解析 GitHub `releases/latest` 的 JSON。挑第一個 .dmg 資產;同名 .sha256
    /// 資產(若有)一併帶回供下載後校驗。draft/prerelease 一律不給(正式通道)。
    public static func parse(_ data: Data) -> Release? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = obj["tag_name"] as? String,
              (obj["draft"] as? Bool) != true,
              (obj["prerelease"] as? Bool) != true,
              let assets = obj["assets"] as? [[String: Any]] else { return nil }
        var dmg: URL?
        var sha: URL?
        for a in assets {
            guard let name = a["name"] as? String,
                  let urlStr = a["browser_download_url"] as? String,
                  let url = URL(string: urlStr) else { continue }
            if dmg == nil, name.hasSuffix(".dmg") { dmg = url }
            if sha == nil, name.hasSuffix(".dmg.sha256") { sha = url }
        }
        guard let dmgURL = dmg else { return nil }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        return Release(version: version,
                       notes: (obj["body"] as? String) ?? "",
                       dmgURL: dmgURL,
                       sha256URL: sha)
    }
}
