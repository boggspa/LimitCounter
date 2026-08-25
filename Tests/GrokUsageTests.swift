import Foundation

private enum GrokUsageTestError: Error, CustomStringConvertible {
    case failure(String)

    var description: String {
        switch self {
        case .failure(let message):
            return message
        }
    }
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() {
        throw GrokUsageTestError.failure(message)
    }
}

private func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) throws {
    if actual != expected {
        throw GrokUsageTestError.failure("\(message): expected \(expected), got \(actual)")
    }
}

private func decodeSnapshot(_ payload: String) throws -> GrokUsageSnapshot {
    try JSONDecoder().decode(GrokUsageSnapshot.self, from: Data(payload.utf8))
}

private func makeDate(_ value: String) -> Date {
    let withFractional = ISO8601DateFormatter()
    withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = withFractional.date(from: value) {
        return date
    }
    return ISO8601DateFormatter().date(from: value)!
}

private func testWeeklyUsedPercentSnapshotBuildsWeeklyWindow() throws {
    let snapshot = try decodeSnapshot("""
    {
      "provider": "grok",
      "source": "grok-cli-usage",
      "usageKind": "weekly_limit",
      "weeklyLimitUsedPercent": 98,
      "weeklyLimitUsedDisplay": "98%",
      "resetAtText": "July 2, 09:04 PT",
      "refreshedAt": "2026-07-01T21:22:55.000Z",
      "planLabel": "SuperGrok",
      "confidence": "observed"
    }
    """)

    let window = try expectWindow(GrokUsageWindowMapper.quotaWindow(from: snapshot, now: makeDate("2026-07-01T21:30:00Z")))

    try expectEqual(window.label, "Weekly", "weekly label")
    try expectEqual(window.windowKind, .weekly, "weekly kind")
    try expectEqual(window.used, 98, "weekly used percent")
    try expectEqual(window.total, 100, "weekly total")
    try expectEqual(window.unit, "%", "weekly unit")
    try expectEqual(window.resetDate, makeDate("2026-07-02T16:04:00Z"), "PT reset should parse with PDT offset")
    try expect(window.subtitle?.contains("Weekly limit resets July 2, 09:04 PT") == true, "weekly subtitle")
}

private func testWeeklyLeftPercentSnapshotInvertsToUsedPercent() throws {
    let snapshot = try decodeSnapshot("""
    {
      "usageKind": "weekly_limit",
      "weeklyLimitLeftPercent": "2%",
      "nextResetText": "July 2, 09:04 PT",
      "refreshedAt": "2026-07-01T21:22:55.000Z",
      "confidence": "observed"
    }
    """)

    let window = try expectWindow(GrokUsageWindowMapper.quotaWindow(from: snapshot, now: makeDate("2026-07-01T21:30:00Z")))

    try expectEqual(window.label, "Weekly", "left-percent label")
    try expectEqual(window.used, 98, "left percent should invert to used percent")
    try expectEqual(window.resetDate, makeDate("2026-07-02T16:04:00Z"), "next reset text should parse")
}

private func testCLIParserReadsWeeklyUsageScreen() throws {
    let rawOutput = """
    \u{001B}[34mWeekly limit:\u{001B}[0m 98%
    Next reset: July 2, 09:04 PT

    \u{001B}[33mWeekly limit left: 2%\u{001B}[0m · Composer 2.5
    """
    let snapshot = GrokCLIUsageParser.parse(rawOutput, refreshedAt: makeDate("2026-07-01T21:22:55Z"))
    let window = try expectWindow(GrokUsageWindowMapper.quotaWindow(from: snapshot, now: makeDate("2026-07-01T21:30:00Z")))

    try expectEqual(snapshot.usageKind, "weekly_limit", "CLI parser usage kind")
    try expectEqual(snapshot.weeklyLimitUsedPercent ?? -1, 98, "CLI parser weekly used percent")
    try expectEqual(snapshot.weeklyLimitLeftPercent ?? -1, 2, "CLI parser weekly left percent")
    try expectEqual(window.label, "Weekly", "CLI parser weekly label")
    try expectEqual(window.used, 98, "CLI parser weekly window used percent")
    try expectEqual(window.resetDate, makeDate("2026-07-02T16:04:00Z"), "CLI parser reset date")
}

