import Foundation
import PocketConnectKit

// Talks to the Pocket bridge's app-facing API (APP_BRIDGE_CONTRACT.md):
//   POST /app/v1/auth/apple   — verify Apple identity token, mint account session
//   POST /app/v1/pair/new     — desktop mints a one-time pairing code for the phone
//
// The public host comes from Config.connectURL (Cloudflare tunnel), never a
// hard-coded 127.0.0.1 — the phone must reach it over the internet.

// MARK: - Bridge bearer token (ported from pocket-pair.py read_token())
enum BridgeToken {
    // 使用者在「連線設定」手動貼的金鑰（自動讀不到時用）。
    private static let overrideKey = "pocketBridgeTokenOverride"

    /// 讀到的金鑰 + 它從哪來（UI 要說得出來源，不然使用者無從判斷對不對）。
    struct Resolved {
        let token: String
        let source: BridgeTokenSource
    }

    /// 讓使用者手動設/清金鑰（連線設定的貼上欄位）。
    static func setOverride(_ token: String?) {
        let t = token?.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set((t?.isEmpty ?? true) ? nil : t, forKey: overrideKey)
    }

    /// Resolve the bridge master token: 手動覆寫 → env var → LaunchAgent plist。
    /// plist 依序找 **Pocket 自己裝的** bridge，再退到開發機上既有的 Hermes bridge
    /// —— 一台全新的 Mac 只會有前者，開發機兩者都有，順序決定「用自己裝的那份」。
    /// Returns nil if missing or an unconfigured placeholder.
    static func resolve(layout: BridgeInstallLayout? = nil) -> Resolved? {
        if let manual = UserDefaults.standard.string(forKey: overrideKey),
           let s = BridgeTokenReader.sanitize(manual) {
            return Resolved(token: s, source: .manualOverride)
        }
        if let env = ProcessInfo.processInfo.environment["BRIDGE_TOKEN"],
           let s = BridgeTokenReader.sanitize(env) {
            return Resolved(token: s, source: .environment)
        }
        let home = NSHomeDirectory()
        let effective = layout ?? BridgeInstallLayout.resolve(
            home: home,
            environment: ProcessInfo.processInfo.environment,
            bundledBridgePath: BridgeBootstrap.bundledBridgePath())
        for candidate in BridgeTokenReader.candidatePlists(layout: effective) {
            guard let data = FileManager.default.contents(atPath: candidate.path),
                  let token = BridgeTokenReader.parse(plistData: data) else { continue }
            return Resolved(token: token, source: candidate.source)
        }
        return nil
    }

    /// 舊呼叫點的相容入口 — 只要金鑰字串。
    static func read() -> String? { resolve()?.token }
}

// MARK: - Client
struct BridgeError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

struct AppleAuthResult {
    let sessionToken: String
    let expiresAt: TimeInterval?
    let displayName: String?
}

struct AppleWebAuthAttempt {
    let flowID: String
    let pollSecret: String
    let authorizationURL: URL
    let expiresAt: Date
    let pollInterval: TimeInterval
}

struct AppleWebIdentity {
    let appleUserID: String
    let identityToken: String
    let displayName: String?
    let email: String?
}

enum AppleWebAuthStatus {
    case pending
    case complete(AppleWebIdentity)
    case failed(String)
}

struct PairCode {
    let code: String
    let ttl: Int   // seconds until the code expires (bridge says 5 min)
}

final class BridgeClient {
    let baseURL: String          // desktop API base, usually http://127.0.0.1:8081
    let pairingBaseURL: String   // phone-facing URL used in the QR payload

    init(baseURL: String, pairingBaseURL: String? = nil) {
        self.baseURL = Self.normalized(baseURL)
        self.pairingBaseURL = Self.normalized(pairingBaseURL ?? baseURL)
    }

    private static func normalized(_ raw: String) -> String {
        raw.hasSuffix("/") ? String(raw.dropLast()) : raw
    }

    /// Host portion of the phone-facing URL (for the QR payload's host= param).
    var host: String { URL(string: pairingBaseURL)?.host ?? pairingBaseURL }
    /// Scheme portion of the phone-facing URL (for the QR payload's scheme= param).
    var scheme: String { URL(string: pairingBaseURL)?.scheme ?? "https" }

    // POST /app/v1/auth/apple — authenticated by the Apple JWT itself.
    func authApple(appleUserID: String, identityToken: String, displayName: String?, email: String?,
                   completion: @escaping (Result<AppleAuthResult, Error>) -> Void) {
        var body: [String: Any] = ["apple_user_id": appleUserID, "identityToken": identityToken]
        if let displayName, !displayName.isEmpty { body["display_name"] = displayName }
        if let email, !email.isEmpty { body["email"] = email }
        post(path: "/app/v1/auth/apple", body: body, headers: [:]) { result in
            switch result {
            case .failure(let e): completion(.failure(e))
            case .success(let json):
                completion(Self.appleAuthResult(from: json))
            }
        }
    }

