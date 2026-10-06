import Foundation

private enum PeriodGroupingTestError: Error, CustomStringConvertible {
    case failure(String)

    var description: String {
        switch self {
        case .failure(let message): return message
        }
    }
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw PeriodGroupingTestError.failure(message) }
}

private func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) throws {
    if actual != expected {
        throw PeriodGroupingTestError.failure("\(message): expected \(expected), got \(actual)")
    }
}

private func window(
    _ label: String,
    _ kind: QuotaWindowKind,
    used: Double = 10,
    total: Double? = 100
) -> QuotaWindow {
    QuotaWindow(
        label: label,
        windowKind: kind,
        used: used,
        total: total,
        resetDate: Date().addingTimeInterval(3600),
        unit: "%"
    )
}

private func snapshot(
    _ providerID: ProviderID,
    _ displayName: String,
    _ windows: [QuotaWindow]
) -> QuotaSnapshot {
    QuotaSnapshot(
        providerID: providerID,
        displayName: displayName,
        windows: windows,
        fetchState: .success
    )
}

// MARK: - Classification

/// Every window shape the shipping providers actually emit, taken from a
/// live snapshot cache. The label wins over the window kind because
/// providers disagree wildly on both: Claude's five-hour meter is
/// labelled "Session" with kind `.session`, Kimi's is labelled "5H" with
/// kind `.sliding`, and Qwen names its meter after the plan's period —
/// "7-Day Quota" on a rolling weekly plan, "Monthly Usage" on the monthly
/// Standard plan that replaced it.
private func testRealWorldWindowsLandInTheRightPeriod() throws {
    let cases: [(ProviderID, QuotaWindow, QuotaPeriodGroup)] = [
        (.claude, window("Session", .session), .fiveHour),
        (.claude, window("Weekly", .weekly), .weekly),
        (.claude, window("🪐 Fable", .weekly), .weekly),
        (.openai, window("Weekly", .weekly), .weekly),
        (.openai, window("5H", .session), .fiveHour),
        (.openai, window("⚡ Spark 5H", .session), .fiveHour),
        (.openai, window("⚡ Spark Weekly", .weekly), .weekly),
        (.kimi, window("5H", .sliding), .fiveHour),
        (.kimi, window("Weekly", .weekly), .weekly),
        (.kimi, window("Monthly", .monthly), .monthlyAndAPI),
        (.antigravity, window("Gemini 5H", .session), .fiveHour),
        (.antigravity, window("Gemini Weekly", .weekly), .weekly),
        (.antigravity, window("Claude/GPT 5H", .session), .fiveHour),
        (.antigravity, window("Claude/GPT Weekly", .weekly), .weekly),
        (.mistral, window("API usage", .monthly), .monthlyAndAPI),
        (.mistral, window("Vibe Code usage", .monthly), .monthlyAndAPI),
        (.cursor, window("Included in Pro", .monthly), .monthlyAndAPI),
        (.cursor, window("Auto + Composer", .monthly), .monthlyAndAPI),
        (.cursor, window("API", .monthly), .monthlyAndAPI),
        (.grok, window("Weekly", .weekly), .weekly),
        (.ollama, window("Session usage", .session), .fiveHour),
        (.ollama, window("Weekly usage", .weekly), .weekly),
        (.devin, window("Daily quota", .session), .daily),
        (.devin, window("Weekly quota (account 2)", .weekly), .weekly),
        (.mimo, window("Plan Quota", .monthly), .monthlyAndAPI),
        (.qwen, window("7-Day Quota", .weekly), .weekly),
        (.qwen, window("Monthly Usage", .monthly), .monthlyAndAPI),
        (.meta, window("Current usage", .session), .fiveHour),
        (.meta, window("Weekly limit", .weekly), .weekly),
        (.deepseek, window("Credit used", .custom, used: 13.23, total: 20), .monthlyAndAPI),
        (.cerebras, window("Credit used", .custom, used: 1.29, total: 11.56), .monthlyAndAPI),
        (.chatgpt, window("24H Active Chats", .daily, total: nil), .daily),
        (.chatgpt, window("7D Active Chats", .weekly, total: nil), .weekly),
        (.chatgpt, window("30D Active Chats", .monthly, total: nil), .monthlyAndAPI)
    ]

    for (providerID, quotaWindow, expected) in cases {
        try expectEqual(
            quotaWindow.periodGroup(for: providerID),
            expected,
            "\(providerID.rawValue) \"\(quotaWindow.label)\" (\(quotaWindow.windowKind.rawValue))"
        )
    }
}

