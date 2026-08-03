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

private func testMistralReadsOnlySessionMetadataTotals() throws {
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
        "input_price_per_million": 1.5,
        "output_price_per_million": 7.5,
        "session_cost": 0.053832
      }
    }
    """
    try Data(payload.utf8).write(to: session.appendingPathComponent("meta.json"))

    let summary = try MistralVibeUsageReader.read(
        rootURL: root,
        now: date("2026-08-01T12:00:00Z")
    ) ?? { throw AdditionalProviderTestError.failure("Mistral metadata did not parse") }()
    try expectClose(summary.currentMonthCostUSD, 0.053832, "Mistral current-month cost")
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
    try expectEqual(summary.analyticsBuckets.first?.source, .localTelemetry, "Mistral source provenance")
    let timestampFormatter = ISO8601DateFormatter()
    timestampFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    try expectEqual(
        summary.events.first?.timestamp,
        timestampFormatter.date(from: "2026-08-01T02:15:18.173565+00:00"),
        "Mistral fractional timestamp"
    )
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
        try testMistralReadsOnlySessionMetadataTotals()
        try testMistralAdminUsageParserKeepsOfficialCurrency()
        try testMistralAdminUsageParserMarksOpaqueSharedPoolPartial()
        try testMistralManualAnchorAccumulatesAcrossMonthAndScanGaps()
        try testDeepSeekBalanceAndObservedSpendSemantics()
        try testTaskWraithPricingIsProviderScopedAndEstimated()
        try testCerebrasCSVHandlesQuotedNumbersAndCurrency()
        try testCurrencyFormatting()
        print("Additional provider usage tests passed")
    }
}
