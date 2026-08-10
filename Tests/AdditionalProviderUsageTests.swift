import Foundation

private enum AdditionalProviderTestError: Error, CustomStringConvertible {
    case failure(String)

    var description: String {
        switch self {
        case .failure(let message): return message
        }
    }
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw AdditionalProviderTestError.failure(message) }
}

private func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) throws {
    if actual != expected {
        throw AdditionalProviderTestError.failure("\(message): expected \(expected), got \(actual)")
    }
}

private func expectClose(_ actual: Double, _ expected: Double, _ message: String) throws {
    if abs(actual - expected) > 0.000_001 {
        throw AdditionalProviderTestError.failure("\(message): expected \(expected), got \(actual)")
    }
}

private func date(_ value: String) -> Date {
    ISO8601DateFormatter().date(from: value)!
}

private func testAntigravityParsesOfficialGeminiBucketsOnly() throws {
    let payload = """
    {
      "groups": [
        {
          "displayName": "Gemini Models",
          "buckets": [
            {
              "bucketId": "gemini-weekly",
              "displayName": "Weekly Limit",
              "remainingFraction": 0.42,
              "resetTime": "2026-08-05T07:44:00Z"
            },
            {
              "bucketId": "gemini-5h",
              "displayName": "Five Hour Limit",
              "remainingFraction": 1.0,
              "resetTime": "2026-08-01T16:00:00Z"
            }
          ]
        },
        {
          "displayName": "Claude and GPT models",
          "buckets": [
            {
              "bucketId": "3p-weekly",
              "displayName": "Weekly Limit",
              "remainingFraction": 0.05,
              "resetTime": "2026-08-05T07:44:00Z"
            }
          ]
        }
      ]
    }
    """
    let observed = try AntigravityQuotaSummaryParser.parse(
        Data(payload.utf8),
        planName: "Google AI Pro"
    )

    let parsed = try observed ?? { throw AdditionalProviderTestError.failure("Antigravity summary did not parse") }()
    try expectEqual(parsed.planName, "Google AI Pro", "Antigravity plan")
    try expectEqual(parsed.windows.count, 2, "Gemini window count")
    let weekly = try parsed.windows.first(where: { $0.windowKind == .weekly })
        ?? { throw AdditionalProviderTestError.failure("Missing weekly window") }()
    let fiveHour = try parsed.windows.first(where: { $0.windowKind == .session })
        ?? { throw AdditionalProviderTestError.failure("Missing five-hour window") }()
    try expectClose(weekly.used, 58, "weekly remaining must invert to used")
    try expectClose(fiveHour.used, 0, "available five-hour quota must be unused")
    try expectEqual(weekly.resetDate, date("2026-08-05T07:44:00Z"), "Antigravity reset timestamp")
    try expect(!parsed.windows.contains(where: { $0.used == 95 }), "Claude/GPT pool leaked into Gemini")
}

private func testAntigravityFailsClosedWithoutBothGeminiBuckets() throws {
    let missingFiveHour = """
    {"groups":[{"buckets":[
      {"bucketId":"gemini-weekly","remainingFraction":0.5,"resetTime":"2026-08-05T07:44:00Z"},
      {"bucketId":"3p-5h","remainingFraction":0.1,"resetTime":"2026-08-01T16:00:00Z"}
    ]}]}
    """
    let parsed = try AntigravityQuotaSummaryParser.parse(Data(missingFiveHour.utf8), planName: nil)
    try expect(
        parsed == nil,
        "A third-party five-hour bucket must not satisfy Gemini quota"
    )
}

private func testAntigravityParsesOfficialOAuthEnvelope() throws {
    let payload = """
    {
      "auth_method": "consumer",
      "id_token": "unused-test-id-token",
      "token": {
        "access_token": "test-access-token",
        "refresh_token": "test-refresh-token",
        "token_type": "Bearer",
        "expiry": "2026-08-08T17:20:35.123456+01:00"
      }
    }
    """
    let session = try AntigravityOAuthSessionParser.parse(Data(payload.utf8))
    try expectEqual(session.accessToken, "test-access-token", "Antigravity access token")
    try expectEqual(session.refreshToken, "test-refresh-token", "Antigravity refresh token")
    try expect(session.expiry != nil, "Antigravity fractional expiry should parse")
}

private func testAntigravityImportAcceptsOfficialCLIDataFolder() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("limit-counter-antigravity-tests-\(UUID().uuidString)", isDirectory: true)
    let geminiRoot = root.appendingPathComponent(".gemini", isDirectory: true)
    let cliRoot = geminiRoot.appendingPathComponent("antigravity-cli", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: cliRoot, withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: cliRoot.appendingPathComponent("antigravity-oauth-token"))

    let imported = try CredentialImportService.importFromURL(geminiRoot, for: .antigravity)
    try expectEqual(imported.customEndpoint, cliRoot.path, "Antigravity CLI data root")
    try expectEqual(
        imported.extraFields?["antigravitySource"],
        "officialCLIData",
        "Antigravity import source"
    )

    do {
        _ = try CredentialImportService.importFromURL(root, for: .antigravity)
        throw AdditionalProviderTestError.failure("Antigravity import accepted a folder without a token file")
    } catch let error as CredentialImportService.ImportError {
        try expectEqual(
            error.errorDescription,
            "Missing required field: antigravity-oauth-token",
            "Antigravity missing-token error"
        )
    }
}