private func testCLIParserReadsWeeklyStatusLineFallback() throws {
    let snapshot = GrokCLIUsageParser.parse(
        "~\n\nWeekly limit left: 2% · Composer 2.5",
        refreshedAt: makeDate("2026-07-01T21:22:55Z")
    )
    let window = try expectWindow(GrokUsageWindowMapper.quotaWindow(from: snapshot, now: makeDate("2026-07-01T21:30:00Z")))

    try expectEqual(snapshot.usageKind, "weekly_limit", "status line usage kind")
    try expectEqual(snapshot.weeklyLimitUsedPercent ?? -1, 98, "status line left percent should invert")
    try expectEqual(window.used, 98, "status line window used percent")
    try expect(window.resetDate == nil, "status line fallback has no reset date")
}

private func testCLIParserReadsCursorPaintedUsageScreen() throws {
    let snapshot = GrokCLIUsageParser.parse(
        "Weeklylimit:98%Nextreset:July2,09:04PT",
        refreshedAt: makeDate("2026-07-01T21:22:55Z")
    )
    let window = try expectWindow(GrokUsageWindowMapper.quotaWindow(from: snapshot, now: makeDate("2026-07-01T21:30:00Z")))

    try expectEqual(window.used, 98, "cursor-painted weekly screen used percent")
    try expectEqual(window.resetDate, makeDate("2026-07-02T16:04:00Z"), "cursor-painted reset date")
}

private func testCLIParserReadsLegacyCreditScreen() throws {
    let snapshot = GrokCLIUsageParser.parse(
        "Credits used: 3%\nResets: July 31, 16:00 PT",
        refreshedAt: makeDate("2026-07-01T21:22:55Z")
    )
    let window = try expectWindow(GrokUsageWindowMapper.quotaWindow(from: snapshot, now: makeDate("2026-07-01T21:30:00Z")))

    try expectEqual(snapshot.usageKind, "subscription_credits", "legacy CLI usage kind")
    try expectEqual(window.label, "Credits", "legacy CLI label")
    try expectEqual(window.used, 3, "legacy CLI used percent")
}

private func testBillingLogReaderUsesLatestWeeklyConfig() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("limit-counter-grok-log-test-\(UUID().uuidString)", isDirectory: true)
    let logs = root.appendingPathComponent("logs", isDirectory: true)
    let log = logs.appendingPathComponent("unified.jsonl")
    defer { try? FileManager.default.removeItem(at: root) }

    try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
    try """
    {"ts":"2026-07-01T15:16:04.850Z","lvl":"info","msg":"billing: fetched credits config","ctx":{"config":{"creditUsagePercent":5.0,"currentPeriod":{"type":"USAGE_PERIOD_TYPE_MONTHLY","start":"2026-07-01T00:00:00+00:00","end":"2026-08-01T00:00:00+00:00"},"billingPeriodStart":"2026-07-01T00:00:00+00:00","billingPeriodEnd":"2026-08-01T00:00:00+00:00"},"subscriptionTier":"SuperGrok"}}
    {"ts":"2026-07-01T22:12:27.295Z","lvl":"info","msg":"billing: fetched credits config","ctx":{"config":{"creditUsagePercent":98.0,"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","start":"2026-06-25T17:04:15.560820+00:00","end":"2026-07-02T17:04:15.560820+00:00"},"isUnifiedBillingUser":true,"billingPeriodStart":"2026-06-25T17:04:15.560820+00:00","billingPeriodEnd":"2026-07-02T17:04:15.560820+00:00"},"subscriptionTier":"SuperGrok"}}
    """.data(using: .utf8)!.write(to: log)

    let snapshot = try expectSnapshot(GrokLocalBillingLogReader.latestSnapshot(rootURL: root, now: makeDate("2026-07-01T22:13:00Z")))
    let window = try expectWindow(GrokUsageWindowMapper.quotaWindow(from: snapshot, now: makeDate("2026-07-01T22:13:00Z")))

    try expectEqual(snapshot.usageKind, "weekly_limit", "billing log usage kind")
    try expectEqual(snapshot.weeklyLimitUsedPercent ?? -1, 98, "billing log used percent")
    try expectEqual(window.label, "Weekly", "billing log window label")
    try expectEqual(window.used, 98, "billing log window percent")
    try expectEqual(window.resetDate, makeDate("2026-07-02T17:04:15.560820Z"), "billing log reset date")
}

