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

private func utcCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
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

private func testClaudeSonnetWindowWithoutResetStillDisplays() throws {
    let window = ClaudeOAuthModelWindowMapper.quotaWindow(
        label: "Sonnet",
        subtitle: "Sonnet 7-day rolling window",
        from: ClaudeOAuthWindow(utilization: 0, resetAt: nil)
    )

    try expect(window != nil, "Sonnet utilization should create window without reset")
    try expectEqual(window?.label, "Sonnet", "Sonnet label")
    try expectEqual(window?.used, 0, "Sonnet utilization")
    try expectEqual(window?.resetDate, nil, "Sonnet reset remains nil")
}

private func testClaudeMissingSonnetWindowDoesNotDisplay() throws {
    try expect(
        ClaudeOAuthModelWindowMapper.quotaWindow(
            label: "Sonnet",
            subtitle: "Sonnet 7-day rolling window",
            from: nil
        ) == nil,
        "missing Sonnet response should not create window"
    )

    try expect(
        ClaudeOAuthModelWindowMapper.quotaWindow(
            label: "Sonnet",
            subtitle: "Sonnet 7-day rolling window",
            from: ClaudeOAuthWindow(utilization: nil, resetAt: nil)
        ) == nil,
        "Sonnet response without utilization should not create window"
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

private func testClaudeOAuthCacheFreshReadsDoNotSlideTTL() throws {
    let cache = ClaudeOAuthResponseCache(freshTTL: 10, staleTTL: 60, diskMaxAge: 60)
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

@main
private enum ClaudeUsageTestRunner {
    static func main() throws {
        try testClaudeHeatmapBucketingRetainsFullWindow()
        try testClaudeSonnetWindowWithoutResetStillDisplays()
        try testClaudeMissingSonnetWindowDoesNotDisplay()
        try testClaudeOpusWindowUsesSameRule()
        try testClaudeOAuthCacheFreshReadsDoNotSlideTTL()
        try testClaudeCodeKeychainFallbackIsOptIn()
        try testClaudeJSONLReaderStreamsAcrossChunkBoundaries()
        print("Claude usage tests passed")
    }
}
