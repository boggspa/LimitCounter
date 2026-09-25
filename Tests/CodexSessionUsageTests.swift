import Foundation

private enum CodexSessionUsageTestError: Error, CustomStringConvertible {
    case failure(String)

    var description: String {
        switch self {
        case .failure(let message): return message
        }
    }
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw CodexSessionUsageTestError.failure(message) }
}

private func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) throws {
    if actual != expected {
        throw CodexSessionUsageTestError.failure("\(message): expected \(expected), got \(actual)")
    }
}

private func fixture(planType: String, additionalRateLimits: String = "") -> Data {
    """
    {
      "plan_type": "\(planType)",
      "rate_limit": {
        "primary_window": {
          "used_percent": 42,
          "limit_window_seconds": 18000,
          "reset_after_seconds": 10400,
          "reset_at": 4102444800
        },
        "secondary_window": {
          "used_percent": 64,
          "limit_window_seconds": 604800,
          "reset_after_seconds": 340000,
          "reset_at": 4102444800
        }
      }\(additionalRateLimits)
    }
    """.data(using: .utf8)!
}

private let lunaReserveAdditionalRateLimit = """
,
"additional_rate_limits": [
  {
    "limit_name": "gpt-reserve",
    "rate_limit": {
      "primary_window": {
        "used_percent": 0,
        "limit_window_seconds": 604800,
        "reset_after_seconds": 604800,
        "reset_at": 4102444800
      }
    }
  }
]
"""

private let sparkAdditionalRateLimit = """
,
"additional_rate_limits": [
  {
    "limit_name": "GPT-5.3-Codex-Spark",
    "rate_limit": {
      "primary_window": {
        "used_percent": 0,
        "limit_window_seconds": 18000,
        "reset_after_seconds": 10400,
        "reset_at": 4102444800
      },
      "secondary_window": {
        "used_percent": 97,
        "limit_window_seconds": 604800,
        "reset_after_seconds": 340000,
        "reset_at": 4102444800
      }
    }
  }
]
"""

