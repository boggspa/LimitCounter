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

private func makeDate(_ value: String) -> Date {
    ISO8601DateFormatter().date(from: value)!
}

private func isolatedDefaults() -> (defaults: UserDefaults, suiteName: String) {
    let suiteName = "ClaudeUsageTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return (defaults, suiteName)
}

private func utcCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
}

private func claudeOAuthDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .custom { decoder in
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFractional.date(from: string) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: string) { return date }
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unparseable date: \(string)")
    }
    return decoder
}

private func testClaudeHeatmapBucketingRetainsFullWindow() throws {
    let calendar = utcCalendar()
    let now = makeDate("2026-05-16T23:59:00Z")
    var records: [ClaudeUsageRecord] = []

    for dayOffset in 0..<35 {
        let day = calendar.date(byAdding: .day, value: -dayOffset, to: calendar.startOfDay(for: now))!
        for row in 0..<12 {
            let bucketStart = calendar.date(byAdding: .hour, value: row * 2, to: day)!
            for repeatIndex in 0..<3 {
                records.append(
                    ClaudeUsageRecord(
                        timestamp: bucketStart.addingTimeInterval(Double(repeatIndex * 60)),
                        tokens: Double(repeatIndex + 1)
                    )
                )
            }
        }
    }

    let oldDay = calendar.date(byAdding: .day, value: -36, to: calendar.startOfDay(for: now))!
    records.append(ClaudeUsageRecord(timestamp: oldDay, tokens: 999))

    let events = ClaudeHeatmapEventBucketer.events(from: records, now: now, calendar: calendar)

    try expect(records.count > 1_000, "fixture should exceed old raw-event cap")
    try expectEqual(events.count, 35 * 12, "bucket count")
    try expect(events.allSatisfy { $0.type == .bucket }, "all events are heatmap buckets")
    try expect(events.allSatisfy { $0.model == "Claude" }, "all events retain Claude model")
    try expect(events.allSatisfy { ($0.tokens ?? 0) == 6 }, "bucket token totals are summed")

    let oldestExpectedDay = calendar.date(byAdding: .day, value: -34, to: calendar.startOfDay(for: now))!
    try expectEqual(events.map(\.timestamp).min(), oldestExpectedDay, "oldest retained bucket")
}

private func testClaudeFableWindowWithoutResetStillDisplays() throws {
    let window = ClaudeOAuthModelWindowMapper.quotaWindow(
        label: "Fable",
        subtitle: "Fable 7-day rolling window",
        from: ClaudeOAuthWindow(utilization: 0, resetAt: nil)
    )

    try expect(window != nil, "Fable utilization should create window without reset")
    try expectEqual(window?.label, "Fable", "Fable label")
    try expectEqual(window?.used, 0, "Fable utilization")
    try expectEqual(window?.resetDate, nil, "Fable reset remains nil")
}

private func testClaudeMissingFableWindowDoesNotDisplay() throws {
    try expect(
        ClaudeOAuthModelWindowMapper.quotaWindow(
            label: "Fable",
            subtitle: "Fable 7-day rolling window",
            from: nil
        ) == nil,
        "missing Fable response should not create window"
    )

    try expect(
        ClaudeOAuthModelWindowMapper.quotaWindow(
            label: "Fable",
            subtitle: "Fable 7-day rolling window",
            from: ClaudeOAuthWindow(utilization: nil, resetAt: nil)
        ) == nil,
        "Fable response without utilization should not create window"
    )
}

private func testClaudeFableWindowFromWeeklyScopedLimit() throws {
    let reset = makeDate("2026-07-07T07:00:00Z")
    let limit = ClaudeOAuthLimit(
        group: "weekly",
        kind: "weekly_scoped",
        percent: 0,
        resetAt: reset,
        scope: nil
    )

    let window = ClaudeOAuthModelWindowMapper.fableQuotaWindow(from: limit.oauthWindow)

    try expect(limit.isFableWeeklyLimit, "weekly_scoped Claude limit should map to Fable")
    try expect(window != nil, "Fable limit should create a quota window")
    try expectEqual(window?.label, "Fable", "Fable scoped label")
    try expectEqual(window?.used, 0, "Fable scoped utilization")
    try expectEqual(window?.resetDate, reset, "Fable scoped reset")
    try expectEqual(window?.subtitle, "You haven't used Fable yet", "Fable zero-use subtitle")
}