private func testBillingLogReaderTreatsOmittedUsageInNewPeriodAsReset() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("limit-counter-grok-reset-test-\(UUID().uuidString)", isDirectory: true)
    let logs = root.appendingPathComponent("logs", isDirectory: true)
    let log = logs.appendingPathComponent("unified.jsonl")
    defer { try? FileManager.default.removeItem(at: root) }

    try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
    try """
    {"ts":"2026-08-20T16:54:49.719Z","lvl":"info","msg":"billing: fetched credits config","ctx":{"config":{"creditUsagePercent":99.0,"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","start":"2026-08-13T17:04:15.560820+00:00","end":"2026-08-20T17:04:15.560820+00:00"}},"subscriptionTier":"SuperGrok"}}
    {"ts":"2026-08-20T17:27:36.037Z","lvl":"info","msg":"billing: fetched credits config","ctx":{"config":{"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","start":"2026-08-20T17:04:15.560820+00:00","end":"2026-08-27T17:04:15.560820+00:00"}},"subscriptionTier":"X Premium"}}
    """.data(using: .utf8)!.write(to: log)

    let now = makeDate("2026-08-20T18:00:00Z")
    let snapshot = try expectSnapshot(GrokLocalBillingLogReader.latestSnapshot(rootURL: root, now: now))
    let window = try expectWindow(GrokUsageWindowMapper.quotaWindow(from: snapshot, now: now))

    try expectEqual(snapshot.planLabel, "X Premium", "new billing period plan")
    try expectEqual(snapshot.periodStartAt, "2026-08-20T17:04:15.560Z", "new billing period start")
    try expectEqual(window.used, 0, "omitted usage in a fresh active period should mean zero")
    try expectEqual(window.resetDate, makeDate("2026-08-27T17:04:15.560820Z"), "new billing period reset")
}

private func testBillingLogReaderPreservesUsageAcrossSamePeriodOmission() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("limit-counter-grok-omission-test-\(UUID().uuidString)", isDirectory: true)
    let logs = root.appendingPathComponent("logs", isDirectory: true)
    let log = logs.appendingPathComponent("unified.jsonl")
    defer { try? FileManager.default.removeItem(at: root) }

    try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
    try """
    {"ts":"2026-08-22T10:00:00.000Z","lvl":"info","msg":"billing: fetched credits config","ctx":{"config":{"creditUsagePercent":12.0,"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","start":"2026-08-20T17:04:15.560820+00:00","end":"2026-08-27T17:04:15.560820+00:00"}},"subscriptionTier":"X Premium"}}
    {"ts":"2026-08-22T10:05:00.000Z","lvl":"info","msg":"billing: fetched credits config","ctx":{"config":{"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","start":"2026-08-20T17:04:15.560820+00:00","end":"2026-08-27T17:04:15.560820+00:00"}},"subscriptionTier":"X Premium"}}
    """.data(using: .utf8)!.write(to: log)

    let now = makeDate("2026-08-22T10:06:00Z")
    let snapshot = try expectSnapshot(GrokLocalBillingLogReader.latestSnapshot(rootURL: root, now: now))
    let window = try expectWindow(GrokUsageWindowMapper.quotaWindow(from: snapshot, now: now))

    try expectEqual(window.used, 12, "same-period omission should preserve the last reported usage")
    try expectEqual(snapshot.planLabel, "X Premium", "same-period omission plan")
}

