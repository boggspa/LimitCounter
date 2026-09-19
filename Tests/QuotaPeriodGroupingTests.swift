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
/// kind `.sliding`, and Qwen's weekly plan is "7-Day Quota".
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
        (.devin, window("Daily quota (live)", .daily), .daily),
        (.devin, window("Weekly quota (Chris Izatt)", .weekly), .weekly),
        (.mimo, window("Plan Quota", .monthly), .monthlyAndAPI),
        (.qwen, window("7-Day Quota", .weekly), .weekly),
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
        print("Quota period grouping tests passed")
    }
}