private func testClaudeUsageResponseBuildsFableFromLimits() throws {
    let payload = """
    {
      "seven_day_sonnet": { "utilization": 88.0 },
      "limits": [
        {
          "group": "weekly",
          "kind": "weekly_all",
          "percent": 49,
          "resets_at": "2026-07-07T07:00:00.000000+00:00"
        },
        {
          "group": "weekly",
          "kind": "weekly_scoped",
          "percent": 0,
          "resets_at": "2026-07-07T06:59:59.516637+00:00",
          "scope": { "label": "Fable" }
        }
      ]
    }
    """

    let usage = try claudeOAuthDecoder().decode(ClaudeOAuthUsageResponse.self, from: Data(payload.utf8))
    let fable = usage.fableWeeklyWindow

    try expectEqual(fable?.utilization, 0, "Fable should prefer weekly_scoped limits entry over legacy Sonnet")
    let expectedReset = makeDate("2026-07-07T06:59:59Z").addingTimeInterval(0.516637)
    try expect(
        fable?.resetAt.map { abs($0.timeIntervalSince(expectedReset)) < 0.001 } == true,
        "Fable scoped reset should decode"
    )
}

private func testClaudeOpusWindowUsesSameRule() throws {
    let reset = makeDate("2026-05-20T00:00:00Z")
    let window = ClaudeOAuthModelWindowMapper.quotaWindow(
        label: "Opus",
        subtitle: "Opus 7-day rolling window",
        from: ClaudeOAuthWindow(utilization: 12.5, resetAt: reset)
    )

    try expect(window != nil, "Opus utilization should create window")
    try expectEqual(window?.label, "Opus", "Opus label")
    try expectEqual(window?.used, 12.5, "Opus utilization")
    try expectEqual(window?.resetDate, reset, "Opus reset")
}

private func testClaudeProfileResolvesLiveMax20Plan() throws {
    let payload = """
    {
      "organization": {
        "organization_type": "claude_max",
        "rate_limit_tier": "default_claude_max_20x"
      }
    }
    """

    let profile = try JSONDecoder().decode(ClaudeOAuthProfileResponse.self, from: Data(payload.utf8))

    try expectEqual(profile.planInfo?.displayName, "Max x20", "live profile plan")
    try expectEqual(profile.planInfo?.isMax, true, "live profile Max gate")
}

private func testClaudePlanResolverRetainsCredentialFallback() throws {
    let plan = ClaudePlanResolver.resolve(
        subscriptionType: "max",
        rateLimitTier: "default_claude_max_5x"
    )

    try expectEqual(plan?.displayName, "Max x5", "credential fallback plan")
}

private func testClaudeOAuthCacheFreshReadsDoNotSlideTTL() throws {
    let storage = isolatedDefaults()
    defer { storage.defaults.removePersistentDomain(forName: storage.suiteName) }

    let cache = ClaudeOAuthResponseCache(
        freshTTL: 10,
        staleTTL: 60,
        diskMaxAge: 60,
        defaults: storage.defaults,
        legacySnapshotLoader: { nil }
    )
    let now = makeDate("2026-05-16T00:00:00Z")
    let snapshot = QuotaSnapshot(
        providerID: .claude,
        displayName: "Claude Code",
        planName: "Max x5",
        windows: [
            QuotaWindow(
                label: "Session",
                windowKind: .session,
                used: 12,
                total: 100,
                unit: "%"
            )
        ],
        fetchedAt: now
    )

    cache.store(snapshot, now: now)

    try expect(
        cache.fresh(now: now.addingTimeInterval(5)) != nil,
        "cache should be fresh inside TTL"
    )
    try expect(
        cache.fresh(now: now.addingTimeInterval(11)) == nil,
        "cache read should not extend TTL"
    )
}

private func testClaudeOAuthCacheRejectsTranscriptSnapshots() throws {
    let storage = isolatedDefaults()
    defer { storage.defaults.removePersistentDomain(forName: storage.suiteName) }

    let now = makeDate("2026-08-16T00:00:00Z")
    let localSnapshot = QuotaSnapshot(
        providerID: .claude,
        displayName: "Claude Code",
        windows: [
            QuotaWindow(
                label: "Session",
                windowKind: .session,
                used: 91_214_868,
                unit: "tok",
                subtitle: "Local Claude Code transcript"
            ),
            QuotaWindow(
                label: "Weekly",
                windowKind: .weekly,
                used: 2_306_975_133,
                unit: "tok",
                subtitle: "Aggregated local Claude Code usage"
            )
        ],
        fetchedAt: now
    )
    let cache = ClaudeOAuthResponseCache(
        freshTTL: 10,
        staleTTL: 60,
        diskMaxAge: 60,
        defaults: storage.defaults,
        legacySnapshotLoader: { localSnapshot }
    )

    cache.store(localSnapshot, now: now)

    try expect(
        !ClaudeOAuthResponseCache.isOAuthQuotaSnapshot(localSnapshot),
        "local transcript totals must not be classified as OAuth quota"
    )
    try expect(cache.fresh(now: now) == nil, "local transcript totals must not enter memory cache")
    try expect(
        cache.staleFallback(now: now.addingTimeInterval(1)) == nil,
        "local transcript totals must not enter disk fallback"
    )
}