private func testAntigravityRefreshCadenceLoopsFourSevenSixteenThreeTwentyOne() throws {
    try expectEqual(AntigravityRefreshCadence.intervalsMinutes, [4, 7, 16, 3, 21], "Antigravity cadence minutes")
    try expectClose(AntigravityRefreshCadence.interval(at: 0), 4 * 60, "Antigravity step 1")
    try expectClose(AntigravityRefreshCadence.interval(at: 1), 7 * 60, "Antigravity step 2")
    try expectClose(AntigravityRefreshCadence.interval(at: 2), 16 * 60, "Antigravity step 3")
    try expectClose(AntigravityRefreshCadence.interval(at: 3), 3 * 60, "Antigravity step 4")
    try expectClose(AntigravityRefreshCadence.interval(at: 4), 21 * 60, "Antigravity step 5")
    try expectEqual(AntigravityRefreshCadence.nextIndex(after: 4), 0, "Antigravity cadence loops")

    let start = date("2026-08-10T12:00:00Z")
    try expect(
        AntigravityRefreshCadence.isDue(
            now: start,
            cadenceIndex: 0,
            fetchedAt: nil,
            lastAttemptAt: nil
        ),
        "Antigravity first autonomous refresh is due immediately"
    )
    try expect(
        !AntigravityRefreshCadence.isDue(
            now: start.addingTimeInterval(3 * 60),
            cadenceIndex: 0,
            fetchedAt: start,
            lastAttemptAt: start
        ),
        "Antigravity step 1 waits the full 4 minutes"
    )
    try expect(
        AntigravityRefreshCadence.isDue(
            now: start.addingTimeInterval(4 * 60),
            cadenceIndex: 0,
            fetchedAt: start,
            lastAttemptAt: start
        ),
        "Antigravity step 1 becomes due at 4 minutes"
    )
    try expect(
        !AntigravityRefreshCadence.isDue(
            now: start.addingTimeInterval(15 * 60),
            cadenceIndex: 2,
            fetchedAt: start,
            lastAttemptAt: start
        ),
        "Antigravity step 3 still waits until 16 minutes"
    )
    try expect(
        AntigravityRefreshCadence.isDue(
            now: start.addingTimeInterval(16 * 60),
            cadenceIndex: 2,
            fetchedAt: start,
            lastAttemptAt: start
        ),
        "Antigravity step 3 becomes due at 16 minutes"
    )
}

private func testMistralCatalogueRatesAndCharsEstimate() throws {
    try expectClose(MistralModelRate.lookup("mistral-medium-3.5").inputUsdPerMillion, 1.5, "medium input")
    try expectClose(MistralModelRate.lookup("mistral-medium-3.5").outputUsdPerMillion, 7.5, "medium output")
    try expectClose(MistralModelRate.lookup("devstral-small").inputUsdPerMillion, 0.1, "devstral input")
    try expectClose(MistralModelRate.lookup("devstral-small").outputUsdPerMillion, 0.3, "devstral output")
    try expectClose(MistralModelRate.lookup("mistral-vibe-cli-latest").inputUsdPerMillion, 1.5, "vibe-cli alias")
    try expectClose(MistralModelRate.lookup("devstral-small-latest").inputUsdPerMillion, 0.1, "devstral-latest alias")
    try expectClose(MistralModelRate.lookup("mistral-large").inputUsdPerMillion, 1.5, "unknown → medium")
    try expectClose(MistralModelRate.lookup(nil).outputUsdPerMillion, 7.5, "nil → medium")

    try expectEqual(MistralTokenEstimate.estimateTokensFromChars(0), 0, "zero chars")
    try expectEqual(MistralTokenEstimate.estimateTokensFromChars(1), 1, "1 char")
    try expectEqual(MistralTokenEstimate.estimateTokensFromChars(4), 1, "4 chars")
    try expectEqual(MistralTokenEstimate.estimateTokensFromChars(5), 2, "5 chars")
    try expectEqual(MistralTokenEstimate.estimateTokensFromChars(40_000), 10_000, "AGBench prompt chars")

    let medium = MistralTokenEstimate.estimateUsage(
        model: "mistral-medium-3.5",
        promptChars: 40_000,
        responseChars: 20_000
    )
    try expectEqual(medium.inputTokens, 10_000, "medium input tokens")
    try expectEqual(medium.outputTokens, 5_000, "medium output tokens")
    try expectClose(medium.costUSD, 0.0525, "medium chars cost")

    let cheap = MistralTokenEstimate.estimateUsage(
        model: "devstral-small",
        promptChars: 40_000,
        responseChars: 20_000
    )
    try expectClose(cheap.costUSD, 0.0025, "devstral chars cost")
}

private func testMistralLocalCostUsesTaskWraithEstimateDoctrine() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("limit-counter-mistral-tests-\(UUID().uuidString)", isDirectory: true)
    let session = root.appendingPathComponent("logs/session/example", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
    let payload = """
    {
      "start_time": "2026-08-01T02:14:53.745363+00:00",
      "end_time": "2026-08-01T02:15:18.173565+00:00",
      "config": { "active_model": "mistral-large" },
      "stats": {
        "session_prompt_tokens": 30773,
        "session_completion_tokens": 1023,
        "input_price_per_million": 0.01,
        "output_price_per_million": 0.01,
        "session_cost": 9.99
      }
    }
    """
    try Data(payload.utf8).write(to: session.appendingPathComponent("meta.json"))

    let summary = try MistralVibeUsageReader.read(
        rootURL: root,
        now: date("2026-08-01T12:00:00Z")
    ) ?? { throw AdditionalProviderTestError.failure("Mistral metadata did not parse") }()
    // No messages.jsonl → catalogue × session tokens (unknown model → medium).
    // session_cost 9.99 and meta $/M 0.01 must be ignored.
    try expectClose(summary.currentMonthCostUSD, 0.053832, "Mistral catalogue fallback cost")
    try expectClose(summary.last30DaysCostUSD, 0.053832, "Mistral 30-day cost")
    try expectClose(summary.inputTokens, 30_773, "Mistral input tokens")
    try expectClose(summary.outputTokens, 1_023, "Mistral output tokens")
    try expectClose(
        summary.costUSD(since: date("2026-08-01T02:15:00Z")),
        0.053832,
        "Mistral cost after anchor"
    )
    try expectClose(
        summary.costUSD(since: date("2026-08-01T02:16:00Z")),
        0,
        "Mistral cost before anchor excluded"
    )
    try expectEqual(summary.analyticsBuckets.first?.source, .localEstimate, "Mistral estimate provenance")
    try expectEqual(
        summary.analyticsBuckets.first?.note,
        "Catalogue × Vibe session tokens",
        "Mistral fallback note"
    )
    let timestampFormatter = ISO8601DateFormatter()
    timestampFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    try expectEqual(
        summary.events.first?.timestamp,
        timestampFormatter.date(from: "2026-08-01T02:15:18.173565+00:00"),
        "Mistral fractional timestamp"
    )
}