/// Gemini CLI is the one provider that models daily request caps as
/// `.custom` windows; every other `.custom` window is a rolling credit
/// balance that belongs with the API meters.
private func testGeminiCustomWindowsAreDailyAndOtherCustomWindowsAreAPI() throws {
    try expectEqual(window("Pro", .custom).periodGroup(for: .gemini), .daily, "Gemini custom window")
    try expectEqual(window("Pro", .custom).periodGroup(for: .deepseek), .monthlyAndAPI, "spend custom window")
    try expectEqual(window("Pro", .custom).periodGroup(), .monthlyAndAPI, "custom window with no provider")
}

// MARK: - Row labels

private func testRowLabelsPrefixTheProviderAndCollapseOverlap() throws {
    let claude = snapshot(.claude, "Claude Code", [window("Session", .session)])
    try expectEqual(
        claude.periodRowLabel(for: claude.windows[0]),
        "Claude Code Session",
        "plain prefix"
    )

    let mimo = snapshot(.mimo, "MiMo Token Plan", [window("Plan Quota", .monthly)])
    try expectEqual(
        mimo.periodRowLabel(for: mimo.windows[0]),
        "MiMo Token Plan Quota",
        "trailing provider word overlapping the leading label word collapses"
    )

    let meta = snapshot(.meta, "Meta API", [window("API", .monthly)])
    try expectEqual(
        meta.periodRowLabel(for: meta.windows[0]),
        "Meta API",
        "a label fully contained in the provider name is not repeated"
    )

    let cursor = snapshot(.cursor, "Cursor", [window("API", .monthly)])
    try expectEqual(
        cursor.periodRowLabel(for: cursor.windows[0]),
        "Cursor API",
        "no overlap leaves both parts"
    )

    let codex = snapshot(.openai, "Codex", [window("⚡ Spark 5H", .session)])
    try expectEqual(
        codex.periodRowLabel(for: codex.windows[0]),
        "Codex ⚡ Spark 5H",
        "emoji labels survive intact"
    )
}

// MARK: - Sections

/// Sections come out in period order, and inside a period the rows keep
/// the provider order the caller handed in (the dashboard's drag order)
/// and then the provider's own window order.
private func testSectionsGroupByPeriodAndPreserveProviderOrder() throws {
    let snapshots = [
        snapshot(.openai, "Codex", [
            window("Weekly", .weekly),
            window("⚡ Spark 5H", .session),
            window("⚡ Spark Weekly", .weekly)
        ]),
        snapshot(.claude, "Claude Code", [
            window("Session", .session),
            window("Weekly", .weekly)
        ]),
        snapshot(.devin, "Devin", [window("Daily quota", .daily)]),
        snapshot(.cursor, "Cursor", [window("Included in Pro", .monthly)]),
        snapshot(.openrouter, "OpenRouter", [])
    ]

    let sections = QuotaPeriodSection.sections(from: snapshots)

    try expectEqual(
        sections.map(\.group),
        [.fiveHour, .daily, .weekly, .monthlyAndAPI],
        "section order"
    )
    try expectEqual(
        sections[0].rows.map(\.label),
        ["Codex ⚡ Spark 5H", "Claude Code Session"],
        "5H rows follow the provider order they were handed in"
    )
    try expectEqual(
        sections[2].rows.map(\.label),
        ["Codex Weekly", "Codex ⚡ Spark Weekly", "Claude Code Weekly"],
        "weekly rows keep each provider's own window order"
    )
    try expectEqual(
        sections[3].rows.map(\.label),
        ["Cursor Included in Pro", "OpenRouter"],
        "a provider with no meters lands at the bottom of the last section"
    )
    try expect(
        sections[3].rows.last?.window == nil,
        "the idle provider's row carries no window"
    )
}

