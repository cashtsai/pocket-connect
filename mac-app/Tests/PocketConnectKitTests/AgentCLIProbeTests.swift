import XCTest
@testable import PocketConnectKit

final class AgentCLIProbeTests: XCTestCase {

    // MARK: claude auth status(JSON)

    func testClaudeLoggedInWithAccount() {
        let json = """
        {
          "loggedIn": true,
          "authMethod": "claude.ai",
          "apiProvider": "firstParty",
          "email": "cash@example.com",
          "subscriptionType": "max"
        }
        """
        XCTAssertEqual(AgentCLIProbe.parseStatus(for: .claude, exitCode: 0, output: json),
                       .connected(account: "cash@example.com · max"))
    }

    func testClaudeLoggedInWithoutOptionalFields() {
        XCTAssertEqual(AgentCLIProbe.parseStatus(for: .claude, exitCode: 0,
                                                 output: #"{"loggedIn": true}"#),
                       .connected(account: nil))
    }

    func testClaudeLoggedOut() {
        XCTAssertEqual(AgentCLIProbe.parseStatus(for: .claude, exitCode: 0,
                                                 output: #"{"loggedIn": false}"#),
                       .notLoggedIn)
    }

    func testClaudeNonZeroExitIsNotLoggedIn() {
        XCTAssertEqual(AgentCLIProbe.parseStatus(for: .claude, exitCode: 1,
                                                 output: #"{"loggedIn": true}"#),
                       .notLoggedIn)
    }

    func testClaudeGarbageOutputIsNotLoggedIn() {
        XCTAssertEqual(AgentCLIProbe.parseStatus(for: .claude, exitCode: 0, output: "boom"),
                       .notLoggedIn)
        XCTAssertEqual(AgentCLIProbe.parseStatus(for: .claude, exitCode: 0, output: ""),
                       .notLoggedIn)
    }

    func testClaudeJSONSurroundedByNoise() {
        // 保守解析:抓第一個 { 到最後一個 }。
        let noisy = "warning: something\n{\"loggedIn\": true, \"email\": \"a@b.c\"}\n"
        XCTAssertEqual(AgentCLIProbe.parseStatus(for: .claude, exitCode: 0, output: noisy),
                       .connected(account: "a@b.c"))
    }

    // MARK: codex login status(純文字)

    func testCodexLoggedIn() {
        XCTAssertEqual(AgentCLIProbe.parseStatus(for: .codex, exitCode: 0,
                                                 output: "Logged in using ChatGPT\n"),
                       .connected(account: "Logged in using ChatGPT"))
    }

    func testCodexNotLoggedIn() {
        // 實測:未登入輸出 "Not logged in"、exit 1。
        XCTAssertEqual(AgentCLIProbe.parseStatus(for: .codex, exitCode: 1,
                                                 output: "Not logged in"),
                       .notLoggedIn)
    }

    func testCodexNotLoggedInTextEvenWithZeroExit() {
        // "Not logged in" 也含 "logged in" 子字串 — 不能誤判成已登入。
        XCTAssertEqual(AgentCLIProbe.parseStatus(for: .codex, exitCode: 0,
                                                 output: "Not logged in"),
                       .notLoggedIn)
    }

    func testCodexNonZeroExitIsNotLoggedIn() {
        XCTAssertEqual(AgentCLIProbe.parseStatus(for: .codex, exitCode: 1,
                                                 output: "Logged in using ChatGPT"),
                       .notLoggedIn)
    }

    // MARK: 執行檔探測(GUI PATH 沒 shell profile → 掃常見位置)

    func testResolveBinaryPrefersLocalBin() {
        let found = AgentCLIProbe.resolveBinary(
            named: "claude", home: "/Users/t", pathVariable: "/usr/bin:/bin",
            isExecutable: { $0 == "/Users/t/.local/bin/claude" || $0 == "/usr/local/bin/claude" })
        XCTAssertEqual(found, "/Users/t/.local/bin/claude")
    }

    func testResolveBinaryFallsBackToPATHEntries() {
        let found = AgentCLIProbe.resolveBinary(
            named: "codex", home: "/Users/t", pathVariable: "/weird/place",
            isExecutable: { $0 == "/weird/place/codex" })
        XCTAssertEqual(found, "/weird/place/codex")
    }

    func testResolveBinaryMissing() {
        XCTAssertNil(AgentCLIProbe.resolveBinary(
            named: "claude", home: "/Users/t", pathVariable: nil,
            isExecutable: { _ in false }))
    }

    func testCandidateDirectoriesDeduplicatesAndKeepsOrder() {
        let dirs = AgentCLIProbe.candidateDirectories(
            home: "/Users/t", pathVariable: "/usr/bin:/opt/homebrew/bin:/extra")
        XCTAssertEqual(dirs.first, "/Users/t/.local/bin")
        XCTAssertEqual(dirs.filter { $0 == "/usr/bin" }.count, 1)
        XCTAssertEqual(dirs.filter { $0 == "/opt/homebrew/bin" }.count, 1)
        XCTAssertTrue(dirs.contains("/extra"))
    }

    func testAugmentedPATHContainsLocalBin() {
        let path = AgentCLIProbe.augmentedPATH(home: "/Users/t", existing: "/usr/bin")
        XCTAssertTrue(path.hasPrefix("/Users/t/.local/bin:"))
        XCTAssertTrue(path.contains("/usr/bin"))
    }
}