private func testMistralJsonlUniquePayloadCharsEstimate() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("limit-counter-mistral-jsonl-\(UUID().uuidString)", isDirectory: true)
    let session = root.appendingPathComponent("logs/session/example", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)

    // 4 input chars (user) → 1 token @ $1.50
    // 8 output chars (assistant) → 2 tokens @ $7.50
    // cost = 1/1e6*1.5 + 2/1e6*7.5 = 0.0000165
    let payload = """
    {
      "start_time": "2026-08-01T02:14:53.745363+00:00",
      "end_time": "2026-08-01T02:15:18.173565+00:00",
      "config": { "active_model": "mistral-medium-3.5" },
      "system_prompt": { "role": "system", "content": "SYS!" },
      "stats": {
        "session_prompt_tokens": 999999,
        "session_completion_tokens": 999999,
        "session_cost": 9.99
      }
    }
    """
    try Data(payload.utf8).write(to: session.appendingPathComponent("meta.json"))
    let jsonl = """
    {"role":"user","content":"USER"}
    {"role":"assistant","content":"ASSISTOK"}
    """
    try Data(jsonl.utf8).write(to: session.appendingPathComponent("messages.jsonl"))

    let summary = try MistralVibeUsageReader.read(
        rootURL: root,
        now: date("2026-08-01T12:00:00Z")
    ) ?? { throw AdditionalProviderTestError.failure("Mistral jsonl estimate did not parse") }()
    try expectClose(summary.currentMonthCostUSD, 0.0000165, "Mistral unique payload cost")
    try expectClose(summary.inputTokens, 1, "Mistral estimated input tokens")
    try expectClose(summary.outputTokens, 2, "Mistral estimated output tokens")
    try expectEqual(
        summary.analyticsBuckets.first?.note,
        "TaskWraith-style chars÷4 × catalogue",
        "Mistral jsonl estimate note"
    )
}

private func testMistralAdminMeterPrefersVibeSpend() throws {
    let withVibe = """
    {
      "currency": "EUR",
      "usage": {
        "chat": { "cost": 1.20 },
        "vibe_usage": { "amount": 0.35 }
      }
    }
    """
    let parsed = try MistralAdminUsageParser.parse(data: Data(withVibe.utf8))
        ?? { throw AdditionalProviderTestError.failure("Mistral Admin payload did not parse") }()
    let adminSpend = parsed.vibeSpend ?? (parsed.totalSpendIsComplete ? parsed.totalSpend : nil)
    try expectClose(adminSpend ?? -1, 0.35, "Admin meter must prefer vibe_usage over totalSpend")
}

private func testMistralAdminUsageParserKeepsOfficialCurrency() throws {
    let payload = """
    {
      "currency": "EUR",
      "usage": {
        "chat": { "cost": 1.20 },
        "vibe_usage": { "amount": 0.35 }
      }
    }
    """
    let result = try MistralAdminUsageParser.parse(data: Data(payload.utf8))
        ?? { throw AdditionalProviderTestError.failure("Mistral Admin payload did not parse") }()
    try expectClose(result.totalSpend, 1.55, "Mistral Admin total")
    try expect(result.totalSpendIsComplete, "All present Mistral categories should form a complete total")
    try expectClose(result.vibeSpend ?? -1, 0.35, "Mistral Admin Vibe portion")
    try expectEqual(result.currency, "EUR", "Mistral Admin currency")
}

private func testMistralAdminUsageParserMarksOpaqueSharedPoolPartial() throws {
    let payload = """
    {
      "chat": { "models": { "mistral-large": { "tokens": [] } } },
      "vibe_usage": 14
    }
    """
    let result = try MistralAdminUsageParser.parse(data: Data(payload.utf8))
        ?? { throw AdditionalProviderTestError.failure("Mistral partial Admin payload did not parse") }()
    try expect(!result.totalSpendIsComplete, "Opaque Mistral categories must not become a shared-pool total")
    try expectClose(result.vibeSpend ?? -1, 14, "Mistral direct Vibe usage")
    try expectEqual(result.currency, "billing units", "Missing Mistral currency must not be guessed as USD")
}

private func testMistralVibeBudgetMigratesLegacySharedPool() throws {
    let migrated = MistralVibeBudgetResolver.effectiveAllowance(
        rawAllowance: 25.5,
        currency: "EUR",
        planName: "Pro",
        configuredBudgetUSD: nil
    )
    try expectClose(migrated ?? -1, 255, "Mistral Pro Vibe budget migration")
    try expect(
        MistralVibeBudgetResolver.shouldDiscardLegacyAnchor(
            rawAllowance: 25.5,
            rawSpent: 1.44,
            currency: "EUR",
            planName: "Pro"
        ),
        "Legacy shared-pool spend must not be added to the Vibe meter"
    )
    try expect(
        !MistralVibeBudgetResolver.shouldDiscardLegacyAnchor(
            rawAllowance: 25.5,
            rawSpent: 36.81,
            currency: "EUR",
            planName: "Pro"
        ),
        "A larger manual Vibe reading must remain authoritative"
    )
    try expectClose(
        MistralVibeBudgetResolver.effectiveAllowance(
            rawAllowance: 255,
            currency: "EUR",
            planName: "Pro",
            configuredBudgetUSD: nil
        ) ?? -1,
        255,
        "Current Vibe budget must not be migrated again"
    )
    try expectClose(
        MistralVibeBudgetResolver.amountInCurrency(10, currency: "EUR") ?? -1,
        9.2,
        "Automatic local Vibe spend currency conversion"
    )
}