private final class CodexMockURLProtocol: URLProtocol {
    static var responseData: Data?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let responseData = Self.responseData else {
            client?.urlProtocol(self, didFailWithError: CodexSessionUsageTestError.failure("missing fixture"))
            return
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: responseData)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private func fetch(planType: String, additionalRateLimits: String = "") async throws -> QuotaSnapshot {
    CodexMockURLProtocol.responseData = fixture(
        planType: planType,
        additionalRateLimits: additionalRateLimits
    )
    defer { CodexMockURLProtocol.responseData = nil }

    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [CodexMockURLProtocol.self]
    return try await CodexSessionProviderClient(session: URLSession(configuration: configuration))
        .fetchSnapshot(credentials: ProviderCredential(accessToken: "test-token", accountIdentifier: "test-account"))
}

private func testPlusRendersFiveHourThenWeekly() async throws {
    let snapshot = try await fetch(planType: "plus")

    try expectEqual(snapshot.windows.map(\.label), ["5H", "Weekly"], "Plus window order")
    try expectEqual(snapshot.windows[0].windowKind, .session, "Plus 5H window kind")
    try expectEqual(snapshot.windows[0].percentageUsed, 42, "Plus 5H usage")
    try expectEqual(snapshot.windows[1].windowKind, .weekly, "Plus weekly window kind")
}

private func testProOmitsFiveHourAndKeepsWeekly() async throws {
    let snapshot = try await fetch(planType: "pro")

    try expectEqual(snapshot.windows.map(\.label), ["Weekly"], "Pro should not render a 5H window")
    try expectEqual(snapshot.windows[0].percentageUsed, 64, "Pro weekly usage")
}

private func testProLiteOmitsFiveHourAndNamesThePlan() async throws {
    // Pro Lite, like Pro, has no 5-hour allowance; only Plus and below do.
    let snapshot = try await fetch(planType: "prolite")

    try expectEqual(snapshot.windows.map(\.label), ["Weekly"], "Pro Lite should not render a 5H window")
    try expectEqual(snapshot.windows[0].percentageUsed, 64, "Pro Lite weekly usage")
    try expectEqual(snapshot.planName, "Pro Lite", "Pro Lite is named as two words, not \"Prolite\"")
}

private func testLunaReserveRendersFriendlyWeeklyAllowance() async throws {
    let snapshot = try await fetch(
        planType: "pro",
        additionalRateLimits: lunaReserveAdditionalRateLimit
    )

    try expectEqual(
        snapshot.windows.map(\.label),
        ["Weekly", "🌙 Luna Reserve Weekly"],
        "Luna Reserve window label"
    )
    try expectEqual(snapshot.windows[1].windowKind, .weekly, "Luna Reserve window kind")
    try expectEqual(snapshot.windows[1].percentageUsed, 0, "Luna Reserve usage")
    try expectEqual(
        snapshot.windows[1].subtitle,
        "Separate 7-day Luna Reserve allowance",
        "Luna Reserve window subtitle"
    )
}

private func testSparkRendersFriendlyWindowLabels() async throws {
    let snapshot = try await fetch(
        planType: "pro",
        additionalRateLimits: sparkAdditionalRateLimit
    )

    try expectEqual(
        snapshot.windows.map(\.label),
        ["Weekly", "⚡ Spark 5H", "⚡ Spark Weekly"],
        "Spark window labels"
    )
    try expectEqual(snapshot.windows[1].windowKind, .session, "Spark 5H window kind")
    try expectEqual(snapshot.windows[2].windowKind, .weekly, "Spark weekly window kind")
}

/// The two endpoints behind the Codex app's "Usage limit resets" panel, as
/// observed live on 2026-09-16 (with a credit added to the otherwise empty
/// list).
private func testResetCreditParsersReadDetailsAndHistory() throws {
    let details = """
    {
      "credits": [
        {
          "id": "RateLimitResetCredit_bb6b",
          "reset_type": "weekly",
          "status": "available",
          "granted_at": "2026-09-05T04:20:07.256813Z",
          "expires_at": "2026-09-05T12:20:07Z",
          "title": "Usage limit reset",
          "description": null
        }
      ],
      "available_count": 1,
      "total_earned_count": 3,
      "immediate_reset_purchase_eligible": false,
      "history_enabled": true
    }
    """.data(using: .utf8)!
    let parsed = try CodexResetCreditsParser.parseDetails(details)
    try expectEqual(parsed.availableCount, 1, "available count")
    try expectEqual(parsed.earnedCount, 3, "earned count")
    try expectEqual(parsed.credits.count, 1, "credit list")
    let credit = parsed.credits[0]
    try expectEqual(credit.id, "RateLimitResetCredit_bb6b", "credit id")
    try expect(credit.isAvailable, "status available")
    try expectEqual(credit.grantedAt, CodexResetCreditsParser.parseDate("2026-09-05T04:20:07.256813Z"), "granted date with fractional seconds")
    try expectEqual(credit.expiresAt, Date(timeIntervalSince1970: 1_788_610_807), "expiry date")
    try expectEqual(credit.note, "weekly", "reset type kept as the note when there is no description")

    let history = """
    {
      "events": [
        {"id": "RateLimitResetCredit_bb6b:used", "kind": "used", "occurred_at": "2026-09-05T11:11:31.367474Z"},
        {"id": "RateLimitResetCredit_bb6b:granted", "kind": "granted", "occurred_at": "2026-09-05T04:20:07.256813Z"},
        {"id": "RateLimitResetCredit_zzzz:unknown", "kind": "mystery", "occurred_at": "2026-09-05T04:20:07Z"}
      ],
      "window_start": "2026-08-17T04:14:39.218092Z",
      "as_of": "2026-09-16T04:14:39.218092Z",
      "next_cursor": null
    }
    """.data(using: .utf8)!
    let events = try CodexResetCreditsParser.parseHistory(history)
    try expectEqual(events.map(\.kind), [.used, .granted], "known kinds, newest first, unknown dropped")
    try expectEqual(events.first?.id, "RateLimitResetCredit_bb6b:used", "event id")

    let summary = QuotaResetCreditSummary(
        availableCount: parsed.availableCount,
        earnedCount: parsed.earnedCount,
        credits: parsed.credits,
        history: events,
        redeemHint: CodexResetCreditsFetcher.redeemHint,
        observedAt: Date(timeIntervalSince1970: 1_788_600_000)
    )
    try expectEqual(summary.nearestExpiry, credit.expiresAt, "nearest expiry")
    try expectEqual(
        summary.statusLine(at: Date(timeIntervalSince1970: 1_788_600_000)),
        "1 reset banked · expires in 3h",
        "status line"
    )

    let empty = try CodexResetCreditsParser.parseDetails(
        #"{"credits": [], "available_count": 0, "total_earned_count": 0, "history_enabled": true}"#.data(using: .utf8)!
    )
    try expectEqual(empty.availableCount, 0, "empty list")
    try expect(empty.credits.isEmpty, "no credits")
}

private func testResetCreditCacheIsFiledPerAccount() throws {
    // Two Codex accounts refresh through the same fetcher; one shared entry
    // let the second show the first's banked credits, then overwrite them.
    let personal = CodexResetCreditsFetcher.cacheKey(forAccountID: "acct-personal")
    let work = CodexResetCreditsFetcher.cacheKey(forAccountID: "acct-work")
    try expect(personal != work, "each ChatGPT account files its own reset-credit summary")
    try expectEqual(personal, "codex.resetCredits.cache.v1.acct-personal", "the key extends the original one with the account id")
    try expectEqual(
        CodexResetCreditsFetcher.cacheKey(forAccountID: "acct-work"),
        work,
        "the same account finds its own summary again"
    )
}

@main
private enum CodexSessionUsageTestRunner {
    static func main() async throws {
        try await testPlusRendersFiveHourThenWeekly()
        try await testProOmitsFiveHourAndKeepsWeekly()
        try await testProLiteOmitsFiveHourAndNamesThePlan()
        try await testLunaReserveRendersFriendlyWeeklyAllowance()
        try await testSparkRendersFriendlyWindowLabels()
        try testResetCreditParsersReadDetailsAndHistory()
        try testResetCreditCacheIsFiledPerAccount()
        print("Codex session usage tests passed")
    }
}