/// A period with nothing in it must not render an empty header — most
/// setups have no daily meters at all.
private func testEmptyPeriodsAreDropped() throws {
    let sections = QuotaPeriodSection.sections(from: [
        snapshot(.grok, "Grok", [window("Weekly", .weekly)])
    ])

    try expectEqual(sections.map(\.group), [.weekly], "only the populated period survives")
}

/// With no meters anywhere, the idle providers still need a home.
private func testIdleOnlyDashboardFallsBackToTheAPISection() throws {
    let sections = QuotaPeriodSection.sections(from: [snapshot(.openrouter, "OpenRouter", [])])

    try expectEqual(sections.map(\.group), [.monthlyAndAPI], "fallback section")
    try expectEqual(sections[0].rows.map(\.label), ["OpenRouter"], "fallback row")
}

private func testEmptyDashboardProducesNoSections() throws {
    try expect(QuotaPeriodSection.sections(from: []).isEmpty, "no snapshots means no sections")
}

/// A row's identity has to survive a refresh. `QuotaWindow.id` is a fresh UUID
/// on every fetch, so keying a `ForEach` on it rebuilds every row whenever a
/// provider is re-read — invisible until something is being dragged, at which
/// point the gesture is torn down mid-flight. It would also stop a dragged rank
/// from being recognised on the next pass.
private func testRowIdentitySurvivesARefresh() throws {
    func rows() -> [QuotaPeriodRow] {
        QuotaPeriodSection.sections(from: [
            snapshot(.qwen, "Qwen Token Plan", [window("Monthly Usage", .monthly)]),
            snapshot(.claude, "Claude", [window("5H", .session), window("Weekly", .weekly)]),
            snapshot(.openrouter, "OpenRouter", [])
        ]).flatMap(\.rows)
    }

    let first = rows()
    try expectEqual(rows().map(\.id), first.map(\.id), "the same meters keep the same row ids across a refresh")
    try expectEqual(Set(first.map(\.id)).count, first.count, "row ids are unique within one pass")

    let idle = try first.first(where: { $0.window == nil })
        ?? { throw PeriodGroupingTestError.failure("missing idle row") }()
    try expectEqual(idle.id, "idle|openrouter", "an idle provider keeps a stable row id of its own")

    // A meter that starts reporting a different period is a different meter and
    // must not inherit the old row's identity, or it would inherit its rank too.
    let qwenBefore = try first.first(where: { $0.providerID == .qwen })
        ?? { throw PeriodGroupingTestError.failure("missing qwen row") }()
    let qwenAfter = QuotaPeriodSection.sections(from: [
        snapshot(.qwen, "Qwen Token Plan", [window("7-Day Quota", .weekly)])
    ]).flatMap(\.rows)
    try expect(
        !qwenAfter.map(\.id).contains(qwenBefore.id),
        "a meter that changes what it reports gets a new identity"
    )
}

// MARK: - Usage credits

private func creditsSnapshot(
    _ providerID: ProviderID,
    balances: [QuotaBalance] = [],
    windows: [QuotaWindow] = [],
    stats: [QuotaStat] = [],
    fetchState: ProviderFetchState = .success
) -> QuotaSnapshot {
    QuotaSnapshot(
        providerID: providerID,
        displayName: providerID.displayName,
        windows: windows,
        stats: stats,
        balances: balances,
        fetchState: fetchState
    )
}

private func requireCredits(_ snapshot: QuotaSnapshot) throws -> QuotaUsageCredits {
    guard let credits = snapshot.usageCredits else {
        throw PeriodGroupingTestError.failure("missing usage credits for \(snapshot.accountKey.rawValue)")
    }
    return credits
}