private func testMistralManualAnchorAccumulatesAcrossMonthAndScanGaps() throws {
    let suiteName = "limit-counter-mistral-watermark-tests-\(UUID().uuidString)"
    let defaults = try UserDefaults(suiteName: suiteName)
        ?? { throw AdditionalProviderTestError.failure("Could not create isolated defaults") }()
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let july = date("2026-07-31T12:00:00Z")
    let august = date("2026-08-01T12:00:00Z")
    let initial = MistralAnchorWatermarkStore.adjustedSpend(
        anchoredSpend: 5,
        currentLocalSpendUSD: 10,
        currency: "USD",
        signature: "anchor-a",
        now: july,
        defaults: defaults
    )
    let advanced = MistralAnchorWatermarkStore.adjustedSpend(
        anchoredSpend: 5,
        currentLocalSpendUSD: 10.5,
        currency: "USD",
        signature: "anchor-a",
        now: july,
        defaults: defaults
    )
    let partialScan = MistralAnchorWatermarkStore.adjustedSpend(
        anchoredSpend: 5,
        currentLocalSpendUSD: 9,
        currency: "USD",
        signature: "anchor-a",
        now: july,
        defaults: defaults
    )
    let recoveredScan = MistralAnchorWatermarkStore.adjustedSpend(
        anchoredSpend: 5,
        currentLocalSpendUSD: 10.5,
        currency: "USD",
        signature: "anchor-a",
        now: july,
        defaults: defaults
    )
    let nextMonth = MistralAnchorWatermarkStore.adjustedSpend(
        anchoredSpend: 5,
        currentLocalSpendUSD: 0.2,
        currency: "USD",
        signature: "anchor-a",
        now: august,
        defaults: defaults
    )
    let missingScan = MistralAnchorWatermarkStore.adjustedSpend(
        anchoredSpend: 5,
        currentLocalSpendUSD: nil,
        currency: "USD",
        signature: "anchor-a",
        now: august,
        defaults: defaults
    )
    let convertedInitial = MistralAnchorWatermarkStore.adjustment(
        anchoredSpend: 5,
        currentLocalSpendUSD: 20,
        currency: "GBP",
        signature: "anchor-b",
        initialLocalIncrementUSD: 0.25,
        now: august,
        defaults: defaults
    )
    let convertedAdvanced = MistralAnchorWatermarkStore.adjustment(
        anchoredSpend: 5,
        currentLocalSpendUSD: 20.5,
        currency: "GBP",
        signature: "anchor-b",
        now: august,
        defaults: defaults
    )

    try expectClose(initial, 5, "Mistral anchor baseline")
    try expectClose(advanced, 5.5, "Mistral post-anchor local delta")
    try expectClose(partialScan, 5.5, "Mistral partial scan must not reduce spend")
    try expectClose(recoveredScan, 5.5, "Mistral recovered scan must not double count")
    try expectClose(nextMonth, 5.7, "Mistral month rollover accumulation")
    try expectClose(missingScan, 5.7, "Mistral missing scan must preserve accumulated spend")
    try expectClose(convertedInitial.spend, 5.1975, "Mistral recovered GBP increment")
    try expectClose(convertedInitial.localIncrement, 0.1975, "Mistral GBP increment provenance")
    try expectClose(convertedAdvanced.spend, 5.5925, "Mistral live GBP accumulation")
}

private func testDeepSeekBalanceAndObservedSpendSemantics() throws {
    let payload = """
    {
      "is_available": true,
      "balance_infos": [{
        "currency": "USD",
        "total_balance": "9.08",
        "granted_balance": "0.00",
        "topped_up_balance": "9.08"
      }]
    }
    """
    let balance = try DeepSeekBalanceParser.parse(data: Data(payload.utf8))
        ?? { throw AdditionalProviderTestError.failure("DeepSeek balance did not parse") }()
    try expectClose(balance.totalBalance, 9.08, "DeepSeek total balance")
    try expectClose(balance.toppedUpBalance, 9.08, "DeepSeek topped-up balance")

    let creditUsed = try DeepSeekTopUpMeter.creditUsed(totalTopUp: 10, currentBalance: balance.totalBalance)
        ?? { throw AdditionalProviderTestError.failure("DeepSeek top-up meter was not derived") }()
    try expectClose(creditUsed, 0.92, "DeepSeek credit used from cumulative top-ups")
    try expectClose(
        DeepSeekTopUpMeter.creditUsed(totalTopUp: 8, currentBalance: balance.totalBalance) ?? -1,
        0,
        "DeepSeek credit used clamps when grants put balance above top-ups"
    )
    try expect(
        DeepSeekTopUpMeter.creditUsed(totalTopUp: nil, currentBalance: balance.totalBalance) == nil,
        "DeepSeek top-up meter remains optional"
    )

    let initial = DeepSeekObservedSpendAccumulator.updated(
        previous: nil,
        balance: 10,
        currency: "USD",
        monthKey: "2026-08"
    )
    let spent = DeepSeekObservedSpendAccumulator.updated(
        previous: initial,
        balance: 9.20,
        currency: "USD",
        monthKey: "2026-08"
    )
    let toppedUp = DeepSeekObservedSpendAccumulator.updated(
        previous: spent,
        balance: 12,
        currency: "USD",
        monthKey: "2026-08"
    )
    let afterTopUpSpend = DeepSeekObservedSpendAccumulator.updated(
        previous: toppedUp,
        balance: 11.50,
        currency: "USD",
        monthKey: "2026-08"
    )
    let nextMonth = DeepSeekObservedSpendAccumulator.updated(
        previous: afterTopUpSpend,
        balance: 11,
        currency: "USD",
        monthKey: "2026-09"
    )
    try expectClose(spent.observedSpend, 0.80, "DeepSeek observed balance decrease")
    try expectClose(toppedUp.observedSpend, 0.80, "DeepSeek top-up must not count as negative spend")
    try expectClose(afterTopUpSpend.observedSpend, 1.30, "DeepSeek spend after top-up")
    try expectClose(nextMonth.observedSpend, 0, "DeepSeek month boundary reset")
}

