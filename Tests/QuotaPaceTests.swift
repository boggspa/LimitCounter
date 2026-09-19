import Foundation

private enum TestError: Error, CustomStringConvertible {
    case failure(String)

    var description: String {
        switch self {
        case .failure(let message):
            return message
        }
    }
}

private func expect(_ condition: Bool, _ label: String) throws {
    guard condition else {
        throw TestError.failure(label)
    }
}

private func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ label: String) throws {
    guard actual == expected else {
        throw TestError.failure("\(label): expected \(expected), got \(actual)")
    }
}

private func expectApproximately(_ actual: Double, _ expected: Double, _ label: String) throws {
    guard abs(actual - expected) < 0.0001 else {
        throw TestError.failure("\(label): expected \(expected), got \(actual)")
    }
}

private func quotaWindow(
    label: String,
    kind: QuotaWindowKind,
    used: Double,
    total: Double? = 100,
    resetDate: Date?,
    subtitle: String? = nil
) -> QuotaWindow {
    QuotaWindow(
        label: label,
        windowKind: kind,
        used: used,
        total: total,
        resetDate: resetDate,
        unit: "%",
        subtitle: subtitle
    )
}

private func testFiveHourBehindWhenOverGuide() throws {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let window = quotaWindow(
        label: "Session",
        kind: .session,
        used: 70,
        resetDate: now.addingTimeInterval(2.5 * 60 * 60),
        subtitle: "5-hour rolling window"
    )

    let pace = try expectPace(window.pace(providerID: .openai, at: now), "5H over-guide pace")
    try expectEqual(pace.state, .behind, "5H over-guide state")
    try expectApproximately(pace.expectedFraction, 0.5, "5H expected fraction")
    try expectApproximately(abs(pace.deltaFraction), 0.2, "5H delta fraction")
}

private func testFiveHourAheadWhenUnderGuide() throws {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let window = quotaWindow(
        label: "Session",
        kind: .session,
        used: 30,
        resetDate: now.addingTimeInterval(2.5 * 60 * 60),
        subtitle: "5-hour rolling window"
    )

    let pace = try expectPace(window.pace(providerID: .openai, at: now), "5H under-guide pace")
    try expectEqual(pace.state, .ahead, "5H under-guide state")
    try expectEqual(pace.compactStatusText, "Ahead 20%", "5H compact text")
}

private func testDailyOnTrackIsSuppressed() throws {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let window = quotaWindow(
        label: "Daily Quota",
        kind: .daily,
        used: 50,
        resetDate: now.addingTimeInterval(12 * 60 * 60)
    )

    let pace = window.pace(providerID: .devin, at: now)
    try expectEqual(pace?.state, .onTrack, "daily on-track state")
    try expect(pace?.shouldSurface == true, "daily on-track should surface")
}

private func testWeeklyAheadWhenUnderGuide() throws {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let window = quotaWindow(
        label: "Weekly",
        kind: .weekly,
        used: 10,
        resetDate: now.addingTimeInterval(5.25 * 24 * 60 * 60)
    )

    let pace = try expectPace(window.pace(providerID: .kimi, at: now), "weekly under-guide pace")
    try expectEqual(pace.state, .ahead, "weekly under-guide state")
    try expectApproximately(pace.expectedFraction, 0.25, "weekly expected fraction")
}

private func testMissingInputsAreSuppressed() throws {
    let now = Date(timeIntervalSince1970: 1_000_000)

    try expect(
        quotaWindow(label: "Weekly", kind: .weekly, used: 10, total: nil, resetDate: now.addingTimeInterval(100)).pace(at: now) == nil,
        "missing total is suppressed"
    )
    try expect(
        quotaWindow(label: "Weekly", kind: .weekly, used: 10, resetDate: nil).pace(at: now) == nil,
        "missing reset is suppressed"
    )
    try expect(
        quotaWindow(label: "Weekly", kind: .weekly, used: 10, resetDate: now.addingTimeInterval(-100)).pace(at: now) == nil,
        "expired reset is suppressed"
    )
    try expect(
        quotaWindow(label: "Generic", kind: .session, used: 10, resetDate: now.addingTimeInterval(100)).pace(providerID: .devin, at: now) == nil,
        "unlabeled session duration is suppressed"
    )
}