private func testRemainingCreditsKeepTheirAmountAndUnitIncludingZero() throws {
    let cases: [(ProviderID, String, Double, String)] = [
        (.openai, "Credits Remaining", 14_000, "credits"),
        (.grok, "Usage Credits", 23.75, "USD"),
        (.minimax, "Credits Remaining", 0, "credits"),
        (.minimax, "Usage Credits", 0.03, ""),
        (.claude, "Usage Credits", 12.5, "USD"),
        (.openrouter, "Credit remaining", 6.99, "USD"),
        (.cerebras, "Current balance", 0, "USD"),
        (.meta, "Remaining balance", 19.25, "EUR")
    ]

    for (providerID, label, amount, unit) in cases {
        let balance = QuotaBalance(label: label, amount: amount, unit: unit)
        let credits = try requireCredits(creditsSnapshot(providerID, balances: [balance]))
        try expectEqual(credits.balance, balance, "\(providerID.rawValue) retains the original balance")
        try expectEqual(credits.valueText, balance.valueText, "\(providerID.rawValue) keeps the balance's unit and formatting")
        try expect(credits.unavailableReason == nil, "a reported balance must not show an unavailable explanation")
    }
    try expectEqual(
        QuotaBalance(label: "Usage Credits", amount: 0.03, unit: "").valueText,
        "0.03",
        "MiniMax's fractional balance without a reported currency must not round to zero"
    )
}

private func testCreditsPreferOneTotalWithoutAddingComponentsOrTopUps() throws {
    let total = QuotaBalance(label: "Total available", amount: 12, unit: "USD")
    let balances = [
        QuotaBalance(label: "Prepaid remaining", amount: 8, unit: "USD"),
        QuotaBalance(label: "Granted", amount: 4, unit: "USD"),
        QuotaBalance(label: "Total topped up", amount: 50, unit: "USD"),
        total
    ]
    let credits = try requireCredits(creditsSnapshot(.deepseek, balances: balances))
    try expectEqual(credits.balance, total, "the reported total wins even when components are listed first")

    let accountBalance = QuotaBalance(label: "Credit remaining", amount: 25, unit: "USD")
    let capped = creditsSnapshot(.openrouter, balances: [
        QuotaBalance(label: "Key limit remaining", amount: 3, unit: "USD"),
        accountBalance
    ])
    try expectEqual(try requireCredits(capped).balance, accountBalance, "a key spending cap is not the account's credit balance")
}

private func testCostsQuotaEstimatesAndBankedResetsDoNotBecomeCredits() throws {
    let excluded: [QuotaSnapshot] = [
        creditsSnapshot(.openaiAPI, balances: [QuotaBalance(label: "Current balance", amount: 9, unit: "USD")]),
        creditsSnapshot(.kimi, balances: [QuotaBalance(label: "Total Quota", amount: 700, unit: "quota")]),
        creditsSnapshot(.openrouter, balances: [QuotaBalance(label: "Key limit remaining", amount: 8, unit: "USD")]),
        creditsSnapshot(.cursor, balances: [QuotaBalance(label: "On-Demand Spend", amount: 4.5, unit: "USD")]),
        creditsSnapshot(.deepseek, balances: [QuotaBalance(label: "Total topped up", amount: 20, unit: "USD")]),
        creditsSnapshot(.cerebras, stats: [QuotaStat(label: "TaskWraith 35D estimate", value: 1.33, unit: "USD")]),
        creditsSnapshot(.openai, windows: [window("Weekly", .weekly)])
            .withResetCredits(QuotaResetCreditSummary(availableCount: 2))
    ]
    for snapshot in excluded {
        try expect(snapshot.usageCredits == nil, "\(snapshot.providerID.rawValue) non-credit data must not be presented as usage credits")
    }

    let usedOnly = creditsSnapshot(.claude, balances: [
        QuotaBalance(label: "Extra Usage", amount: 15, unit: "USD", subtitle: "Additional usage this month"),
        QuotaBalance(label: "Extra usage limit remaining", amount: 35, unit: "USD", subtitle: "Monthly spending cap headroom")
    ], windows: [window("Weekly", .weekly)])
    let credits = try requireCredits(usedOnly)
    try expect(credits.balance == nil, "Claude's used-only amount and spending cap must never be shown as remaining credits")
    try expectEqual(credits.valueText, "—", "unknown remaining credit stays unknown")
}