private func testTaskWraithPricingIsProviderScopedAndEstimated() throws {
    let now = date("2026-08-01T12:00:00Z")
    let timestamp = now.timeIntervalSince1970 * 1_000
    let priorMonthTimestamp = now.addingTimeInterval(-20 * 86_400).timeIntervalSince1970 * 1_000
    let payload = """
    [
      {
        "provider": "pi",
        "model": "deepseek/deepseek-v4-flash",
        "timestamp": \(timestamp),
        "inputTokens": 1000000,
        "outputTokens": 500000,
        "cacheReadInputTokens": 2000000,
        "cacheCreationInputTokens": 1000000
      },
      {
        "provider": "pi",
        "model": "deepseek/deepseek-v4-flash",
        "timestamp": \(priorMonthTimestamp),
        "inputTokens": 1000000,
        "outputTokens": 0
      },
      {
        "provider": "pi",
        "model": "cerebras/zai-glm-4.7",
        "timestamp": \(timestamp),
        "inputTokens": 1000000,
        "outputTokens": 1000000
      }
    ]
    """
    let summary = try TaskWraithSpendReader.parse(
        data: Data(payload.utf8),
        provider: .deepseek,
        now: now
    ) ?? { throw AdditionalProviderTestError.failure("TaskWraith spend did not parse") }()
    try expectClose(summary.currentMonthCostUSD, 0.4256, "DeepSeek TaskWraith monthly price estimate")
    try expectClose(summary.last35DaysCostUSD, 0.5656, "DeepSeek TaskWraith 35-day price estimate")
    try expectEqual(summary.analyticsBuckets.count, 2, "TaskWraith provider and period filter")
    try expectEqual(summary.analyticsBuckets.first?.source, .localEstimate, "TaskWraith estimate provenance")
}

private func museSparkRate() -> MuseModelRate {
    MuseModelRate.sparkDefault
}

private func testMuseCostEstimatorMatchesSparkSessionTotals() throws {
    let rate = museSparkRate()
    // 16009 * 1.25e-6 + 130 * 4.25e-6 ≈ 0.02056 (catalog Spark rates)
    let plain = MuseCostEstimator.estimateUSD(
        input: 16_009,
        output: 130,
        cacheRead: 0,
        rate: rate
    )
    try expectClose(Double(plain), 0.02056375, "Muse Spark session cost without cache")

    // Live-session style: omitted / zero cacheCreation must match plain MuseUsage.ts cost.
    let liveSessionOmitted = MuseCostEstimator.estimateUSD(
        input: 16_009,
        output: 130,
        cacheRead: 0,
        rate: rate
    )
    let liveSessionZero = MuseCostEstimator.estimateUSD(
        input: 16_009,
        output: 130,
        cacheRead: 0,
        cacheCreation: 0,
        rate: rate
    )
    try expectClose(Double(liveSessionOmitted), Double(plain), "Omitted cacheCreation matches live session cost")
    try expectClose(Double(liveSessionZero), Double(plain), "Zero cacheCreation matches live session cost")

    let withCache = MuseCostEstimator.estimateUSD(
        input: 16_009,
        output: 130,
        cacheRead: 1_000,
        rate: rate
    )
    // Billable input excludes cache-read: (15009*1.25 + 1000*0.15 + 130*4.25) / 1e6
    try expectClose(Double(withCache), 0.01946375, "Muse billable input excludes cache-read tokens")
    try expect(Double(withCache) < Double(plain), "Cache-read pricing must reduce cost vs full input rate")

    // TaskWraith journal path: cacheCreation billed at input rate on top of plain cost.
    let withCreation = MuseCostEstimator.estimateUSD(
        input: 16_009,
        output: 130,
        cacheRead: 0,
        cacheCreation: 2_000,
        rate: rate
    )
    try expectClose(Double(withCreation), Double(plain) + 0.0025, "cacheCreation 2000 @ Spark adds 0.0025")
}

private func testMuseSessionUsageReducerCountsProviderAttributionOnce() throws {
    let attribution = """
    {"schema_version":1,"id":"attr-1","stream":{"kind":"session","id":"sess-1"},"sequence":33,"payload_type":"runtime.session","payload":{"kind":"run","run_id":"run-1","event":{"kind":"goal_usage_attribution","record":{"usage_id":"usage-1","usage_family":"provider","quantity":{"unit":"tokens","reported":true,"input_tokens":16009,"output_tokens":130,"cached_tokens":0,"reasoning_tokens":40}}}}}
    """
    let completed = """
    {"schema_version":1,"id":"done-1","stream":{"kind":"session","id":"sess-1"},"sequence":34,"payload_type":"runtime.session","payload":{"kind":"run","run_id":"run-1","event":{"kind":"model_completed","usage":{"input_tokens":16009,"output_tokens":130,"cached_tokens":0,"cache_read_tokens":0,"cache_write_tokens":0,"reasoning_tokens":40},"duration_ms":1745,"model":"muse-spark-1.2"}}}
    """
    let duplicateAttribution = """
    {"schema_version":1,"id":"attr-1-dup","stream":{"kind":"session","id":"sess-1"},"sequence":35,"payload_type":"runtime.session","payload":{"kind":"run","run_id":"run-1","event":{"kind":"goal_usage_attribution","record":{"usage_id":"usage-1","usage_family":"provider","quantity":{"unit":"tokens","reported":true,"input_tokens":16009,"output_tokens":130,"cached_tokens":0}}}}}
    """
    let toolFamily = """
    {"schema_version":1,"id":"tool-1","stream":{"kind":"session","id":"sess-1"},"sequence":36,"payload_type":"runtime.session","payload":{"kind":"run","run_id":"run-1","event":{"kind":"goal_usage_attribution","record":{"usage_id":"usage-tool","usage_family":"tool","quantity":{"unit":"tokens","reported":true,"input_tokens":999,"output_tokens":9}}}}}
    """
    let unreported = """
    {"schema_version":1,"id":"est-1","stream":{"kind":"session","id":"sess-1"},"sequence":37,"payload_type":"runtime.session","payload":{"kind":"run","run_id":"run-1","event":{"kind":"goal_usage_attribution","record":{"usage_id":"usage-est","usage_family":"provider","quantity":{"unit":"tokens","reported":false,"input_tokens":888,"output_tokens":8}}}}}
    """

    var reducer = MuseSessionUsageReducer(museSessionId: "sess-1", logPath: "/tmp/session.jsonl")
    reducer.ingestLine(attribution)
    reducer.ingestLine(completed)
    let snap = reducer.snapshot(rate: museSparkRate())
    try expectClose(Double(snap.inputTokens), 16_009, "Muse attribution input tokens")
    try expectClose(Double(snap.outputTokens), 130, "Muse attribution output tokens")
    try expectClose(Double(snap.totalTokens), 16_139, "Muse total excludes reasoning")
    try expect(snap.model == "muse-spark-1.2", "Muse model from model_completed")
    try expectClose(snap.estimatedCostUSD ?? -1, 0.02056375, "Muse snapshot cost once")

    reducer.ingestLine(duplicateAttribution)
    reducer.ingestLine(toolFamily)
    reducer.ingestLine(unreported)
    let afterNoise = reducer.snapshot(rate: museSparkRate())
    try expectClose(Double(afterNoise.inputTokens), 16_009, "Duplicate usage_id and ignored families must not double count")
    try expectClose(Double(afterNoise.outputTokens), 130, "Ignored attribution must not add output")
    try expectClose(afterNoise.estimatedCostUSD ?? -1, 0.02056375, "Cost stays single-counted")
}