private func testMuseCurrentUsageGetsFiveHourPace() throws {
    let now = Date(timeIntervalSince1970: 1_000_000)
    // The Muse card's own wording: nothing in the label or subtitle says "5h",
    // so the duration has to come from the provider.
    let window = quotaWindow(
        label: "Current usage",
        kind: .session,
        used: 39,
        resetDate: now.addingTimeInterval(60 * 60),
        subtitle: "Muse Code subscription — captured at import"
    )

    let pace = try expectPace(window.pace(providerID: .meta, at: now), "Muse current-usage pace")
    try expectApproximately(pace.expectedFraction, 0.8, "four of five hours elapsed")
    try expectApproximately(pace.actualFraction, 0.39, "39% used")
    try expectEqual(pace.state, .ahead, "well under the guide reads as ahead")

    // The same window still has no pace for a provider with no session length.
    try expect(
        window.pace(providerID: .devin, at: now) == nil,
        "the five-hour default stays scoped to providers that have one"
    )
}

private func testSlidingFiveHourInference() throws {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let window = quotaWindow(
        label: "5H",
        kind: .sliding,
        used: 20,
        resetDate: now.addingTimeInterval(4 * 60 * 60)
    )

    let pace = try expectPace(window.pace(providerID: .kimi, at: now), "sliding 5H pace")
    try expectApproximately(pace.expectedFraction, 0.2, "sliding 5H expected fraction")
}

private func testCompactStringFormatsBillions() throws {
    try expectEqual(999.0.compactString, "999", "sub-thousand compact string")
    try expectEqual(1_260.0.compactString, "1.3K", "thousands compact string")
    try expectEqual(2_500_000.0.compactString, "2.5M", "millions compact string")
    try expectEqual(3_683_972_788.0.compactString, "3.7B", "billions compact string")
    try expectEqual(4_000_000_000.0.compactString, "4B", "whole billions compact string")
}

private func testAnalyticsBucketsRoundTripAndDefaultDecode() throws {
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    let end = start.addingTimeInterval(86_400)
    let bucket = UsageAnalyticsBucket(
        startDate: start,
        endDate: end,
        model: "gpt-test",
        projectID: "proj_test",
        inputTokens: 100,
        outputTokens: 25,
        cachedInputTokens: 10,
        requests: 4,
        costUSD: 0.42,
        source: .officialAPI
    )

    let snapshot = QuotaSnapshot(
        providerID: .openaiAPI,
        displayName: "OpenAI API",
        analyticsBuckets: [bucket]
    )
    let data = try JSONEncoder().encode(snapshot)
    let decoded = try JSONDecoder().decode(QuotaSnapshot.self, from: data)
    try expectEqual(decoded.analyticsBuckets, [bucket], "analytics buckets round trip")
    try expectApproximately(decoded.analyticsBuckets[0].totalTokens, 135, "analytics total tokens")

    let legacyJSON = """
    {
      "id": "\(UUID().uuidString)",
      "providerID": "openaiAPI",
      "displayName": "OpenAI API",
      "windows": [],
      "stats": [],
      "balances": [],
      "signals": [],
      "events": [],
      "fetchState": "success",
      "fetchedAt": 1700000000
    }
    """.data(using: .utf8)!
    let legacyDecoder = JSONDecoder()
    legacyDecoder.dateDecodingStrategy = .secondsSince1970
    let legacy = try legacyDecoder.decode(QuotaSnapshot.self, from: legacyJSON)
    try expect(legacy.analyticsBuckets.isEmpty, "legacy snapshots decode without analytics buckets")
}