private func testMissingCreditReadingsExplainUnavailableWithoutInventingZero() throws {
    for providerID in [ProviderID.grok, .minimax, .claude] {
        let configured = creditsSnapshot(providerID, windows: [window("Weekly", .weekly)])
        let credits = try requireCredits(configured)
        try expect(credits.balance == nil, "\(providerID.rawValue) must not derive credits from quota headroom")
        try expectEqual(credits.valueText, "—", "missing credit is not a zero balance")
        try expect(!(credits.unavailableReason ?? "").isEmpty, "\(providerID.rawValue) explains the absent reading")
        try expectEqual(configured.balancesSectionTitle, "Usage Credits", "the detail view has a Usage Credits section")
        try expect(
            creditsSnapshot(providerID, fetchState: .notConfigured).usageCredits == nil,
            "an unconfigured provider with no content must not acquire a credits row"
        )
    }
}

private func testInvalidCreditAmountsAreSkippedAndLabelsAreNormalized() throws {
    let valid = QuotaBalance(label: "  CREDITS REMAINING \n", amount: 0, unit: "credits")
    let snapshot = creditsSnapshot(.openai, balances: [
        QuotaBalance(label: "Usage Credits", amount: .nan, unit: "credits"),
        QuotaBalance(label: "Credits Remaining", amount: .infinity, unit: "credits"),
        valid
    ])
    try expectEqual(try requireCredits(snapshot).balance, valid, "invalid numbers cannot hide a valid zero or reach the UI")
}

private func testCreditsIdentityIsPerAccountAndSurvivesRefreshAndRename() throws {
    func reading(_ amount: Double, slot: String = "", label: String? = nil) throws -> QuotaUsageCredits {
        try requireCredits(creditsSnapshot(.openai, balances: [
            QuotaBalance(label: "Credits Remaining", amount: amount, unit: "credits")
        ]).withAccount(slot: slot, label: label, fingerprint: nil))
    }
    let primary = try reading(14_000)
    let secondary = try reading(500, slot: "work", label: "Work")
    let refetched = try reading(250, slot: "work", label: "Client")

    try expectEqual(primary.id, "usage-credits|openai", "primary account's credit row id")
    try expectEqual(secondary.id, "usage-credits|openai#work", "secondary account's credit row id")
    try expectEqual(secondary.accountKey, ProviderAccountKey(providerID: .openai, slot: "work"), "credit rows retain the account")
    try expectEqual(Set([primary.id, secondary.id]).count, 2, "two accounts never collapse into one credit row")
    try expectEqual(secondary.id, refetched.id, "balance changes and account renames do not reset row identity")
    try expectEqual(secondary.label, "\(ProviderID.openai.displayName) · Work", "period credits identify the account")
    try expectEqual(refetched.label, "\(ProviderID.openai.displayName) · Client", "a rename updates presentation")

    let missing = try requireCredits(creditsSnapshot(.claude, windows: [window("Weekly", .weekly)]))
    let restored = try requireCredits(creditsSnapshot(.claude, balances: [
        QuotaBalance(label: "Usage Credits", amount: 20, unit: "USD")
    ]))
    try expectEqual(missing.id, restored.id, "the missing-reading placeholder keeps its rank when credits return")
}

private func testBalanceOnlyAccountsDoNotAlsoClaimToHaveNoUsageData() throws {
    let funded = creditsSnapshot(.openrouter, balances: [
        QuotaBalance(label: "Credit remaining", amount: 6.99, unit: "USD")
    ])
    try expect(QuotaPeriodSection.sections(from: [funded]).isEmpty, "balance-only accounts belong in Usage Credits, without an idle quota row")

    let snapshots = [funded, snapshot(.kimi, "Kimi", [window("Monthly", .monthly)]), snapshot(.openrouter, "Idle", [])]
    let rows = QuotaPeriodSection.sections(from: snapshots).flatMap(\.rows)
    try expectEqual(rows.map(\.label), ["Kimi Monthly", "Idle"], "real meters and genuinely idle providers remain visible")
    try expectEqual(snapshots.compactMap(\.usageCredits).count, 1, "the funded account has one separate credits row")
}