private func testClaudeOAuthCachePersistsQuotaOnlyAcrossInstances() throws {
    let storage = isolatedDefaults()
    defer { storage.defaults.removePersistentDomain(forName: storage.suiteName) }

    let now = makeDate("2026-08-16T00:00:00Z")
    let event = UsageEvent(
        timestamp: now.addingTimeInterval(-300),
        tokens: 42,
        model: "Claude",
        type: .bucket
    )
    let oauthSnapshot = QuotaSnapshot(
        providerID: .claude,
        displayName: "Claude Code",
        planName: "Max x20",
        windows: [
            QuotaWindow(
                label: "Session",
                windowKind: .session,
                used: 6,
                total: 100,
                resetDate: now.addingTimeInterval(3_600),
                unit: "%"
            ),
            QuotaWindow(
                label: "Weekly",
                windowKind: .weekly,
                used: 80,
                total: 100,
                resetDate: now.addingTimeInterval(2 * 24 * 60 * 60),
                unit: "%"
            )
        ],
        events: [event],
        fetchedAt: now
    )
    let firstCache = ClaudeOAuthResponseCache(
        freshTTL: 10,
        staleTTL: 60,
        diskMaxAge: 120,
        defaults: storage.defaults,
        legacySnapshotLoader: { nil }
    )
    firstCache.store(oauthSnapshot, now: now)

    let relaunchedCache = ClaudeOAuthResponseCache(
        freshTTL: 10,
        staleTTL: 60,
        diskMaxAge: 120,
        defaults: storage.defaults,
        legacySnapshotLoader: { nil }
    )
    let restored = relaunchedCache.staleFallback(now: now.addingTimeInterval(30))

    try expect(
        ClaudeOAuthResponseCache.isOAuthQuotaSnapshot(oauthSnapshot),
        "percentage windows with explicit limits should be classified as OAuth quota"
    )
    try expectEqual(restored?.planName, "Max x20", "persisted OAuth plan")
    try expectEqual(restored?.windows, oauthSnapshot.windows, "persisted OAuth windows")
    try expectEqual(restored?.events.count, 0, "dedicated OAuth persistence should strip local events")
}

private func testClaudeCodeKeychainFallbackIsOptIn() throws {
    try expect(
        !ClaudeOAuthCredentialPolicy.isClaudeCodeKeychainFallbackEnabled(in: nil),
        "missing Claude credentials should not enable Claude Code keychain fallback"
    )
    try expect(
        !ClaudeOAuthCredentialPolicy.isClaudeCodeKeychainFallbackEnabled(
            in: ProviderCredential(extraFields: ["unrelated": "true"])
        ),
        "unrelated fields should not enable Claude Code keychain fallback"
    )
    try expect(
        ClaudeOAuthCredentialPolicy.isClaudeCodeKeychainFallbackEnabled(
            in: ProviderCredential(extraFields: [ClaudeOAuthCredentialPolicy.keychainAccessEnabledKey: "true"])
        ),
        "explicit true should enable Claude Code keychain fallback"
    )

    var extraFields = [ClaudeOAuthCredentialPolicy.keychainAccessEnabledKey: "true"]
    ClaudeOAuthCredentialPolicy.setClaudeCodeKeychainFallbackEnabled(false, in: &extraFields)
    try expectEqual(extraFields[ClaudeOAuthCredentialPolicy.keychainAccessEnabledKey], nil, "disabled Claude Code keychain fallback flag should not be persisted")

    try expect(
        !ClaudeOAuthCredentialPolicy.allowsClaudeCodeKeychainAccess(enabled: true, userInitiated: false),
        "background refresh must never read Claude Code's keychain item"
    )
    try expect(
        !ClaudeOAuthCredentialPolicy.allowsClaudeCodeKeychainAccess(enabled: false, userInitiated: true),
        "manual refresh must still respect the opt-in setting"
    )
    try expect(
        ClaudeOAuthCredentialPolicy.allowsClaudeCodeKeychainAccess(enabled: true, userInitiated: true),
        "an opted-in manual refresh may recover from Claude Code's keychain item"
    )
}

