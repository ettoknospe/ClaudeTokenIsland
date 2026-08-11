import XCTest
@testable import ClaudeTokenIsland

// MARK: - OAuthUsageResponse decoding

final class OAuthUsageResponseTests: XCTestCase {

    func testDecodesFullResponse() throws {
        let json = """
        {
          "five_hour":   { "utilization": 35.0, "resets_at": "2026-03-19T19:00:00.367134+00:00" },
          "seven_day":   { "utilization": 71.0, "resets_at": "2026-03-20T11:00:00.367161+00:00" },
          "seven_day_sonnet": { "utilization": 27.0, "resets_at": "2026-03-20T12:00:00.367175+00:00" },
          "seven_day_oauth_apps": null,
          "seven_day_opus": null,
          "seven_day_cowork": null,
          "iguana_necktie": null,
          "extra_usage": { "is_enabled": false, "monthly_limit": null, "used_credits": null, "utilization": null }
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(OAuthUsageResponse.self, from: json)

        XCTAssertEqual(response.fiveHour?.utilization, 35.0)
        XCTAssertEqual(response.sevenDay?.utilization, 71.0)
        XCTAssertEqual(response.sevenDaySonnet?.utilization, 27.0)
        XCTAssertEqual(response.extraUsage?.isEnabled, false)
        // Values are null when the toggle is off.
        XCTAssertNil(response.extraUsage?.utilization)
        XCTAssertNil(response.extraUsage?.usedCredits)
        XCTAssertNil(response.extraUsage?.monthlyLimit)
    }

    func testDecodesExtraUsageEnabled() throws {
        let json = """
        {
          "five_hour": null, "seven_day": null, "seven_day_sonnet": null,
          "extra_usage": { "is_enabled": true, "monthly_limit": null, "used_credits": null, "utilization": null }
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(OAuthUsageResponse.self, from: json)

        XCTAssertEqual(response.extraUsage?.isEnabled, true)
    }

    // Assumed shape (plain numbers) — replace if a real enabled sample differs.
    func testDecodesExtraUsageEnabledWithValues() throws {
        let json = """
        {
          "five_hour": null, "seven_day": null, "seven_day_sonnet": null,
          "extra_usage": { "is_enabled": true, "monthly_limit": 50.0, "used_credits": 12.5, "utilization": 25.0 }
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(OAuthUsageResponse.self, from: json)

        XCTAssertEqual(response.extraUsage?.isEnabled, true)
        XCTAssertEqual(response.extraUsage?.monthlyLimit, 50.0)
        XCTAssertEqual(response.extraUsage?.usedCredits, 12.5)
        XCTAssertEqual(response.extraUsage?.utilization, 25.0)
    }

    // The guessed value types are decoded through `try?`: if the real API sends
    // a different shape (money object, string), those fields must fall to nil
    // WITHOUT throwing and taking the rest of the response down with them.
    func testExtraUsageWrongValueTypesDoNotBreakDecode() throws {
        let json = """
        {
          "five_hour": { "utilization": 42.0, "resets_at": "2026-03-19T19:00:00+00:00" },
          "seven_day": null, "seven_day_sonnet": null,
          "extra_usage": { "is_enabled": true, "monthly_limit": "n/a",
                           "used_credits": { "amount_minor": 1250 }, "utilization": 25.0 }
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(OAuthUsageResponse.self, from: json)

        XCTAssertEqual(response.extraUsage?.isEnabled, true)
        XCTAssertNil(response.extraUsage?.monthlyLimit)   // string → nil, no throw
        XCTAssertNil(response.extraUsage?.usedCredits)    // object → nil, no throw
        XCTAssertEqual(response.extraUsage?.utilization, 25.0)
        XCTAssertEqual(response.fiveHour?.utilization, 42.0)  // rest intact
    }

    func testDecodesExtraUsageAbsent() throws {
        let json = """
        { "five_hour": null, "seven_day": null, "seven_day_sonnet": null }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(OAuthUsageResponse.self, from: json)

        XCTAssertNil(response.extraUsage)
    }

    func testDecodesNullSonnet() throws {
        let json = """
        {
          "five_hour":   { "utilization": 10.0, "resets_at": "2026-03-19T19:00:00+00:00" },
          "seven_day":   { "utilization": 20.0, "resets_at": "2026-03-20T11:00:00+00:00" },
          "seven_day_sonnet": null
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(OAuthUsageResponse.self, from: json)

        XCTAssertNil(response.sevenDaySonnet)
        XCTAssertEqual(response.fiveHour?.utilization, 10.0)
    }

    func testDecodesAllNulls() throws {
        let json = """
        {
          "five_hour": null,
          "seven_day": null,
          "seven_day_sonnet": null
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(OAuthUsageResponse.self, from: json)

        XCTAssertNil(response.fiveHour)
        XCTAssertNil(response.sevenDay)
        XCTAssertNil(response.sevenDaySonnet)
    }

    func testResetsAtDateParsesWithFractionalSeconds() throws {
        let json = """
        {
          "five_hour": { "utilization": 35.0, "resets_at": "2026-03-19T19:00:00.367134+00:00" },
          "seven_day": null, "seven_day_sonnet": null
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(OAuthUsageResponse.self, from: json)
        XCTAssertNotNil(response.fiveHour?.resetsAtDate, "resetsAt date should parse successfully")
    }

    func testUtilizationConvertsToInt() throws {
        let json = """
        {
          "five_hour":   { "utilization": 34.7, "resets_at": "2026-03-19T19:00:00+00:00" },
          "seven_day":   { "utilization": 71.2, "resets_at": "2026-03-20T11:00:00+00:00" },
          "seven_day_sonnet": { "utilization": 26.9, "resets_at": "2026-03-20T12:00:00+00:00" }
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(OAuthUsageResponse.self, from: json)

        // Int() truncates (floors), matching how snapshot builds utilization
        XCTAssertEqual(Int(response.fiveHour!.utilization), 34)
        XCTAssertEqual(Int(response.sevenDay!.utilization), 71)
        XCTAssertEqual(Int(response.sevenDaySonnet!.utilization), 26)
    }
}

// MARK: - calculateUtilization

final class CalculateUtilizationTests: XCTestCase {

    func testZeroTokensIsZeroPercent() {
        XCTAssertEqual(calculateUtilization(tokens: 0, limit: 100_000), 0)
    }

    func testHalfLimitIsFiftyPercent() {
        XCTAssertEqual(calculateUtilization(tokens: 50_000, limit: 100_000), 50)
    }

    func testExceedingLimitCapsAtHundred() {
        XCTAssertEqual(calculateUtilization(tokens: 200_000, limit: 100_000), 100)
    }

    func testExactLimitIsHundredPercent() {
        XCTAssertEqual(calculateUtilization(tokens: 100_000, limit: 100_000), 100)
    }

    func testZeroLimitReturnsZero() {
        XCTAssertEqual(calculateUtilization(tokens: 50_000, limit: 0), 0)
    }

    func testRoundsDown() {
        XCTAssertEqual(calculateUtilization(tokens: 1, limit: 3), 33)
    }
}

// MARK: - formatTimeRemaining

final class FormatTimeRemainingTests: XCTestCase {

    func testPastDateReturnsNow() {
        let past = Date().addingTimeInterval(-60)
        XCTAssertEqual(formatTimeRemaining(until: past), "now")
    }

    func testFortyFiveMinutesRemaining() {
        let now = Date()
        XCTAssertEqual(formatTimeRemaining(until: now.addingTimeInterval(45 * 60), from: now), "45m")
    }

    func testTwoHoursThirtyMinutes() {
        let now = Date()
        XCTAssertEqual(formatTimeRemaining(until: now.addingTimeInterval(2 * 3600 + 30 * 60), from: now), "2h 30m")
    }

    func testExactlyOneHour() {
        let now = Date()
        XCTAssertEqual(formatTimeRemaining(until: now.addingTimeInterval(3600), from: now), "1h 0m")
    }
}