private func testMetaCreditUsedAndDefaultMonthlyReset() throws {
    let creditUsed = try DeepSeekTopUpMeter.creditUsed(totalTopUp: 15, currentBalance: 14.95)
        ?? { throw AdditionalProviderTestError.failure("Meta preload credit used was not derived") }()
    try expectClose(creditUsed, 0.05, "Meta preload 15 remaining 14.95 → credit used")

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
    let midMonth = calendar.date(from: DateComponents(year: 2026, month: 8, day: 10, hour: 15))!
    let reset = MetaBillingReset.nextResetDate(from: midMonth, calendar: calendar)
    let parts = calendar.dateComponents([.year, .month, .day], from: reset)
    try expectEqual(parts.year, 2026, "Meta reset year")
    try expectEqual(parts.month, 9, "Meta reset lands on next month")
    try expectEqual(parts.day, 1, "Meta reset lands on day 1")
}

private func testMetaRemainingWatermarkAdvancesAndResetsOnMonth() throws {
    let suiteName = "limit-counter-meta-watermark-tests-\(UUID().uuidString)"
    let defaults = try UserDefaults(suiteName: suiteName)
        ?? { throw AdditionalProviderTestError.failure("Could not create isolated defaults") }()
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let august = date("2026-08-10T12:00:00Z")
    let september = date("2026-09-02T12:00:00Z")

    let baseline = MetaRemainingWatermarkStore.adjustment(
        anchoredRemaining: 15,
        currentObservedMonthUSD: 0.02,
        currency: "USD",
        signature: "sig-a",
        now: august,
        defaults: defaults
    )
    try expectClose(baseline.effectiveRemaining, 15, "Meta remaining baseline leaves anchor intact")
    try expectClose(baseline.localDecrementUSD, 0, "Meta remaining baseline decrement is zero")

    let advanced = MetaRemainingWatermarkStore.adjustment(
        anchoredRemaining: 15,
        currentObservedMonthUSD: 0.05,
        currency: "USD",
        signature: "sig-a",
        now: august,
        defaults: defaults
    )
    try expectClose(advanced.effectiveRemaining, 14.97, "Meta remaining advances with observed spend")
    try expectClose(advanced.localDecrementUSD, 0.03, "Meta remaining decrement tracks observed delta")

    let regression = MetaRemainingWatermarkStore.adjustment(
        anchoredRemaining: 15,
        currentObservedMonthUSD: 0.04,
        currency: "USD",
        signature: "sig-a",
        now: august,
        defaults: defaults
    )
    try expectClose(regression.effectiveRemaining, 14.97, "Meta remaining must not rise when observed regresses")
    try expectClose(regression.localDecrementUSD, 0.03, "Meta remaining decrement never decreases")

    let nextMonth = MetaRemainingWatermarkStore.adjustment(
        anchoredRemaining: 15,
        currentObservedMonthUSD: 0.01,
        currency: "USD",
        signature: "sig-a",
        now: september,
        defaults: defaults
    )
    // Previous accumulated 0.03 + new-month MTD 0.01 = 0.04 (like Mistral month rollover).
    try expectClose(nextMonth.effectiveRemaining, 14.96, "Meta remaining month rollover preserves accumulated drain")
    try expectClose(nextMonth.localDecrementUSD, 0.04, "Meta remaining month rollover adds new-month MTD")

    let afterMonthAdvance = MetaRemainingWatermarkStore.adjustment(
        anchoredRemaining: 15,
        currentObservedMonthUSD: 0.08,
        currency: "USD",
        signature: "sig-a",
        now: september,
        defaults: defaults
    )
    try expectClose(afterMonthAdvance.effectiveRemaining, 14.89, "Meta remaining re-accumulates in new month")
    try expectClose(afterMonthAdvance.localDecrementUSD, 0.11, "Meta remaining new-month decrement continues from preserved baseline")

    let missingScan = MetaRemainingWatermarkStore.adjustment(
        anchoredRemaining: 15,
        currentObservedMonthUSD: nil,
        currency: "USD",
        signature: "sig-a",
        now: september,
        defaults: defaults
    )
    try expectClose(missingScan.effectiveRemaining, 14.89, "Meta remaining missing scan preserves accumulated decrement")
    try expectClose(missingScan.localDecrementUSD, 0.11, "Meta remaining missing scan keeps local decrement")

    let rebased = MetaRemainingWatermarkStore.adjustment(
        anchoredRemaining: 12,
        currentObservedMonthUSD: 0.50,
        currency: "USD",
        signature: "sig-b",
        now: september,
        defaults: defaults
    )
    try expectClose(rebased.effectiveRemaining, 12, "Meta remaining signature change rebases to new anchor")
    try expectClose(rebased.localDecrementUSD, 0, "Meta remaining signature change clears decrement")

    let unknownCurrency = MetaRemainingWatermarkStore.adjustment(
        anchoredRemaining: 10,
        currentObservedMonthUSD: 2,
        currency: "JPY",
        signature: "sig-jpy",
        now: september,
        defaults: defaults
    )
    try expectClose(unknownCurrency.effectiveRemaining, 10, "Meta remaining unknown currency skips auto-decrement")
    try expectClose(unknownCurrency.localDecrementUSD, 0, "Meta remaining unknown currency decrement is zero")
}

