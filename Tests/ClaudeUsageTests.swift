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
    try expectEqual(window?.label, "🪐 Fable", "Fable scoped label")
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
        ClaudeOAuthCredentialPolicy.allowsClaudeCodeKeychainAccess(enabled: true, userInitiated: false),
        "opted-in background refresh can reuse an existing Keychain grant"
    )
    try expect(
        !ClaudeOAuthCredentialPolicy.allowsClaudeCodeKeychainAccess(enabled: false, userInitiated: true),
        "manual refresh must still respect the opt-in setting"
    )
    try expect(
        ClaudeOAuthCredentialPolicy.allowsClaudeCodeKeychainAccess(enabled: true, userInitiated: true),
        "an opted-in manual refresh may recover from Claude Code's keychain item"
    )

    guard let backgroundBudget = ClaudeOAuthCredentialPolicy.makeClaudeCodeKeychainReadBudget(
            enabled: true,
            userInitiated: false
        ) else {
        throw TestError.failure("background recovery needs a silent read budget")
    }
    try expect(backgroundBudget.authenticationContext.interactionNotAllowed, "background recovery cannot prompt")
    try expect(backgroundBudget.claimRead(), "silent recovery gets one read")
    try expect(!backgroundBudget.claimRead(), "silent recovery cannot loop")
    try expect(
        !ProviderFetchError.rateLimited.shouldRecoverClaudeOAuthFromKeychain,
        "rate limiting must not trigger Keychain authorization or token recovery"
    )
    guard let manualRefreshBudget = ClaudeOAuthCredentialPolicy.makeClaudeCodeKeychainReadBudget(
        enabled: true,
        userInitiated: true
    ) else {
        throw TestError.failure("opted-in manual refresh should receive a Claude Code keychain read budget")
    }
    try expect(!manualRefreshBudget.authenticationContext.interactionNotAllowed, "manual recovery may authorize access")
    try expect(
        manualRefreshBudget.claimRead(),
        "the first Claude Code keychain read in a manual refresh should be allowed"
    )
    try expect(
        !manualRefreshBudget.claimRead(),
        "a refresh cycle must never read Claude Code's keychain item more than once"
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

// MARK: - AGBench event merging

/// TaskWraith drives the `claude` CLI, so a run it records is the same run the
/// transcript scan already bucketed. Concatenating the two lists counted that
/// usage twice.
private func testClaudeAGBenchRunsDoNotDoubleCountTranscriptUsage() throws {
    let now = makeDate("2026-05-16T12:00:00Z")
    let bucketStart = makeDate("2026-05-16T04:00:00Z")
    let transcriptBuckets = [
        UsageEvent(timestamp: bucketStart, tokens: 1_000, model: "Claude", type: .bucket)
    ]
    // The same run, as TaskWraith reports it: two raw per-run rows inside that
    // bucket, together no larger than what the transcript already saw.
    let agbenchEvents = [
        UsageEvent(timestamp: bucketStart.addingTimeInterval(60), tokens: 400, model: "claude-opus-5"),
        UsageEvent(timestamp: bucketStart.addingTimeInterval(120), tokens: 300, model: "claude-opus-5")
    ]

    let merged = ClaudeHeatmapEventHistory.mergingAGBench(agbenchEvents, into: transcriptBuckets, now: now, calendar: utcCalendar())

    try expectEqual(merged.count, 1, "AGBench rows fold into the existing bucket")
    try expectEqual(merged[0].tokens, 1_000, "transcript total wins; runs are not added on top")
    try expect(merged.allSatisfy { $0.type == .bucket }, "no raw per-run events survive the merge")
}

/// A run whose temporary workspace was cleaned up leaves no transcript, so
/// TaskWraith is the only remaining record of it and must still count.
private func testClaudeAGBenchRecoversRunsMissingFromTranscripts() throws {
    let now = makeDate("2026-05-16T12:00:00Z")
    let scannedBucket = makeDate("2026-05-16T04:00:00Z")
    let unscannedBucket = makeDate("2026-05-16T08:00:00Z")
    let transcriptBuckets = [
        UsageEvent(timestamp: scannedBucket, tokens: 1_000, model: "Claude", type: .bucket)
    ]
    let agbenchEvents = [
        UsageEvent(timestamp: unscannedBucket.addingTimeInterval(30), tokens: 250, model: "claude-opus-5")
    ]

    let merged = ClaudeHeatmapEventHistory.mergingAGBench(agbenchEvents, into: transcriptBuckets, now: now, calendar: utcCalendar())

    try expectEqual(merged.count, 2, "a bucket the transcript scan never saw is added")
    try expectEqual(
        merged.first { $0.timestamp == unscannedBucket }?.tokens,
        250,
        "AGBench-only usage is preserved"
    )
}

/// The regression that inflated the 30-day total to 187B: every refresh
/// appended the same AGBench rows again, and because `UsageEvent` mints a fresh
/// `id` per construction nothing ever recognised them as repeats.
private func testClaudeAGBenchMergeIsIdempotentAcrossRefreshes() throws {
    let now = makeDate("2026-05-16T12:00:00Z")
    let bucketStart = makeDate("2026-05-16T04:00:00Z")
    let agbenchEvents = [
        UsageEvent(timestamp: bucketStart.addingTimeInterval(60), tokens: 400, model: "claude-opus-5")
    ]

    var events: [UsageEvent] = []
    for _ in 0..<44 {
        // Each refresh re-reads usage.json, so the rows arrive as brand-new
        // values with brand-new ids every time.
        let reread = agbenchEvents.map {
            UsageEvent(timestamp: $0.timestamp, tokens: $0.tokens, model: $0.model, type: $0.type)
        }
        events = ClaudeHeatmapEventHistory.mergingAGBench(reread, into: events, now: now, calendar: utcCalendar())
    }

    try expectEqual(events.count, 1, "44 refreshes must not grow the event list")
    try expectEqual(events[0].tokens, 400, "44 refreshes must not multiply the token total")
}

// MARK: - Cross-snapshot event de-duplication

/// `codexTelemetry` republishes the `openai` snapshot's Codex events verbatim,
/// sharing their ids.
private func testDeduplicatorCollapsesEventsSharedAcrossProviders() throws {
    let shared = UsageEvent(timestamp: makeDate("2026-05-16T04:00:00Z"), tokens: 500, model: "Codex", type: .telemetry)
    let snapshots = [
        QuotaSnapshot(providerID: .openai, displayName: "OpenAI", events: [shared]),
        QuotaSnapshot(providerID: .codexTelemetry, displayName: "Codex", events: [shared])
    ]

    let events = UsageEventDeduplicator.flatten(snapshots)

    try expectEqual(events.count, 1, "the same event under two providers counts once")
    try expectEqual(events.map(\.tokens).compactMap { $0 }.reduce(0, +), 500, "token total is not doubled")
}

/// The id-based filter cannot see content repeats, because every copy carries a
/// fresh `id`. Claude had reached 44 copies of each run this way; Kimi, OpenAI
/// and Meta were accumulating the same way more slowly.
private func testDeduplicatorCollapsesContentRepeatsWithinAProvider() throws {
    let timestamp = makeDate("2026-05-16T04:00:00Z")
    let copies = (0..<44).map { _ in
        UsageEvent(timestamp: timestamp, tokens: 1_000, model: "claude-opus-5")
    }
    let snapshots = [QuotaSnapshot(providerID: .claude, displayName: "Claude", events: copies)]

    let events = UsageEventDeduplicator.flatten(snapshots)

    try expectEqual(events.count, 1, "44 content-identical copies count once")
    try expectEqual(events[0].tokens, 1_000, "token total reflects one run, not 44")
}

/// The content key must not reach across providers: two providers genuinely
/// billing the same amount in the same second are two real events.
private func testDeduplicatorKeepsMatchingEventsFromDifferentProviders() throws {
    let timestamp = makeDate("2026-05-16T04:00:00Z")
    let snapshots = [
        QuotaSnapshot(
            providerID: .grok,
            displayName: "Grok",
            events: [UsageEvent(timestamp: timestamp, tokens: 100, model: "grok")]
        ),
        QuotaSnapshot(
            providerID: .deepseek,
            displayName: "DeepSeek",
            events: [UsageEvent(timestamp: timestamp, tokens: 100, model: "grok")]
        )
    ]

    let events = UsageEventDeduplicator.flatten(snapshots)

    try expectEqual(events.count, 2, "identical payloads from two providers both count")
    try expectEqual(events.compactMap(\.tokens).reduce(0, +), 200, "neither provider is swallowed")
}

/// Distinct usage inside one provider must survive: same second, different
/// totals.
private func testDeduplicatorKeepsDistinctEventsInTheSameSecond() throws {
    let timestamp = makeDate("2026-05-16T04:00:00Z")
    let snapshots = [
        QuotaSnapshot(
            providerID: .claude,
            displayName: "Claude",
            events: [
                UsageEvent(timestamp: timestamp, tokens: 100, model: "claude-opus-5"),
                UsageEvent(timestamp: timestamp, tokens: 250, model: "claude-opus-5")
            ]
        )
    ]

    let events = UsageEventDeduplicator.flatten(snapshots)

    try expectEqual(events.count, 2, "different token totals are different events")
    try expectEqual(events.compactMap(\.tokens).reduce(0, +), 350, "both are counted")
}

// MARK: - OAuth credential renewal

private func makeClaudeCredential(
    accessToken: String = "access-1",
    refreshToken: String? = "refresh-1",
    expiresInHours: Double = 8
) -> ClaudeOAuthCredentials {
    let expiry = Date().addingTimeInterval(expiresInHours * 3600).timeIntervalSince1970 * 1000
    var raw: [String: Any] = [
        "accessToken": accessToken,
        "expiresAt": NSNumber(value: Int64(expiry)),
        "scopes": ["user:profile", "user:inference"],
        "subscriptionType": "max",
        "rateLimitTier": "default_claude_max_20x"
    ]
    if let refreshToken { raw["refreshToken"] = refreshToken }
    return ClaudeOAuthCredentials(
        accessToken: accessToken,
        refreshToken: refreshToken,
        expiresAtMillis: expiry,
        scopes: ["user:profile", "user:inference"],
        rawOAuthDict: raw
    )
}

private func testClaudeRefreshGrantAdoptsRotatedToken() throws {
    let base = makeClaudeCredential(expiresInHours: 0.2)
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let body = """
    {"access_token":"access-2","refresh_token":"refresh-2","expires_in":28800,
     "scope":"user:profile user:inference user:sessions:claude_code"}
    """.data(using: .utf8)!

    let renewed = try ClaudeOAuthRefreshClient.credentials(
        fromRefreshResponse: body,
        status: 200,
        base: base,
        now: now
    )

    try expectEqual(renewed.accessToken, "access-2", "adopts the new access token")
    try expectEqual(renewed.refreshToken, "refresh-2", "adopts a rotated refresh token")
    try expectEqual(renewed.expiresAt, now.addingTimeInterval(28800), "expiry comes from expires_in")
    try expect(renewed.scopes.contains("user:profile"), "keeps the scope /api/oauth/usage needs")

    // The credential is written back into Claude Code's own keychain item, so
    // every field the CLI stored has to survive the round trip.
    try expectEqual(renewed.rawOAuthDict["subscriptionType"] as? String, "max", "preserves subscriptionType")
    try expectEqual(renewed.rawOAuthDict["rateLimitTier"] as? String, "default_claude_max_20x", "preserves rateLimitTier")
    try expectEqual(renewed.rawOAuthDict["refreshToken"] as? String, "refresh-2", "raw dict carries the rotated token")
    try expectEqual(
        (renewed.rawOAuthDict["expiresAt"] as? NSNumber)?.int64Value,
        Int64(now.addingTimeInterval(28800).timeIntervalSince1970 * 1000),
        "raw dict stores millisecond expiry like the CLI does"
    )
}

private func testClaudeRefreshGrantKeepsTokenWhenServerDoesNotRotate() throws {
    let base = makeClaudeCredential()
    let body = #"{"access_token":"access-2","expires_in":28800}"#.data(using: .utf8)!
    let renewed = try ClaudeOAuthRefreshClient.credentials(
        fromRefreshResponse: body,
        status: 200,
        base: base
    )
    try expectEqual(renewed.refreshToken, "refresh-1", "an omitted refresh_token means the old one still works")
    try expect(renewed.scopes.contains("user:profile"), "falls back to the stored scopes")
}

private func testClaudeRefreshFailuresAreClassified() throws {
    let base = makeClaudeCredential()
    for status in [400, 401, 403] {
        do {
            _ = try ClaudeOAuthRefreshClient.credentials(
                fromRefreshResponse: Data(), status: status, base: base
            )
            throw TestError.failure("HTTP \(status) should not yield a credential")
        } catch let error as ClaudeOAuthRefreshClient.RefreshError {
            try expect(error.isTerminal, "HTTP \(status) is a dead refresh token, not a retry")
        }
    }

    do {
        _ = try ClaudeOAuthRefreshClient.credentials(
            fromRefreshResponse: Data(), status: 503, base: base
        )
        throw TestError.failure("HTTP 503 should not yield a credential")
    } catch let error as ClaudeOAuthRefreshClient.RefreshError {
        try expect(!error.isTerminal, "a 503 is transient and must be retried")
    }

    // The token endpoint rate-limits without a Retry-After header, so a 429
    // must be both retryable and slower to retry than an ordinary blip.
    let rateLimited = ClaudeOAuthRefreshClient.RefreshError.rejected(status: 429)
    try expect(!rateLimited.isTerminal, "a 429 never means the refresh token is dead")
    try expect(rateLimited.retryDelay > ClaudeOAuthRefreshClient.RefreshError.malformedResponse.retryDelay,
               "a 429 backs off for longer than a transient parse failure")

    do {
        _ = try ClaudeOAuthRefreshClient.credentials(
            fromRefreshResponse: Data("not json".utf8), status: 200, base: base
        )
        throw TestError.failure("garbage body should not yield a credential")
    } catch let error as ClaudeOAuthRefreshClient.RefreshError {
        try expect(!error.isTerminal, "an unparseable body is transient")
    }
}

private func testClaudeRefreshRequestRequiresARefreshToken() throws {
    let withoutToken = makeClaudeCredential(refreshToken: nil)
    do {
        _ = try ClaudeOAuthRefreshClient.refreshRequest(for: withoutToken)
        throw TestError.failure("a credential with no refresh token cannot be renewed")
    } catch let error as ClaudeOAuthRefreshClient.RefreshError {
        try expect(error.isTerminal, "a missing refresh token is terminal")
    }

    let request = try ClaudeOAuthRefreshClient.refreshRequest(for: makeClaudeCredential())
    try expectEqual(request.httpMethod, "POST", "refresh is a POST")
    try expectEqual(request.url, ClaudeOAuthRefreshClient.tokenEndpoint, "targets the CLI's token endpoint")
    let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
    try expectEqual(body?["grant_type"] as? String, "refresh_token", "uses the refresh grant")
    try expectEqual(body?["refresh_token"] as? String, "refresh-1", "sends the stored refresh token")
    try expectEqual(
        body?["client_id"] as? String,
        "9d1c250a-e61b-44d9-88ed-5944d1962f5e",
        "reuses Claude Code's client id so the credential stays interchangeable"
    )
    try expect(
        (body?["scope"] as? String)?.contains("user:profile") == true,
        "requests the scope /api/oauth/usage needs"
    )
}

private func testClaudeCredentialExpiryDrivesCacheRefresh() throws {
    // Our copy of Claude Code's token is a cache, not a credential we can
    // renew: the only move once it ages is to read the CLI's item again.
    let fresh = makeClaudeCredential(expiresInHours: 8)
    try expect(!fresh.needsRefresh(buffer: 10 * 60), "a token with 8h left needs no re-read")

    let due = makeClaudeCredential(expiresInHours: 0.1)
    try expect(due.needsRefresh(buffer: 10 * 60), "inside the last ten minutes we look at the CLI's item again")
    try expect(!due.needsRefresh(buffer: 60), "but the cached token is still usable meanwhile")
}

private func testClaudeMirrorNeverStoresTheRefreshToken() throws {
    // Limit Counter does not renew the credential — Claude Code does. Keeping
    // a copy of the refresh token would buy nothing and would hand a future
    // code path the means to renew the CLI's lineage behind its back, which is
    // what led to writing the CLI's keychain item and to macOS asking for the
    // login password on every `security find-generic-password` the CLI runs.
    let adopted = makeClaudeCredential(refreshToken: "refresh-1", expiresInHours: 8)
    try expect(adopted.refreshToken != nil, "Claude Code's own item carries a refresh token")

    let mirrored = adopted.mirrorPayload
    try expect(mirrored["refreshToken"] == nil, "the mirror drops the refresh token")
    try expectEqual(mirrored["accessToken"] as? String, "access-1", "the mirror keeps the access token")
    try expectEqual(mirrored["subscriptionType"] as? String, "max", "plan metadata survives mirroring")
    try expectEqual(mirrored["rateLimitTier"] as? String, "default_claude_max_20x", "tier metadata survives mirroring")
    try expect(mirrored["expiresAt"] is NSNumber, "expiry is stored in Claude Code's integer-millisecond format")
}

private func testClaudeCreditsUseMinorCurrencyUnits() throws {
    for (currency, raw, expected) in [("USD", 1250.0, 12.5), ("JPY", 1250.0, 1250.0), ("BHD", 1250.0, 1.25)] {
        let balance = ClaudeUsageCreditMapper.prepaidBalance(from: ClaudePrepaidCreditsResponse(amount: raw, currency: currency))
        try expectEqual(balance?.amount, expected, "prepaid currency minor units")
        try expectEqual(balance?.unit, currency, "prepaid currency")
        try expectEqual(balance?.label, "Usage Credits", "purchased credit label")
    }
    try expectEqual(ClaudeUsageCreditMapper.prepaidBalance(from: ClaudePrepaidCreditsResponse(amount: 0, currency: "USD"))?.amount,
                    0, "known zero balance is retained")
    for amount in [-1.0, Double.infinity, Double.nan] {
        try expect(ClaudeUsageCreditMapper.prepaidBalance(from: ClaudePrepaidCreditsResponse(amount: amount, currency: "USD")) == nil,
                   "invalid prepaid values stay unavailable")
    }
    try expect(ClaudeUsageCreditMapper.prepaidBalance(from: ClaudePrepaidCreditsResponse(amount: 100, currency: "unknown")) == nil,
               "unknown currency is not guessed")
    let response = try claudeOAuthDecoder().decode(ClaudeOAuthUsageResponse.self, from: Data(#"{"extra_usage":{"is_enabled":true,"monthly_limit":5000,"used_credits":1250,"utilization":25,"currency":"USD"}}"#.utf8))
    let cap = ClaudeUsageCreditMapper.extraUsageBalances(from: response.extraUsage).first
    try expectEqual(cap?.amount, 37.5, "spending limit remaining converts cents")
    try expectEqual(cap?.label, "Extra usage limit remaining", "cap is identified separately from purchased credits")
    let usedOnly = ClaudeOAuthExtraUsage(isEnabled: true, monthlyLimit: nil, usedCredits: 1250, utilization: nil, currency: "USD")
    try expectEqual(ClaudeUsageCreditMapper.extraUsageBalances(from: usedOnly).first?.label, "Extra usage used", "spend is not called remaining")
    let disabled = ClaudeOAuthExtraUsage(isEnabled: false, monthlyLimit: 5000, usedCredits: 1250, utilization: 25, currency: "USD")
    try expect(ClaudeUsageCreditMapper.extraUsageBalances(from: disabled).isEmpty, "disabled usage does not invent spend availability")
}

private func testClaudeCreditOrganizationCacheIsTokenScoped() throws {
    let (defaults, suite) = isolatedDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let cache = ClaudeOAuthResponseCache(defaults: defaults, persistenceKey: "credit-test", legacySnapshotLoader: { nil })
    let org = "11111111-1111-4111-8111-111111111111"
    cache.storeOrganizationID(org, forToken: "first-token")
    try expectEqual(cache.cachedOrganizationID(forToken: "first-token"), org, "same token reuses its org")
    try expect(cache.cachedOrganizationID(forToken: "other-token") == nil, "rotated or different token cannot inherit old org")
    let relaunched = ClaudeOAuthResponseCache(defaults: defaults, persistenceKey: "credit-test", legacySnapshotLoader: { nil })
    try expect(relaunched.cachedOrganizationID(forToken: "first-token") == nil, "raw organization stays in process memory")
}

private final class ClaudeCreditURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var body = Data()
    nonisolated(unsafe) static var requests: [URLRequest] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private func testClaudePrepaidCreditFetchIsOptionalAndReadOnly() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ClaudeCreditURLProtocol.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let client = ClaudePrepaidCreditsClient(session: session)
    let org = "11111111-1111-4111-8111-111111111111"
    ClaudeCreditURLProtocol.body = Data(#"{"amount":1250,"currency":"USD"}"#.utf8)
    let balance = await client.fetchBalance(token: "fixture-token", organizationID: org)
    try expectEqual(balance?.amount, 12.5, "prepaid fetched dollars")
    let request = ClaudeCreditURLProtocol.requests.last!
    try expectEqual(request.url?.absoluteString, "https://api.anthropic.com/api/oauth/organizations/\(org)/prepaid/credits", "known official endpoint")
    try expectEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-token", "same OAuth account")
    try expectEqual(request.value(forHTTPHeaderField: "x-organization-uuid"), org, "organization routing header")
    try expect(request.httpMethod == "GET" && request.httpBody == nil && !request.httpShouldHandleCookies, "read-only credit request")
    for status in [401, 403, 404, 429, 503] {
        ClaudeCreditURLProtocol.status = status
        let failed = await client.fetchBalance(token: "fixture-token", organizationID: org)
        try expect(failed == nil, "supplemental failure remains unavailable")
    }
    ClaudeCreditURLProtocol.status = 200
    ClaudeCreditURLProtocol.body = Data(#"{"amount":true,"currency":"USD"}"#.utf8)
    let invalid = await client.fetchBalance(token: "fixture-token", organizationID: org)
    try expect(invalid == nil, "malformed credit response stays unavailable")
    let before = ClaudeCreditURLProtocol.requests.count
    let missing = await client.fetchBalance(token: "fixture-token", organizationID: nil)
    try expect(missing == nil && ClaudeCreditURLProtocol.requests.count == before, "no request without verified organization")
    try expect(ClaudePrepaidCreditsClient.request(token: "fixture", organizationID: "../another") == nil, "invalid organization rejected")
}

@main
private enum ClaudeUsageTestRunner {
    static func main() async throws {
        try testClaudeCreditsUseMinorCurrencyUnits()
        try testClaudeCreditOrganizationCacheIsTokenScoped()
        try await testClaudePrepaidCreditFetchIsOptionalAndReadOnly()
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
        try testClaudeRateLimitCooldownDoesNotRequestKeychain()
        try testClaudeJSONLReaderStreamsAcrossChunkBoundaries()
        try testClaudeJSONLReaderBoundsOversizedTranscriptsToTail()
        try testClaudeHeatmapHistoryPreservesUnscannedBuckets()
        try testClaudeAGBenchRunsDoNotDoubleCountTranscriptUsage()
        try testClaudeAGBenchRecoversRunsMissingFromTranscripts()
        try testClaudeAGBenchMergeIsIdempotentAcrossRefreshes()
        try testDeduplicatorCollapsesEventsSharedAcrossProviders()
        try testDeduplicatorCollapsesContentRepeatsWithinAProvider()
        try testDeduplicatorKeepsMatchingEventsFromDifferentProviders()
        try testDeduplicatorKeepsDistinctEventsInTheSameSecond()
        try testClaudeRefreshGrantAdoptsRotatedToken()
        try testClaudeRefreshGrantKeepsTokenWhenServerDoesNotRotate()
        try testClaudeRefreshFailuresAreClassified()
        try testClaudeRefreshRequestRequiresARefreshToken()
        try testClaudeCredentialExpiryDrivesCacheRefresh()
        try testClaudeMirrorNeverStoresTheRefreshToken()
        print("Claude usage tests passed")
    }
}

private func testClaudeRateLimitCooldownDoesNotRequestKeychain() throws {
    let suiteName = "claude-retry-tests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let cache = ClaudeOAuthResponseCache(defaults: defaults, persistenceKey: "test", legacySnapshotLoader: { nil })
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    cache.deferRequests(retryAfter: "600", now: now)
    try expect(cache.isBackingOff(now: now.addingTimeInterval(599)), "honor vendor Retry-After")
    try expect(!cache.isBackingOff(now: now.addingTimeInterval(600)), "cooldown eventually expires")
    let restarted = ClaudeOAuthResponseCache(defaults: defaults, persistenceKey: "test", legacySnapshotLoader: { nil })
    try expect(restarted.isBackingOff(now: now), "restarting must not bypass cooldown")
    try expect(!ProviderFetchError.rateLimited.shouldRecoverClaudeOAuthFromKeychain, "429 never triggers reauthorization")
}