    // Developer ID builds cannot carry the native Sign in with Apple
    // entitlement, so they use Apple's web flow through the fixed-domain broker.
    func startWebAppleAuth(
        completion: @escaping (Result<AppleWebAuthAttempt, Error>) -> Void
    ) {
        post(
            path: "/app/v1/auth/apple/web/start",
            body: [:],
            headers: [:]
        ) { result in
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let json):
                guard let flowID = json["flow_id"] as? String, !flowID.isEmpty,
                      let pollSecret = json["poll_secret"] as? String, !pollSecret.isEmpty,
                      let rawURL = json["authorization_url"] as? String,
                      let authorizationURL = URL(string: rawURL),
                      authorizationURL.scheme == "https",
                      let expiresAt = Self.number(json["expires_at"])
                else {
                    return completion(.failure(BridgeError(message: "登入服務回應格式不完整")))
                }
                let interval = max(1, min(5, Self.number(json["poll_interval"]) ?? 2))
                completion(.success(AppleWebAuthAttempt(
                    flowID: flowID,
                    pollSecret: pollSecret,
                    authorizationURL: authorizationURL,
                    expiresAt: Date(timeIntervalSince1970: expiresAt),
                    pollInterval: interval
                )))
            }
        }
    }

    func pollWebAppleAuth(
        _ attempt: AppleWebAuthAttempt,
        completion: @escaping (Result<AppleWebAuthStatus, Error>) -> Void
    ) {
        post(
            path: "/app/v1/auth/apple/web/status",
            body: ["flow_id": attempt.flowID, "poll_secret": attempt.pollSecret],
            headers: [:]
        ) { result in
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let json):
                switch json["status"] as? String {
                case "pending", "processing":
                    completion(.success(.pending))
                case "complete":
                    guard let identity = json["identity"] as? [String: Any],
                          let appleUserID = identity["apple_user_id"] as? String,
                          !appleUserID.isEmpty,
                          let identityToken = identity["identity_token"] as? String,
                          !identityToken.isEmpty else {
                        return completion(.failure(
                            BridgeError(message: "登入服務回應缺少 Apple identity proof")
                        ))
                    }
                    completion(.success(.complete(AppleWebIdentity(
                        appleUserID: appleUserID,
                        identityToken: identityToken,
                        displayName: identity["display_name"] as? String,
                        email: identity["email"] as? String
                    ))))
                case "cancelled":
                    completion(.success(.failed("已取消 Apple 登入")))
                case "failed":
                    completion(.success(.failed("Apple 登入驗證失敗,請重新嘗試。")))
                default:
                    completion(.failure(BridgeError(message: "登入服務回應了未知狀態")))
                }
            }
        }
    }

    private static func appleAuthResult(
        from json: [String: Any]
    ) -> Result<AppleAuthResult, Error> {
        guard let session = json["session"] as? [String: Any],
              let token = session["token"] as? String, !token.isEmpty else {
            return .failure(BridgeError(message: "回應缺少 session.token"))
        }
        let user = json["user"] as? [String: Any]
        return .success(AppleAuthResult(
            sessionToken: token,
            expiresAt: number(session["expires_at"]),
            displayName: user?["display_name"] as? String
        ))
    }

    private static func number(_ value: Any?) -> TimeInterval? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return TimeInterval(string) }
        return nil
    }

    // POST /app/v1/pair/new — needs BOTH the bridge bearer and the account session.
    func pairNew(bridgeToken: String, sessionToken: String,
                 completion: @escaping (Result<PairCode, Error>) -> Void) {
        let headers = [
            "Authorization": "Bearer \(bridgeToken)",
            "X-Pocket-Account-Session": sessionToken,
        ]
        post(path: "/app/v1/pair/new", body: [:], headers: headers) { result in
            switch result {
            case .failure(let e): completion(.failure(e))
            case .success(let json):
                guard let code = json["code"] as? String, !code.isEmpty else {
                    return completion(.failure(BridgeError(message: "回應缺少 code")))
                }
                let ttl = (json["ttl"] as? Int) ?? 300
                completion(.success(PairCode(code: code, ttl: ttl)))
            }
        }
    }

    // MARK: - Paired-device management (bridge token only, no account session)

    struct PairedDevice: Identifiable {
        let id: String            // short-hash token id (used for revoke)
        let name: String
        let platform: String?
        let accountBound: Bool
        let lastSeen: Date?
    }

    /// GET /pair/devices — list the phones paired to this Mac's bridge.
    func listDevices(completion: @escaping (Result<[PairedDevice], Error>) -> Void) {
        func done(_ r: Result<[PairedDevice], Error>) { DispatchQueue.main.async { completion(r) } }
        guard let token = BridgeToken.read() else {
            return done(.failure(BridgeError(message: "找不到 BRIDGE_TOKEN")))
        }
        guard let url = URL(string: baseURL + "/pair/devices") else {
            return done(.failure(BridgeError(message: "無效的網址")))
        }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("PocketConnect/1.0", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { data, resp, err in
            if let err { return done(.failure(err)) }
            let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? nil
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                let detail = (json?["detail"] as? String) ?? "HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0)"
                return done(.failure(BridgeError(message: detail)))
            }
            let arr = (json?["devices"] as? [[String: Any]]) ?? []
            let devices = arr.compactMap { d -> PairedDevice? in
                guard let id = d["id"] as? String, !id.isEmpty else { return nil }
                return PairedDevice(
                    id: id, name: (d["name"] as? String) ?? "device",
                    platform: d["platform"] as? String,
                    accountBound: (d["account_bound"] as? Bool) ?? false,
                    lastSeen: (d["last_seen"] as? Double).map { Date(timeIntervalSince1970: $0) })
            }
            done(.success(devices))
        }.resume()
    }

    /// POST /pair/revoke — unpair a device by id. Returns how many were removed.
    func revoke(id: String, completion: @escaping (Result<Int, Error>) -> Void) {
        func done(_ r: Result<Int, Error>) { DispatchQueue.main.async { completion(r) } }
        guard let token = BridgeToken.read() else {
            return done(.failure(BridgeError(message: "找不到 BRIDGE_TOKEN")))
        }
        guard let url = URL(string: baseURL + "/pair/revoke") else {
            return done(.failure(BridgeError(message: "無效的網址")))
        }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["id": id])
        URLSession.shared.dataTask(with: req) { data, resp, err in
            if let err { return done(.failure(err)) }
            let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? nil
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return done(.failure(BridgeError(message: (json?["detail"] as? String) ?? "撤銷失敗")))
            }
            done(.success((json?["revoked"] as? Int) ?? 0))
        }.resume()
    }

    // MARK: - AI 用量 (bridge token only, no account session)

    /// GET /app/v1/usage — Codex/Claude 本機額度快照。bridge 端自帶 10 秒
    /// 快取,所以照控制台既有的 30 秒 refresh 輪詢不會造成重複 jsonl 掃描。
    func fetchUsage(completion: @escaping (Result<UsageSnapshot, Error>) -> Void) {
        func done(_ r: Result<UsageSnapshot, Error>) { DispatchQueue.main.async { completion(r) } }
        guard let token = BridgeToken.read() else {
            return done(.failure(BridgeError(message: "找不到 BRIDGE_TOKEN")))
        }
        guard let url = URL(string: baseURL + "/app/v1/usage") else {
            return done(.failure(BridgeError(message: "無效的網址")))
        }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("PocketConnect/1.0", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { data, resp, err in
            if let err { return done(.failure(err)) }
            let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? nil
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                let detail = (json?["detail"] as? String) ?? "HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0)"
                return done(.failure(BridgeError(message: detail)))
            }
            done(.success(UsageSnapshot(json: json ?? [:])))
        }.resume()
    }

    // MARK: - Low-level POST returning a JSON object, hopping back to main thread.
    private func post(path: String, body: [String: Any], headers: [String: String],
                      completion: @escaping (Result<[String: Any], Error>) -> Void) {
        func done(_ r: Result<[String: Any], Error>) { DispatchQueue.main.async { completion(r) } }
        guard let url = URL(string: baseURL + path) else {
            return done(.failure(BridgeError(message: "無效的網址")))
        }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("PocketConnect/1.0", forHTTPHeaderField: "User-Agent")
        headers.forEach { req.setValue($1, forHTTPHeaderField: $0) }
        req.httpBody = (try? JSONSerialization.data(withJSONObject: body)) ?? Data("{}".utf8)

        URLSession.shared.dataTask(with: req) { data, resp, err in
            if let err { return done(.failure(err)) }
            guard let http = resp as? HTTPURLResponse else {
                return done(.failure(BridgeError(message: "沒有 HTTP 回應")))
            }
            let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? nil
            guard (200..<300).contains(http.statusCode) else {
                let detail = (json?["detail"] as? String) ?? (json?["error"] as? String) ?? "HTTP \(http.statusCode)"
                return done(.failure(BridgeError(message: detail)))
            }
            done(.success(json ?? [:]))
        }.resume()
    }
}
