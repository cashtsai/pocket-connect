import XCTest
@testable import PocketConnectKit

final class UsageModelsTests: XCTestCase {
    private func snapshot(_ jsonString: String) throws -> UsageSnapshot {
        let obj = try JSONSerialization.jsonObject(with: Data(jsonString.utf8))
        let dict = try XCTUnwrap(obj as? [String: Any])
        return UsageSnapshot(json: dict)
    }

    // 完整 payload:codex 可用 + claude 官方同步(工號範例原文)。
    func testFullPayloadParses() throws {
        let snap = try snapshot("""
        {
          "codex": {
            "available": true, "used_percent": 0.0, "remaining_percent": 100.0,
            "reset_at": "2026-07-11T00:32:09Z", "source": "codex_sessions_jsonl"
          },
          "claude": {
            "available": true, "official_synced": true,
            "five_hour": {"used_percent": 2.0, "remaining_percent": 98.0, "reset_at": "2026-07-11T13:30:00Z"},
            "seven_day": {"used_percent": 15.0, "remaining_percent": 85.0, "reset_at": "2026-07-17T01:00:00Z"},
            "source": "claude_statusline"
          }
        }
        """)
        let codex = try XCTUnwrap(snap.codex)
        XCTAssertTrue(codex.available)
        XCTAssertEqual(codex.window?.usedPercent, 0.0)
        XCTAssertEqual(codex.window?.remainingPercent, 100.0)
        XCTAssertNotNil(codex.window?.resetAt)

        let claude = try XCTUnwrap(snap.claude)
        XCTAssertTrue(claude.available)
        XCTAssertTrue(claude.officialSynced)
        XCTAssertEqual(claude.fiveHour?.usedPercent, 2.0)
        XCTAssertEqual(claude.sevenDay?.remainingPercent, 85.0)
        XCTAssertNotNil(claude.sevenDay?.resetAt)
        XCTAssertNil(claude.tokenUsage)
    }

    // 降級:statusline hook 未裝 → official_synced=false,只有 token_usage。
    func testClaudeFallbackTokenUsageOnly() throws {
        let snap = try snapshot("""
        {
          "codex": {"available": false},
          "claude": {
            "available": true, "official_synced": false,
            "five_hour": null, "seven_day": null,
            "source": "claude_projects_jsonl_fallback",
            "token_usage": {
              "input_tokens": 1200, "output_tokens": 3400,
              "cache_read_input_tokens": 99000, "cache_creation_input_tokens": 500
            }
          }
        }
        """)
        let codex = try XCTUnwrap(snap.codex)
        XCTAssertFalse(codex.available)
        XCTAssertNil(codex.window)

        let claude = try XCTUnwrap(snap.claude)
        XCTAssertTrue(claude.available)
        XCTAssertFalse(claude.officialSynced)
        XCTAssertNil(claude.fiveHour)
        XCTAssertNil(claude.sevenDay)
        let tokens = try XCTUnwrap(claude.tokenUsage)
        XCTAssertEqual(tokens.inputTokens, 1200)
        XCTAssertEqual(tokens.outputTokens, 3400)
        XCTAssertEqual(tokens.cacheReadInputTokens, 99000)
        XCTAssertEqual(tokens.cacheCreationInputTokens, 500)
    }

    // 兩個 provider 都缺席 / 完全空的回應 → 不 crash,全部 nil/false。
    func testAbsentProviders() throws {
        let both = try snapshot(#"{"codex": {"available": false}, "claude": {"available": false, "official_synced": false}}"#)
        XCTAssertFalse(both.codex?.available ?? true)
        XCTAssertFalse(both.claude?.available ?? true)

        let empty = try snapshot("{}")
        XCTAssertNil(empty.codex)
        XCTAssertNil(empty.claude)
    }

    // official_synced=true 但單一視窗過期為 null → 另一視窗照常可用。
    func testSingleNullWindowWhenSynced() throws {
        let snap = try snapshot("""
        {
          "claude": {
            "available": true, "official_synced": true,
            "five_hour": null,
            "seven_day": {"used_percent": 15.0, "remaining_percent": 85.0, "reset_at": "2026-07-17T01:00:00Z"}
          }
        }
        """)
        let claude = try XCTUnwrap(snap.claude)
        XCTAssertNil(claude.fiveHour)
        XCTAssertEqual(claude.sevenDay?.usedPercent, 15.0)
    }

    // 壞資料:型別錯亂、缺 remaining、整數百分比、爛日期 → 容錯不 throw。
    func testMalformedFieldsDegradeGracefully() throws {
        let snap = try snapshot("""
        {
          "codex": {"available": true, "used_percent": 40, "reset_at": "not-a-date"},
          "claude": {"available": true, "official_synced": true,
                     "five_hour": "oops", "seven_day": {"used_percent": "bad"}}
        }
        """)
        let window = try XCTUnwrap(snap.codex?.window)
        XCTAssertEqual(window.usedPercent, 40.0)
        XCTAssertEqual(window.remainingPercent, 60.0)  // 推導 100 - used
        XCTAssertNil(window.resetAt)
        XCTAssertNil(snap.claude?.fiveHour)
        XCTAssertNil(snap.claude?.sevenDay)
    }
}