private func testPercentStringsDecodeWithoutRejectingSnapshot() throws {
    let snapshot = try decodeSnapshot("""
    {
      "usageKind": "weekly_limit",
      "weeklyLimitUsedPercent": "70%",
      "weeklyLimitLeftPercent": "30%",
      "confidence": "observed"
    }
    """)

    let window = try expectWindow(GrokUsageWindowMapper.quotaWindow(from: snapshot))

    try expectEqual(window.used, 70, "percent strings should decode")
}

private func testLegacyCreditSnapshotStillMapsWhenCurrent() throws {
    let snapshot = try decodeSnapshot("""
    {
      "usageKind": "subscription_credits",
      "creditsUsedPercent": 3,
      "creditsUsedDisplay": "3%",
      "resetAt": "2999-07-01T00:00:00.000Z",
      "resetAtText": "Jul 1, 00:00 PT",
      "confidence": "observed"
    }
    """)

    let window = try expectWindow(GrokUsageWindowMapper.quotaWindow(from: snapshot, now: makeDate("2026-07-01T21:30:00Z")))

    try expectEqual(window.label, "Credits", "legacy label")
    try expectEqual(window.windowKind, .sliding, "legacy kind")
    try expectEqual(window.used, 3, "legacy used percent")
}

private func testWeeklyBridgeShapeDoesNotFallBackToLegacyCredits() throws {
    let snapshot = try decodeSnapshot("""
    {
      "usageKind": "weekly_limit",
      "creditsUsedPercent": 99,
      "creditsUsedDisplay": "99%",
      "refreshedAt": "2026-08-20T16:54:50.765Z",
      "confidence": "observed"
    }
    """)

    let window = GrokUsageWindowMapper.quotaWindow(
        from: snapshot,
        now: makeDate("2026-08-20T17:00:00Z")
    )

    try expect(window == nil, "weekly snapshots must not reinterpret legacy credit fields")
}

private func testUndatedLegacyCreditSnapshotExpiresQuickly() throws {
    let snapshot = try decodeSnapshot("""
    {
      "usageKind": "subscription_credits",
      "creditsUsedPercent": 99,
      "refreshedAt": "2026-08-20T12:00:00.000Z",
      "confidence": "observed"
    }
    """)

    let window = GrokUsageWindowMapper.quotaWindow(
        from: snapshot,
        now: makeDate("2026-08-20T17:00:00Z")
    )

    try expect(window == nil, "undated legacy credit snapshots should not persist indefinitely")
}

private func testExpiredLegacyCreditSnapshotIsNotRenderedAsCurrentQuota() throws {
    let snapshot = try decodeSnapshot("""
    {
      "usageKind": "subscription_credits",
      "creditsUsedPercent": 3,
      "resetAt": "2026-06-30T23:00:00.000Z",
      "resetAtText": "Jun30,16:00PT",
      "confidence": "observed"
    }
    """)

    let window = GrokUsageWindowMapper.quotaWindow(from: snapshot, now: makeDate("2026-07-01T21:30:00Z"))

    try expect(window == nil, "expired legacy credit snapshots should not render as current")
}

private func testExpiredWeeklySnapshotIsNotRenderedAsCurrentQuota() throws {
    let snapshot = try decodeSnapshot("""
    {
      "usageKind": "weekly_limit",
      "weeklyLimitUsedPercent": 98,
      "resetAt": "2026-07-02T17:04:15.560820Z",
      "confidence": "observed"
    }
    """)

    let window = GrokUsageWindowMapper.quotaWindow(from: snapshot, now: makeDate("2026-07-02T17:15:00Z"))

    try expect(window == nil, "expired weekly snapshots should not render as current")
}

