import Foundation

// Build the pairing QR payload — MUST stay identical to pocket-pair.py:
//   pocket://pair?scheme=<scheme>&host=<host>&hosts=<csv>&code=<code>
//
// **v2 `hosts=`**(2026-10-11):依優先序的候選清單,App 的自動選路名單就是從
// 這裡來的(在家走 LAN 直連、手機有 tailnet 走 tailnet、出門退回公網過路)。
//
// 為什麼要補 —— 這是個靜默的功能缺口:`HostCandidates.gather()` 早就寫好、
// 也有測試,但**只被 CloudDiscovery(CloudKit)呼叫**,而 CloudKit 在出貨的
// kernel build 是關掉的。出貨路徑(QR)只帶 v1 單一 host = 公網 tunnel,所以
// 照官方安裝流程配對的使用者**拿不到任何私網候選,在家也繞公網出去**。
// 候選算得出來,只是送錯管道。
//
// v1 的 `scheme`/`host` 鍵**保留**(同 pocket-pair.py)—— 舊版 App 掃 v2 QR
// 照樣配得起來,只是沒有多路徑。
public func pairingPayload(scheme: String, host: String, code: String,
                    hosts: [String] = []) -> String {
    func enc(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .pocketQueryValue) ?? s
    }
    var out = "pocket://pair?scheme=\(enc(scheme))&host=\(enc(host))"
    if !hosts.isEmpty {
        out += "&hosts=\(enc(hosts.joined(separator: ",")))"
    }
    out += "&code=\(enc(code))"
    return out
}

extension CharacterSet {
    /// 與 Python `urllib.parse.quote()` 的預設行為對齊(safe="/")——
    /// unreserved 字元加 `/` 不轉義,其餘全轉。
    ///
    /// ⚠️ **不要**改回 `.urlQueryAllowed`:它不會轉義 `,` 與 `:`,兩個生產者就
    /// 會吐出不同位元組。iOS 端是先 percent-decode 再用 `,` 切,所以兩種寫法
    /// 目前都解得開 —— 但「同一份 payload 由兩支程式產生」這件事只要哪天不一致
    /// 就會變成很難查的 bug,而檔頭契約已經寫了 MUST stay identical。
    public static let pocketQueryValue: CharacterSet = {
        var cs = CharacterSet.alphanumerics
        cs.insert(charactersIn: "_.-~/")
        return cs
    }()
}