private func testClaudeJSONLReaderStreamsAcrossChunkBoundaries() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("claude-jsonl-reader-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let url = directory.appendingPathComponent("session.jsonl")
    let payload = [
        """
        {"timestamp":"2026-05-16T00:00:00Z","requestId":"r1","message":{"id":"m1","usage":{"input_tokens":10,"output_tokens":5}}}
        """,
        """
        {"timestamp":"2026-05-16T00:00:00Z","requestId":"r1","message":{"id":"m1","usage":{"input_tokens":10,"output_tokens":5}}}
        """,
        """
        {"timestamp":"2026-05-16T02:00:00Z","usage":{"input_tokens":2,"cache_read_input_tokens":3}}
        """
    ].joined(separator: "\n")
    try payload.write(to: url, atomically: true, encoding: .utf8)

    let formatter = ISO8601DateFormatter()
    let records = try ClaudeJSONLUsageRecordReader.readUsageRecords(
        from: url,
        chunkSize: 32,
        parseTimestamp: { value in
            value.flatMap(formatter.date(from:))
        }
    )

    try expectEqual(records.count, 2, "duplicate lines should be deduped")
    try expectEqual(records[0].tokens, 15, "nested usage token total")
    try expectEqual(records[1].tokens, 5, "top-level usage token total")
    try expectEqual(records[1].timestamp, makeDate("2026-05-16T02:00:00Z"), "final unterminated line is parsed")
}

private func testClaudeJSONLReaderBoundsOversizedTranscriptsToTail() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("claude-jsonl-tail-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let url = directory.appendingPathComponent("oversized.jsonl")
    let oldRecord = #"{"timestamp":"2026-05-01T00:00:00Z","usage":{"input_tokens":99}}"#
    let recentRecord = #"{"timestamp":"2026-05-16T04:00:00Z","usage":{"output_tokens":7}}"#
    let payload = oldRecord + "\n" + String(repeating: "x", count: 4_096) + "\n" + recentRecord
    try payload.write(to: url, atomically: true, encoding: .utf8)

    let formatter = ISO8601DateFormatter()
    let records = try ClaudeJSONLUsageRecordReader.readUsageRecords(
        from: url,
        chunkSize: 31,
        maxBytes: 256,
        parseTimestamp: { value in value.flatMap(formatter.date(from:)) }
    )

    try expectEqual(records.count, 1, "bounded reader should parse only complete records in the tail")
    try expectEqual(records[0].tokens, 7, "bounded reader should retain the latest usage record")
    try expectEqual(records[0].timestamp, makeDate("2026-05-16T04:00:00Z"), "bounded reader latest timestamp")
}

private func testClaudeHeatmapHistoryPreservesUnscannedBuckets() throws {
    let now = makeDate("2026-05-16T12:00:00Z")
    let preservedTimestamp = makeDate("2026-05-15T02:00:00Z")
    let newTimestamp = makeDate("2026-05-16T04:00:00Z")
    let previous = [
        UsageEvent(timestamp: preservedTimestamp, tokens: 20, model: "Claude", type: .bucket)
    ]
    let current = [
        UsageEvent(timestamp: preservedTimestamp, tokens: 5, model: "Claude", type: .bucket),
        UsageEvent(timestamp: newTimestamp, tokens: 8, model: "Claude", type: .bucket)
    ]

    let merged = ClaudeHeatmapEventHistory.merged(current: current, previous: previous, now: now)

    try expectEqual(merged.count, 2, "history merge should retain unscanned buckets")
    try expectEqual(
        merged.first { $0.timestamp == preservedTimestamp }?.tokens,
        20,
        "partial tail scans should not reduce a previously complete bucket"
    )
    try expectEqual(
        merged.first { $0.timestamp == newTimestamp }?.tokens,
        8,
        "new buckets should be added"
    )
}

@main
private enum ClaudeUsageTestRunner {
    static func main() throws {
        try testClaudeHeatmapBucketingRetainsFullWindow()
        try testClaudeFableWindowWithoutResetStillDisplays()
        try testClaudeMissingFableWindowDoesNotDisplay()
        try testClaudeFableWindowFromWeeklyScopedLimit()
        try testClaudeUsageResponseBuildsFableFromLimits()
        try testClaudeOpusWindowUsesSameRule()
        try testClaudeProfileResolvesLiveMax20Plan()
        try testClaudePlanResolverRetainsCredentialFallback()
        try testClaudeOAuthCacheFreshReadsDoNotSlideTTL()
        try testClaudeOAuthCacheRejectsTranscriptSnapshots()
        try testClaudeOAuthCachePersistsQuotaOnlyAcrossInstances()
        try testClaudeCodeKeychainFallbackIsOptIn()
        try testClaudeJSONLReaderStreamsAcrossChunkBoundaries()
        try testClaudeJSONLReaderBoundsOversizedTranscriptsToTail()
        try testClaudeHeatmapHistoryPreservesUnscannedBuckets()
        print("Claude usage tests passed")
    }
}
