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

/// The other direction, for fixtures that have to stay relative to the clock.
/// A hard-coded "far future" date drifts into range as time passes and quietly
/// turns a passing test into a failing one.
private func isoString(_ value: Date) -> String {
    ISO8601DateFormatter().string(from: value)
}
private func testCodexSessionCredentialParserSupportsNestedAndDirectAuth() throws {
    let nested = CodexSessionCredentialParser.parse([
        "tokens": [
            "access_token": "nested-token",
            "account_id": "nested-account"
        ]
    ])
    try expectEqual(nested?.accessToken, "nested-token", "Codex nested access token")
    try expectEqual(nested?.accountIdentifier, "nested-account", "Codex nested account")

    let direct = CodexSessionCredentialParser.parse([
        "access_token": "direct-token",
        "account_id": "direct-account"
    ])
    try expectEqual(direct?.accessToken, "direct-token", "Codex direct access token")
    try expectEqual(direct?.accountIdentifier, "direct-account", "Codex direct account")
}

private func testCodexSessionCredentialReaderFollowsDirectoryRotation() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("limit-counter-codex-auth-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try """
    {"tokens":{"access_token":"rotated-token","account_id":"rotated-account"}}
    """.write(
        to: root.appendingPathComponent("auth.json"),
        atomically: true,
        encoding: .utf8
    )

    let stored = ProviderCredential(
        accessToken: "stale-token",
        accountIdentifier: "stale-account",
        customEndpoint: root.path,
        extraFields: ["codexAuthSource": "directory"]
    )
    let refreshed = CodexSessionCredentialReader.refreshedCredential(from: stored)

    try expectEqual(refreshed?.accessToken, "rotated-token", "Codex rotated access token")
    try expectEqual(refreshed?.accountIdentifier, "rotated-account", "Codex rotated account")

    let pasted = ProviderCredential(accessToken: "pasted-token", accountIdentifier: "pasted-account")
    let pastedRefresh = CodexSessionCredentialReader.refreshedCredential(from: pasted)
    try expect(
        pastedRefresh.map { _ in false } ?? true,
        "pasted Codex credentials should remain independent of local files"
    )
}

private func testCodexDirectoryImportStoresPersistentSource() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("limit-counter-codex-import-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try """
    {"tokens":{"access_token":"import-token","account_id":"import-account"}}
    """.write(
        to: root.appendingPathComponent("auth.json"),
        atomically: true,
        encoding: .utf8
    )

    let imported = try CredentialImportService.importFromURL(root, for: .openai)
    try expectEqual(imported.accessToken, "import-token", "Codex directory import token")
    try expectEqual(imported.accountIdentifier, "import-account", "Codex directory import account")
    try expectEqual(imported.customEndpoint, root.path, "Codex directory import root")
    try expectEqual(imported.extraFields?["codexAuthSource"], "directory", "Codex directory source")
    try expect(imported.bookmarkData != nil, "Codex directory import should retain a security-scoped bookmark")
}

private func testAntigravityParsesOfficialGeminiAndClaudeGPTBuckets() throws {
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
    try expectEqual(parsed.windows.count, 3, "Gemini + Claude/GPT window count")
    let weekly = try parsed.windows.first(where: { $0.label == "Gemini Weekly" })
        ?? { throw AdditionalProviderTestError.failure("Missing Gemini weekly window") }()
    let fiveHour = try parsed.windows.first(where: { $0.label == "Gemini 5H" })
        ?? { throw AdditionalProviderTestError.failure("Missing Gemini five-hour window") }()
    let p3Weekly = try parsed.windows.first(where: { $0.label == "Claude/GPT Weekly" })
        ?? { throw AdditionalProviderTestError.failure("Missing Claude/GPT weekly window") }()
    
    try expectClose(weekly.used, 58, "weekly remaining must invert to used")
    try expectClose(fiveHour.used, 0, "available five-hour quota must be unused")
    try expectEqual(weekly.resetDate, date("2026-08-05T07:44:00Z"), "Antigravity reset timestamp")
    try expectClose(p3Weekly.used, 95, "3p-weekly remaining must invert to used")
    let windowLabels = parsed.windows.map(\.label)
    try expectEqual(
        windowLabels,
        ["Gemini 5H", "Gemini Weekly", "Claude/GPT Weekly"],
        "Gemini windows stay adjacent to the 3P bucket"
    )
}

private func testAntigravityParsesSeparatedClaudeAndGPTBuckets() throws {
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
              "bucketId": "claude-5h",
              "displayName": "Five Hour Limit",
              "remainingFraction": 0.6,
              "resetTime": "2026-08-01T22:00:00Z"
            },
            {
              "bucketId": "claude-weekly",
              "displayName": "Weekly Limit",
              "remainingFraction": 0.3,
              "resetTime": "2026-08-05T07:44:00Z"
            },
            {
              "bucketId": "gpt-5h",
              "displayName": "Five Hour Limit",
              "remainingFraction": 0.7,
              "resetTime": "2026-08-01T22:00:00Z"
            },
            {
              "bucketId": "gpt-weekly",
              "displayName": "Weekly Limit",
              "remainingFraction": 0.85,
              "resetTime": "2026-08-06T07:44:00Z"
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

    let labels = parsed.windows.map(\.label)
    try expectEqual(
        labels,
        [
            "Gemini 5H",
            "Gemini Weekly",
            "Claude 5H",
            "Claude Weekly",
            "GPT 5H",
            "GPT Weekly"
        ],
        "Gemini and Claude/GPT windows should stay adjacent by family"
    )

    let claude5h = try parsed.windows.first(where: { $0.label == "Claude 5H" })
        ?? { throw AdditionalProviderTestError.failure("Missing Claude 5H window") }()
    let claudeWeekly = try parsed.windows.first(where: { $0.label == "Claude Weekly" })
        ?? { throw AdditionalProviderTestError.failure("Missing Claude Weekly window") }()
    let gpt5h = try parsed.windows.first(where: { $0.label == "GPT 5H" })
        ?? { throw AdditionalProviderTestError.failure("Missing GPT 5H window") }()
    let gptWeekly = try parsed.windows.first(where: { $0.label == "GPT Weekly" })
        ?? { throw AdditionalProviderTestError.failure("Missing GPT Weekly window") }()

    try expectClose(claude5h.used, 40, "Claude 5h remaining should invert")
    try expectClose(claudeWeekly.used, 70, "Claude weekly remaining should invert")
    try expectClose(gpt5h.used, 30, "GPT 5h remaining should invert")
    try expectClose(gptWeekly.used, 15, "GPT weekly remaining should invert")
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

private func testMistralWebParserReadsSubscriptionPage() throws {
    let now = date("2026-08-18T17:00:00Z")
    let html = """
    <!DOCTYPE html>
    <html><head><title>Admin - Mistral AI</title><style>.bar { max-width: 100%; }</style></head>
    <body>
    <nav><a href="/organization">Organization</a> <a href="/usage">Usage</a> <a href="/limits">Limits</a></nav>
    <main>
    <h1>Subscription</h1>
    <p>CURRENT PLAN</p>
    <h2>Pro <span>Active</span></h2>
    <p>Full access to Vibe for all-day coding and long-running tasks.</p>
    <h3>INCLUDED MONTHLY ALLOWANCE</h3>
    <h4>Included API usage</h4>
    <p>Included monthly allowance for API/Studio usage.</p>
    <div><span>€17.43</span><span>€25.5</span></div>
    <p>Resets in 13 days</p>
    <h4>Included Vibe Code usage</h4>
    <p>Included monthly allowance for Vibe Code.</p>
    <div><span>€90.09</span><span>€255</span></div>
    <p>Resets in 13 days</p>
    <h3>PAY-AS-YOU-GO &amp; SPENDING LIMIT</h3>
    <p>API pay-as-you-go: create API keys and use the free tier.</p>
    <h3>ESTIMATED PRICE</h3>
    <div>Subscription €14.99</div>
    <div>Estimated total €14.99 /month</div>
    </main>
    </body></html>
    """
    let result = try MistralWebSubscriptionClient.parse(html: html, now: now)
        ?? { throw AdditionalProviderTestError.failure("Subscription page did not parse") }()
    try expectClose(result.apiSpent ?? -1, 17.43, "api spent")
    try expectClose(result.apiAllowance ?? -1, 25.5, "api allowance")
    try expectClose(result.vibeSpent ?? -1, 90.09, "vibe spent")
    try expectClose(result.vibeAllowance ?? -1, 255, "vibe allowance")
    try expectEqual(result.currency, "EUR", "currency")
    try expectEqual(result.planName, "Pro", "plan name")
    let expectedReset = now.addingTimeInterval(13 * 86400)
    let drift = result.periodEnd.map { abs($0.timeIntervalSince(expectedReset)) } ?? .infinity
    try expect(drift < 1, "period end from resets-in-13-days")
}

private func testMistralWebParserSurvivesReactCommentAndTagSplitting() throws {
    let now = date("2026-08-18T17:00:00Z")
    let html = """
    <body>
    <p>CURRENT PLAN</p><h2>Pro</h2>
    <h4>Included <!-- -->API<!-- --> usage</h4>
    <div><span>€</span><span>17.43</span> of <span>€</span><span>25.5</span></div>
    <p>Resets in <!-- -->13<!-- --> days</p>
    <h4>Included <!-- -->Vibe Code<!-- --> usage</h4>
    <div><span>€</span><span>90.09</span> of <span>€</span><span>255</span></div>
    <p>Resets in 13 days</p>
    <h3>PAY-AS-YOU-GO &amp; SPENDING LIMIT</h3>
    </body>
    """
    let result = try MistralWebSubscriptionClient.parse(html: html, now: now)
        ?? { throw AdditionalProviderTestError.failure("Comment-split page did not parse") }()
    try expectClose(result.apiSpent ?? -1, 17.43, "api spent across markup splits")
    try expectClose(result.apiAllowance ?? -1, 25.5, "api allowance across markup splits")
    try expectClose(result.vibeSpent ?? -1, 90.09, "vibe spent across markup splits")
    try expectClose(result.vibeAllowance ?? -1, 255, "vibe allowance across markup splits")
}

private func testMistralWebParserToleratesPayAsYouGoTooltipBeforeVibeAmounts() throws {
    let now = date("2026-08-18T17:00:00Z")
    let html = """
    <body>
    <h4>Included API usage</h4>
    <div>€17.43 €25.5</div>
    <p>Resets in 13 days</p>
    <h4>Included Vibe Code usage <button aria-describedby="tip">i</button></h4>
    <div role="tooltip" id="tip">Once the included allowance is exhausted, enable Pay-as-you-go for Vibe Code to keep coding.</div>
    <p>Included monthly allowance for Vibe Code.</p>
    <div>€90.09 €255</div>
    <p>Resets in 13 days</p>
    <h3>PAY-AS-YOU-GO &amp; SPENDING LIMIT</h3>
    </body>
    """
    let result = try MistralWebSubscriptionClient.parse(html: html, now: now)
        ?? { throw AdditionalProviderTestError.failure("Tooltip page did not parse") }()
    try expectClose(result.vibeSpent ?? -1, 90.09, "vibe spent despite pay-as-you-go tooltip copy")
    try expectClose(result.vibeAllowance ?? -1, 255, "vibe allowance despite pay-as-you-go tooltip copy")
}

private func testMistralWebParserHandlesLandmarksAppearingBeforeSections() throws {
    let now = date("2026-08-18T17:00:00Z")
    let html = """
    <html><head>
    <script>window.__i18n = {"payg":"PAY-AS-YOU-GO & SPENDING LIMIT","vibe":"Vibe Code usage","estimated":"ESTIMATED PRICE"}</script>
    </head>
    <body>
    <div>Settings / Pay-as-you-go &amp; spending limit / Estimated price</div>
    <h4>Included API usage</h4>
    <div>€17.43 €25.5</div>
    <p>Resets in 13 days</p>
    <h4>Included Vibe Code usage</h4>
    <div>€90.09 €255</div>
    <p>Resets in 13 days</p>
    <h3>PAY-AS-YOU-GO &amp; SPENDING LIMIT</h3>
    </body></html>
    """
    let result = try MistralWebSubscriptionClient.parse(html: html, now: now)
        ?? { throw AdditionalProviderTestError.failure("Early-landmark page did not parse") }()
    try expectClose(result.apiSpent ?? -1, 17.43, "api spent with early landmarks")
    try expectClose(result.vibeSpent ?? -1, 90.09, "vibe spent with early landmarks")
    try expectClose(result.vibeAllowance ?? -1, 255, "vibe allowance with early landmarks")
}

private func testMistralWebParserReadsFlightPayloadOnlyPage() throws {
    let now = date("2026-08-18T17:00:00Z")
    let html = #"""
    <!DOCTYPE html>
    <html><head><meta charset="utf-8"></head>
    <body><div id="root"></div>
    <script>self.__next_f.push([1,"7:[\"$\",\"h4\",null,{\"children\":\"Included API usage\"}]\n8:[\"$\",\"span\",null,{\"children\":\"€17.43\"}]\n9:[\"$\",\"span\",null,{\"children\":\"€25.5\"}]\n10:[\"$\",\"p\",null,{\"children\":\"Resets in 13 days\"}]"])</script>
    <script>self.__next_f.push([1,"11:[\"$\",\"h4\",null,{\"children\":\"Included Vibe Code usage\"}]\n12:[\"$\",\"span\",null,{\"children\":\"€90.09\"}]\n13:[\"$\",\"span\",null,{\"children\":\"€255\"}]\n14:[\"$\",\"p\",null,{\"children\":\"Resets in 13 days\"}]"])</script>
    </body></html>
    """#
    let result = try MistralWebSubscriptionClient.parse(html: html, now: now)
        ?? { throw AdditionalProviderTestError.failure("Flight-payload page did not parse") }()
    try expectClose(result.apiSpent ?? -1, 17.43, "api spent from flight payload")
    try expectClose(result.apiAllowance ?? -1, 25.5, "api allowance from flight payload")
    try expectClose(result.vibeSpent ?? -1, 90.09, "vibe spent from flight payload")
    try expectClose(result.vibeAllowance ?? -1, 255, "vibe allowance from flight payload")
    try expectEqual(result.currency, "EUR", "flight payload currency")
}

private func testMistralWebParserRejectsSignedOutPage() throws {
    let html = """
    <html><body>
    <h1>Sign in to your account</h1>
    <form action="/login"><input name="email"/><button>Continue</button></form>
    </body></html>
    """
    let result = MistralWebSubscriptionClient.parse(html: html, now: date("2026-08-18T17:00:00Z"))
    try expect(result == nil, "signed-out page must not parse")
}

private func testMistralWebParserReturnsPartialResultWhenVibeMissing() throws {
    let now = date("2026-08-18T17:00:00Z")
    let html = """
    <body>
    <h4>Included API usage</h4>
    <div>€17.43 €25.5</div>
    <p>Resets in 13 days</p>
    <h3>PAY-AS-YOU-GO &amp; SPENDING LIMIT</h3>
    <h3>ESTIMATED PRICE</h3>
    <div>Subscription €14.99</div>
    </body>
    """
    let result = try MistralWebSubscriptionClient.parse(html: html, now: now)
        ?? { throw AdditionalProviderTestError.failure("API-only page did not parse") }()
    try expectClose(result.apiSpent ?? -1, 17.43, "api spent on partial page")
    try expect(result.vibeSpent == nil, "vibe spent must stay nil on partial page")
}

private func testMistralAssemblyKeepsVibeAnchorWhenWebParseIsPartial() throws {
    let suiteName = "limit-counter-mistral-assembly-tests-\(UUID().uuidString)"
    let defaults = try UserDefaults(suiteName: suiteName)
        ?? { throw AdditionalProviderTestError.failure("Could not create isolated defaults") }()
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let now = date("2026-08-18T17:00:00Z")
    let web = MistralWebSubscriptionResult(
        planName: "Pro",
        apiSpent: 17.43,
        apiAllowance: 25.5,
        vibeSpent: nil,
        vibeAllowance: nil,
        currency: "EUR",
        periodEnd: date("2026-08-31T17:00:00Z")
    )
    let fields: [String: String] = [
        SpendProviderCredentialField.manualSpent: "90.09",
        SpendProviderCredentialField.manualAllowance: "255",
        SpendProviderCredentialField.manualCurrency: "EUR",
        SpendProviderCredentialField.manualResetAt: "2026-08-31T17:00:00Z",
        SpendProviderCredentialField.anchorUpdatedAt: "2026-08-17T23:12:28Z"
    ]
    let assembly = MistralProviderClient.assembleMeters(
        webResult: web,
        admin: nil,
        local: nil,
        fields: fields,
        now: now,
        watermarkDefaults: defaults
    )
    try expectEqual(assembly.windows.count, 2, "partial web parse keeps both meters")
    let api = try assembly.windows.first(where: { $0.label == "API usage" })
        ?? { throw AdditionalProviderTestError.failure("Missing API window") }()
    let vibe = try assembly.windows.first(where: { $0.label == "Vibe Code usage" })
        ?? { throw AdditionalProviderTestError.failure("Missing Vibe window after partial web parse") }()
    try expectClose(api.used, 17.43, "api used comes from web")
    try expectClose(vibe.used, 90.09, "vibe used comes from manual anchor")
    try expectClose(vibe.total ?? -1, 255, "vibe allowance comes from manual anchor")
    try expectEqual(assembly.planName, "Pro", "plan name from web result")
}

private func testMistralAssemblyPrefersFullWebResultOverAnchor() throws {
    let suiteName = "limit-counter-mistral-assembly-tests-\(UUID().uuidString)"
    let defaults = try UserDefaults(suiteName: suiteName)
        ?? { throw AdditionalProviderTestError.failure("Could not create isolated defaults") }()
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let now = date("2026-08-18T17:00:00Z")
    let webPeriodEnd = date("2026-08-31T17:00:00Z")
    let web = MistralWebSubscriptionResult(
        planName: "Pro",
        apiSpent: 17.43,
        apiAllowance: 25.5,
        vibeSpent: 90.09,
        vibeAllowance: 255,
        currency: "EUR",
        periodEnd: webPeriodEnd
    )
    let fields: [String: String] = [
        SpendProviderCredentialField.manualSpent: "42",
        SpendProviderCredentialField.manualAllowance: "255",
        SpendProviderCredentialField.manualCurrency: "EUR",
        SpendProviderCredentialField.manualResetAt: "2026-09-01T00:00:00Z",
        SpendProviderCredentialField.anchorUpdatedAt: "2026-08-17T23:12:28Z"
    ]
    let assembly = MistralProviderClient.assembleMeters(
        webResult: web,
        admin: nil,
        local: nil,
        fields: fields,
        now: now,
        watermarkDefaults: defaults
    )
    try expectEqual(assembly.windows.count, 2, "full web parse yields exactly two meters")
    let vibe = try assembly.windows.first(where: { $0.label == "Vibe Code usage" })
        ?? { throw AdditionalProviderTestError.failure("Missing Vibe window") }()
    try expectClose(vibe.used, 90.09, "vibe used comes from web, not anchor")
    try expectEqual(vibe.resetDate, webPeriodEnd, "vibe reset comes from web period end")
    try expect(defaults.string(forKey: "mistral.manualAnchor.signature") == nil, "anchor watermark must not run when web vibe is present")
}

private func testMistralAssemblyKeepsAdminCombinedTotalWithoutWeb() throws {
    let suiteName = "limit-counter-mistral-assembly-tests-\(UUID().uuidString)"
    let defaults = try UserDefaults(suiteName: suiteName)
        ?? { throw AdditionalProviderTestError.failure("Could not create isolated defaults") }()
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let now = date("2026-08-18T17:00:00Z")
    let admin = MistralAdminUsageResult(
        totalSpend: 12.5,
        totalSpendIsComplete: true,
        vibeSpend: nil,
        currency: "USD",
        periodStart: nil,
        periodEnd: date("2026-09-01T00:00:00Z")
    )
    let fields: [String: String] = [
        SpendProviderCredentialField.manualSpent: "90.09",
        SpendProviderCredentialField.mistralApiSpent: "17.43",
        SpendProviderCredentialField.manualCurrency: "EUR",
        SpendProviderCredentialField.manualResetAt: "2026-09-01T00:00:00Z"
    ]
    let assembly = MistralProviderClient.assembleMeters(
        webResult: nil,
        admin: admin,
        local: nil,
        fields: fields,
        now: now,
        watermarkDefaults: defaults
    )
    try expectEqual(assembly.windows.count, 1, "opaque complete admin total stays a single combined meter")
    try expectEqual(assembly.windows[0].label, "Mistral usage this billing period", "combined admin label")
    try expectClose(assembly.windows[0].used, 12.5, "combined admin spend")
}

private func testMistralAssemblyFallsBackToLocalEstimateWithoutAnchor() throws {
    let suiteName = "limit-counter-mistral-assembly-tests-\(UUID().uuidString)"
    let defaults = try UserDefaults(suiteName: suiteName)
        ?? { throw AdditionalProviderTestError.failure("Could not create isolated defaults") }()
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let now = date("2026-08-18T17:00:00Z")
    let web = MistralWebSubscriptionResult(
        planName: "Pro",
        apiSpent: 17.43,
        apiAllowance: 25.5,
        vibeSpent: nil,
        vibeAllowance: nil,
        currency: "EUR",
        periodEnd: date("2026-08-31T17:00:00Z")
    )
    let local = MistralLocalUsageSummary(
        currentMonthCostUSD: 12.34,
        last30DaysCostUSD: 20,
        inputTokens: 1000,
        outputTokens: 500,
        events: [],
        analyticsBuckets: [],
        costObservations: []
    )
    let fields: [String: String] = [
        SpendProviderCredentialField.manualCurrency: "USD"
    ]
    let assembly = MistralProviderClient.assembleMeters(
        webResult: web,
        admin: nil,
        local: local,
        fields: fields,
        now: now,
        watermarkDefaults: defaults
    )
    try expectEqual(assembly.windows.count, 2, "web api plus local vibe estimate")
    let vibe = try assembly.windows.first(where: { $0.label == "Vibe Code usage" })
        ?? { throw AdditionalProviderTestError.failure("Missing local-estimate Vibe window") }()
    try expectClose(vibe.used, 12.34, "vibe used from local estimate")
    try expectEqual(vibe.subtitle, "TaskWraith-style local estimate", "local estimate subtitle")
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

private func testMuseAnalyticsSeparatesCachedInput() throws {
    let now = Date()
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("limit-counter-muse-analytics-\(UUID().uuidString)")
        .appendingPathComponent("muse")
    let session = root.appendingPathComponent("sessions/test/session.jsonl")
    defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    try FileManager.default.createDirectory(at: session.deletingLastPathComponent(), withIntermediateDirectories: true)
    let recordedAt = Int(now.timeIntervalSince1970 * 1_000_000)
    let attribution = """
    {"schema_version":1,"id":"attr-1","recorded_at":\(recordedAt),"stream":{"kind":"session","id":"test"},"sequence":1,"payload_type":"runtime.session","payload":{"kind":"run","run_id":"run-1","event":{"kind":"goal_usage_attribution","record":{"usage_id":"usage-1","usage_family":"provider","quantity":{"unit":"tokens","reported":true,"input_tokens":1000,"output_tokens":100,"cached_tokens":700}}}}}
    """
    let completed = """
    {"schema_version":1,"id":"done-1","recorded_at":\(recordedAt),"stream":{"kind":"session","id":"test"},"sequence":2,"payload_type":"runtime.session","payload":{"kind":"run","run_id":"run-1","event":{"kind":"model_completed","usage":{"cache_read_tokens":700},"model":"muse-spark-1.2"}}}
    """
    try (attribution + "\n" + completed + "\n").write(to: session, atomically: true, encoding: .utf8)

    let summary = try MuseLocalUsageReader.read(rootURL: root, now: now)
        ?? { throw AdditionalProviderTestError.failure("Muse session fixture was not read") }()
    let bucket = try summary.analyticsBuckets.first
        ?? { throw AdditionalProviderTestError.failure("Muse analytics bucket was not emitted") }()
    try expectClose(bucket.inputTokens, 300, "Muse analytics keeps only fresh input")
    try expectClose(bucket.cachedInputTokens, 700, "Muse cache read is separate")
    try expectClose(bucket.totalTokens, 1_100, "Muse analytics counts each token once")
    try expectClose(summary.inputTokens, 1_000, "Legacy Muse summary keeps cache-inclusive input")
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

private func testMetaWebBillingRefreshCadenceProtectsBrowserSession() throws {
    let start = date("2026-08-27T12:00:00Z")

    try expect(
        MetaWebBillingRefreshCadence.isDue(
            now: start,
            lastSuccessfulFetchAt: nil,
            lastAttemptAt: nil
        ),
        "Meta first billing read is due"
    )
    try expect(
        !MetaWebBillingRefreshCadence.isDue(
            now: start.addingTimeInterval(59 * 60),
            lastSuccessfulFetchAt: start,
            lastAttemptAt: start
        ),
        "Meta successful billing read is cached for one hour"
    )
    try expect(
        MetaWebBillingRefreshCadence.isDue(
            now: start.addingTimeInterval(60 * 60),
            lastSuccessfulFetchAt: start,
            lastAttemptAt: start
        ),
        "Meta successful billing read becomes due after one hour"
    )

    let failedAttempt = start.addingTimeInterval(61 * 60)
    try expect(
        !MetaWebBillingRefreshCadence.isDue(
            now: failedAttempt.addingTimeInterval(6 * 60 * 60 - 1),
            lastSuccessfulFetchAt: start,
            lastAttemptAt: failedAttempt
        ),
        "Meta failed billing read waits six hours before retrying"
    )
    try expect(
        MetaWebBillingRefreshCadence.isDue(
            now: failedAttempt.addingTimeInterval(6 * 60 * 60),
            lastSuccessfulFetchAt: start,
            lastAttemptAt: failedAttempt
        ),
        "Meta failed billing read retries after six hours"
    )
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

private func testOpenRouterParsesValidKeyResponse() throws {
    let json = """
    {
        "data": {
            "label": "My API Key",
            "usage": 123.45,
            "limit": 1000.00,
            "is_free_tier": false,
            "rate_limit": {
                "requests": 60,
                "interval": "min"
            }
        }
    }
    """
    let parsed = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
    guard let data = parsed["data"] as? [String: Any] else {
        throw AdditionalProviderTestError.failure("Missing data field")
    }
    try expectEqual(data["label"] as? String, "My API Key", "OpenRouter label")
    try expectClose(data["usage"] as? Double ?? 0, 123.45, "OpenRouter usage")
    try expectClose(data["limit"] as? Double ?? 0, 1000.00, "OpenRouter limit")
    try expectEqual(data["is_free_tier"] as? Bool, false, "OpenRouter is not free tier")
    if let rateLimit = data["rate_limit"] as? [String: Any] {
        try expectEqual(rateLimit["requests"] as? Int, 60, "OpenRouter rate limit requests")
        try expectEqual(rateLimit["interval"] as? String, "min", "OpenRouter rate limit interval")
    } else {
        throw AdditionalProviderTestError.failure("Missing rate_limit")
    }
}

private func testOpenRouterParsesUnlimitedKey() throws {
    let json = """
    {
        "data": {
            "label": "Unlimited Key",
            "usage": 500.00,
            "limit": null,
            "is_free_tier": false,
            "rate_limit": null
        }
    }
    """
    let parsed = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
    guard let data = parsed["data"] as? [String: Any?] else {
        throw AdditionalProviderTestError.failure("Missing data field")
    }
    try expectClose(data["usage"] as? Double ?? 0, 500.00, "OpenRouter unlimited usage")
    try expect(data["limit"] is NSNull || (data["limit"] as? Double) == nil, "OpenRouter unlimited key has null limit")
}

private func testOpenRouterParsesFreeTier() throws {
    let json = """
    {
        "data": {
            "label": "Free Tier Key",
            "usage": 5.50,
            "limit": 20.00,
            "is_free_tier": true,
            "rate_limit": {
                "requests": 20,
                "interval": "min"
            }
        }
    }
    """
    let parsed = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
    guard let data = parsed["data"] as? [String: Any] else {
        throw AdditionalProviderTestError.failure("Missing data field")
    }
    try expectEqual(data["is_free_tier"] as? Bool, true, "OpenRouter free tier flag")
}

private func testOpenRouterParsesRateLimit() throws {
    let json = """
    {
        "data": {
            "label": "Test Key",
            "usage": 10.00,
            "limit": 100.00,
            "is_free_tier": false,
            "rate_limit": {
                "requests": 120,
                "interval": "hour"
            }
        }
    }
    """
    let parsed = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
    guard let data = parsed["data"] as? [String: Any] else {
        throw AdditionalProviderTestError.failure("Missing data field")
    }
    if let rateLimit = data["rate_limit"] as? [String: Any] {
        try expectEqual(rateLimit["requests"] as? Int, 120, "OpenRouter rate limit requests")
        try expectEqual(rateLimit["interval"] as? String, "hour", "OpenRouter rate limit interval")
    } else {
        throw AdditionalProviderTestError.failure("Missing rate_limit")
    }
}



/// Friday 2026-09-25 04:00 UTC.
private let openRouterNow = date("2026-09-25T04:00:00Z")

private func testOpenRouterMetersLoadedCreditAgainstKeySpend() throws {
    let key = OpenRouterKeyData(
        label: "sk-or-v1-abc...123",
        usage: 2.5,
        usageDaily: 0.25,
        usageWeekly: 1,
        usageMonthly: 2,
        isFreeTier: false,
        rateLimit: OpenRouterRateLimit(requests: -1, interval: "10s")
    )
    let snapshot = OpenRouterSnapshotBuilder.snapshot(
        key: key,
        credits: .unavailable,
        creditLoaded: 10,
        now: openRouterNow
    )

    try expectEqual(snapshot.windows.map(\.label), ["Credit used"], "OpenRouter loaded-credit windows")
    let meter = snapshot.windows[0]
    try expectEqual(meter.windowKind, .custom, "OpenRouter credit meter kind")
    try expectClose(meter.used, 2.5, "OpenRouter credit used")
    try expectEqual(meter.total, 10, "OpenRouter credit loaded")
    try expectEqual(meter.unit, "USD", "OpenRouter credit unit")
    try expectEqual(snapshot.balances.map(\.label), ["Credit remaining"], "OpenRouter balances")
    try expectClose(snapshot.balances[0].amount, 7.5, "OpenRouter credit remaining")
    try expectEqual(
        snapshot.stats.map(\.label),
        ["Today", "This week", "This month", "All time"],
        "OpenRouter spend stats, without the deprecated -1 rate limit"
    )
    try expectEqual(snapshot.planName, "API Credits", "OpenRouter key-shaped label is hidden")
    try expectEqual(
        OpenRouterCredentialField.creditLoaded,
        SpendProviderCredentialField.manualTopUpTotal,
        "OpenRouter's loaded credit shares the top-up field"
    )
}

private func testOpenRouterPrefersAccountCredits() throws {
    let snapshot = OpenRouterSnapshotBuilder.snapshot(
        key: OpenRouterKeyData(usage: 2.5),
        credits: .read(OpenRouterCredits(totalCredits: 50, totalUsage: 12.25)),
        creditLoaded: 10,
        now: openRouterNow
    )

    let meter = snapshot.windows[0]
    try expectEqual(meter.label, "Credit used", "OpenRouter account meter label")
    try expectClose(meter.used, 12.25, "OpenRouter account usage")
    try expectEqual(meter.total, 50, "OpenRouter account credits")
    try expectEqual(meter.subtitle, "Official OpenRouter account credits", "OpenRouter account source")
    try expectClose(snapshot.balances[0].amount, 37.75, "OpenRouter account remaining")
}

private func testOpenRouterRefusedManagementKeyFallsBack() throws {
    let withLoadedCredit = OpenRouterSnapshotBuilder.snapshot(
        key: OpenRouterKeyData(usage: 1),
        credits: .rejected,
        creditLoaded: 10,
        now: openRouterNow
    )
    try expectEqual(withLoadedCredit.windows[0].total, 10, "refused key falls back to the loaded credit")
    try expect(
        withLoadedCredit.windows[0].subtitle?.contains("refused the management key") == true,
        "the meter says the management key was refused"
    )

    let spendOnly = OpenRouterSnapshotBuilder.snapshot(
        key: OpenRouterKeyData(usage: 1),
        credits: .rejected,
        creditLoaded: nil,
        now: openRouterNow
    )
    try expectEqual(spendOnly.windows.map(\.label), ["Total spend"], "refused key without loaded credit")
    try expectEqual(
        spendOnly.windows[0].subtitle,
        "OpenRouter refused the management key",
        "spend window says the management key was refused"
    )
}

private func testOpenRouterKeyLimitFollowsItsResetPeriod() throws {
    let monthly = OpenRouterSnapshotBuilder.snapshot(
        key: OpenRouterKeyData(usage: 100, limit: 20, limitRemaining: 15, limitReset: "monthly", usageMonthly: 5),
        credits: .unavailable,
        creditLoaded: nil,
        now: openRouterNow
    )
    try expectEqual(monthly.windows.map(\.label), ["Key limit"], "capped key windows")
    let cap = monthly.windows[0]
    try expectEqual(cap.windowKind, .monthly, "monthly cap kind")
    try expectClose(cap.used, 5, "a resetting cap reads its own period, not all-time usage")
    try expectEqual(cap.total, 20, "cap total")
    try expectEqual(cap.resetDate, date("2026-10-01T00:00:00Z"), "monthly cap resets on the 1st, UTC")
    try expectClose(monthly.balances[0].amount, 15, "cap remaining")

    let weekly = OpenRouterSnapshotBuilder.snapshot(
        key: OpenRouterKeyData(usage: 100, limit: 20, limitReset: "weekly", usageWeekly: 4),
        credits: .unavailable,
        creditLoaded: nil,
        now: openRouterNow
    )
    try expectClose(weekly.windows[0].used, 4, "weekly cap without limit_remaining reads weekly usage")
    try expectEqual(weekly.windows[0].resetDate, date("2026-09-28T00:00:00Z"), "weekly cap resets on Monday, UTC")

    let daily = OpenRouterSnapshotBuilder.snapshot(
        key: OpenRouterKeyData(usage: 100, limit: 20, limitRemaining: 19, limitReset: "daily"),
        credits: .unavailable,
        creditLoaded: nil,
        now: openRouterNow
    )
    try expectEqual(daily.windows[0].resetDate, date("2026-09-26T00:00:00Z"), "daily cap resets at midnight UTC")

    let lifetime = OpenRouterSnapshotBuilder.snapshot(
        key: OpenRouterKeyData(usage: 12, limit: 20),
        credits: .unavailable,
        creditLoaded: 30,
        now: openRouterNow
    )
    try expectEqual(lifetime.windows.map(\.label), ["Credit used", "Key limit"], "credit meter leads the cap")
    try expectClose(lifetime.windows[1].used, 12, "a cap that never resets reads all-time usage")
    try expect(lifetime.windows[1].resetDate == nil, "a cap that never resets has no reset date")
}

private func testOpenRouterSpendOnlyWithoutCredit() throws {
    let snapshot = OpenRouterSnapshotBuilder.snapshot(
        key: OpenRouterKeyData(label: "Personal", usage: 0.0117),
        credits: .unavailable,
        creditLoaded: nil,
        now: openRouterNow
    )
    try expectEqual(snapshot.windows.map(\.label), ["Total spend"], "spend-only window")
    try expect(snapshot.windows[0].total == nil, "spend-only window has no total")
    try expect(snapshot.balances.isEmpty, "no placeholder \"Unlimited\" balance")
    try expect(snapshot.stats.isEmpty, "no stats without period usage")
    try expectEqual(snapshot.planName, "Personal", "real key label is the plan name")
}

private func testOpenRouterSendsManagementKeyOnlyToCredits() async throws {
    var keyAuthorization: String?
    var creditsAuthorization: String?
    var creditsHost: String?
    OpenRouterMockURLProtocol.handler = { request in
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        if request.url?.path == "/api/v1/credits" {
            creditsAuthorization = request.value(forHTTPHeaderField: "Authorization")
            creditsHost = request.url?.host
            return (response, Data(#"{"data":{"total_credits":25,"total_usage":5.5}}"#.utf8))
        }
        keyAuthorization = request.value(forHTTPHeaderField: "Authorization")
        return (response, Data(#"{"data":{"label":"sk-or-v1-abc","usage":1.5,"limit":null,"is_free_tier":false,"is_management_key":false}}"#.utf8))
    }
    defer { OpenRouterMockURLProtocol.handler = nil }

    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [OpenRouterMockURLProtocol.self]
    let snapshot = try await OpenRouterProviderClient(
        session: URLSession(configuration: configuration)
    ).fetchSnapshot(credentials: ProviderCredential(
        accessToken: "sk-or-v1-inference",
        customEndpoint: "https://proxy.example/api/v1/auth/key",
        extraFields: [
            OpenRouterCredentialField.managementKey: "sk-or-v1-management",
            OpenRouterCredentialField.creditLoaded: "10"
        ]
    ))

    try expectEqual(keyAuthorization, "Bearer sk-or-v1-inference", "the API key reads the key endpoint")
    try expectEqual(creditsAuthorization, "Bearer sk-or-v1-management", "the management key reads credits")
    try expectEqual(creditsHost, "openrouter.ai", "credits never follow a custom endpoint")
    try expectEqual(snapshot.windows[0].total, 25, "account credits win over the loaded figure")
    try expectClose(snapshot.windows[0].used, 5.5, "account usage")
}

private func testOpenRouterManagementAPIKeyReadsItsOwnCredits() async throws {
    var creditsAuthorization: String?
    OpenRouterMockURLProtocol.handler = { request in
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        if request.url?.path == "/api/v1/credits" {
            creditsAuthorization = request.value(forHTTPHeaderField: "Authorization")
            return (response, Data(#"{"data":{"total_credits":40,"total_usage":10}}"#.utf8))
        }
        return (response, Data(#"{"data":{"label":"Admin","usage":0,"limit":null,"is_management_key":true}}"#.utf8))
    }
    defer { OpenRouterMockURLProtocol.handler = nil }

    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [OpenRouterMockURLProtocol.self]
    let snapshot = try await OpenRouterProviderClient(
        session: URLSession(configuration: configuration)
    ).fetchSnapshot(credentials: ProviderCredential(accessToken: "sk-or-v1-admin"))

    try expectEqual(creditsAuthorization, "Bearer sk-or-v1-admin", "a management API key reads its own credits")
    try expectEqual(snapshot.windows[0].total, 40, "management API key credit meter")

    // An inference key without a saved management key never asks.
    var creditRequests = 0
    OpenRouterMockURLProtocol.handler = { request in
        if request.url?.path == "/api/v1/credits" { creditRequests += 1 }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (response, Data(#"{"data":{"label":"sk-or-v1-abc","usage":1,"limit":null}}"#.utf8))
    }
    _ = try await OpenRouterProviderClient(
        session: URLSession(configuration: configuration)
    ).fetchSnapshot(credentials: ProviderCredential(accessToken: "sk-or-v1-inference"))
    try expectEqual(creditRequests, 0, "an inference key does not call the management-only endpoint")
}

private final class OpenRouterMockURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private func testImportedCookieHeaderMergePreservesAndRotates() throws {
    let requestURL = URL(string: "https://admin.mistral.ai/subscription")!
    let existing = "session=old-token; theme=dark"
    let now = Date()

    let rotated = ImportedCookieHeaderMerger.mergedHeader(
        existingHeader: existing,
        responseHeaderFields: [
            "Set-Cookie": "session=new-token; Domain=.mistral.ai; Path=/subscription; Max-Age=3600; Secure; HttpOnly"
        ],
        requestURL: requestURL,
        allowedDomains: ["mistral.ai"],
        now: now
    )
    try expectEqual(
        rotated,
        "session=new-token; theme=dark",
        "Set-Cookie rotation should preserve unrelated imported cookies"
    )

    let withoutRotation = ImportedCookieHeaderMerger.mergedHeader(
        existingHeader: existing,
        responseHeaderFields: ["Content-Type": "text/html"],
        requestURL: requestURL,
        allowedDomains: ["mistral.ai"],
        now: now
    )
    try expectEqual(
        withoutRotation,
        nil,
        "responses without Set-Cookie must not replace the imported header"
    )

    let wrongPath = ImportedCookieHeaderMerger.mergedHeader(
        existingHeader: existing,
        responseHeaderFields: [
            "Set-Cookie": "session=wrong-path; Domain=.mistral.ai; Path=/admin; Max-Age=3600"
        ],
        requestURL: requestURL,
        allowedDomains: ["mistral.ai"],
        now: now
    )
    try expectEqual(
        wrongPath,
        nil,
        "cookies outside the request path must be ignored"
    )

    let deleted = ImportedCookieHeaderMerger.mergedHeader(
        existingHeader: existing,
        responseHeaderFields: [
            "Set-Cookie": "session=; Domain=.mistral.ai; Path=/subscription; Max-Age=0"
        ],
        requestURL: requestURL,
        allowedDomains: ["mistral.ai"],
        now: now
    )
    try expectEqual(
        deleted,
        "theme=dark",
        "Max-Age=0 should remove only the rotated cookie"
    )
}

private func testTokenPlanParserReadsRenderedZeroUsage() throws {
    let qwenText = """
    Plan Quota
    Last Updated: 2026-08-25 17:31:03
    End Time 2026-09-25 17:00:00
    7-Day Quota
    0% Used
    Will reset at 2026-09-02 06:45:00 (UTC+8)
    0% 50% 90% 100%
    """
    let qwen = try TokenPlanWebClient.parseQwen(renderedText: qwenText)
        ?? { throw AdditionalProviderTestError.failure("Qwen rendered quota did not parse") }()
    try expectClose(qwen.quotaUsedPercent ?? -1, 0, "Qwen rendered zero usage")
    try expectEqual(qwen.periodEnd, date("2026-09-01T22:45:00Z"), "Qwen UTC+8 reset is converted to UTC")

    let mimoText = """
    Plan usage
    Lite Monthly Plan
    Auto-Renewal Monthly
    Valid until 2026-09-25 23:59:59 (UTC)
    Current plan usage
    0 / 4,100,000,000 Used 0.0%
    """
    let mimo = try TokenPlanWebClient.parse(renderedText: mimoText)
        ?? { throw AdditionalProviderTestError.failure("MiMo rendered quota did not parse") }()
    try expectClose(mimo.quotaUsedPercent ?? -1, 0, "MiMo rendered zero usage")
    try expectEqual(mimo.planName, "Lite Monthly Plan", "MiMo rendered plan name")
    try expectEqual(mimo.periodEnd, date("2026-09-25T23:59:59Z"), "MiMo rendered validity")
}

/// Model Studio moved the 7-day meter's value to the end of the reset row, so
/// "0% Used" no longer appears and the label is separated from its number by a
/// timestamp. Both the session import and the background refresh gate on
/// `quotaUsedPercent != nil`, so this stopped Qwen dead in both.
/// Fixture transcribed from the console on 2026-09-10.
private func testTokenPlanParserReadsQwenResetRowLayout() throws {
    let qwenText = """
    Standard Plan Active
    Remaining Days 14 days
    Auto-Renewal
    Start Time 2026/08/25 15:01:34
    End Time 2026/09/25 17:00:00
    Plan Quota
    Updated at: 2026-09-10 19:18:20
    Usage Statistics
    7-Day Used
    Will reset at 2026-09-16 10:03:00 (UTC+8) 100%
    0% 100%
    Reset
    Quota Add-on
    """
    let qwen = try TokenPlanWebClient.parseQwen(renderedText: qwenText)
        ?? { throw AdditionalProviderTestError.failure("Qwen reset-row layout did not parse") }()

    try expectClose(qwen.quotaUsedPercent ?? -1, 100, "meter value, not the bar's axis label")
    try expectEqual(qwen.periodEnd, date("2026-09-16T02:03:00Z"), "UTC+8 reset converted to UTC")
    try expectEqual(qwen.planName, "Standard Plan", "plan name")
    try expectEqual(qwen.remainingDays, 14, "remaining days")
}

/// A partly-used meter reads its own value, not either axis label.
private func testTokenPlanParserReadsPartialQwenUsage() throws {
    let qwenText = """
    7-Day Used
    Will reset at 2026-09-16 10:03:00 (UTC+8) 42.5%
    0% 100%
    """
    let qwen = try TokenPlanWebClient.parseQwen(renderedText: qwenText)
        ?? { throw AdditionalProviderTestError.failure("Qwen partial usage did not parse") }()
    try expectClose(qwen.quotaUsedPercent ?? -1, 42.5, "fractional meter value")
}

/// A zero meter is still three percentages: its own value plus both axis
/// labels.
/// The Plan Quota card shows the banked resets beside its Reset button
/// ("Reset ⓘ 1 available"); the icon renders as its own text node.
private func testTokenPlanParserReadsQwenResetAvailability() throws {
    let qwenText = """
    Plan Quota
    Updated at: 2026-09-16 05:04:14
    7-Day Used
    Will reset at 2026-09-23 10:10:00 (UTC+8) 15.19%
    0%
    100%
    Reset
    ⓘ
    1 available
    Quota Add-on
    Quota Statistics
    """
    let qwen = try TokenPlanWebClient.parseQwen(renderedText: qwenText)
        ?? { throw AdditionalProviderTestError.failure("Qwen reset availability did not parse") }()
    try expectClose(qwen.quotaUsedPercent ?? -1, 15.19, "meter value still reads")
    try expectEqual(qwen.resetAvailableCount, 1, "one banked reset")

    let none = try TokenPlanWebClient.parseQwen(renderedText: "7-Day Used\nWill reset at 2026-09-23 10:10:00 (UTC+8) 15.19%\nReset\n0 available")
        ?? { throw AdditionalProviderTestError.failure("zero availability did not parse") }()
    try expectEqual(none.resetAvailableCount, 0, "zero is a reading too")

    let absent = try TokenPlanWebClient.parseQwen(renderedText: "7-Day Used\nWill reset at 2026-09-23 10:10:00 (UTC+8) 15.19%\nQuota Add-on")
        ?? { throw AdditionalProviderTestError.failure("meter without the button did not parse") }()
    try expectEqual(absent.resetAvailableCount, nil, "no button, no reading")
}

private func testTokenPlanConsoleAPIScansResetAvailability() throws {
    func envelope(_ payload: String) -> Data {
        """
        {"data": {"success": true, "DataV2": {"data": {"data": \(payload)}}}}
        """.data(using: .utf8)!
    }
    try expectEqual(
        TokenPlanConsoleAPIClient.parseResetAvailableCount(envelope(#"{"remainResetCount": 1, "per1WeekResetTime": 1789400000000}"#)),
        1,
        "a reset count key"
    )
    try expectEqual(
        TokenPlanConsoleAPIClient.parseResetAvailableCount(envelope(#"{"resetInfo": {"availableTimes": 2}, "specCode": "standard"}"#)),
        2,
        "nested reset info"
    )
    try expectEqual(
        TokenPlanConsoleAPIClient.parseResetAvailableCount(envelope(#"{"per1WeekPercentage": 0.15, "per1WeekResetTime": 1789400000000}"#)),
        nil,
        "reset timestamps are not counts"
    )
    try expectEqual(
        TokenPlanConsoleAPIClient.parseResetAvailableCount(#"{"data": {"success": false, "errorCode": "NotLogined"}}"#.data(using: .utf8)!),
        nil,
        "a failed envelope yields nothing"
    )
}

private func testTokenPlanParserReadsZeroQwenUsage() throws {
    let qwenText = """
    7-Day Used
    Will reset at 2026-09-16 10:03:00 (UTC+8) 0%
    0% 100%
    """
    let qwen = try TokenPlanWebClient.parseQwen(renderedText: qwenText)
        ?? { throw AdditionalProviderTestError.failure("Qwen zero usage did not parse") }()
    try expectClose(qwen.quotaUsedPercent ?? -1, 0, "zero meter value")
}

/// A page that has not rendered the quota card must stay unparsed, so the
/// readiness poll keeps waiting instead of importing a number that is not
/// there.
private func testTokenPlanParserReportsNoQuotaBeforeTheValueRenders() throws {
    let qwenText = """
    Standard Plan Active
    Remaining Days 14 days
    Plan Quota
    Usage Statistics
    """
    let reading = TokenPlanWebClient.parseQwen(renderedText: qwenText)
    try expect(reading?.quotaUsedPercent == nil, "no quota reading before the meter renders")
}

/// Model Studio moved the Standard plan from a 7-day rolling quota to a monthly
/// one. The card's layout is unchanged — only its heading and the reset date
/// differ — so the period has to be read from the heading. Fixture transcribed
/// from the console on 2026-09-22.
private func testTokenPlanParserReadsQwenMonthlyMeter() throws {
    let qwenText = """
    Standard Plan Active
    Auto-Renewal
    Start Time 2026-08-26 00:00:00
    End Time 2026-09-26 00:00:00
    Plan Quota
    Updated at: 2026-09-22 22:34:02
    Usage Statistics
    Monthly Usage
    Will reset at 2026-09-26 00:00:00 (UTC+8) 0%
    0%
    100%
    Reset
    Quota Add-on
    """
    let qwen = try TokenPlanWebClient.parseQwen(renderedText: qwenText)
        ?? { throw AdditionalProviderTestError.failure("Qwen monthly meter did not parse") }()

    try expectClose(qwen.quotaUsedPercent ?? -1, 0, "meter value, not the bar's axis label")
    try expectEqual(qwen.meterPeriod, .monthly, "the heading says the meter is monthly")
    try expectEqual(qwen.periodEnd, date("2026-09-25T16:00:00Z"), "UTC+8 monthly reset converted to UTC")
    try expectEqual(qwen.planName, "Standard Plan", "plan name")

    // A heading and its noun rendered as separate text nodes still count.
    let split = try TokenPlanWebClient.parseQwen(renderedText: "Monthly\nUsed\nWill reset at 2026-09-26 00:00:00 (UTC+8) 7%")
        ?? { throw AdditionalProviderTestError.failure("split monthly heading did not parse") }()
    try expectEqual(split.meterPeriod, .monthly, "a heading split across two lines still reads")
    try expectClose(split.quotaUsedPercent ?? -1, 7, "split heading keeps its value")
}

/// The old weekly card must keep reporting weekly, or every account still on a
/// rolling 7-day plan would be relabelled by the new monthly default.
private func testTokenPlanParserKeepsQwenWeeklyMeterPeriod() throws {
    let qwenText = """
    Plan Quota
    7-Day Used
    Will reset at 2026-09-16 10:03:00 (UTC+8) 42.5%
    0% 100%
    """
    let qwen = try TokenPlanWebClient.parseQwen(renderedText: qwenText)
        ?? { throw AdditionalProviderTestError.failure("Qwen weekly meter did not parse") }()
    try expectEqual(qwen.meterPeriod, .weekly, "the heading says the meter is weekly")
    try expectClose(qwen.quotaUsedPercent ?? -1, 42.5, "weekly value unchanged")
}

/// The period must come from the meter's own heading, and "Month" appears all
/// over a billing console.
///
/// Every case below goes through `parseQwen`, which flattens the card onto one
/// line exactly as the production callers do. That flattening is the whole
/// difficulty: afterwards a "Billing Month" row three blocks up sits directly
/// beside an "Usage Statistics" heading, so proximity is worthless and only the
/// order of the words against the reset row carries any information. Testing
/// `meterPeriod(in:)` with hand-written newlines in it would pass while the
/// shipping parser got it wrong.
private func testTokenPlanParserDoesNotReadPeriodFromUnrelatedText() throws {
    func period(_ text: String) throws -> TokenPlanMeterPeriod? {
        TokenPlanWebClient.parseQwen(renderedText: text)?.meterPeriod
    }

    try expectEqual(
        try period("""
        Standard Monthly Plan Active
        Remaining Days 14 days
        Plan Quota
        7-Day Used
        Will reset at 2026-09-16 10:03:00 (UTC+8) 12%
        """),
        .weekly,
        "a tier named for a month does not make the meter monthly"
    )

    try expectEqual(
        try period("""
        Billing Month
        Usage Statistics
        7-Day Used
        Will reset at 2026-09-16 10:03:00 (UTC+8) 12%
        """),
        .weekly,
        "a billing row elsewhere on the card cannot claim the reset row"
    )

    try expectEqual(
        try period("""
        Plan Quota
        Updated at: 2026-09-22 22:34:02
        Usage Statistics
        Will reset at 2026-09-26 00:00:00 (UTC+8) 3%
        """),
        nil,
        "no period word anywhere, so no period is claimed and the provider default applies"
    )

    // `innerText` keeps `&nbsp;` as U+00A0, and the heading is markup that can
    // produce one. Called directly because the flattener would replace it.
    try expectEqual(
        TokenPlanWebClient.meterPeriod(in: "Monthly\u{00A0}Usage"),
        .monthly,
        "a non-breaking space inside the heading still reads"
    )
}

// MARK: - Token Plan console API

/// Verbatim response from the console gateway on 2026-09-10, captured while the
/// page displayed 100% used. Note `per1WeekPercentage` is `1.0` for that 100% —
/// it is a 0-1 fraction, matching how the official CLI renders it
/// (`percentage * 100`). Reading it as a percentage would show 1%.
private let qwenConsoleUsageResponse = """
{
  "code": "200",
  "data": {
    "DataV2": {
      "ret": ["SUCCESS::x"],
      "data": {
        "msg": "Success.",
        "code": "SUCCESS",
        "data": { "per1WeekResetTime": 1789524180000, "per1WeekPercentage": 1.0 },
        "requestId": "affb7200-687d-9720-877b-db61640f82d4",
        "success": true
      }
    },
    "success": true,
    "httpStatus": 200,
    "errorCode": "",
    "api": "zeldaHttp.apikeyMgr./tokenplan/personal/api/v2/usage",
    "errorMsg": ""
  },
  "httpStatusCode": "200",
  "requestId": "affb7200-687d-4720-877b-db61640f82d4",
  "successResponse": true
}
"""

private func testTokenPlanConsoleAPIReadsFullQuota() throws {
    let reading = try TokenPlanConsoleAPIClient.parseUsage(Data(qwenConsoleUsageResponse.utf8))
        ?? { throw AdditionalProviderTestError.failure("console usage response did not parse") }()

    try expectClose(reading.quotaUsedPercent ?? -1, 100, "1.0 is a fraction: 100% used, not 1%")
    try expectEqual(reading.periodEnd, date("2026-09-16T02:03:00Z"), "epoch-ms reset converted")
}

/// A partly-used week must not be rounded away.
private func testTokenPlanConsoleAPIReadsFractionalQuota() throws {
    let json = qwenConsoleUsageResponse.replacingOccurrences(of: "\"per1WeekPercentage\": 1.0", with: "\"per1WeekPercentage\": 0.425")
    let reading = try TokenPlanConsoleAPIClient.parseUsage(Data(json.utf8))
        ?? { throw AdditionalProviderTestError.failure("fractional usage did not parse") }()
    try expectClose(reading.quotaUsedPercent ?? -1, 42.5, "0.425 -> 42.5%")
}

/// The Standard plan's monthly meter, on the same response and the same
/// envelope. The weekly pair is *absent* rather than zero — that is exactly how
/// the console decides which meter to draw (`typeof per1WeekPercentage ===
/// 'number'`), so the app has to decide the same way. Field names and units
/// confirmed against the console's own `app-tokenplan` bundle.
private let qwenConsoleMonthlyUsageResponse = """
{
  "code": "200",
  "data": {
    "DataV2": {
      "ret": ["SUCCESS::x"],
      "data": {
        "msg": "Success.",
        "code": "SUCCESS",
        "data": { "per1MonthResetTime": 1790352000000, "per1MonthPercentage": 0.0 },
        "requestId": "b1a2c3d4",
        "success": true
      }
    },
    "success": true,
    "httpStatus": 200,
    "errorCode": "",
    "api": "zeldaHttp.apikeyMgr./tokenplan/personal/api/v2/usage",
    "errorMsg": ""
  },
  "httpStatusCode": "200",
  "requestId": "b1a2c3d4",
  "successResponse": true
}
"""

private func testTokenPlanConsoleAPIReadsMonthlyQuota() throws {
    let reading = try TokenPlanConsoleAPIClient.parseUsage(Data(qwenConsoleMonthlyUsageResponse.utf8))
        ?? { throw AdditionalProviderTestError.failure("console monthly usage response did not parse") }()

    try expectClose(reading.quotaUsedPercent ?? -1, 0, "0.0 is a fraction: 0% used, not a miss")
    try expectEqual(reading.meterPeriod, .monthly, "a monthly-only payload is a monthly meter")
    try expectEqual(reading.periodEnd, date("2026-09-25T16:00:00Z"), "epoch-ms monthly reset converted")

    let used = qwenConsoleMonthlyUsageResponse
        .replacingOccurrences(of: "\"per1MonthPercentage\": 0.0", with: "\"per1MonthPercentage\": 0.425")
    let partUsed = try TokenPlanConsoleAPIClient.parseUsage(Data(used.utf8))
        ?? { throw AdditionalProviderTestError.failure("fractional monthly usage did not parse") }()
    try expectClose(partUsed.quotaUsedPercent ?? -1, 42.5, "0.425 -> 42.5%")
    try expectEqual(partUsed.meterPeriod, .monthly, "still monthly")
}

/// A response can carry both periods, and a weekly timestamp can outlive the
/// weekly plan. Picking by "whichever key is present" would file a monthly
/// account under Weekly and then reject its reset as too far off.
private func testTokenPlanConsoleAPIPrefersWeeklyOnlyWhenItReportsOne() throws {
    func envelope(_ payload: String) -> Data {
        """
        {"data": {"success": true, "DataV2": {"data": {"data": \(payload)}}}}
        """.data(using: .utf8)!
    }

    let both = try TokenPlanConsoleAPIClient.parseUsage(envelope(
        #"{"per1WeekPercentage": 0.25, "per1WeekResetTime": 1789524180000, "per1MonthPercentage": 0.9, "per1MonthResetTime": 1790352000000}"#
    )) ?? { throw AdditionalProviderTestError.failure("both-period payload did not parse") }()
    try expectEqual(both.meterPeriod, .weekly, "the console renders the weekly meter when it reports one")
    try expectClose(both.quotaUsedPercent ?? -1, 25, "and the weekly percentage goes with it")
    try expectEqual(both.periodEnd, date("2026-09-16T02:03:00Z"), "as does the weekly reset")

    let staleWeek = try TokenPlanConsoleAPIClient.parseUsage(envelope(
        #"{"per1WeekResetTime": 1789524180000, "per1MonthPercentage": 0.4, "per1MonthResetTime": 1790352000000}"#
    )) ?? { throw AdditionalProviderTestError.failure("stale weekly reset payload did not parse") }()
    try expectEqual(staleWeek.meterPeriod, .monthly, "a leftover weekly timestamp cannot drag a monthly account back to weekly")
    try expectClose(staleWeek.quotaUsedPercent ?? -1, 40, "the monthly percentage is the one rendered")
    try expectEqual(staleWeek.periodEnd, date("2026-09-25T16:00:00Z"), "and the monthly reset goes with it")
}

/// The Plan Quota card's "{n} available" badge counts the reset-card list. The
/// subscription record has no such field, which is why the count came back
/// empty and the banked-reset pill never appeared.
private func testTokenPlanConsoleAPIReadsResetCardList() throws {
    func envelope(_ payload: String) -> Data {
        """
        {"data": {"success": true, "DataV2": {"data": {"data": \(payload)}}}}
        """.data(using: .utf8)!
    }

    try expectEqual(
        TokenPlanConsoleAPIClient.parseResetCardCount(envelope(#"{"result": [{"id": "a"}, {"id": "b"}]}"#)),
        2,
        "two cards, two banked resets"
    )
    try expectEqual(
        TokenPlanConsoleAPIClient.parseResetCardCount(envelope(#"{"result": []}"#)),
        0,
        "an empty list is a real zero, not a miss"
    )
    try expectEqual(
        TokenPlanConsoleAPIClient.parseResetCardCount(envelope(#"{"per1MonthPercentage": 0.1}"#)),
        nil,
        "no list, no count"
    )
    try expectEqual(
        TokenPlanConsoleAPIClient.parseResetCardCount(#"{"data": {"success": false, "errorCode": "NotLogined"}}"#.data(using: .utf8)!),
        nil,
        "a failed envelope yields nothing"
    )
}
/// The gateway reports an expired console session in the body with HTTP 200, so
/// it has to be surfaced as a credential problem rather than a parse failure —
/// otherwise the card asks the user to wait instead of to reconnect.
private func testTokenPlanConsoleAPIDetectsExpiredSession() throws {
    let json = """
    {"code":"200","data":{"success":false,"errorCode":"NotLogined","errorMsg":"","DataV2":{}},"successResponse":false}
    """
    do {
        _ = try TokenPlanConsoleAPIClient.parseUsage(Data(json.utf8))
        throw AdditionalProviderTestError.failure("expired session should throw")
    } catch let error as ProviderFetchError {
        guard case .credentialExpired = error else {
            throw AdditionalProviderTestError.failure("expected credentialExpired, got \(error)")
        }
    }
}

/// An unrecognised body must not masquerade as a zero quota.
private func testTokenPlanConsoleAPIReportsNothingForUnknownShape() throws {
    let reading = try TokenPlanConsoleAPIClient.parseUsage(Data("{\"code\":\"200\"}".utf8))
    try expect(reading == nil, "unknown shape yields no reading, not 0%")
}

private func testTokenPlanCachedAndManualZeroUsageProduceMeters() async throws {
    let cachedCredential = ProviderCredential(
        extraFields: [
            SpendProviderCredentialField.tokenPlanCachedUsedPercent: "0",
            SpendProviderCredentialField.tokenPlanCachedPlanName: "Lite Plan Plan",
            SpendProviderCredentialField.tokenPlanCachedResetAt: "2026-09-25T23:59:59Z"
        ]
    )
    let cachedSnapshot = try await MimoProviderClient().fetchSnapshot(credentials: cachedCredential)
    try expectEqual(cachedSnapshot.fetchState, .success, "MiMo cached snapshot succeeds")
    try expectEqual(cachedSnapshot.planName, "Lite Plan", "Duplicated cached plan suffix is repaired")
    try expectEqual(cachedSnapshot.windows.count, 1, "MiMo cached snapshot has one quota meter")
    try expectEqual(cachedSnapshot.windows[0].windowKind, .monthly, "MiMo quota has a monthly pace window")
    try expectClose(cachedSnapshot.windows[0].used, 0, "MiMo cached zero usage")
    try expectEqual(
        cachedSnapshot.windows[0].subtitle,
        "Captured from the imported browser session",
        "MiMo cached reading provenance"
    )

    let manualCredential = ProviderCredential(
        extraFields: [SpendProviderCredentialField.manualWeeklyUsedPercent: "0"]
    )
    let manualSnapshot = try await QwenProviderClient().fetchSnapshot(credentials: manualCredential)
    try expectEqual(manualSnapshot.fetchState, .success, "Qwen manual zero snapshot succeeds")
    try expectEqual(manualSnapshot.windows.count, 1, "Qwen manual zero has one quota meter")
    try expectClose(manualSnapshot.windows[0].used, 0, "Qwen manual zero usage")

    let staleQwenSnapshot = try await QwenProviderClient().fetchSnapshot(
        credentials: ProviderCredential(
            extraFields: [
                SpendProviderCredentialField.tokenPlanCachedUsedPercent: "32",
                SpendProviderCredentialField.tokenPlanCachedResetAt: isoString(Date().addingTimeInterval(400 * 86_400))
            ]
        )
    )
    try expect(
        staleQwenSnapshot.windows.first?.resetDate == nil,
        "Qwen ignores a cached subscription end date"
    )

    // The other side of the same acceptance window. A monthly boundary is up to
    // a month away, so the eight-day cap built for a weekly meter used to drop
    // it and the card showed no reset at all. Both fixtures are relative to now:
    // a hard-coded "far future" date drifts into range and rots the test.
    let monthlyQwenSnapshot = try await QwenProviderClient().fetchSnapshot(
        credentials: ProviderCredential(
            extraFields: [
                SpendProviderCredentialField.tokenPlanCachedUsedPercent: "32",
                SpendProviderCredentialField.tokenPlanCachedResetAt: isoString(Date().addingTimeInterval(21 * 86_400))
            ]
        )
    )
    try expect(
        monthlyQwenSnapshot.windows.first?.resetDate != nil,
        "Qwen keeps a monthly reset three weeks out"
    )
    try expectEqual(
        monthlyQwenSnapshot.windows.first?.label,
        "Monthly Usage",
        "a cached Qwen reading still lands on the monthly meter"
    )
}

/// The meter has to reach the Monthly bucket, not Weekly. The grouping keys off
/// the label first and the window kind second, so the two have to agree — and a
/// monthly meter filed under Weekly also draws seven segments for a four-week
/// span.
private func testQwenMonthlyMeterLandsInMonthlyPeriod() async throws {
    let snapshot = try await QwenProviderClient().fetchSnapshot(
        credentials: ProviderCredential(
            extraFields: [SpendProviderCredentialField.manualWeeklyUsedPercent: "12"]
        )
    )
    try expectEqual(snapshot.windows.count, 1, "Qwen has one quota meter")
    let window = snapshot.windows[0]
    try expectEqual(window.label, "Monthly Usage", "the Standard plan's meter is labelled monthly")
    try expectEqual(window.windowKind, .monthly, "and keyed monthly")
    try expectEqual(window.periodGroup(for: .qwen), .monthlyAndAPI, "so it lands in the Monthly + API bucket")
    try expectEqual(window.segmentCount(for: .qwen), 4, "and draws four segments, not seven")

    try expect(
        TokenPlanMeterPeriod.monthly.maximumResetLeadTime > TokenPlanMeterPeriod.weekly.maximumResetLeadTime,
        "a monthly reset may sit further out than a weekly one"
    )
}

/// The other side of the same lookup: an account still on a rolling week keeps
/// the old label, the old bucket and the old eight-day horizon. This is what
/// stops the new monthly default from relabelling a plan that never moved, and
/// it exercises the recorded-period field end to end — import writes it, the
/// cached reading returns it, and the snapshot labels the meter from it.
private func testQwenWeeklyAccountKeepsWeeklyMeter() async throws {
    let snapshot = try await QwenProviderClient().fetchSnapshot(
        credentials: ProviderCredential(
            extraFields: [
                SpendProviderCredentialField.tokenPlanCachedUsedPercent: "18",
                SpendProviderCredentialField.tokenPlanCachedMeterPeriod: TokenPlanMeterPeriod.weekly.rawValue,
                SpendProviderCredentialField.tokenPlanCachedResetAt: isoString(Date().addingTimeInterval(21 * 86_400))
            ]
        )
    )
    try expectEqual(snapshot.windows.count, 1, "Qwen has one quota meter")
    let window = snapshot.windows[0]
    try expectEqual(window.label, "7-Day Quota", "a recorded weekly period keeps the weekly label")
    try expectEqual(window.windowKind, .weekly, "and the weekly window kind")
    try expectEqual(window.periodGroup(for: .qwen), .weekly, "so it stays in the Weekly bucket")
    try expectEqual(window.segmentCount(for: .qwen), 7, "and draws seven segments")
    try expect(
        window.resetDate == nil,
        "a reset three weeks out is beyond a weekly meter's horizon"
    )
}

/// Both sources can miss, and the *kind* of error has to decide which verdict
/// the user sees — not the order the sources happened to run in. Reversing this
/// is the original bug: the API's rejection was thrown from inside the fetch, so
/// the scrape never ran and a readable page was reported as a parse error.
private func testTokenPlanFailureChoicePrefersCredentialErrors() throws {
    let apiCredential = ProviderFetchError.credentialExpired("Qwen console session expired.")
    let apiParse = ProviderFetchError.parsingError("Model Studio console API error: Throttled")
    let scrapeParse = ProviderFetchError.parsingError("No token-plan meters found.")
    let scrapeCredential = ProviderFetchError.credentialExpired("Browser sign-in expired.")

    func isCredential(_ error: Error) -> Bool {
        (error as? ProviderFetchError)?.isCredentialFailure == true
    }

    try expect(
        isCredential(TokenPlanFailureChoice.preferred(scrape: scrapeParse, api: apiCredential)),
        "a credential rejection from the API rescues a vague parse failure from the page"
    )
    try expectEqual(
        TokenPlanFailureChoice.preferred(scrape: scrapeCredential, api: apiParse).localizedDescription,
        scrapeCredential.localizedDescription,
        "the page's own credential verdict beats the API's parse error"
    )
    try expectEqual(
        TokenPlanFailureChoice.preferred(scrape: scrapeCredential, api: apiCredential).localizedDescription,
        scrapeCredential.localizedDescription,
        "when both are credential errors the more specific page verdict wins"
    )
    try expectEqual(
        TokenPlanFailureChoice.preferred(scrape: scrapeParse, api: apiParse).localizedDescription,
        scrapeParse.localizedDescription,
        "with no credential error anywhere the page's own error is reported"
    )
    try expectEqual(
        TokenPlanFailureChoice.preferred(scrape: scrapeParse, api: nil).localizedDescription,
        scrapeParse.localizedDescription,
        "no API attempt, no API verdict"
    )
}

/// The classification above only works if the kind survives being persisted: the
/// store keeps failures as text in UserDefaults, across restarts.
@MainActor
private func testBrowserRefreshStoreRecordsCredentialFailureKind() async throws {
    let suite = "browser-meter-credential-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let cache = BrowserMeterRefreshStore(defaults: defaults)
    let url = URL(string: "https://modelstudio.console.alibabacloud.com/token-plan")!

    let expired = await cache.read(
        url: url, sessionID: "cookie-a", initial: Optional<TokenPlanWebReading>.none,
        initialAt: nil, interval: 300, failureInterval: 900
    ) {
        throw ProviderFetchError.credentialExpired("Qwen console session expired.")
    }
    guard case .credentialExpired = expired.failureError else {
        throw AdditionalProviderTestError.failure("a rejected session must stay a credential error, got \(String(describing: expired.failureError))")
    }

    let unparsed = await cache.read(
        url: url, sessionID: "cookie-b", initial: Optional<TokenPlanWebReading>.none,
        initialAt: nil, interval: 300, failureInterval: 900
    ) {
        throw ProviderFetchError.parsingError("No token-plan meters found.")
    }
    guard case .parsingError(let message) = unparsed.failureError else {
        throw AdditionalProviderTestError.failure("a page that did not parse must stay a parse error")
    }
    try expectEqual(message, "No token-plan meters found.", "the prefix is applied once, not twice")

    // Still inside the failure cooldown, so this returns the stored entry
    // without calling the closure — proving the kind was written to disk.
    let restarted = BrowserMeterRefreshStore(defaults: defaults)
    let persisted = await restarted.read(
        url: url, sessionID: "cookie-a", initial: Optional<TokenPlanWebReading>.none,
        initialAt: nil, interval: 300, failureInterval: 900
    ) {
        throw ProviderFetchError.parsingError("must not be called during the cooldown")
    }
    guard case .credentialExpired = persisted.failureError else {
        throw AdditionalProviderTestError.failure("the credential kind must survive a restart")
    }
}

private func testCerebrasCachedWebBalanceSurvivesLiveMiss() async throws {
    let credential = ProviderCredential(
        extraFields: [
            SpendProviderCredentialField.cerebrasCachedBalance: "11.48",
            SpendProviderCredentialField.cerebrasCachedCurrency: "USD"
        ]
    )
    let snapshot = try await CerebrasProviderClient().fetchSnapshot(credentials: credential)

    try expectEqual(snapshot.fetchState, .success, "Cerebras cached balance snapshot succeeds")
    try expectEqual(snapshot.balances.first?.label, "Current balance", "Cerebras cached balance label")
    try expectClose(snapshot.balances.first?.amount ?? -1, 11.48, "Cerebras cached balance amount")
}

private func testCerebrasWebBillingParserReadsCurrentBalance() throws {
    let reading = try WebBillingClient.parse(
        html: "Current balance $11.48 Active subscriptions There are no active subscriptions",
        now: date("2026-08-28T11:00:00Z")
    ) ?? { throw AdditionalProviderTestError.failure("Cerebras current balance did not parse") }()

    try expectClose(reading.balance ?? -1, 11.48, "Cerebras current balance")
    try expectEqual(reading.currency, "USD", "Cerebras current balance currency")
}

private func testMetaCreditMeterCarriesBillingReset() async throws {
    let resetAt = "2026-09-01T00:00:00Z"
    let credential = ProviderCredential(
        extraFields: [
            SpendProviderCredentialField.manualTopUpTotal: "15",
            SpendProviderCredentialField.manualCurrentBalance: "11.19",
            SpendProviderCredentialField.manualCurrency: "GBP",
            SpendProviderCredentialField.manualResetAt: resetAt
        ]
    )
    let client = MetaProviderClient(museCliProbe: { _, _, _ in nil })
    let snapshot = try await client.fetchSnapshot(credentials: credential)
    let creditWindow = try snapshot.windows.first(where: { $0.label == "Credit used" })
        ?? { throw AdditionalProviderTestError.failure("Meta credit meter missing") }()

    try expectEqual(creditWindow.windowKind, .monthly, "Meta credit meter has a monthly pace window")
    try expectEqual(creditWindow.resetDate, date(resetAt), "Meta credit meter carries billing reset")
    try expect(
        creditWindow.pace(providerID: .meta, at: date("2026-08-20T00:00:00Z")) != nil,
        "Meta credit meter surfaces a pace marker"
    )
}

private func localDate(
    year: Int, month: Int, day: Int, hour: Int = 0, minute: Int = 0
) -> Date {
    var components = DateComponents()
    components.year = year
    components.month = month
    components.day = day
    components.hour = hour
    components.minute = minute
    return Calendar.current.date(from: components)!
}

private func testMuseSubscriptionParserReadsUsagePage() throws {
    let now = localDate(year: 2026, month: 9, day: 1, hour: 12)
    let renderedText = """
    Usage
    Muse Code High Usage subscription
    Last updated at 10:14
    Current usage
    12% used
    Weekly limit
    34% used
    Resets 7 Sep at 01:00
    Pay as you go
    API Key: All
    Model: All
    26/08/2026 - 01/09/2026
    £3.84
    Spend (GBP)
    7d
    19.6M
    Input tokens
    183.1k
    Output tokens
    """
    let reading = try MuseSubscriptionWebClient.parse(renderedText: renderedText, now: now)
        ?? { throw AdditionalProviderTestError.failure("Muse usage page should parse") }()
    try expectEqual(reading.planName, "Muse Code High Usage", "Muse plan name")
    try expectClose(reading.currentUsedPercent ?? -1, 12, "Muse current usage percent")
    try expectClose(reading.weeklyUsedPercent ?? -1, 34, "Muse weekly percent")
    try expectEqual(
        reading.weeklyResetAt,
        localDate(year: 2026, month: 9, day: 7, hour: 1),
        "Muse weekly reset infers the year from the page's local date"
    )
}

private func testMuseSubscriptionParserAcceptsValueBeforeLabel() throws {
    let now = Date()
    let reading = try MuseSubscriptionWebClient.parse(
        renderedText: "Muse Code High Usage subscription 3% used Current usage Weekly limit 45 % used Resets in 3 days",
        now: now
    ) ?? { throw AdditionalProviderTestError.failure("value-before-label layout should parse") }()
    try expectClose(reading.currentUsedPercent ?? -1, 3, "value-before-label current percent")
    try expectClose(reading.weeklyUsedPercent ?? -1, 45, "spaced weekly percent")
    let expectedReset = now.addingTimeInterval(3 * 24 * 60 * 60)
    try expect(
        abs(reading.weeklyResetAt.map { $0.timeIntervalSince(expectedReset) } ?? 999) < 5,
        "relative reset lands three days out"
    )
}

private func testMuseSubscriptionParserRejectsSignedOutAndPAYGOnlyPages() throws {
    let now = Date()
    try expect(
        MuseSubscriptionWebClient.parse(renderedText: "Sign in Email Password Continue", now: now) == nil,
        "signed-out page must not parse"
    )
    try expect(
        MuseSubscriptionWebClient.parse(renderedText: "Usage Pay as you go £3.84 Spend (GBP)", now: now) == nil,
        "PAYG-only page must not fabricate subscription meters"
    )
}

private func testMuseSubscriptionResetDateParsesVariantsAndRollsYear() throws {
    let calendar = Calendar.current
    let decemberNow = localDate(year: 2026, month: 12, day: 30, hour: 12)
    try expectEqual(
        MuseSubscriptionWebClient.resetDate(in: "Resets 2 Jan at 01:00", now: decemberNow, calendar: calendar),
        localDate(year: 2027, month: 1, day: 2, hour: 1),
        "December reset rolls into the next year"
    )
    let septemberNow = localDate(year: 2026, month: 9, day: 1, hour: 12)
    try expectEqual(
        MuseSubscriptionWebClient.resetDate(in: "Resets Sep 7 at 1:00 AM", now: septemberNow, calendar: calendar),
        localDate(year: 2026, month: 9, day: 7, hour: 1),
        "US month-day order with a 12-hour clock"
    )
    try expectEqual(
        MuseSubscriptionWebClient.resetDate(in: "Resets 7 Sep 2026 at 13:30", now: septemberNow, calendar: calendar),
        localDate(year: 2026, month: 9, day: 7, hour: 13, minute: 30),
        "explicit year and 24-hour time"
    )
    try expectEqual(
        MuseSubscriptionWebClient.resetDate(in: "Resets tomorrow at 01:00", now: septemberNow, calendar: calendar),
        localDate(year: 2026, month: 9, day: 2, hour: 1),
        "tomorrow with a time"
    )
}

private func testMuseSubscriptionParserReadsCurrentWindowClockReset() throws {
    let now = localDate(year: 2026, month: 9, day: 1, hour: 12)
    let renderedText = """
    Usage
    Muse Code High Usage subscription
    Current usage
    12% used
    Resets at 9:18 PM
    Weekly limit
    34% used
    Resets 7 Sep at 01:00
    Pay as you go
    """
    let reading = try MuseSubscriptionWebClient.parse(renderedText: renderedText, now: now)
        ?? { throw AdditionalProviderTestError.failure("usage page with both resets should parse") }()
    try expectEqual(
        reading.currentResetAt,
        localDate(year: 2026, month: 9, day: 1, hour: 21, minute: 18),
        "bare clock time resolves to today when it is still ahead"
    )
    try expectEqual(
        reading.weeklyResetAt,
        localDate(year: 2026, month: 9, day: 7, hour: 1),
        "weekly reset is unaffected by the current window's clock time"
    )

    let lateEvening = localDate(year: 2026, month: 9, day: 1, hour: 22)
    let rolled = try MuseSubscriptionWebClient.parse(renderedText: renderedText, now: lateEvening)
        ?? { throw AdditionalProviderTestError.failure("late-evening parse should succeed") }()
    try expectEqual(
        rolled.currentResetAt,
        localDate(year: 2026, month: 9, day: 2, hour: 21, minute: 18),
        "a clock time already past today rolls to tomorrow"
    )
}

private func testMuseSubscriptionWeeklyFallbackIgnoresBareClockTime() throws {
    let now = localDate(year: 2026, month: 9, day: 1, hour: 12)
    let reading = try MuseSubscriptionWebClient.parse(
        renderedText: "Muse Code High Usage subscription Current usage 12% used Resets at 9:18 PM",
        now: now
    ) ?? { throw AdditionalProviderTestError.failure("current-only page should parse") }()
    try expectClose(reading.currentUsedPercent ?? -1, 12, "current percent still reads")
    try expect(
        reading.weeklyResetAt == nil,
        "the whole-page weekly fallback must not adopt the current window's clock time"
    )
}

private func testMuseCachedSubscriptionReadingRestoresCurrentReset() throws {
    let currentReset = localDate(year: 2026, month: 9, day: 1, hour: 21, minute: 18)
    let weeklyReset = localDate(year: 2026, month: 9, day: 7, hour: 1)
    let formatter = ISO8601DateFormatter()
    let fields = [
        SpendProviderCredentialField.museCachedPlanName: "Muse Code High Usage",
        SpendProviderCredentialField.museCachedCurrentPercent: "12",
        SpendProviderCredentialField.museCachedCurrentResetAt: formatter.string(from: currentReset),
        SpendProviderCredentialField.museCachedWeeklyPercent: "34",
        SpendProviderCredentialField.museCachedWeeklyResetAt: formatter.string(from: weeklyReset)
    ]
    let reading = try MetaProviderClient.cachedMuseSubscriptionReading(from: fields)
        ?? { throw AdditionalProviderTestError.failure("cached import fields should rehydrate") }()
    try expectClose(reading.currentUsedPercent ?? -1, 12, "cached current percent")
    try expectEqual(reading.currentResetAt, currentReset, "cached current reset round-trips")
    try expectEqual(reading.weeklyResetAt, weeklyReset, "cached weekly reset round-trips")

    // A reset with no meter behind it is still not a usable reading.
    try expect(
        MetaProviderClient.cachedMuseSubscriptionReading(
            from: [SpendProviderCredentialField.museCachedCurrentResetAt: formatter.string(from: currentReset)]
        ) == nil,
        "a stored reset alone does not make a reading"
    )
}

private func testMuseSubscriptionMetersCarryImportedCurrentReset() throws {
    let now = Date()
    let cached = MuseSubscriptionWebReading(
        planName: "Muse Code High Usage",
        currentUsedPercent: 12,
        currentResetAt: now.addingTimeInterval(2 * 60 * 60),
        weeklyUsedPercent: 34,
        weeklyResetAt: now.addingTimeInterval(3 * 24 * 60 * 60)
    )
    let assembly = MetaProviderClient.museSubscriptionMeters(cli: nil, live: nil, cached: cached, now: now)
    try expectEqual(assembly.windows.count, 2, "both cached meters render")
    try expectEqual(
        assembly.windows[0].resetDate,
        cached.currentResetAt,
        "the imported current reset reaches the session meter"
    )

    // The current window rolls in hours, so an import older than the window
    // must not show a reset that has already passed.
    let lapsed = MuseSubscriptionWebReading(
        planName: nil,
        currentUsedPercent: 12,
        currentResetAt: now.addingTimeInterval(-600),
        weeklyUsedPercent: nil,
        weeklyResetAt: nil
    )
    let lapsedAssembly = MetaProviderClient.museSubscriptionMeters(cli: nil, live: nil, cached: lapsed, now: now)
    try expect(
        lapsedAssembly.windows[0].resetDate == nil,
        "a lapsed imported current reset is dropped"
    )

    // A CLI reading owns its own reset; a stale cached one must not leak in.
    let cli = MuseCliSubscriptionReading(
        planName: "Muse Code High Usage",
        currentUsedPercent: 40,
        currentResetAt: nil,
        weeklyUsedPercent: 55,
        weeklyResetAt: nil
    )
    let cliAssembly = MetaProviderClient.museSubscriptionMeters(cli: cli, live: nil, cached: cached, now: now)
    try expectClose(cliAssembly.windows[0].used, 40, "CLI current percent wins")
    try expect(
        cliAssembly.windows[0].resetDate == nil,
        "the CLI meter does not borrow the import's reset"
    )
}

private func testMuseSubscriptionMetersPreferLiveAndFallBackToCached() throws {
    let now = Date()
    let cachedReset = now.addingTimeInterval(3 * 24 * 60 * 60)
    let live = MuseSubscriptionWebReading(
        planName: nil,
        currentUsedPercent: 12,
        weeklyUsedPercent: nil,
        weeklyResetAt: nil
    )
    let cached = MuseSubscriptionWebReading(
        planName: "Muse Code High Usage",
        currentUsedPercent: 90,
        weeklyUsedPercent: 34,
        weeklyResetAt: cachedReset
    )
    let assembly = MetaProviderClient.museSubscriptionMeters(cli: nil, live: live, cached: cached, now: now)
    try expectEqual(assembly.planName, "Muse Code High Usage", "plan falls back to cached")
    try expectEqual(assembly.windows.count, 2, "both meters present")
    try expectEqual(assembly.windows[0].label, "Current usage", "current meter leads")
    try expectClose(assembly.windows[0].used, 12, "live current beats cached")
    try expectEqual(assembly.windows[0].windowKind, .session, "current meter is a session window")
    try expectClose(assembly.windows[1].used, 34, "weekly falls back to cached")
    try expectEqual(assembly.windows[1].resetDate, cachedReset, "weekly reset follows the weekly source")
    try expectEqual(assembly.windows[1].windowKind, .weekly, "weekly meter kind")

    let expired = MuseSubscriptionWebReading(
        planName: nil,
        currentUsedPercent: nil,
        weeklyUsedPercent: 50,
        weeklyResetAt: now.addingTimeInterval(-3_600)
    )
    let expiredAssembly = MetaProviderClient.museSubscriptionMeters(cli: nil, live: expired, cached: nil, now: now)
    try expectEqual(expiredAssembly.windows.count, 1, "weekly-only reading yields one meter")
    try expect(
        expiredAssembly.windows[0].resetDate == nil,
        "expired reset is dropped so the meter is not zeroed"
    )

    let farReset = MuseSubscriptionWebReading(
        planName: nil,
        currentUsedPercent: nil,
        weeklyUsedPercent: 50,
        weeklyResetAt: now.addingTimeInterval(20 * 24 * 60 * 60)
    )
    let farAssembly = MetaProviderClient.museSubscriptionMeters(cli: nil, live: farReset, cached: nil, now: now)
    try expect(
        farAssembly.windows[0].resetDate == nil,
        "a 20-day weekly reset is treated as a misparse"
    )

    let none = MetaProviderClient.museSubscriptionMeters(cli: nil, live: nil, cached: nil, now: now)
    try expect(none.windows.isEmpty && none.planName == nil, "no readings produce no meters")
}

private func testMuseSubscriptionRefreshCacheServesHourlyAndSurvivesRestart() async throws {
    let suiteName = "muse-subscription-cache-tests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let key = "meta.museSubscriptionRefreshCache.test"
    let cache = MuseSubscriptionRefreshCache(defaults: defaults, persistenceKey: key)
    let t0 = Date()
    let cookie = "session=abc"

    guard case .fetch = await cache.decision(for: cookie, now: t0) else {
        throw AdditionalProviderTestError.failure("first decision must fetch")
    }

    let reading = MuseSubscriptionWebReading(
        planName: "Muse Code High Usage",
        currentUsedPercent: 12,
        weeklyUsedPercent: 34,
        weeklyResetAt: nil
    )
    _ = await cache.recordResult(reading, for: cookie, now: t0)

    guard case .cached(let served) = await cache.decision(for: cookie, now: t0.addingTimeInterval(30 * 60)) else {
        throw AdditionalProviderTestError.failure("within the hour the cache must be served")
    }
    try expectEqual(served, reading, "cached reading round-trips")

    guard case .fetch = await cache.decision(for: cookie, now: t0.addingTimeInterval(61 * 60)) else {
        throw AdditionalProviderTestError.failure("after an hour a live fetch is due")
    }

    // A failed live fetch keeps the last reading and backs off six hours.
    let t1 = t0.addingTimeInterval(2 * 60 * 60)
    let kept = await cache.recordResult(nil, for: cookie, now: t1)
    try expectEqual(kept, reading, "failed fetch keeps the last reading")
    guard case .cached(let stillServed) = await cache.decision(for: cookie, now: t1.addingTimeInterval(3 * 60 * 60)) else {
        throw AdditionalProviderTestError.failure("failure backoff must serve the cache")
    }
    try expectEqual(stillServed, reading, "backoff serves the kept reading")
    guard case .fetch = await cache.decision(for: cookie, now: t1.addingTimeInterval(6 * 60 * 60 + 1)) else {
        throw AdditionalProviderTestError.failure("after the failure backoff a fetch is due")
    }

    guard case .fetch = await cache.decision(for: "session=other", now: t0.addingTimeInterval(60)) else {
        throw AdditionalProviderTestError.failure("a different session must not reuse the cache")
    }

    let restarted = MuseSubscriptionRefreshCache(defaults: defaults, persistenceKey: key)
    guard case .cached(let persisted) = await restarted.decision(for: cookie, now: t1.addingTimeInterval(60)) else {
        throw AdditionalProviderTestError.failure("persisted cache must survive a restart")
    }
    try expectEqual(persisted, reading, "persisted reading survives restart")
}

private func testMetaSnapshotLeadsWithCachedSubscriptionMeters() async throws {
    let reset = Date().addingTimeInterval(3 * 24 * 60 * 60)
    let credential = ProviderCredential(
        extraFields: [
            SpendProviderCredentialField.museCachedCurrentPercent: "12.5",
            SpendProviderCredentialField.museCachedWeeklyPercent: "34",
            SpendProviderCredentialField.museCachedPlanName: "Muse Code High Usage",
            SpendProviderCredentialField.museCachedWeeklyResetAt: ISO8601DateFormatter().string(from: reset)
        ]
    )
    let client = MetaProviderClient(museCliProbe: { _, _, _ in nil })
    let snapshot = try await client.fetchSnapshot(credentials: credential)
    try expectEqual(snapshot.planName, "Muse Code High Usage", "subscription plan leads the card")
    try expectEqual(snapshot.windows.first?.label, "Current usage", "subscription meters lead the windows")
    try expectClose(snapshot.windows.first?.used ?? -1, 12.5, "cached current percent")
    let weekly = try snapshot.windows.first(where: { $0.label == "Weekly limit" })
        ?? { throw AdditionalProviderTestError.failure("weekly limit meter missing") }()
    try expectClose(weekly.used, 34, "cached weekly percent")
    try expect(weekly.resetDate != nil, "weekly reset carried onto the meter")
}

private func testMuseCliParserReadsCompactedUsageScreen() throws {
    // Verbatim shape of a partial TUI redraw: cursor positioning instead of
    // spaces, so the whole panel arrives whitespace-free.
    let raw = "Subscription·MuseCodeHighUsageCurrent14%used·Resetsat9:18PMWeekly30%used·ResetsSep7at1:00AMasof4:43PM"
    let now = localDate(year: 2026, month: 9, day: 3, hour: 16, minute: 43)
    let reading = try MuseCliUsageParser.parse(rawText: raw, now: now)
        ?? { throw AdditionalProviderTestError.failure("compacted CLI screen should parse") }()

    try expectEqual(reading.planName, "Muse Code High Usage", "CLI plan name is re-spaced")
    try expectClose(reading.currentUsedPercent ?? -1, 14, "CLI current percent")
    try expectClose(reading.weeklyUsedPercent ?? -1, 30, "CLI weekly percent")
    try expectEqual(
        reading.currentResetAt,
        localDate(year: 2026, month: 9, day: 3, hour: 21, minute: 18),
        "current reset resolves to today's 9:18 PM"
    )
    try expectEqual(
        reading.weeklyResetAt,
        localDate(year: 2026, month: 9, day: 7, hour: 1),
        "weekly reset resolves to Sep 7 at 1:00 AM"
    )
}

private func testMuseCliParserHandlesSpacedRedrawAndAnsi() throws {
    // A full redraw keeps its spacing and arrives wrapped in ANSI.
    let raw = "\u{001B}[2J\u{001B}[H  Subscription · \u{001B}[1mMuse Code High Usage\u{001B}[0m\n"
        + "  Current      7% used · Resets at 11:05 AM\n"
        + "  Weekly       62% used · Resets Sep 7 at 1:00 AM\n"
        + "  as of 3:50 PM\n"
    let now = localDate(year: 2026, month: 9, day: 3, hour: 15, minute: 50)
    let reading = try MuseCliUsageParser.parse(rawText: raw, now: now)
        ?? { throw AdditionalProviderTestError.failure("spaced CLI screen should parse") }()

    try expectClose(reading.currentUsedPercent ?? -1, 7, "spaced current percent")
    try expectClose(reading.weeklyUsedPercent ?? -1, 62, "spaced weekly percent")
    try expectEqual(reading.planName, "Muse Code High Usage", "plan name survives ANSI")
    // 11:05 AM has already passed at 3:50 PM, so the reset rolls to tomorrow.
    try expectEqual(
        reading.currentResetAt,
        localDate(year: 2026, month: 9, day: 4, hour: 11, minute: 5),
        "elapsed current reset rolls to tomorrow"
    )
}

private func testMuseCliParserRollsWeeklyResetAcrossYearEnd() throws {
    let raw = "Subscription·MuseCodeHighUsageCurrent5%used·Resetsat2:00AMWeekly88%used·ResetsJan2at1:00AM"
    let now = localDate(year: 2026, month: 12, day: 30, hour: 12)
    let reading = try MuseCliUsageParser.parse(rawText: raw, now: now)
        ?? { throw AdditionalProviderTestError.failure("year-end CLI screen should parse") }()
    try expectEqual(
        reading.weeklyResetAt,
        localDate(year: 2027, month: 1, day: 2, hour: 1),
        "December weekly reset rolls into the next year"
    )
}

private func testMuseCliParserReadsNewestFrameFromAccumulatedRedraws() throws {
    // The pty buffer keeps every frame the TUI paints. Reading the first match
    // would report the oldest percentages and let the plan capture bridge two
    // frames, so the newest frame must win.
    let raw = "Subscription·MuseCodeHighUsageCurrent14%used·Resetsat9:18PMWeekly30%used·ResetsSep7at1:00AMasof4:43PM"
        + "SessionusageInput0Cached0Output0Total0Turns0Subagentsnone"
        + "Subscription·MuseCodeHighUsageCurrent29%used·Resetsat9:18PMWeekly35%used·ResetsSep7at1:00AMasof5:13PM"
    let now = localDate(year: 2026, month: 9, day: 3, hour: 17, minute: 13)
    let reading = try MuseCliUsageParser.parse(rawText: raw, now: now)
        ?? { throw AdditionalProviderTestError.failure("multi-frame capture should parse") }()

    try expectClose(reading.currentUsedPercent ?? -1, 29, "newest current percent wins")
    try expectClose(reading.weeklyUsedPercent ?? -1, 35, "newest weekly percent wins")
    try expectEqual(
        reading.planName,
        "Muse Code High Usage",
        "plan name survives across accumulated frames"
    )
}

private func testMuseCliParserRejectsIncompleteScreens() throws {
    let now = Date()
    // The status card carries the plan but no meters.
    try expect(
        MuseCliUsageParser.parse(
            rawText: "BILLING  Subscription·MuseCodeHighUsage",
            now: now
        ) == nil,
        "status card without meters must not parse"
    )
    try expect(
        !MuseCliUsageParser.hasSubscriptionScreen(
            MuseCliUsageParser.compacted("Current 14% used · Resets at 9:18 PM")
        ),
        "a half-painted screen is not yet complete"
    )
    try expect(
        MuseCliUsageParser.hasSubscriptionScreen(
            MuseCliUsageParser.compacted("Weekly 30% used · Resets Sep 7 at 1:00 AM")
        ),
        "the weekly meter marks the screen complete"
    )
}

private func testMuseSubscriptionMetersPreferCliOverWeb() throws {
    let now = localDate(year: 2026, month: 9, day: 3, hour: 16)
    let cli = MuseCliSubscriptionReading(
        planName: "Muse Code High Usage",
        currentUsedPercent: 14,
        currentResetAt: localDate(year: 2026, month: 9, day: 3, hour: 21, minute: 18),
        weeklyUsedPercent: 30,
        weeklyResetAt: localDate(year: 2026, month: 9, day: 7, hour: 1)
    )
    let web = MuseSubscriptionWebReading(
        planName: "Stale Plan",
        currentUsedPercent: 47,
        weeklyUsedPercent: 17,
        weeklyResetAt: localDate(year: 2026, month: 9, day: 7, hour: 1)
    )
    let assembly = MetaProviderClient.museSubscriptionMeters(
        cli: cli,
        live: web,
        cached: nil,
        now: now
    )
    try expectEqual(assembly.planName, "Muse Code High Usage", "CLI plan wins over web")
    try expectClose(assembly.windows[0].used, 14, "CLI current percent wins")
    try expectClose(assembly.windows[1].used, 30, "CLI weekly percent wins")
    try expectEqual(
        assembly.windows[0].resetDate,
        cli.currentResetAt,
        "CLI supplies the current-window reset the web page lacks"
    )
    try expectEqual(
        assembly.windows[0].subtitle,
        "Muse Code subscription — local CLI",
        "CLI-sourced meter is labelled as such"
    )

    // With no CLI reading the web values still drive the meters.
    let webOnly = MetaProviderClient.museSubscriptionMeters(
        cli: nil,
        live: web,
        cached: nil,
        now: now
    )
    try expectClose(webOnly.windows[0].used, 47, "web reading remains the fallback")
    try expect(webOnly.windows[0].resetDate == nil, "web current meter has no reset")
    try expectEqual(
        webOnly.windows[0].subtitle,
        "Muse Code subscription — dev.meta.ai/usage",
        "web-sourced meter is labelled as such"
    )

    // A CLI reading that only carries the weekly meter must not blank current.
    let partialCli = MuseCliSubscriptionReading(
        planName: nil,
        currentUsedPercent: nil,
        currentResetAt: nil,
        weeklyUsedPercent: 33,
        weeklyResetAt: nil
    )
    let mixed = MetaProviderClient.museSubscriptionMeters(
        cli: partialCli,
        live: web,
        cached: nil,
        now: now
    )
    try expectClose(mixed.windows[0].used, 47, "current falls back to web when CLI omits it")
    try expectClose(mixed.windows[1].used, 33, "weekly still comes from the CLI")
}

private func testMetaSnapshotPrefersCliReadingOverCachedImport() async throws {
    // End-to-end: a CLI reading must win over the values captured at import,
    // and must carry its current-window reset onto the meter.
    let currentReset = Date().addingTimeInterval(3 * 60 * 60)
    let cliReading = MuseCliSubscriptionReading(
        planName: "Muse Code High Usage",
        currentUsedPercent: 35,
        currentResetAt: currentReset,
        weeklyUsedPercent: 38,
        weeklyResetAt: Date().addingTimeInterval(3 * 24 * 60 * 60)
    )
    let credential = ProviderCredential(
        extraFields: [
            SpendProviderCredentialField.museCachedCurrentPercent: "47",
            SpendProviderCredentialField.museCachedWeeklyPercent: "17",
            SpendProviderCredentialField.museCachedPlanName: "Muse Code High Usage"
        ]
    )
    let client = MetaProviderClient(museCliProbe: { _, _, _ in cliReading })
    let snapshot = try await client.fetchSnapshot(credentials: credential)

    let current = try snapshot.windows.first(where: { $0.label == "Current usage" })
        ?? { throw AdditionalProviderTestError.failure("current meter missing") }()
    try expectClose(current.used, 35, "CLI current percent beats the imported value")
    try expectEqual(current.resetDate, currentReset, "CLI current-window reset reaches the meter")
    try expectEqual(
        current.subtitle,
        "Muse Code subscription — local CLI",
        "the meter is labelled as CLI-sourced"
    )
    let weekly = try snapshot.windows.first(where: { $0.label == "Weekly limit" })
        ?? { throw AdditionalProviderTestError.failure("weekly meter missing") }()
    try expectClose(weekly.used, 38, "CLI weekly percent beats the imported value")
}

private func testMuseCliBinaryLocatorResolvesGrantedFolders() throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory
        .appendingPathComponent("limit-counter-muse-locator-\(UUID().uuidString)", isDirectory: true)
    defer { try? fileManager.removeItem(at: root) }
    let binDirectory = root.appendingPathComponent("bin", isDirectory: true)
    try fileManager.createDirectory(at: binDirectory, withIntermediateDirectories: true)

    try expect(
        MuseCliBinaryLocator.binaryURL(within: binDirectory) == nil,
        "an empty folder holds no launcher"
    )

    let launcher = binDirectory.appendingPathComponent("muse")
    try "#!/bin/sh\n".write(to: launcher, atomically: true, encoding: .utf8)
    try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)

    try expectEqual(
        MuseCliBinaryLocator.binaryURL(within: binDirectory)?.path,
        launcher.path,
        "the launcher is found in the granted folder"
    )
    // Granting the parent (~/.local) must also work, since `muse` lives in its
    // `bin` subfolder.
    try expectEqual(
        MuseCliBinaryLocator.binaryURL(within: root)?.path,
        launcher.path,
        "the launcher is found one level below the granted folder"
    )
    // Executability is deliberately NOT part of the check: the sandbox denies
    // the execute-bit test even for a granted folder, so a present launcher
    // must still resolve.
    try fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: launcher.path)
    try expectEqual(
        MuseCliBinaryLocator.binaryURL(within: binDirectory)?.path,
        launcher.path,
        "a present launcher resolves regardless of the execute bit"
    )
    // A directory named `muse` is not a launcher.
    try fileManager.removeItem(at: launcher)
    try fileManager.createDirectory(at: launcher, withIntermediateDirectories: true)
    try expect(
        MuseCliBinaryLocator.binaryURL(within: binDirectory) == nil,
        "a directory is never accepted as the launcher"
    )
}

private func testMuseCliCadenceIsFrequentButCached() throws {
    let t0 = Date()
    try expect(
        MuseCliRefreshCadence.isDue(now: t0, lastSuccessfulFetchAt: nil, lastAttemptAt: nil),
        "first probe is always due"
    )
    try expect(
        !MuseCliRefreshCadence.isDue(
            now: t0.addingTimeInterval(5 * 60),
            lastSuccessfulFetchAt: t0,
            lastAttemptAt: t0
        ),
        "a five-minute-old CLI reading is reused"
    )
    try expect(
        MuseCliRefreshCadence.isDue(
            now: t0.addingTimeInterval(11 * 60),
            lastSuccessfulFetchAt: t0,
            lastAttemptAt: t0
        ),
        "the CLI re-probes after ten minutes"
    )
    try expect(
        MuseCliRefreshCadence.isDue(
            now: t0.addingTimeInterval(60),
            lastSuccessfulFetchAt: t0,
            lastAttemptAt: t0,
            userInitiated: true
        ),
        "a manual refresh always re-probes"
    )
    // A failed probe backs off harder than a successful one.
    try expect(
        !MuseCliRefreshCadence.isDue(
            now: t0.addingTimeInterval(20 * 60),
            lastSuccessfulFetchAt: nil,
            lastAttemptAt: t0
        ),
        "a failed probe waits out its backoff"
    )
    try expect(
        MuseCliRefreshCadence.isDue(
            now: t0.addingTimeInterval(31 * 60),
            lastSuccessfulFetchAt: nil,
            lastAttemptAt: t0
        ),
        "a failed probe retries after thirty minutes"
    )
    // The CLI must stay far more frequent than the console scrape.
    try expect(
        MuseCliRefreshCadence.successfulFetchInterval
            < MetaWebBillingRefreshCadence.successfulFetchInterval,
        "CLI cadence must beat the rate-limited console cadence"
    )
}

private func testMuseCliRefreshCacheKeepsLastReadingAcrossRestart() async throws {
    let suiteName = "muse-cli-cache-tests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let key = "meta.museCliRefreshCache.test"
    let cache = MuseCliRefreshCache(defaults: defaults, persistenceKey: key)
    let t0 = Date()

    guard case .fetch = await cache.decision(now: t0, userInitiated: false) else {
        throw AdditionalProviderTestError.failure("first decision must probe")
    }

    let reading = MuseCliSubscriptionReading(
        planName: "Muse Code High Usage",
        currentUsedPercent: 14,
        currentResetAt: nil,
        weeklyUsedPercent: 30,
        weeklyResetAt: nil
    )
    _ = await cache.recordResult(reading, now: t0)

    guard case .cached(let served) = await cache.decision(
        now: t0.addingTimeInterval(4 * 60),
        userInitiated: false
    ) else {
        throw AdditionalProviderTestError.failure("a fresh reading must be served from cache")
    }
    try expectEqual(served, reading, "cached CLI reading round-trips")

    // A failed probe keeps the last good reading rather than blanking meters.
    let kept = await cache.recordResult(nil, now: t0.addingTimeInterval(15 * 60))
    try expectEqual(kept, reading, "failed probe keeps the last reading")

    let restarted = MuseCliRefreshCache(defaults: defaults, persistenceKey: key)
    guard case .cached(let persisted) = await restarted.decision(
        now: t0.addingTimeInterval(16 * 60),
        userInitiated: false
    ) else {
        throw AdditionalProviderTestError.failure("persisted CLI cache must survive a restart")
    }
    try expectEqual(persisted, reading, "persisted CLI reading survives restart")
}

// MARK: - Per-file parse caches

private func makeParseCacheRoot(_ name: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("limit-counter-\(name)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

/// Rewrites a file's bytes but gives it back the identity it had, so only a
/// cache that skips unchanged files still reports the old contents.
private func replaceKeepingIdentity(_ url: URL, with text: String, modifiedAt: Date) throws {
    let original = try Data(contentsOf: url)
    let replacement = Data(text.utf8)
    guard replacement.count == original.count else {
        throw AdditionalProviderTestError.failure("fixture edit must keep \(url.lastPathComponent)'s size")
    }
    try replacement.write(to: url)
    try FileManager.default.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: url.path)
}

private func touch(_ url: URL, at modifiedAt: Date) throws {
    try FileManager.default.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: url.path)
}

/// A small deterministic generator, so the splitter property tests are
/// reproducible.
private struct SplitFixtureGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next(below bound: Int) -> Int {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Int((state >> 33) % UInt64(bound))
    }

    mutating func data(from fragments: [[UInt8]], maxFragments: Int) -> Data {
        var bytes: [UInt8] = []
        for _ in 0..<next(below: maxFragments) {
            bytes += fragments[next(below: fragments.count)]
        }
        return Data(bytes)
    }
}

private let validSplitFragments: [[UInt8]] = [
    "a", "{\"k\":1}", " ", "\t", "é", "€", "😀", "e\u{0301}", "\n", "\r", "\r\n", "\u{0B}", "\u{0C}",
    "\u{85}", "\u{2028}", "\u{2029}", "\n\u{0301}", "\u{A0}"
].map { Array($0.utf8) }

private func testMuseLineScanSplitsLikeCharacterNewlines() throws {
    let fragments = validSplitFragments + [[0xC2], [0xE2, 0x80], [0xFF], [0x80], [0xE2], [0xF0, 0x9F]]
    var generator = SplitFixtureGenerator(seed: 0x4D75_7365)
    for _ in 0..<3_000 {
        let data = generator.data(from: fragments, maxFragments: 24)
        var scanned: [String] = []
        MuseLocalUsageReader.forEachLine(in: data) { scanned.append(String(decoding: $0, as: UTF8.self)) }
        let expected = String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map(String.init)
        guard scanned == expected else {
            throw AdditionalProviderTestError.failure(
                "Muse byte scan split \(Array(data)) into \(scanned), Character split gives \(expected)"
            )
        }
    }
}

private func testMuseByteIngestionMatchesStringIngestion() throws {
    let recordedAt = 1_790_000_000_000_000
    let lines = [
        #"{"id":"a1","recorded_at":\#(recordedAt),"stream":{"id":"s"},"sequence":1,"payload_type":"runtime.session","payload":{"run_id":"r1","event":{"kind":"goal_usage_attribution","record":{"usage_id":"u1","usage_family":"provider","quantity":{"reported":true,"input_tokens":1000,"output_tokens":100,"cached_tokens":600}}}}}"#,
        "  \t" + #"{"id":"a2","stream":{"id":"s"},"sequence":2,"payload_type":"runtime.session","payload":{"run_id":"r1","event":{"kind":"goal_usage_attribution","record":{"usage_id":"u2","usage_family":"provider","quantity":{"reported":true,"input_tokens":7,"output_tokens":3}}}}}"# + " ",
        "\u{A0}" + #"{"id":"a3","stream":{"id":"s"},"sequence":3,"payload_type":"runtime.session","payload":{"run_id":"r2","event":{"kind":"goal_usage_attribution","record":{"usage_id":"u3","usage_family":"provider","quantity":{"reported":true,"input_tokens":50,"output_tokens":5}}}}}"# + "\u{3000}",
        #"{"id":"c1","stream":{"id":"s"},"sequence":4,"payload_type":"runtime.session","payload":{"run_id":"r1","event":{"kind":"model_completed","usage":{"cache_read_tokens":500},"duration_ms":10,"model":"muse-spark-1.2"}}}"#,
        #"{"id":"a1","stream":{"id":"s"},"sequence":1}"#,
        "not json",
        "[1,2]"
    ]
    var fromStrings = MuseSessionUsageReducer(museSessionId: "s", logPath: "/tmp/s.jsonl")
    var fromBytes = MuseSessionUsageReducer(museSessionId: "s", logPath: "/tmp/s.jsonl")
    for line in lines {
        fromStrings.ingestLine(line)
        fromBytes.ingestLine(utf8: Data(line.utf8))
    }
    var invalid = Data(lines[1].utf8)
    invalid.append(0xFF)
    fromStrings.ingestLine(String(decoding: invalid, as: UTF8.self))
    fromBytes.ingestLine(utf8: invalid)

    let rate = MuseModelRate.sparkDefault
    let expected = fromStrings.snapshot(rate: rate)
    let actual = fromBytes.snapshot(rate: rate)
    try expectEqual(actual.inputTokens, expected.inputTokens, "byte ingestion input tokens")
    try expectEqual(actual.outputTokens, expected.outputTokens, "byte ingestion output tokens")
    try expectEqual(actual.cacheReadInputTokens, expected.cacheReadInputTokens, "byte ingestion cache reads")
    try expectEqual(Set(actual.usageIds), Set(expected.usageIds), "byte ingestion accepts the same attributions")
    try expectEqual(actual.latestRecordedAt, expected.latestRecordedAt, "byte ingestion recorded-at")
    try expectEqual(actual.estimatedCostUSD, expected.estimatedCostUSD, "byte ingestion cost")
    try expectEqual(expected.usageIds.count, 3, "padded lines are still ingested")
}

private func testMuseSessionCacheReparsesOnlyChangedSessions() throws {
    let now = Date()
    let base = try makeParseCacheRoot("muse-cache")
    defer { try? FileManager.default.removeItem(at: base) }
    let root = base.appendingPathComponent("muse", isDirectory: true)
    let session = root.appendingPathComponent("sessions/one/session.jsonl")
    try FileManager.default.createDirectory(at: session.deletingLastPathComponent(), withIntermediateDirectories: true)
    let recordedAt = Int(now.timeIntervalSince1970 * 1_000_000)
    func attribution(_ id: String, input: Int) -> String {
        #"{"id":"\#(id)","recorded_at":\#(recordedAt),"stream":{"id":"one"},"sequence":1,"payload_type":"runtime.session","payload":{"run_id":"run","event":{"kind":"goal_usage_attribution","record":{"usage_id":"\#(id)","usage_family":"provider","quantity":{"reported":true,"input_tokens":\#(input),"output_tokens":100}}}}}"#
    }
    let fixedDate = Date(timeIntervalSince1970: floor(now.timeIntervalSince1970) - 60)
    try (attribution("u1", input: 1000) + "\n").write(to: session, atomically: true, encoding: .utf8)
    try touch(session, at: fixedDate)

    let cacheDirectory = base.appendingPathComponent("cache", isDirectory: true)
    let cache = TelemetryParseCache(filename: "cache.jsonl", directory: cacheDirectory)
    let first = try MuseLocalUsageReader.read(rootURL: root, now: now, parseCache: cache)
        ?? { throw AdditionalProviderTestError.failure("Muse fixture was not read") }()
    try expectClose(first.inputTokens, 1_000, "Muse first read parses the session")

    try replaceKeepingIdentity(session, with: attribution("u1", input: 2000) + "\n", modifiedAt: fixedDate)
    let cached = try MuseLocalUsageReader.read(rootURL: root, now: now, parseCache: cache)
        ?? { throw AdditionalProviderTestError.failure("Muse cached read failed") }()
    try expectClose(cached.inputTokens, 1_000, "an unchanged Muse session is served from the cache")
    try expectClose(cached.currentMonthCostUSD, first.currentMonthCostUSD, "cached sessions are priced the same")

    try (attribution("u1", input: 2000) + "\n" + attribution("u2", input: 500) + "\n")
        .write(to: session, atomically: true, encoding: .utf8)
    let updated = try MuseLocalUsageReader.read(rootURL: root, now: now, parseCache: cache)
        ?? { throw AdditionalProviderTestError.failure("Muse updated read failed") }()
    try expectClose(updated.inputTokens, 2_500, "a Muse session that changed is re-parsed")

    let reloaded = try MuseLocalUsageReader.read(
        rootURL: root,
        now: now,
        parseCache: TelemetryParseCache(filename: "cache.jsonl", directory: cacheDirectory)
    ) ?? { throw AdditionalProviderTestError.failure("Muse reload failed") }()
    try expectClose(reloaded.inputTokens, 2_500, "the Muse cache persists across launches")
}

private func testMistralSessionCacheReparsesOnlyChangedFiles() throws {
    let root = try makeParseCacheRoot("mistral-cache")
    defer { try? FileManager.default.removeItem(at: root) }
    let session = root.appendingPathComponent("logs/session/example", isDirectory: true)
    try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
    let metaURL = session.appendingPathComponent("meta.json")
    let messagesURL = session.appendingPathComponent("messages.jsonl")
    func meta(model: String) -> String {
        #"{"end_time":"2026-08-01T02:15:18+00:00","config":{"active_model":"\#(model)"},"stats":{"session_prompt_tokens":10,"session_completion_tokens":10}}"#
    }
    // 4 input chars and 8 output chars: 1 and 2 tokens.
    try meta(model: "mistral-medium-3.5").write(to: metaURL, atomically: true, encoding: .utf8)
    try "{\"role\":\"user\",\"content\":\"USER\"}\n{\"role\":\"assistant\",\"content\":\"ASSISTOK\"}\n"
        .write(to: messagesURL, atomically: true, encoding: .utf8)
    let fixedDate = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970) - 60)
    try touch(metaURL, at: fixedDate)
    try touch(messagesURL, at: fixedDate)

    let now = date("2026-08-01T12:00:00Z")
    let cache = TelemetryParseCache(filename: "cache.jsonl", directory: root.appendingPathComponent("cache"))
    func read() throws -> MistralLocalUsageSummary {
        try MistralVibeUsageReader.read(rootURL: root, now: now, parseCache: cache)
            ?? { throw AdditionalProviderTestError.failure("Mistral fixture was not read") }()
    }
    let first = try read()
    try expectClose(first.inputTokens, 1, "Mistral first read counts input chars")
    try expectClose(first.outputTokens, 2, "Mistral first read counts output chars")

    // Same sizes and dates, different contents: both files are served cached.
    try replaceKeepingIdentity(
        messagesURL,
        with: "{\"role\":\"user\",\"content\":\"USERUSER\"}\n{\"role\":\"assistant\",\"content\":\"ASSI\"}\n",
        modifiedAt: fixedDate
    )
    try replaceKeepingIdentity(metaURL, with: meta(model: "devstral-small    "), modifiedAt: fixedDate)
    let cached = try read()
    try expectClose(cached.inputTokens, 1, "unchanged messages are not re-counted")
    try expectClose(cached.currentMonthCostUSD, first.currentMonthCostUSD, "unchanged metadata is not re-read")
    try expectEqual(cached.analyticsBuckets.first?.model, "mistral-medium-3.5", "the cached model is kept")

    try touch(messagesURL, at: fixedDate.addingTimeInterval(1))
    let recounted = try read()
    try expectClose(recounted.inputTokens, 2, "changed messages are re-counted")
    try expectClose(recounted.outputTokens, 1, "changed messages are re-counted")
    try expectEqual(recounted.analyticsBuckets.first?.model, "mistral-medium-3.5", "metadata stays cached on its own")

    try touch(metaURL, at: fixedDate.addingTimeInterval(1))
    let reread = try read()
    try expectEqual(reread.analyticsBuckets.first?.model, "devstral-small", "changed metadata is re-read")
    try expectClose(
        reread.currentMonthCostUSD,
        MistralModelRate.devstralSmall.estimateUSD(inputTokens: 2, outputTokens: 1),
        "the re-read model reprices the session"
    )
}

private func testKimiLineScanSplitsLikeStringSplit() throws {
    var generator = SplitFixtureGenerator(seed: 0x4B69_6D69)
    for _ in 0..<3_000 {
        let data = generator.data(from: validSplitFragments, maxFragments: 24)
        let scanned = KimiLocalTranscriptReader.lines(in: data).map { String(decoding: $0, as: UTF8.self) }
        let expected = String(decoding: data, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
        guard scanned == expected else {
            throw AdditionalProviderTestError.failure(
                "Kimi byte scan split \(Array(data)) into \(scanned), String split gives \(expected)"
            )
        }
    }
}

private func testKimiWireCacheReparsesOnlyChangedFiles() throws {
    let root = try makeParseCacheRoot("kimi-cache")
    defer { try? FileManager.default.removeItem(at: root) }
    let wire = root.appendingPathComponent("sessions/abc/wire.jsonl")
    try FileManager.default.createDirectory(at: wire.deletingLastPathComponent(), withIntermediateDirectories: true)
    let turnAt = floor(Date().timeIntervalSince1970) - 3_600
    func statusUpdate(output: Int, at offset: Double = 0) -> String {
        #"{"timestamp":\#(turnAt + offset),"message":{"type":"StatusUpdate","payload":{"token_usage":{"input_other":100,"output":\#(output),"input_cache_read":0,"input_cache_creation":0}}}}"#
    }
    let fixedDate = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970) - 60)
    try (statusUpdate(output: 200) + "\n").write(to: wire, atomically: true, encoding: .utf8)
    try touch(wire, at: fixedDate)

    let cacheDirectory = root.appendingPathComponent("cache", isDirectory: true)
    let cache = TelemetryParseCache(filename: "cache.jsonl", directory: cacheDirectory)
    func totalTokens(_ cache: TelemetryParseCache) -> Double {
        KimiLocalTranscriptReader.loadEvents(kimiRootURL: root, parseCache: cache)
            .reduce(0) { $0 + ($1.tokens ?? 0) }
    }
    try expectClose(totalTokens(cache), 300, "Kimi first read parses the transcript")

    try replaceKeepingIdentity(wire, with: statusUpdate(output: 900) + "\n", modifiedAt: fixedDate)
    try expectClose(totalTokens(cache), 300, "an unchanged Kimi transcript is served from the cache")

    try (statusUpdate(output: 900) + "\n" + statusUpdate(output: 1, at: 1) + "\n")
        .write(to: wire, atomically: true, encoding: .utf8)
    try expectClose(totalTokens(cache), 1_101, "a Kimi transcript that changed is re-parsed")
    try expectClose(
        totalTokens(TelemetryParseCache(filename: "cache.jsonl", directory: cacheDirectory)),
        1_101,
        "the Kimi cache persists across launches"
    )
}

private func testAGBenchUsageRowsAreReparsedOnlyWhenTheFileChanges() throws {
    let root = try makeParseCacheRoot("agbench-usage")
    defer { try? FileManager.default.removeItem(at: root) }
    let usage = root.appendingPathComponent("usage.json")
    let now = Date()
    let timestampMs = Int((now.timeIntervalSince1970 - 3_600) * 1_000)
    func rows(tokens: Int) -> String {
        #"[{"provider":"Kimi","timestamp":\#(timestampMs),"totalTokens":\#(tokens),"model":"k2"},{"provider":"codex","timestamp":\#(timestampMs),"totalTokens":5},{"timestamp":\#(timestampMs),"totalTokens":9}]"#
    }
    let fixedDate = Date(timeIntervalSince1970: floor(now.timeIntervalSince1970) - 60)
    try rows(tokens: 100).write(to: usage, atomically: true, encoding: .utf8)
    try touch(usage, at: fixedDate)

    func kimiTokens() -> [Double?] {
        AGBenchUsageReader.events(forProviderKey: "kimi", rootURL: root, now: now).map(\.tokens)
    }
    try expectEqual(kimiTokens(), [100], "usage.json rows are filtered by provider")
    let codex = AGBenchUsageReader.events(forProviderKey: "codex", rootURL: root, now: now)
    try expectEqual(codex.map(\.model), ["codex"], "a row without a model falls back to the provider key")

    try replaceKeepingIdentity(usage, with: rows(tokens: 900), modifiedAt: fixedDate)
    try expectEqual(kimiTokens(), [100], "an unchanged usage.json is not re-parsed")

    try rows(tokens: 12345).write(to: usage, atomically: true, encoding: .utf8)
    try expectEqual(kimiTokens(), [12_345], "a rewritten usage.json is re-parsed")
}

// MARK: - Mistral accounts

private final class MistralMockURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private func mistralMockWebClient() -> MistralWebSubscriptionClient {
    MistralWebSubscriptionClient(makeSession: {
        let configuration = MistralWebSubscriptionClient.cookieInertConfiguration()
        configuration.protocolClasses = [MistralMockURLProtocol.self]
        return URLSession(configuration: configuration)
    })
}

private func mistralSubscriptionPage(plan: String, api: (String, String), vibe: (String, String)) -> String {
    """
    <html><body><main>
    <p>CURRENT PLAN</p><h2>\(plan) <span>Active</span></h2>
    <h4>Included API usage</h4>
    <div><span>€\(api.0)</span><span>€\(api.1)</span></div>
    <p>Resets in 6 days</p>
    <h4>Included Vibe Code usage</h4>
    <div><span>€\(vibe.0)</span><span>€\(vibe.1)</span></div>
    <p>Resets in 6 days</p>
    <h3>PAY-AS-YOU-GO &amp; SPENDING LIMIT</h3>
    </main></body></html>
    """
}

private func mistralPageResponse(
    _ request: URLRequest,
    status: Int = 200,
    url: URL? = nil,
    headers: [String: String] = [:],
    body: String
) -> (HTTPURLResponse, Data) {
    var fields = ["Content-Type": "text/html; charset=utf-8"]
    fields.merge(headers) { _, new in new }
    return (
        HTTPURLResponse(url: url ?? request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: fields)!,
        Data(body.utf8)
    )
}

private let mistralSignInPage = """
<html><body><h1>Sign in to your account</h1><form action="/login"><input name="email"/></form></body></html>
"""

private func testMistralWebFetchRecognisesASignedOutSession() async throws {
    defer { MistralMockURLProtocol.handler = nil }
    let client = mistralMockWebClient()
    let now = date("2026-09-25T06:00:00Z")

    MistralMockURLProtocol.handler = { mistralPageResponse($0, body: mistralSignInPage) }
    try expectEqual(await client.fetch(cookieHeader: "ory_session=gone", now: now), .signedOut, "sign-in form")

    MistralMockURLProtocol.handler = {
        mistralPageResponse($0, url: URL(string: "https://v2.auth.mistral.ai/ui/login?flow=1")!, body: "<html><body>Log in</body></html>")
    }
    try expectEqual(await client.fetch(cookieHeader: "ory_session=gone", now: now), .signedOut, "sent to the sign-in service")

    MistralMockURLProtocol.handler = {
        mistralPageResponse($0, url: URL(string: "https://console.mistral.ai/billing")!, body: "<html><body>Billing</body></html>")
    }
    guard case .unreadable = await client.fetch(cookieHeader: "ory_session=live", now: now) else {
        throw AdditionalProviderTestError.failure("a page moved to another host is not a sign-out")
    }

    MistralMockURLProtocol.handler = { mistralPageResponse($0, status: 401, body: "") }
    try expectEqual(await client.fetch(cookieHeader: "ory_session=gone", now: now), .signedOut, "HTTP 401")

    MistralMockURLProtocol.handler = { mistralPageResponse($0, status: 502, body: "Bad gateway") }
    guard case .unreadable = await client.fetch(cookieHeader: "ory_session=live", now: now) else {
        throw AdditionalProviderTestError.failure("a server error is a miss to retry, not a sign-out")
    }

    MistralMockURLProtocol.handler = { mistralPageResponse($0, body: "<html><body><h1>Subscription</h1></body></html>") }
    guard case .unreadable = await client.fetch(cookieHeader: "ory_session=live", now: now) else {
        throw AdditionalProviderTestError.failure("a page without meters is a miss to retry, not a sign-out")
    }
}

private final class RotatedHeaderBox {
    var headers: [String] = []
}

private func testMistralWebFetchHandsRotatedCookiesToItsCaller() async throws {
    defer { MistralMockURLProtocol.handler = nil }
    let client = mistralMockWebClient()
    let now = date("2026-09-25T06:00:00Z")
    let page = mistralSubscriptionPage(plan: "Pro", api: ("3.20", "25.5"), vibe: ("41.00", "255"))
    MistralMockURLProtocol.handler = {
        mistralPageResponse(
            $0,
            headers: ["Set-Cookie": "ory_session=rotated; Domain=.mistral.ai; Path=/; Max-Age=3600; Secure; HttpOnly"],
            body: page
        )
    }

    let saved = RotatedHeaderBox()
    let outcome = await client.fetch(cookieHeader: "ory_session=old; theme=dark", now: now) {
        saved.headers.append($0)
        return true
    }
    try expectClose(outcome.reading?.apiSpent ?? -1, 3.2, "the page still parses")
    try expectEqual(saved.headers, ["ory_session=rotated; theme=dark"], "rotation goes to the caller, which files it under the account")

    let refused = await client.fetch(cookieHeader: "ory_session=old; theme=dark", now: now) { _ in false }
    guard case .unreadable = refused else {
        throw AdditionalProviderTestError.failure("a rotation Keychain refused must not pass for a durable session")
    }
}

private func testMistralStaleTombstoneRules() throws {
    let now = date("2026-09-25T06:00:00Z")
    let reading = MistralWebSubscriptionResult(
        planName: "Pro", apiSpent: 3, apiAllowance: 25.5, vibeSpent: 40, vibeAllowance: 255,
        currency: "EUR", periodEnd: date("2026-10-01T00:00:00Z")
    )
    let fresh = MistralWebReadingCache.Entry(reading: reading, fetchedAt: now.addingTimeInterval(-10 * 60))
    let hoursOld = MistralWebReadingCache.Entry(reading: reading, fetchedAt: now.addingTimeInterval(-3 * 3600))
    let lastMonth = MistralWebReadingCache.Entry(
        reading: MistralWebSubscriptionResult(
            planName: "Pro", apiSpent: 20, apiAllowance: 25.5, vibeSpent: 200, vibeAllowance: 255,
            currency: "EUR", periodEnd: date("2026-09-01T00:00:00Z")
        ),
        fetchedAt: date("2026-08-30T12:00:00Z")
    )

    let noSession = MistralProviderClient.resolveWebReading(outcome: nil, cached: fresh, now: now)
    try expect(noSession.reading == nil && noSession.signals.isEmpty, "no imported session: nothing stands in")

    let live = MistralProviderClient.resolveWebReading(outcome: .reading(reading), cached: hoursOld, now: now)
    try expect(live.reading == reading && live.staleSince == nil && live.signals.isEmpty, "a live reading is used as it is")

    let blip = MistralProviderClient.resolveWebReading(outcome: .unreadable("timed out"), cached: fresh, now: now)
    try expect(blip.reading == reading, "a transient miss keeps the last reading")
    try expectEqual(blip.staleSince, fresh.fetchedAt, "and dates the meters to it")
    try expect(blip.signals.isEmpty && !blip.signedOut, "a recent reading needs no signal")

    let stale = MistralProviderClient.resolveWebReading(outcome: .unreadable("timed out"), cached: hoursOld, now: now)
    try expect(stale.reading == reading, "an old reading still stands in")
    try expectEqual(stale.signals.map(\.severity), [.info], "an hour-old stand-in is flagged")
    try expect(stale.signals.first?.message.contains("timed out") == true, "with the reason")

    let tombstone = MistralProviderClient.resolveWebReading(outcome: .signedOut, cached: fresh, now: now)
    try expect(tombstone.reading == reading && tombstone.signedOut, "a signed-out account keeps its last reading")
    try expectEqual(tombstone.signals.map(\.title), ["Mistral sign-in expired"], "and says why it will not refresh")
    try expectEqual(tombstone.signals.first?.severity, .warning, "as a warning")
    try expect(tombstone.signals.first?.message.contains("These meters are the reading from") == true, "naming the reading's age")
    try expect(tombstone.signals.first?.resetKind == nil, "never read as a reset")

    let expired = MistralProviderClient.resolveWebReading(outcome: .signedOut, cached: lastMonth, now: now)
    try expect(expired.reading == nil && expired.staleSince == nil, "last period's numbers do not stand in for this one")
    try expectEqual(expired.signals.map(\.title), ["Mistral sign-in expired"], "the sign-out is still reported")
    try expect(expired.signals.first?.message.contains("These meters") == false, "without claiming meters it does not show")

    let undated = MistralWebReadingCache.Entry(
        reading: MistralWebSubscriptionResult(
            planName: nil, apiSpent: 1, apiAllowance: nil, vibeSpent: nil, vibeAllowance: nil,
            currency: "EUR", periodEnd: nil
        ),
        fetchedAt: date("2026-09-02T00:00:00Z")
    )
    try expect(MistralProviderClient.isCurrent(undated, now: now), "an undated reading holds for its month")
    try expect(!MistralProviderClient.isCurrent(undated, now: date("2026-10-01T00:00:01Z")), "and not past it")
}

private func testMistralSecondaryAccountReadsOnlyItsOwnSession() async throws {
    defer { MistralMockURLProtocol.handler = nil }
    let suiteName = "limit-counter-mistral-accounts-tests-\(UUID().uuidString)"
    let defaults = try UserDefaults(suiteName: suiteName)
        ?? { throw AdditionalProviderTestError.failure("Could not create isolated defaults") }()
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let secondary = ProviderAccountKey(providerID: .mistral, slot: "tw1234")
    let client = MistralProviderClient(webClient: mistralMockWebClient(), readingDefaults: defaults)
    let credential = ProviderCredential(extraFields: ["mistralCookieHeader": "ory_session=second"])
    let pro = mistralSubscriptionPage(plan: "Pro", api: ("3.20", "25.5"), vibe: ("41.00", "255"))
    let free = mistralSubscriptionPage(plan: "Free", api: ("2.10", "8.5"), vibe: ("8.50", "8.5"))
    MistralMockURLProtocol.handler = { request in
        let cookie = request.value(forHTTPHeaderField: "Cookie") ?? ""
        return mistralPageResponse(request, body: cookie.contains("ory_session=second") ? free : pro)
    }

    let snapshot = try await client.fetchSnapshot(credentials: credential, account: secondary, userInitiated: false)
    try expectEqual(snapshot.planName, "Free", "the second account's own plan")
    try expectClose(snapshot.windows.first { $0.label == "API usage" }?.used ?? -1, 2.1, "its own API meter")
    try expectClose(snapshot.windows.first { $0.label == "Vibe Code usage" }?.total ?? -1, 8.5, "its own Vibe allowance")
    try expect(!snapshot.stats.contains { $0.label == "Local 30D cost" }, "~/.vibe is the primary account's, not this one's")
    try expect(MistralWebReadingCache.load(for: secondary, defaults: defaults) != nil, "the reading is kept for this account")
    try expect(MistralWebReadingCache.load(for: .primary(.mistral), defaults: defaults) == nil, "and not for the primary")

    MistralMockURLProtocol.handler = { mistralPageResponse($0, body: mistralSignInPage) }
    let tombstone = try await client.fetchSnapshot(credentials: credential, account: secondary, userInitiated: false)
    try expectClose(tombstone.windows.first { $0.label == "API usage" }?.used ?? -1, 2.1, "signed out: the last reading stands in")
    try expect(tombstone.windows.allSatisfy { $0.subtitle?.hasPrefix("Last reading") == true }, "each meter says it is a past reading")
    try expectEqual(tombstone.fetchedAt, snapshot.fetchedAt, "the card is dated to that reading")
    try expectEqual(tombstone.signals.map(\.title), ["Mistral sign-in expired"], "and asks for a fresh import")

    MistralWebReadingCache.clear(for: secondary, defaults: defaults)
    do {
        _ = try await client.fetchSnapshot(credentials: credential, account: secondary, userInitiated: false)
        throw AdditionalProviderTestError.failure("a signed-out account with nothing to show must report the sign-out")
    } catch ProviderFetchError.credentialExpired {
        // The coordinator keeps the previous snapshot and files the message under the account.
    }
}

private func testMistralAnchorWatermarkIsKeptPerAccount() throws {
    let suiteName = "limit-counter-mistral-watermark-accounts-\(UUID().uuidString)"
    let defaults = try UserDefaults(suiteName: suiteName)
        ?? { throw AdditionalProviderTestError.failure("Could not create isolated defaults") }()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let secondary = ProviderAccountKey(providerID: .mistral, slot: "tw1234")
    let july = date("2026-07-10T12:00:00Z")

    _ = MistralAnchorWatermarkStore.adjustedSpend(
        anchoredSpend: 10, currentLocalSpendUSD: 5, currency: "USD",
        signature: "primary-anchor", now: july, defaults: defaults
    )
    _ = MistralAnchorWatermarkStore.adjustedSpend(
        anchoredSpend: 1, currentLocalSpendUSD: 50, currency: "USD",
        signature: "secondary-anchor", now: july, account: secondary, defaults: defaults
    )
    try expectEqual(defaults.string(forKey: "mistral.manualAnchor.signature"), "primary-anchor", "the primary keeps its original keys")
    try expectEqual(defaults.string(forKey: "mistral.manualAnchor.signature#tw1234"), "secondary-anchor", "a second account gets its own")

    let primaryLater = MistralAnchorWatermarkStore.adjustedSpend(
        anchoredSpend: 10, currentLocalSpendUSD: 7, currency: "USD",
        signature: "primary-anchor", now: july, defaults: defaults
    )
    try expectClose(primaryLater, 12, "the primary advances by its own local spend only")

    MistralAnchorWatermarkStore.clear(for: secondary, defaults: defaults)
    try expect(defaults.string(forKey: "mistral.manualAnchor.signature#tw1234") == nil, "a removed account's watermark goes")
    try expectEqual(defaults.string(forKey: "mistral.manualAnchor.signature"), "primary-anchor", "and only that account's")
}

private func testMistralAccountsSignInToSeparateWebStores() throws {
    try expect(ProviderWebSessionStore.identifier(for: .primary(.mistral)) == nil, "the primary keeps WebKit's default store")
    let first = ProviderAccountKey(providerID: .mistral, slot: "tw1234")
    let second = ProviderAccountKey(providerID: .mistral, slot: "zz9999")
    let identifier = try ProviderWebSessionStore.identifier(for: first)
        ?? { throw AdditionalProviderTestError.failure("a second Mistral account needs a store of its own") }()
    try expectEqual(ProviderWebSessionStore.identifier(for: first), identifier, "derived, so the same store every launch")
    try expectEqual(identifier.uuidString, "54199951-0BB7-5E22-8B61-FEF48D13F967", "the derivation never changes under a signed-in store")
    try expect(ProviderWebSessionStore.identifier(for: second) != identifier, "each account signs in on its own")
    try expect(
        ProviderWebSessionStore.identifier(for: ProviderAccountKey(providerID: .cerebras, slot: "tw1234")) == nil,
        "providers whose background readers use the default store keep it"
    )
}

@main
private enum AdditionalProviderUsageTestRunner {
    static func main() async throws {
        try await testBrowserRefreshTracksNewReadingsAndCooldowns()
        try await testBrowserRefreshSharesOverlappingRequests()
        try testBrowserSessionKeepsRotatedCookiesAndOrigin()
        try testCodexSessionCredentialParserSupportsNestedAndDirectAuth()
        try testCodexSessionCredentialReaderFollowsDirectoryRotation()
        try testCodexDirectoryImportStoresPersistentSource()
        try testAntigravityParsesOfficialGeminiAndClaudeGPTBuckets()
        try testAntigravityParsesSeparatedClaudeAndGPTBuckets()
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
        try testMistralWebParserReadsSubscriptionPage()
        try testMistralWebParserSurvivesReactCommentAndTagSplitting()
        try testMistralWebParserToleratesPayAsYouGoTooltipBeforeVibeAmounts()
        try testMistralWebParserHandlesLandmarksAppearingBeforeSections()
        try testMistralWebParserReadsFlightPayloadOnlyPage()
        try testMistralWebParserRejectsSignedOutPage()
        try testMistralWebParserReturnsPartialResultWhenVibeMissing()
        try testMistralAssemblyKeepsVibeAnchorWhenWebParseIsPartial()
        try testMistralAssemblyPrefersFullWebResultOverAnchor()
        try testMistralAssemblyKeepsAdminCombinedTotalWithoutWeb()
        try testMistralAssemblyFallsBackToLocalEstimateWithoutAnchor()
        try await testMistralWebFetchRecognisesASignedOutSession()
        try await testMistralWebFetchHandsRotatedCookiesToItsCaller()
        try testMistralStaleTombstoneRules()
        try await testMistralSecondaryAccountReadsOnlyItsOwnSession()
        try testMistralAnchorWatermarkIsKeptPerAccount()
        try testMistralAccountsSignInToSeparateWebStores()
        try testDeepSeekBalanceAndObservedSpendSemantics()
        try testTaskWraithPricingIsProviderScopedAndEstimated()
        try testMuseCostEstimatorMatchesSparkSessionTotals()
        try testMuseSessionUsageReducerCountsProviderAttributionOnce()
        try testMuseAnalyticsSeparatesCachedInput()
        try testMetaCreditUsedAndDefaultMonthlyReset()
        try testMetaWebBillingRefreshCadenceProtectsBrowserSession()
        try testMetaRemainingWatermarkAdvancesAndResetsOnMonth()
        try testMetaRemainingWatermarkConvertsGBP()
        try testMetaSpendWatermarkAccumulatesLikeMistral()
        try testMetaSpendWatermarkWithZeroAnchorAccumulatesLocal()
        try testTaskWraithMusePricingUsesMuseCostEstimator()
        try testCerebrasCSVHandlesQuotedNumbersAndCurrency()
        try testCurrencyFormatting()
        try testOpenRouterParsesValidKeyResponse()
        try testOpenRouterParsesUnlimitedKey()
        try testOpenRouterParsesFreeTier()
        try testOpenRouterParsesRateLimit()
        try testOpenRouterMetersLoadedCreditAgainstKeySpend()
        try testOpenRouterPrefersAccountCredits()
        try testOpenRouterRefusedManagementKeyFallsBack()
        try testOpenRouterKeyLimitFollowsItsResetPeriod()
        try testOpenRouterSpendOnlyWithoutCredit()
        try await testOpenRouterSendsManagementKeyOnlyToCredits()
        try await testOpenRouterManagementAPIKeyReadsItsOwnCredits()
        try testImportedCookieHeaderMergePreservesAndRotates()
        try testTokenPlanParserReadsRenderedZeroUsage()
        try testTokenPlanConsoleAPIReadsFullQuota()
        try testTokenPlanConsoleAPIReadsFractionalQuota()
        try testTokenPlanConsoleAPIDetectsExpiredSession()
        try testTokenPlanConsoleAPIReportsNothingForUnknownShape()
        try testTokenPlanParserReadsQwenResetRowLayout()
        try testTokenPlanParserReadsPartialQwenUsage()
        try testTokenPlanParserReadsZeroQwenUsage()
        try testTokenPlanParserReadsQwenResetAvailability()
        try testTokenPlanConsoleAPIScansResetAvailability()
        try testTokenPlanParserReportsNoQuotaBeforeTheValueRenders()
        try testTokenPlanParserReadsQwenMonthlyMeter()
        try testTokenPlanParserKeepsQwenWeeklyMeterPeriod()
        try testTokenPlanParserDoesNotReadPeriodFromUnrelatedText()
        try testTokenPlanConsoleAPIReadsMonthlyQuota()
        try testTokenPlanConsoleAPIPrefersWeeklyOnlyWhenItReportsOne()
        try testTokenPlanConsoleAPIReadsResetCardList()
        try testBrowserMeterFailureKeepsCredentialKind()
        try testQuotaSignalMessagesCarryNoAccountIdentifier()
        try testTokenPlanFailureChoicePrefersCredentialErrors()
        try await testBrowserRefreshStoreRecordsCredentialFailureKind()
        try await testTokenPlanCachedAndManualZeroUsageProduceMeters()
        try await testQwenMonthlyMeterLandsInMonthlyPeriod()
        try await testQwenWeeklyAccountKeepsWeeklyMeter()
        try await testCerebrasCachedWebBalanceSurvivesLiveMiss()
        try testCerebrasWebBillingParserReadsCurrentBalance()
        try await testMetaCreditMeterCarriesBillingReset()
        try testMuseSubscriptionParserReadsUsagePage()
        try testMuseSubscriptionParserAcceptsValueBeforeLabel()
        try testMuseSubscriptionParserRejectsSignedOutAndPAYGOnlyPages()
        try testMuseSubscriptionResetDateParsesVariantsAndRollsYear()
        try testMuseSubscriptionParserReadsCurrentWindowClockReset()
        try testMuseSubscriptionWeeklyFallbackIgnoresBareClockTime()
        try testMuseCachedSubscriptionReadingRestoresCurrentReset()
        try testMuseSubscriptionMetersCarryImportedCurrentReset()
        try testMuseSubscriptionMetersPreferLiveAndFallBackToCached()
        try testMuseCliParserReadsCompactedUsageScreen()
        try testMuseCliParserHandlesSpacedRedrawAndAnsi()
        try testMuseCliParserRollsWeeklyResetAcrossYearEnd()
        try testMuseCliParserReadsNewestFrameFromAccumulatedRedraws()
        try testMuseCliParserRejectsIncompleteScreens()
        try testMuseSubscriptionMetersPreferCliOverWeb()
        try await testMetaSnapshotPrefersCliReadingOverCachedImport()
        try testMuseCliBinaryLocatorResolvesGrantedFolders()
        try testMuseCliCadenceIsFrequentButCached()
        try await testMuseCliRefreshCacheKeepsLastReadingAcrossRestart()
        try await testMuseSubscriptionRefreshCacheServesHourlyAndSurvivesRestart()
        try await testMetaSnapshotLeadsWithCachedSubscriptionMeters()
        try testMuseLineScanSplitsLikeCharacterNewlines()
        try testMuseByteIngestionMatchesStringIngestion()
        try testMuseSessionCacheReparsesOnlyChangedSessions()
        try testMistralSessionCacheReparsesOnlyChangedFiles()
        try testKimiLineScanSplitsLikeStringSplit()
        try testKimiWireCacheReparsesOnlyChangedFiles()
        try testAGBenchUsageRowsAreReparsedOnlyWhenTheFileChanges()
        print("Additional provider usage tests passed")
    }
}

@MainActor
private func testBrowserRefreshTracksNewReadingsAndCooldowns() async throws {
    let suite = "browser-meter-tests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let cache = BrowserMeterRefreshStore(defaults: defaults)
    let url = URL(string: "https://cloud.cerebras.ai/platform/test/billing")!
    let start = date("2026-09-05T12:00:00Z")
    let imported = WebBillingReading(balance: 12, spend: nil, currency: "USD", periodEnd: nil)
    var requests = 0
    func read(_ store: BrowserMeterRefreshStore, at now: Date, fail: Bool = false, session: String = "session-a") async -> BrowserMeterResult<WebBillingReading> {
        await store.read(
            url: url, sessionID: session, initial: imported, initialAt: start,
            interval: 300, failureInterval: 900, now: now
        ) {
            requests += 1
            if fail { throw ProviderFetchError.rateLimited }
            return WebBillingReading(balance: 10, spend: nil, currency: "USD", periodEnd: nil)
        }
    }
    let first = await read(cache, at: start.addingTimeInterval(60))
    try expectEqual(requests, 0, "a recent browser import does not immediately navigate again")
    try expectClose(first.value?.balance ?? -1, 12, "first imported balance")
    let live = await read(cache, at: start.addingTimeInterval(300))
    try expectEqual(requests, 1, "one new browser read when due")
    try expectClose(live.value?.balance ?? -1, 10, "updated balance replaces original import")
    let reread = await read(cache, at: start.addingTimeInterval(360))
    try expectClose(reread.value?.balance ?? -1, 10, "old import cannot overwrite a newer reading")
    try expectEqual(reread.fetchedAt, live.fetchedAt, "cache hits must not slide observation time")
    let failure = await read(cache, at: start.addingTimeInterval(600), fail: true)
    try expect(failure.failure != nil, "failed refresh exposes its failure")
    try expectClose(failure.value?.balance ?? -1, 10, "failure retains last successful reading")
    let restarted = BrowserMeterRefreshStore(defaults: defaults)
    let persisted = await read(restarted, at: start.addingTimeInterval(1000))
    try expectEqual(requests, 2, "cooldown survives restart")
    try expectClose(persisted.value?.balance ?? -1, 10, "latest success survives restart")
    _ = await read(restarted, at: start.addingTimeInterval(1500))
    try expectEqual(requests, 3, "failure cooldown eventually permits recovery")
    let switched = await read(restarted, at: start.addingTimeInterval(1501), fail: true, session: "session-b")
    try expectClose(switched.value?.balance ?? -1, 12, "another session never gets the prior account's cached balance")
    let stored = String(data: defaults.data(forKey: BrowserSessionRefreshPolicy.cacheKey(url: url, sessionID: "session-a"))!, encoding: .utf8)!
    try expect(!stored.contains("session-a"), "cache does not store session material")
}

@MainActor
private func testBrowserRefreshSharesOverlappingRequests() async throws {
    let suite = "browser-overlap-tests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let cache = BrowserMeterRefreshStore(defaults: defaults)
    let url = URL(string: "https://dev.meta.ai/usage/")!
    var calls = 0
    func read() async -> BrowserMeterResult<WebBillingReading> {
        await cache.read(
            url: url, sessionID: "test-cookie", initial: Optional<WebBillingReading>.none,
            initialAt: nil, interval: 3600, failureInterval: 21600
        ) {
            calls += 1
            try await Task.sleep(for: .milliseconds(30))
            return WebBillingReading(balance: 1, spend: nil, currency: "GBP", periodEnd: nil)
        }
    }
    let one = Task { @MainActor in await read() }
    let two = Task { @MainActor in await read() }
    let a = await one.value
    let b = await two.value
    try expectEqual(calls, 1, "concurrent refreshes share one navigation")
    try expectEqual(a.fetchedAt, b.fetchedAt, "shared reading keeps one timestamp")
}

/// The store persists failures as text, so the kind has to travel with it. A
/// rejected Qwen session used to reach the card as "Parse error: Qwen console
/// session expired", which tells the user to wait for a page layout that is
/// perfectly fine instead of reconnecting.
private func testBrowserMeterFailureKeepsCredentialKind() throws {
    let expired = BrowserMeterResult<TokenPlanWebReading>(
        value: nil,
        fetchedAt: nil,
        failure: "Qwen console session expired. Reconnect the browser session.",
        failureIsCredential: true
    )
    guard case .credentialExpired = expired.failureError else {
        throw AdditionalProviderTestError.failure("a rejected session must stay a credential error, got \(String(describing: expired.failureError))")
    }

    let unparsed = BrowserMeterResult<TokenPlanWebReading>(
        value: nil,
        fetchedAt: nil,
        failure: "No token-plan meters found.",
        failureIsCredential: false
    )
    guard case .parsingError = unparsed.failureError else {
        throw AdditionalProviderTestError.failure("a page that did not parse must stay a parse error")
    }
    try expectEqual(
        unparsed.failureError?.localizedDescription,
        "Parse error: No token-plan meters found.",
        "the prefix is applied once"
    )

    // `failure` holds a localized description, so a parse error stored by an
    // older build already carries the prefix.
    let alreadyPrefixed = BrowserMeterResult<TokenPlanWebReading>(
        value: nil,
        fetchedAt: nil,
        failure: "Parse error: No token-plan meters found.",
        failureIsCredential: false
    )
    try expectEqual(
        alreadyPrefixed.failureError?.localizedDescription,
        "Parse error: No token-plan meters found.",
        "a stored description that already carries the prefix is not wrapped twice"
    )

    let fine = BrowserMeterResult<TokenPlanWebReading>(
        value: nil,
        fetchedAt: nil,
        failure: nil,
        failureIsCredential: false
    )
    try expect(fine.failureError == nil, "no failure, no error")

    // The classification has to come from the error itself, not from a phrase
    // in its message.
    try expect(ProviderFetchError.credentialExpired("anything").isCredentialFailure, "credentialExpired is a credential failure")
    try expect(ProviderFetchError.invalidCredential.isCredentialFailure, "invalidCredential is a credential failure")
    try expect(!ProviderFetchError.parsingError("anything").isCredentialFailure, "a parse error is not")
    try expect(!ProviderFetchError.rateLimited.isCredentialFailure, "a rate limit is not")
    try expect(!ProviderFetchError.notConfigured.isCredentialFailure, "an unconfigured provider is not")
}

/// Regression guard for the two signals that used to interpolate an account
/// email into `QuotaSignal.message`.
///
/// That message is not local. It rides inside `QuotaSnapshot.signals` into the
/// App Group cache the widget reads and into the CloudKit payload, so both
/// addresses were leaving the machine while the README promised that only
/// normalized snapshots were written to the shared cache. They were the only
/// personal identifiers that did.
///
/// This is deliberately a blunt scan of the two known sites and not a claim that
/// free text is sanitized anywhere — there is no sanitizer, and adding one would
/// be the wrong fix. It exists so that putting an address back in either place
/// fails a test instead of failing a privacy review.
private func testQuotaSignalMessagesCarryNoAccountIdentifier() throws {
    let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let sources = [
        "App/Providers/GeminiProviderClient.swift",
        "App/Providers/ProviderClient.swift"
    ]
    let forbidden = ["\\(email)", "\\(cachedEmail)", "\\(activeEmail)", "\\(userEmail)", "\\(accountEmail)"]

    for relative in sources {
        let text = try String(
            contentsOf: repoRoot.appendingPathComponent(relative),
            encoding: .utf8
        )
        for (index, line) in text.split(separator: "\n").enumerated() {
            guard line.contains("message:") else { continue }
            for interpolation in forbidden {
                try expect(
                    !line.contains(interpolation),
                    "\(relative):\(index + 1) interpolates an account identifier into a signal message, which is cached in the App Group and uploaded to CloudKit"
                )
            }
        }
    }
}

private func testBrowserSessionKeepsRotatedCookiesAndOrigin() throws {
    let qwenHost = "modelstudio.console.alibabacloud.com"
    try expect(
        BrowserSessionRefreshPolicy.allowsNavigation(to: URL(string: "https://account.alibabacloud.com/login/login_aliyun.htm")!, dashboardHost: qwenHost),
        "Qwen can renew the console ticket through its first-party account service"
    )
    for blockedHost in ["accounts.google.com", "alibabacloud.com.evil.example"] {
        try expect(
            !BrowserSessionRefreshPolicy.allowsNavigation(to: URL(string: "https://\(blockedHost)/login")!, dashboardHost: qwenHost),
            "external sign-in requires the visible importer"
        )
    }
    let cookie = HTTPCookie(properties: [
        .domain: ".xiaomimimo.com", .path: "/", .name: "session", .value: "rotated"
    ])!
    try expect(
        !BrowserSessionRefreshPolicy.shouldSeedCookies(existing: [cookie], host: "platform.xiaomimimo.com"),
        "existing WebKit session wins over the stale imported cookie"
    )
    try expect(
        BrowserSessionRefreshPolicy.shouldSeedCookies(existing: [cookie], host: "cloud.cerebras.ai"),
        "cookies from another provider do not prevent bootstrapping"
    )
    let fallback = URL(string: "https://cloud.cerebras.ai/platform/default/billing")!
    try expectEqual(
        BrowserSessionRefreshPolicy.validatedURL("https://cloud.cerebras.ai/platform/new/billing", fallback: fallback).path,
        "/platform/new/billing", "selected billing account URL is retained"
    )
    for badURL in ["https://cloud.cerebras.ai.evil.example/billing", "http://cloud.cerebras.ai/billing", "https://example.com", "https://user:secret@cloud.cerebras.ai/billing"] {
        try expectEqual(BrowserSessionRefreshPolicy.validatedURL(badURL, fallback: fallback), fallback, "reject foreign or unsafe session URL")
    }
}