// MARK: - Available resets

private func requireAvailableResets(_ snapshot: QuotaSnapshot) throws -> QuotaAvailableResets {
    guard let resets = snapshot.availableResets else {
        throw PeriodGroupingTestError.failure("missing available resets for \(snapshot.accountKey.rawValue)")
    }
    return resets
}

private func testAvailableResetReadingsDistinguishZeroFromUnavailable() throws {
    for providerID in [ProviderID.claude, .openai, .grok, .qwen] {
        let configured = creditsSnapshot(providerID, windows: [window("Weekly", .weekly)])
        let missing = try requireAvailableResets(configured)
        try expect(missing.summary == nil, "\(providerID.rawValue) keeps a missing banked-reset reading unknown")
        try expectEqual(missing.valueText, "—", "missing reset counts must not appear as zero")
        try expect(!missing.detail.isEmpty, "the absent banked-reset reading has an explanation")

        for count in [0, 2] {
            let summary = QuotaResetCreditSummary(availableCount: count, earnedCount: 7)
            let reported = try requireAvailableResets(configured.withResetCredits(summary))
            try expectEqual(reported.summary, summary, "\(providerID.rawValue) preserves the provider's summary")
            try expectEqual(reported.valueText, String(count), "available count is shown rather than all-time earned count")
            try expectEqual(reported.id, missing.id, "a known count replaces the placeholder in place")
        }

        try expect(
            creditsSnapshot(providerID, fetchState: .notConfigured).availableResets == nil,
            "an unconfigured provider without content gets no reset placeholder"
        )
        let cached = creditsSnapshot(providerID, fetchState: .notConfigured)
            .withResetCredits(QuotaResetCreditSummary(availableCount: 1))
        try expectEqual(try requireAvailableResets(cached).valueText, "1",
                        "an actual cached banked-reset count remains visible without other content")
    }

    let providerWithActualSummary = creditsSnapshot(.minimax)
        .withResetCredits(QuotaResetCreditSummary(availableCount: 3))
    try expectEqual(
        try requireAvailableResets(providerWithActualSummary).valueText,
        "3",
        "a genuine summary is supported even outside the providers with placeholders"
    )
    try expect(creditsSnapshot(.minimax).availableResets == nil, "providers without reset support or a summary get no placeholder")
}

private func testObservedResetSignalsAreNotBankedResetAvailability() throws {
    let observedReset = QuotaSignal(
        kind: .unexpectedRecovery,
        title: "Gifted reset",
        message: "The weekly window recovered",
        severity: .info,
        resetKind: .gifted
    )
    let claude = creditsSnapshot(.claude, windows: [window("Weekly", .weekly, used: 0)])
        .withSignals([observedReset])
    let placeholder = try requireAvailableResets(claude)
    try expect(placeholder.summary == nil, "an observed quota recovery is not a redeemable reset")
    try expectEqual(placeholder.valueText, "—", "reset history and quota headroom cannot fabricate a banked count")
    try expect(
        creditsSnapshot(.minimax).withSignals([observedReset]).availableResets == nil,
        "inferred signals alone do not add reset rows to other providers"
    )
}