private func testUnavailableSnapshotProducesNoWindow() throws {
    let snapshot = try decodeSnapshot("""
    {
      "usageKind": "weekly_limit",
      "weeklyLimitUsedPercent": 98,
      "confidence": "unavailable"
    }
    """)

    let window = GrokUsageWindowMapper.quotaWindow(from: snapshot)

    try expect(window == nil, "unavailable snapshots should not render")
}

private func testGrokDirectoryImportStoresFolderCredential() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("limit-counter-grok-test-\(UUID().uuidString)", isDirectory: true)
    let bin = root.appendingPathComponent("bin", isDirectory: true)
    let binary = bin.appendingPathComponent("grok")
    defer { try? FileManager.default.removeItem(at: root) }

    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    try Data("#!/bin/sh\n".utf8).write(to: binary)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)

    let imported = try CredentialImportService.importFromURL(root, for: .grok)

    try expectEqual(imported.customEndpoint, root.path, "Grok import should store selected root path")
    try expectEqual(imported.extraFields?["grokSource"], "directory", "Grok import should tag source")
    try expect(imported.accessToken == nil, "Grok import should not store an access token")
}

private func testLiveGrokCLIProbeIfRequested() async throws {
    guard ProcessInfo.processInfo.environment["RUN_LIVE_GROK_USAGE_TEST"] == "1" else {
        return
    }

    let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".grok")
    let credential = ProviderCredential(
        accessToken: nil,
        accountIdentifier: nil,
        customEndpoint: root.path,
        extraFields: ["grokSource": "directory"]
    )
    guard let snapshot = await GrokCLIUsageProbe.fetchSnapshot(credentials: credential) else {
        throw GrokUsageTestError.failure("live Grok CLI probe returned no snapshot")
    }
    let window = try expectWindow(GrokUsageWindowMapper.quotaWindow(from: snapshot))

    try expectEqual(window.label, "Weekly", "live Grok CLI label")
    try expect(window.used >= 0 && window.used <= 100, "live Grok CLI used percent should be a percent")
    try expect(window.resetDate != nil, "live Grok CLI probe should capture the reset date from /usage")
}

private func expectWindow(_ window: QuotaWindow?) throws -> QuotaWindow {
    guard let window else {
        throw GrokUsageTestError.failure("expected quota window")
    }
    return window
}

private func expectSnapshot(_ snapshot: GrokUsageSnapshot?) throws -> GrokUsageSnapshot {
    guard let snapshot else {
        throw GrokUsageTestError.failure("expected Grok usage snapshot")
    }
    return snapshot
}

@main
private enum GrokUsageTestRunner {
    static func main() async throws {
        try testWeeklyUsedPercentSnapshotBuildsWeeklyWindow()
        try testWeeklyLeftPercentSnapshotInvertsToUsedPercent()
        try testCLIParserReadsWeeklyUsageScreen()
        try testCLIParserReadsWeeklyStatusLineFallback()
        try testCLIParserReadsCursorPaintedUsageScreen()
        try testCLIParserReadsLegacyCreditScreen()
        try testBillingLogReaderUsesLatestWeeklyConfig()
        try testBillingLogReaderTreatsOmittedUsageInNewPeriodAsReset()
        try testBillingLogReaderPreservesUsageAcrossSamePeriodOmission()
        try testPercentStringsDecodeWithoutRejectingSnapshot()
        try testLegacyCreditSnapshotStillMapsWhenCurrent()
        try testWeeklyBridgeShapeDoesNotFallBackToLegacyCredits()
        try testUndatedLegacyCreditSnapshotExpiresQuickly()
        try testExpiredLegacyCreditSnapshotIsNotRenderedAsCurrentQuota()
        try testExpiredWeeklySnapshotIsNotRenderedAsCurrentQuota()
        try testUnavailableSnapshotProducesNoWindow()
        try testGrokDirectoryImportStoresFolderCredential()
        try await testLiveGrokCLIProbeIfRequested()
        print("Grok usage tests passed")
    }
}