private func testMetaRemainingWatermarkConvertsGBP() throws {
    let suiteName = "limit-counter-meta-gbp-remaining-\(UUID().uuidString)"
    let defaults = try UserDefaults(suiteName: suiteName)
        ?? { throw AdditionalProviderTestError.failure("Could not create isolated defaults") }()
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let now = date("2026-08-10T12:00:00Z")
    let baseline = MetaRemainingWatermarkStore.adjustment(
        anchoredRemaining: 15,
        currentObservedMonthUSD: 0.02,
        currency: "GBP",
        signature: "gbp-remaining",
        now: now,
        defaults: defaults
    )
    try expectClose(baseline.effectiveRemaining, 15, "Meta GBP remaining baseline leaves anchor intact")
    try expectClose(baseline.localDecrementUSD, 0, "Meta GBP remaining baseline decrement is zero")

    let advanced = MetaRemainingWatermarkStore.adjustment(
        anchoredRemaining: 15,
        currentObservedMonthUSD: 0.12,
        currency: "GBP",
        signature: "gbp-remaining",
        now: now,
        defaults: defaults
    )
    // USD observed delta 0.10 × 0.79 = 0.079 GBP → remaining 15 → 14.921
    try expectClose(advanced.localDecrementUSD, 0.079, "Meta GBP remaining converts USD delta via FX")
    try expectClose(advanced.effectiveRemaining, 14.921, "Meta GBP remaining decrements in billing currency")
}

private func testMetaSpendWatermarkAccumulatesLikeMistral() throws {
    let suiteName = "limit-counter-meta-spend-watermark-tests-\(UUID().uuidString)"
    let defaults = try UserDefaults(suiteName: suiteName)
        ?? { throw AdditionalProviderTestError.failure("Could not create isolated defaults") }()
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let july = date("2026-07-31T12:00:00Z")
    let august = date("2026-08-01T12:00:00Z")

    try expectClose(
        MetaSpendWatermarkStore.amountInCurrency(1, currency: "GBP") ?? -1,
        0.79,
        "Meta spend GBP conversion"
    )
    try expectClose(
        MetaSpendWatermarkStore.amountInCurrency(1, currency: "EUR") ?? -1,
        0.92,
        "Meta spend EUR conversion"
    )
    try expectClose(
        MetaSpendWatermarkStore.amountInCurrency(1, currency: "USD") ?? -1,
        1,
        "Meta spend USD conversion"
    )

    let initial = MetaSpendWatermarkStore.adjustment(
        anchoredSpend: 0.05,
        currentLocalSpendUSD: 0.02,
        currency: "GBP",
        signature: "meta-anchor-a",
        initialLocalIncrementUSD: 0.02,
        now: july,
        defaults: defaults
    )
    try expectClose(initial.spend, 0.05 + 0.02 * 0.79, "Meta spend converts console anchor plus local USD")
    try expectClose(initial.localIncrement, 0.02 * 0.79, "Meta spend GBP increment from recovered local")

    let advanced = MetaSpendWatermarkStore.adjustment(
        anchoredSpend: 0.05,
        currentLocalSpendUSD: 0.05,
        currency: "GBP",
        signature: "meta-anchor-a",
        now: july,
        defaults: defaults
    )
    // Accumulated 0.02 + delta 0.03 = 0.05 USD × 0.79
    try expectClose(advanced.spend, 0.05 + 0.05 * 0.79, "Meta spend advances with local Muse USD")
    try expectClose(advanced.localIncrement, 0.05 * 0.79, "Meta spend GBP increment grows")

    let regression = MetaSpendWatermarkStore.adjustment(
        anchoredSpend: 0.05,
        currentLocalSpendUSD: 0.04,
        currency: "GBP",
        signature: "meta-anchor-a",
        now: july,
        defaults: defaults
    )
    try expectClose(regression.spend, 0.05 + 0.05 * 0.79, "Meta spend never shrinks on partial scan")
    try expectClose(regression.localIncrement, 0.05 * 0.79, "Meta spend increment never decreases")

    let recovered = MetaSpendWatermarkStore.adjustment(
        anchoredSpend: 0.05,
        currentLocalSpendUSD: 0.05,
        currency: "GBP",
        signature: "meta-anchor-a",
        now: july,
        defaults: defaults
    )
    try expectClose(recovered.spend, 0.05 + 0.05 * 0.79, "Meta spend recovered scan must not double count")

    let nextMonth = MetaSpendWatermarkStore.adjustment(
        anchoredSpend: 0.05,
        currentLocalSpendUSD: 0.01,
        currency: "GBP",
        signature: "meta-anchor-a",
        now: august,
        defaults: defaults
    )
    // Previous accumulated 0.05 + new-month MTD 0.01 = 0.06 USD × 0.79
    try expectClose(nextMonth.spend, 0.05 + 0.06 * 0.79, "Meta spend month rollover preserves + adds")
    try expectClose(nextMonth.localIncrement, 0.06 * 0.79, "Meta spend month rollover local increment")

    let missingScan = MetaSpendWatermarkStore.adjustment(
        anchoredSpend: 0.05,
        currentLocalSpendUSD: nil,
        currency: "GBP",
        signature: "meta-anchor-a",
        now: august,
        defaults: defaults
    )
    try expectClose(missingScan.spend, 0.05 + 0.06 * 0.79, "Meta spend missing scan preserves accumulated")
}

private func testMetaSpendWatermarkWithZeroAnchorAccumulatesLocal() throws {
    let suiteName = "limit-counter-meta-zero-anchor-\(UUID().uuidString)"
    let defaults = try UserDefaults(suiteName: suiteName)
        ?? { throw AdditionalProviderTestError.failure("Could not create isolated defaults") }()
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let now = date("2026-08-10T12:00:00Z")
    let seeded = MetaSpendWatermarkStore.adjustment(
        anchoredSpend: 0,
        currentLocalSpendUSD: 0.05,
        currency: "GBP",
        signature: "zero-anchor",
        initialLocalIncrementUSD: 0.05,
        now: now,
        defaults: defaults
    )
    try expectClose(seeded.spend, 0.05 * 0.79, "Meta zero-anchor spend converts local USD to GBP")
    try expectClose(seeded.localIncrement, 0.05 * 0.79, "Meta zero-anchor local increment in GBP")
}

