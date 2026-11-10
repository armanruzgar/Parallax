import XCTest
@testable import Parallax

final class CodexResetTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func parse(_ count: Any, credits: Any = NSNull()) -> [LimitReset]? {
        CodexProvider.resets(fromRateLimits: ["rateLimitResetCredits": ["availableCount": count, "credits": credits]], now: now)
    }

    func testCountAndEarliestAvailableFutureExpiry() {
        let credits: [[String: Any]] = [
            ["status": "available", "expiresAt": now.timeIntervalSince1970 + 200],
            ["status": "available", "expiresAt": now.timeIntervalSince1970 + 100],
            ["status": "redeemed", "expiresAt": now.timeIntervalSince1970 + 50],
            ["status": "available", "expiresAt": now.timeIntervalSince1970 - 1],
            ["status": "available", "expiresAt": 32_503_680_000],
            ["status": "available", "expiresAt": true]
        ]
        XCTAssertEqual(parse(9, credits: credits), [LimitReset(kind: "usage limit reset", count: 9, expiresAt: now.addingTimeInterval(100))])
        XCTAssertEqual(parse(2), [LimitReset(kind: "usage limit reset", count: 2)])
        XCTAssertNil(parse(2, credits: [["status": "available", "expiresAt": NSNull()]])?.first?.expiresAt)
        XCTAssertEqual(parse(NSNumber(value: Int.max - 1))?.first?.count, Int.max - 1)
        XCTAssertEqual(parse(2.0)?.first?.count, 2)
        XCTAssertEqual(parse(0), [])
        XCTAssertEqual(parse(-1), [])
        XCTAssertEqual(parse(NSNumber(value: UInt64.max))?.first?.count, Int.max)
    }

    func testAbsentAndInvalidValues() {
        for result: [String: Any] in [[:], ["rateLimitResetCredits": NSNull()], ["rateLimitResetCredits": "invalid"], ["rateLimitResetCredits": [:]]] {
            XCTAssertNil(CodexProvider.resets(fromRateLimits: result, now: now))
        }
        for count: Any in [true, 1.5, Double.infinity, Double.nan, "2", NSNull()] {
            XCTAssertNil(parse(count))
        }
    }

    func testStatusResetsAndLimitsError() throws {
        let account: [String: Any] = ["result": ["account": ["email": "synthetic@example.com"]]]
        let result: [String: Any] = [
            "rateLimits": ["primary": ["usedPercent": 10]],
            "rateLimitResetCredits": ["availableCount": 2, "credits": [["status": "available", "expiresAt": now.timeIntervalSince1970 + 100]]]
        ]
        let status = try CodexProvider.status(accountReply: account, limitsReply: ["result": result], now: now)
        XCTAssertEqual(status.resets, [LimitReset(kind: "usage limit reset", count: 2, expiresAt: now.addingTimeInterval(100))])
        XCTAssertNil(status.usageError)
        let failed = try CodexProvider.status(accountReply: account, limitsReply: ["result": result, "error": ["message": "Synthetic failure"]], now: now)
        XCTAssertNil(failed.resets)
        XCTAssertEqual(failed.usageError, "Synthetic failure")
    }
}