private func testUsageAnalyticsIntelligenceProjectionAndInsights() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!

    let now = calendar.date(from: DateComponents(
        timeZone: calendar.timeZone,
        year: 2026,
        month: 5,
        day: 16,
        hour: 12
    ))!
    let dayStart = calendar.startOfDay(for: now)

    func bucket(offset: Int, model: String, tokens: Double, requests: Double, cost: Double) -> UsageAnalyticsBucket {
        let start = calendar.date(byAdding: .day, value: offset, to: dayStart)!
        let end = calendar.date(byAdding: .day, value: 1, to: start)!
        return UsageAnalyticsBucket(
            startDate: start,
            endDate: end,
            model: model,
            inputTokens: tokens,
            requests: requests,
            costUSD: cost,
            source: .officialAPI
        )
    }

    var buckets = [
        bucket(offset: 0, model: "gpt-heavy", tokens: 200_000, requests: 40, cost: 20)
    ]
    for offset in -7 ... -1 {
        buckets.append(bucket(offset: offset, model: "gpt-heavy", tokens: 30_000, requests: 10, cost: 5))
        buckets.append(bucket(offset: offset, model: "gpt-light", tokens: 5_000, requests: 4, cost: 0))
    }

    let intelligence = UsageAnalyticsIntelligence(buckets: buckets, now: now, calendar: calendar)

    try expectApproximately(intelligence.today.cost, 20, "today cost")
    try expectApproximately(intelligence.previousSevenDayAverage.cost, 5, "previous seven day average cost")
    try expectApproximately(intelligence.monthToDate.cost, 55, "month to date cost")
    try expectApproximately(intelligence.projectedMonth.cost, 106.5625, "projected month cost")
    try expectEqual(intelligence.elapsedMonthDays, 16, "elapsed month days")
    try expectEqual(intelligence.totalMonthDays, 31, "total month days")
    try expectEqual(intelligence.topModels.first?.name, "gpt-heavy", "top model")

    let insightKinds = Set(intelligence.insights.map(\.kind))
    try expect(insightKinds.contains(.projectedMonth), "projected month insight")
    try expect(insightKinds.contains(.usageSpike), "usage spike insight")
    try expect(insightKinds.contains(.topModel), "top model insight")
    try expectEqual(
        intelligence.insights.first(where: { $0.kind == .usageSpike })?.severity,
        .critical,
        "usage spike severity"
    )
}

private func testUsageAnalyticsBudgetStatus() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!

    let now = calendar.date(from: DateComponents(
        timeZone: calendar.timeZone,
        year: 2026,
        month: 5,
        day: 10,
        hour: 12
    ))!
    let dayStart = calendar.startOfDay(for: now)
    let nextDay = calendar.date(byAdding: .day, value: 1, to: dayStart)!

    let bucket = UsageAnalyticsBucket(
        startDate: dayStart,
        endDate: nextDay,
        costUSD: 50,
        source: .officialAPI,
        note: "Cost"
    )
    let intelligence = UsageAnalyticsIntelligence(
        buckets: [bucket],
        monthlyBudgetUSD: 100,
        now: now,
        calendar: calendar
    )

    try expectApproximately(intelligence.monthToDate.cost, 50, "budget month to date cost")
    try expectApproximately(intelligence.projectedMonth.cost, 155, "budget projected cost")
    try expectEqual(intelligence.monthlyBudget?.state, .overBudget, "budget state")
    try expectEqual(intelligence.monthlyBudget?.severity, .critical, "budget severity")
    try expectEqual(intelligence.insights.first?.kind, .budgetStatus, "budget insight leads")
}

private func expectPace(_ pace: QuotaPace?, _ label: String) throws -> QuotaPace {
    guard let pace else {
        throw TestError.failure("\(label): expected pace")
    }
    return pace
}

@main
private enum QuotaPaceTestRunner {
    static func main() throws {
        try testFiveHourBehindWhenOverGuide()
        try testFiveHourAheadWhenUnderGuide()
        try testDailyOnTrackIsSuppressed()
        try testWeeklyAheadWhenUnderGuide()
        try testMissingInputsAreSuppressed()
        try testMuseCurrentUsageGetsFiveHourPace()
        try testSlidingFiveHourInference()
        try testCompactStringFormatsBillions()
        try testAnalyticsBucketsRoundTripAndDefaultDecode()
        try testUsageAnalyticsIntelligenceProjectionAndInsights()
        try testUsageAnalyticsBudgetStatus()
        print("Quota pace tests passed")
    }
}