private func testResetIdentityIsPerAccountAndSeparateFromUsageCredits() throws {
    let primary = creditsSnapshot(.openai, balances: [
        QuotaBalance(label: "Credits Remaining", amount: 14_000, unit: "credits")
    ]).withResetCredits(QuotaResetCreditSummary(availableCount: 2))
    let secondary = primary.withAccount(slot: "work", label: "Work", fingerprint: nil)
    let refreshed = secondary.withResetCredits(nil).withAccount(slot: "work", label: "Client", fingerprint: nil)
    let first = try requireAvailableResets(primary)
    let second = try requireAvailableResets(secondary)
    let missing = try requireAvailableResets(refreshed)
    let credits = try requireCredits(primary)

    try expectEqual(first.id, "resets-available|openai", "primary reset row id")
    try expectEqual(second.id, "resets-available|openai#work", "secondary reset row id")
    try expectEqual(second.accountKey, secondary.accountKey, "the reset row names its own account")
    try expectEqual(second.id, missing.id, "a refresh, missing count and account rename preserve reset row identity")
    try expectEqual(missing.label, "\(ProviderID.openai.displayName) · Client", "the label follows the current account name")
    try expectEqual(Set([first.id, second.id, credits.id]).count, 3, "reset and credit rows cannot share an identity")
    try expectEqual(first.valueText, "2", "banked count stays independent of spendable credits")
    try expectEqual(credits.balance?.amount, 14_000, "spendable credits stay independent of banked count")
}

private func testResetOnlyAccountsDoNotAlsoGetIdleQuotaRows() throws {
    let resetOnly = creditsSnapshot(.qwen).withResetCredits(QuotaResetCreditSummary(availableCount: 1))
    try expect(resetOnly.usageCredits == nil, "fixture: this account has resets but no credit balance")
    try expect(QuotaPeriodSection.sections(from: [resetOnly]).isEmpty, "reset-only accounts appear in Resets Available without an idle quota row")

    let snapshots = [resetOnly, snapshot(.kimi, "Kimi", [window("Monthly", .monthly)]), snapshot(.openrouter, "Idle", [])]
    try expectEqual(
        QuotaPeriodSection.sections(from: snapshots).flatMap(\.rows).map(\.label),
        ["Kimi Monthly", "Idle"],
        "suppressing reset-only idle rows preserves actual meters and genuinely idle providers"
    )
}

// MARK: - Layout mode

private func testLayoutModeCompactFlags() throws {
    try expect(!DashboardLayoutMode.standard.isCompact, "standard is not compact")
    try expect(DashboardLayoutMode.compact.isCompact, "compact is compact")
    try expect(DashboardLayoutMode.compactPeriod.isCompact, "period is compact")
    try expectEqual(
        DashboardLayoutMode.allCases.map(\.rawValue),
        ["standard", "compact", "compactPeriod"],
        "picker order and persisted raw values"
    )
}

@main
private enum QuotaPeriodGroupingTestRunner {
    static func main() throws {
        try testRealWorldWindowsLandInTheRightPeriod()
        try testGeminiCustomWindowsAreDailyAndOtherCustomWindowsAreAPI()
        try testRowLabelsPrefixTheProviderAndCollapseOverlap()
        try testSectionsGroupByPeriodAndPreserveProviderOrder()
        try testEmptyPeriodsAreDropped()
        try testIdleOnlyDashboardFallsBackToTheAPISection()
        try testEmptyDashboardProducesNoSections()
        try testLayoutModeCompactFlags()
        try testRowIdentitySurvivesARefresh()
        try testRemainingCreditsKeepTheirAmountAndUnitIncludingZero()
        try testCreditsPreferOneTotalWithoutAddingComponentsOrTopUps()
        try testCostsQuotaEstimatesAndBankedResetsDoNotBecomeCredits()
        try testMissingCreditReadingsExplainUnavailableWithoutInventingZero()
        try testInvalidCreditAmountsAreSkippedAndLabelsAreNormalized()
        try testCreditsIdentityIsPerAccountAndSurvivesRefreshAndRename()
        try testBalanceOnlyAccountsDoNotAlsoClaimToHaveNoUsageData()
        try testAvailableResetReadingsDistinguishZeroFromUnavailable()
        try testObservedResetSignalsAreNotBankedResetAvailability()
        try testResetIdentityIsPerAccountAndSeparateFromUsageCredits()
        try testResetOnlyAccountsDoNotAlsoGetIdleQuotaRows()
        print("Quota period grouping tests passed")
    }
}
