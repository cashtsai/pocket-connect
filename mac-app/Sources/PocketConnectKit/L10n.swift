import Foundation

/// 桌面端的字串查表。
///
/// ## 為什麼有這支(2026-10-18)
///
/// 一星風險排查查到:**整個桌面 App 只有繁體中文**,`lproj` / `.strings` 零命中,
/// 而 iOS 那支有 en / zh-Hans / zh-Hant 三語。也就是說一個英語使用者在
/// App Store 看英文介紹、下載英文 App,被告知「要先裝桌面端」—— 裝完打開,
/// **全部是中文**。而桌面端是**必經步驟**,不是選配。
///
/// ## 慣例:key = 繁體中文原字串
///
/// 與 iOS 的 `L10n.t` 完全一致(見 `Pocket iOS/App/Localization.swift`)。
/// 好處是呼叫點讀起來還是人話,而且**翻譯缺漏時自動回退成中文** —— 不會變成
/// 畫面上一串 `onboarding.welcome.title` 那種事故。
///
/// ## 它查哪裡
///
/// `String(localized:)` 查 `Bundle.main`。對 `.app` 來說就是
/// `Contents/Resources/<lang>.lproj/Localizable.strings`,由
/// `packaging/build_dmg.sh` 放進去。
///
/// 跑 `swift test` / `swift run` 時沒有 `.app` bundle,查不到表 → 回退成 key
/// (繁中),**與現況完全一致**,所以不會影響既有測試。
///
/// ## 插值
///
/// `L10n.t("找不到 \(name)")` 的 key 會是 `找不到 %@` —— 與 `.strings` 的
/// 格式標記一致。這是 `String.LocalizationValue` 自動做的,不要自己拼。
///
/// ## ⚠️ 數字一定要先轉成 String
///
/// `String.LocalizationValue` 對 `Int` 會做**在地化數字格式**,也就是加千分位:
///
///     String(localized: "埠 \(8081) 被 \(4242) 占用")
///     → "埠 8,081 被 4,242 占用"        ← 實測
///
/// 對 PID、port、exit code、OSStatus 這種**識別碼**來說那是錯的 ——
/// 使用者照著複製 `lsof -nP -iTCP:8,081` 會是廢的。
///
/// 所以:**插值數字一律寫 `\(String(port))`,不要寫 `\(port)`。**
/// (2026-10-18 實測踩到:`BridgeEnvironmentTests` 的
///  `testPortBusyChecklistNamesTheOccupantAndHowToLookItUp` 當場紅,
///  因為 detail 裡的 PID 變成 `4,242`。測試擋下了一個會出貨的錯。)
public enum L10n {
    public static func t(_ key: String.LocalizationValue) -> String {
        String(localized: key)
    }

    /// key 本身就含 printf 格式符、要交給 `String(format:)` 的樣板。
    /// 走 `t(_:)` 會被 `String.LocalizationValue` 當成插值而改寫 key。
    public static func raw(_ key: String) -> String {
        Bundle.main.localizedString(forKey: key, value: key, table: nil)
    }
}
