import CryptoKit
import XCTest
@testable import Parallax

final class ClaudeResetTests: XCTestCase {
    private let now = RenewalDate.parse("2026-11-10T00:00:00Z")!
    private func data(_ text: String) -> Data { Data(text.utf8) }
    private func parse(_ grants: [[String: Any]]) throws -> [LimitReset]? {
        ClaudeResets.parse(try JSONSerialization.data(withJSONObject: ["cedar_ember": ["eligible": true, "grants": grants]]), now: now)
    }

    func testCLIVersion() {
        for version in ["2.1.309", "2.1", "2.1.3.4"] {
            XCTAssertEqual(ClaudeResets.cliVersion(fromVersionOutput: data(version + " (Claude Code)\n")), version)
        }
        XCTAssertEqual(ClaudeResets.cliVersion(fromVersionOutput: data("2.1 beta")), "2.1")
        for output in ["garbage", "", "2", "2.1.3.4.5", "2.1-beta", "2.1x"] {
            XCTAssertNil(ClaudeResets.cliVersion(fromVersionOutput: data(output)))
        }
    }

    func testRequest() {
        let request = ClaudeResets.request(token: "synthetic", cliVersion: "2.1.309")
        XCTAssertEqual(request.url?.absoluteString, "https://api.anthropic.com/api/oauth/usage?cedar_ember=1&skip_spend=1")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.timeoutInterval, 15)
        let headers = ["Authorization": "Bearer synthetic", "anthropic-beta": "oauth-2025-04-20",
                       "Accept": "application/json", "x-app": "cli", "User-Agent": "claude-cli/2.1.309 (external, cli)"]
        XCTAssertEqual(request.allHTTPHeaderFields?.count, headers.count)
        for (name, value) in headers {
            XCTAssertEqual(request.value(forHTTPHeaderField: name), value)
        }
    }

    func testClaudeCodeGrantResponse() throws {
        let fixture = data(#"""
        {"cedar_ember": {"eligible": true, "ineligible_reason": null, "at_limit": true, "exhausted": ["seven_day_overage_included"],
         "grants": [
          {"id": "full-reset-2611", "label": "One full limit reset (November 2026)", "resets_total": 1, "resets_left": 1,
           "starts_at": "2026-11-10T21:30:00+00:00", "ends_at": "2026-12-10T22:00:00+00:00", "clears": ["seven_day", "seven_day_overage_included"],
           "paused": false, "usable_now": true, "use_requires_limit": false, "percent_used": {"seven_day": 94}, "blocking": [], "arm": null,
           "type": "weekly", "unavailable_reason": null, "gives_back_weekly": false},
          {"id": "free_reset_oct_2026", "label": "Free limit reset", "resets_total": 1, "resets_left": 1,
           "starts_at": "2026-10-21T00:45:00+00:00", "ends_at": "2026-12-16T04:59:00+00:00", "clears": ["seven_day", "seven_day_overage_included"],
           "paused": false, "usable_now": true, "use_requires_limit": false, "percent_used": {}, "blocking": [], "arm": null,
           "type": "weekly", "unavailable_reason": null, "gives_back_weekly": false},
          {"id": "launch-2610-fable", "label": "Fable reset", "resets_total": 1, "resets_left": 0,
           "starts_at": "2026-11-09T18:00:00+00:00", "ends_at": "2027-03-09T07:59:00+00:00", "clears": ["seven_day_overage_included"],
           "paused": false, "usable_now": false, "use_requires_limit": false, "percent_used": {}, "blocking": [], "arm": null,
           "type": "full", "unavailable_reason": "unavailable", "gives_back_weekly": true}],
         "next_grant_id": "full-reset-2611", "weekly_resets_at": "2026-11-16T18:00:00+00:00", "cooldown_until": null, "paused_held": false}}
        """#)
        let now = try XCTUnwrap(RenewalDate.parse("2026-11-10T23:00:00Z"))
        let weekly = LimitReset(kind: "weekly reset", count: 2,
                                expiresAt: try XCTUnwrap(RenewalDate.parse("2026-12-10T22:00:00Z")))
        XCTAssertEqual(ClaudeResets.parse(fixture, now: now), [weekly])
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture) as? [String: Any])
        var reset = try XCTUnwrap(object["cedar_ember"] as? [String: Any])
        var grants = try XCTUnwrap(reset["grants"] as? [[String: Any]])
        grants[2]["resets_left"] = 1
        grants[2]["usable_now"] = true
        reset["grants"] = grants
        object["cedar_ember"] = reset
        XCTAssertEqual(ClaudeResets.parse(try JSONSerialization.data(withJSONObject: object), now: now), [
            weekly, LimitReset(kind: "Fable reset", count: 1,
                               expiresAt: try XCTUnwrap(RenewalDate.parse("2027-03-09T07:59:00Z")))
        ])
    }

    func testCredentialIdentity() {
        let path = "/tmp/Cafe\u{301}/ClaudeConfig"
        let folder = URL(fileURLWithPath: path)
        let digest = SHA256.hash(data: Data(folder.path.precomposedStringWithCanonicalMapping.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(ClaudeResets.keychainService(configFolder: folder), "Claude Code-credentials-" + hex.prefix(8))
        XCTAssertEqual(ClaudeResets.keychainAccount("a b"), "claude-code-user")
        XCTAssertEqual(ClaudeResets.keychainAccount("a.b_2-3"), "a.b_2-3")
    }

    func testAccessToken() throws {
        func credentials(_ oauth: [String: Any]) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["claudeAiOauth": oauth])
        }
        XCTAssertEqual(ClaudeResets.accessToken(fromCredentials: try credentials(["accessToken": "synthetic", "expiresAt": now.addingTimeInterval(1).timeIntervalSince1970 * 1000]), now: now), "synthetic")
        XCTAssertEqual(ClaudeResets.accessToken(fromCredentials: try credentials(["accessToken": "synthetic"]), now: now), "synthetic")
        XCTAssertNil(ClaudeResets.accessToken(fromCredentials: try credentials(["accessToken": "synthetic", "expiresAt": now.timeIntervalSince1970 * 1000]), now: now))
        XCTAssertNil(ClaudeResets.accessToken(fromCredentials: data("{}"), now: now))
        XCTAssertNil(ClaudeResets.accessToken(fromCredentials: data("not JSON"), now: now))
    }

    func testSessionAndAvailability() throws {
        XCTAssertEqual(try parse([["resets_left": 1, "type": "session"]]), [LimitReset(kind: "5-hour reset", count: 1)])
        XCTAssertEqual(try parse([["resets_left": 1, "paused": true], ["resets_left": 0, "usable_now": false], ["type": "session"], ["resets_left": 1, "ends_at": "2026-11-10T00:00:00Z"]]), [])
        XCTAssertEqual(try parse([["resets_left": 0, "usable_now": true, "type": "session"]])?.first?.count, 1)
    }

    func testGroupingKindsAndOrder() throws {
        let resets = try XCTUnwrap(parse([
            ["resets_left": 1, "type": "full"],
            ["resets_left": 1, "gives_back_weekly": true],
            ["resets_left": 2, "clears": ["seven_day"], "ends_at": "2026-11-17T00:00:00Z"],
            ["resets_left": 3, "type": "weekly", "ends_at": "2026-11-15T00:00:00Z"],
            ["resets_left": 1, "type": "weekly"],
            ["resets_left": 1, "clears": ["five_hour"]]
        ]))
        XCTAssertEqual(resets.map(\.kind), ["5-hour reset", "weekly reset", "Fable reset", "full reset"])
        XCTAssertEqual(resets[1].count, 6)
        XCTAssertEqual(resets[1].expiresAt, RenewalDate.parse("2026-11-15T00:00:00Z"))
        XCTAssertNil(resets[0].expiresAt)
        XCTAssertEqual(try parse([["resets_left": 1, "clears": ["five_hour", "seven_day"]]])?.first?.kind, "full reset")
    }

    func testAbsentAndInvalidResponses() {
        XCTAssertEqual(ClaudeResets.parse(data(#"{"cedar_ember":{"eligible":false}}"#), now: now), [])
        XCTAssertEqual(ClaudeResets.parse(data("{}"), now: now), [])
        XCTAssertNil(ClaudeResets.parse(data("not JSON"), now: now))
        XCTAssertNil(ClaudeResets.parse(data("[]"), now: now))
    }

    func testStatusResetsAndFailureIsolation() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let resets = [LimitReset(kind: "5-hour reset", count: 1)]
        for failed in [false, true] {
            let status = try await ClaudeProvider.status(configFolder: folder, run: { _, arguments, _, _ in
                let text = arguments.first == "auth" ? #"{"loggedIn":true}"#
                    : failed ? #"{"result":"unreadable"}"# : #"{"result":"Current session: 6% used"}"#
                return CLIResult(status: 0, stdout: Data(text.utf8), stderr: Data())
            }, readResets: { received in
                XCTAssertFalse(failed, "Must not read resets after usage failure")
                XCTAssertEqual(received, folder)
                return resets
            })
            XCTAssertEqual(status.resets, failed ? nil : resets)
            XCTAssertEqual(status.usageError == nil, !failed)
        }
        let status = try await ClaudeProvider.status(configFolder: folder, run: { _, args, _, _ in
            CLIResult(status: 0, stdout: Data((args.first == "auth" ? #"{"loggedIn":true}"# : #"{"result":"Current session: 6% used"}"#).utf8), stderr: Data())
        }, readResets: { _ in nil })
        XCTAssertNil(status.resets)
        XCTAssertNil(status.usageError)
    }

    func testOldAccountAndExpiration() throws {
        var account = UsageAccount(provider: .claude, label: "Synthetic")
        let old = try JSONEncoder().encode(account)
        XCTAssertFalse(String(decoding: old, as: UTF8.self).contains("resets"))
        XCTAssertNil(try JSONDecoder().decode(UsageAccount.self, from: old).resets)
        let available = LimitReset(kind: "weekly reset", count: 1, expiresAt: now.addingTimeInterval(1))
        account.resets = [LimitReset(kind: "full reset", count: 1, expiresAt: now), available]
        XCTAssertEqual(account.availableResets(at: now), [])
        account.signedIn = true
        XCTAssertEqual(account.availableResets(at: now), [available])
    }
}