private func testTaskWraithMusePricingUsesMuseCostEstimator() throws {
    let now = date("2026-08-10T12:00:00Z")
    let timestamp = now.timeIntervalSince1970 * 1_000
    let payload = """
    [
      {
        "provider": "muse",
        "model": "muse-spark-1.2",
        "timestamp": \(timestamp),
        "inputTokens": 16009,
        "outputTokens": 130,
        "cacheReadInputTokens": 0,
        "cacheCreationInputTokens": 0
      },
      {
        "provider": "muse",
        "model": "muse-spark-1.2",
        "timestamp": \(timestamp),
        "inputTokens": 0,
        "outputTokens": 0,
        "cacheReadInputTokens": 0,
        "cacheCreationInputTokens": 2000
      },
      {
        "provider": "pi",
        "model": "deepseek/deepseek-v4-flash",
        "timestamp": \(timestamp),
        "inputTokens": 1000000,
        "outputTokens": 0
      }
    ]
    """
    let summary = try TaskWraithSpendReader.parse(
        data: Data(payload.utf8),
        provider: .meta,
        now: now
    ) ?? { throw AdditionalProviderTestError.failure("TaskWraith Muse spend did not parse") }()
    // Plain Spark session (0.02056375) + cacheCreation 2000 @ 1.25/1e6 (= 0.0025)
    try expectClose(
        summary.currentMonthCostUSD,
        0.02306375,
        "Meta TaskWraith prices Muse rows including cacheCreation at input rate"
    )
    try expectEqual(summary.analyticsBuckets.count, 1, "Meta TaskWraith ignores non-muse providers")
    try expectEqual(summary.analyticsBuckets.first?.source, .localEstimate, "Muse TaskWraith estimate provenance")
    try expectEqual(summary.analyticsBuckets.first?.model, "muse-spark-1.2", "Muse TaskWraith model")
}

private func testCerebrasCSVHandlesQuotedNumbersAndCurrency() throws {
    let payload = """
    Date (UTC),Model,Cost (USD),Input Tokens,Output Tokens,Requests,Currency
    2026-08-01T12:00:00Z,zai-glm-4.7,"$0.42","1,000","2,000",3,USD
    Total,,"$0.42","1,000","2,000",3,USD
    """
    let summary = try CerebrasCSVUsageParser.parse(
        data: Data(payload.utf8),
        now: date("2026-08-01T12:00:00Z")
    ) ?? { throw AdditionalProviderTestError.failure("Cerebras CSV did not parse") }()
    try expectClose(summary.cost, 0.42, "Cerebras CSV cost")
    try expectEqual(summary.currency, "USD", "Cerebras CSV currency")
    try expectClose(summary.analyticsBuckets.first?.inputTokens ?? -1, 1_000, "Cerebras CSV input tokens")
    try expectClose(summary.analyticsBuckets.first?.outputTokens ?? -1, 2_000, "Cerebras CSV output tokens")
    try expectEqual(summary.analyticsBuckets.first?.source, .officialAPI, "Cerebras CSV provenance")
}

private func testCurrencyFormatting() throws {
    try expectEqual(formattedMetricValue(12.5, unit: "GBP"), "£12.50", "GBP formatting")
    try expectEqual(formattedMetricValue(12.5, unit: "EUR"), "€12.50", "EUR formatting")
    try expectEqual(
        formattedMetricValue(0.1304, unit: "GBP", maximumFractionDigits: 4),
        "£0.1304",
        "Tracked Mistral sub-cent formatting"
    )
    try expectEqual(
        formattedMetricValue(0.13, unit: "GBP", maximumFractionDigits: 4),
        "£0.13",
        "Tracked Mistral formatting trims empty precision"
    )
    let window = QuotaWindow(
        label: "This billing period",
        windowKind: .monthly,
        used: 0.35,
        total: 25.5,
        unit: "GBP"
    )
    try expectEqual(window.leadingValueText, "£0.35", "financial window headline")
    try expectEqual(
        window.leadingValueText(for: .mistral),
        "£0.35",
        "Mistral headline preserves ordinary precision"
    )
    try expectEqual(window.measurementSummary, "£0.35 of £25.50", "financial allowance summary")
    let cnyWindow = QuotaWindow(
        label: "Credit used",
        windowKind: .custom,
        used: 1.5,
        total: 10,
        unit: "CNY"
    )
    try expectEqual(cnyWindow.leadingValueText, "1.50 CNY", "ISO currency amount headline")
}

@main
private enum AdditionalProviderUsageTestRunner {
    static func main() throws {
        try testAntigravityParsesOfficialGeminiBucketsOnly()
        try testAntigravityFailsClosedWithoutBothGeminiBuckets()
        try testAntigravityParsesOfficialOAuthEnvelope()
        try testAntigravityImportAcceptsOfficialCLIDataFolder()
        try testAntigravityRefreshCadenceLoopsFourSevenSixteenThreeTwentyOne()
        try testMistralCatalogueRatesAndCharsEstimate()
        try testMistralLocalCostUsesTaskWraithEstimateDoctrine()
        try testMistralJsonlUniquePayloadCharsEstimate()
        try testMistralAdminMeterPrefersVibeSpend()
        try testMistralAdminUsageParserKeepsOfficialCurrency()
        try testMistralAdminUsageParserMarksOpaqueSharedPoolPartial()
        try testMistralVibeBudgetMigratesLegacySharedPool()
        try testMistralManualAnchorAccumulatesAcrossMonthAndScanGaps()
        try testDeepSeekBalanceAndObservedSpendSemantics()
        try testTaskWraithPricingIsProviderScopedAndEstimated()
        try testMuseCostEstimatorMatchesSparkSessionTotals()
        try testMuseSessionUsageReducerCountsProviderAttributionOnce()
        try testMetaCreditUsedAndDefaultMonthlyReset()
        try testMetaRemainingWatermarkAdvancesAndResetsOnMonth()
        try testMetaRemainingWatermarkConvertsGBP()
        try testMetaSpendWatermarkAccumulatesLikeMistral()
        try testMetaSpendWatermarkWithZeroAnchorAccumulatesLocal()
        try testTaskWraithMusePricingUsesMuseCostEstimator()
        try testCerebrasCSVHandlesQuotedNumbersAndCurrency()
        try testCurrencyFormatting()
        print("Additional provider usage tests passed")
    }
}
