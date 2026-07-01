import Foundation

// Talks to the Pocket bridge's app-facing API (APP_BRIDGE_CONTRACT.md):
//   POST /app/v1/auth/apple   — verify Apple identity token, mint account session
//   POST /app/v1/pair/new     — desktop mints a one-time pairing code for the phone
//
// The public host comes from Config.connectURL (Cloudflare tunnel), never a
// hard-coded 127.0.0.1 — the phone must reach it over the internet.

// MARK: - Bridge bearer token (ported from pocket-pair.py read_token())
enum BridgeToken {
    // LaunchAgent plist that carries BRIDGE_TOKEN in its EnvironmentVariables.
    private static let plistPath = NSString(string: "~/Library/LaunchAgents/ai.studio.hermes-bridge.plist").expandingTildeInPath

    /// Resolve the bridge master token: env var first, then the LaunchAgent plist.
    /// Returns nil if missing or an unconfigured placeholder.
    static func read() -> String? {
        if let env = ProcessInfo.processInfo.environment["BRIDGE_TOKEN"], !env.isEmpty {
            return sanitize(env)
        }
        guard let data = FileManager.default.contents(atPath: plistPath),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let envVars = plist["EnvironmentVariables"] as? [String: Any],
              let token = envVars["BRIDGE_TOKEN"] as? String
        else { return nil }
        return sanitize(token)
    }

    private static func sanitize(_ raw: String) -> String? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty || t.lowercased().hasPrefix("change-me") { return nil }
        return t
    }
}

// MARK: - Client
struct BridgeError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

struct AppleAuthResult {
    let sessionToken: String
    let expiresAt: String?
    let displayName: String?
}

struct PairCode {
    let code: String
    let ttl: Int   // seconds until the code expires (bridge says 5 min)
}

final class BridgeClient {
    let baseURL: String   // e.g. https://pocket.tsai.cash
    init(baseURL: String) { self.baseURL = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL }

    /// Host portion of baseURL (for the QR payload's host= param).
    var host: String { URL(string: baseURL)?.host ?? baseURL }
    /// Scheme portion of baseURL (for the QR payload's scheme= param).
    var scheme: String { URL(string: baseURL)?.scheme ?? "https" }

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
                guard let session = json["session"] as? [String: Any],
                      let token = session["token"] as? String, !token.isEmpty else {
                    return completion(.failure(BridgeError(message: "回應缺少 session.token")))
                }
                let user = json["user"] as? [String: Any]
                completion(.success(AppleAuthResult(
                    sessionToken: token,
                    expiresAt: session["expires_at"] as? String,
                    displayName: user?["display_name"] as? String)))
            }
        }
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
