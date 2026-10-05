import Foundation

enum MeterOrderTestFailure: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case .failed(let message):
            return message
        }
    }
}

func meterExpect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() {
        throw MeterOrderTestFailure.failed(message)
    }
}

func meterExpectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) throws {
    if actual != expected {
        throw MeterOrderTestFailure.failed("\(message): expected \(expected), got \(actual)")
    }
}

@main
enum MeterOrderTestRunner {
    static func main() async throws {
        try await MainActor.run {
            try testEmptyStoreKeepsNaturalOrder()
            try testDragDownwardsLandsAfterTarget()
            try testDragUpwardsLandsBeforeTarget()
            try testMeterCanReachTheFinalSlot()
            try testOrderSurvivesRestart()
            try testMeterMissingFromOneRefreshKeepsItsRank()
            try testVanishedMeterIsPrunedOnNextDrag()
            try testNewMetersAreAppendedInNaturalOrder()
            try testProviderAndPeriodScopesAreIndependent()
            try testDragWithUnknownMeterIsANoOp()
            try testDropOntoItselfIsANoOp()
            try testResetRestoresOnlyThatScope()
            try testKeySurvivesAFreshWindowID()
            try testKeyIgnoresCaseAndSurroundingWhitespace()
            try testRepeatedSavedKeysNeverHideOrRepeatAMeter()
            try testTwoAccountsOfOneProviderSurviveAPeriodDrag()
            try testMoveNeverSavesARepeatedKey()
            try testMoveToGapLandsExactly()
            try testSecondaryAccountKeyAndScopeFormat()
            try testSecondaryBlockDragLeavesPrimaryOrder()
            try testUsageCreditsReorderAmongProviderWindowsAndSurviveRefresh()
            try testUsageCreditPeriodOrderIsIndependentOfProviderAndMeterScopes()
            try testUsageCreditAccountOrderSurvivesRestartAndMissingReading()
            try testResetRowsReorderAmongCreditsAndProviderMeters()
            try testAvailableResetOrderIsIndependentAndSurvivesAccountRefresh()
        }
        print("Meter order tests passed")
    }

    @MainActor
    private static func testEmptyStoreKeepsNaturalOrder() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MeterOrderStore(defaults: defaults)

        try meterExpectEqual(
            store.ordered(weeklySection, scope: weeklyScope) { $0 },
            weeklySection,
            "a scope nobody has reordered must keep the caller's natural order"
        )
        try meterExpect(storedOrder(in: defaults) == nil, "reading an order must not write one")
    }

    @MainActor
    private static func testDragDownwardsLandsAfterTarget() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MeterOrderStore(defaults: defaults)

        store.move(openaiWeekly, toward: kimiWeekly, scope: weeklyScope, natural: weeklySection)

        try meterExpectEqual(
            store.ordered(weeklySection, scope: weeklyScope) { $0 },
            [claudeWeekly, kimiWeekly, openaiWeekly, qwenSevenDay],
            "downward drag should land directly below the target"
        )
    }

    @MainActor
    private static func testDragUpwardsLandsBeforeTarget() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MeterOrderStore(defaults: defaults)

        store.move(qwenSevenDay, toward: claudeWeekly, scope: weeklyScope, natural: weeklySection)

        try meterExpectEqual(
            store.ordered(weeklySection, scope: weeklyScope) { $0 },
            [openaiWeekly, qwenSevenDay, claudeWeekly, kimiWeekly],
            "upward drag should land directly above the target"
        )
    }

    /// Insert-before-only reordering made the last slot unreachable.
    @MainActor
    private static func testMeterCanReachTheFinalSlot() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MeterOrderStore(defaults: defaults)

        store.move(openaiWeekly, toward: qwenSevenDay, scope: weeklyScope, natural: weeklySection)

        try meterExpectEqual(
            store.ordered(weeklySection, scope: weeklyScope) { $0 }.last,
            openaiWeekly,
            "a meter must be able to reach the bottom slot"
        )
    }

    @MainActor
    private static func testOrderSurvivesRestart() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MeterOrderStore(defaults: defaults)
        store.move(qwenSevenDay, toward: openaiWeekly, scope: weeklyScope, natural: weeklySection)
        let expected = [qwenSevenDay, openaiWeekly, claudeWeekly, kimiWeekly]

        try meterExpectEqual(
            storedOrder(in: defaults)?[weeklyScope],
            expected,
            "the order must be saved under dashboardMeterOrder, keyed by scope"
        )

        let restored = MeterOrderStore(defaults: defaults)
        try meterExpectEqual(
            restored.ordered(weeklySection, scope: weeklyScope) { $0 },
            expected,
            "meter order must round-trip through storage"
        )

        // Drag direction comes from the order the user sees: OpenAI now sits
        // below Qwen, so dropping it on Qwen is an upward drag even though
        // OpenAI leads the natural order.
        restored.move(openaiWeekly, toward: qwenSevenDay, scope: weeklyScope, natural: weeklySection)
        try meterExpectEqual(
            restored.ordered(weeklySection, scope: weeklyScope) { $0 },
            [openaiWeekly, qwenSevenDay, claudeWeekly, kimiWeekly],
            "a drag after a restart must build on the restored order"
        )
    }

    /// A meter that misses one refresh (a failed fetch, a provider signed
    /// out for a moment) must come back to the slot the user gave it.
    @MainActor
    private static func testMeterMissingFromOneRefreshKeepsItsRank() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MeterOrderStore(defaults: defaults)
        store.move(kimiWeekly, toward: openaiWeekly, scope: weeklyScope, natural: weeklySection)

        try meterExpectEqual(
            store.ordered([openaiWeekly, kimiWeekly, qwenSevenDay], scope: weeklyScope) { $0 },
            [kimiWeekly, openaiWeekly, qwenSevenDay],
            "a saved key with no live meter must not appear"
        )
        try meterExpectEqual(
            store.ordered(weeklySection, scope: weeklyScope) { $0 },
            [kimiWeekly, openaiWeekly, claudeWeekly, qwenSevenDay],
            "a meter that missed one refresh must return to its saved slot"
        )
    }

    /// Once the user reorders a scope without a meter, the order they chose
    /// no longer includes it, so its old rank is pruned rather than kept
    /// around to resurface.
    @MainActor
    private static func testVanishedMeterIsPrunedOnNextDrag() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MeterOrderStore(defaults: defaults)
        store.move(kimiWeekly, toward: openaiWeekly, scope: weeklyScope, natural: weeklySection)

        let withoutClaude = [openaiWeekly, kimiWeekly, qwenSevenDay]
        store.move(qwenSevenDay, toward: kimiWeekly, scope: weeklyScope, natural: withoutClaude)

        try meterExpectEqual(
            storedOrder(in: defaults)?[weeklyScope],
            [qwenSevenDay, kimiWeekly, openaiWeekly],
            "a drag must prune keys for meters that are no longer shown"
        )

        let restored = MeterOrderStore(defaults: defaults)
        try meterExpectEqual(
            restored.ordered(weeklySection, scope: weeklyScope) { $0 },
            [qwenSevenDay, kimiWeekly, openaiWeekly, claudeWeekly],
            "a pruned meter that returns must be appended, not restored to its old slot"
        )
    }

    @MainActor
    private static func testNewMetersAreAppendedInNaturalOrder() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MeterOrderStore(defaults: defaults)
        store.move(qwenSevenDay, toward: openaiWeekly, scope: weeklyScope, natural: weeklySection)

        // Two weekly meters the user has never ordered: Grok's, which arrives
        // first because its card sits at the top of the dashboard, and a
        // second Claude weekly meter counted in tokens.
        let grokWeekly = meterKey(.grok, "Weekly", .weekly)
        let claudeWeeklyTokens = meterKey(.claude, "Weekly", .weekly, unit: "tok")
        let natural = [grokWeekly, openaiWeekly, claudeWeekly, claudeWeeklyTokens, kimiWeekly, qwenSevenDay]

        try meterExpectEqual(
            store.ordered(natural, scope: weeklyScope) { $0 },
            [qwenSevenDay, openaiWeekly, claudeWeekly, kimiWeekly, grokWeekly, claudeWeeklyTokens],
            "never-ordered meters must trail the saved order in natural order, not vanish or jump ahead"
        )
    }

    /// The same meter sits in both compact layouts with different
    /// neighbours, so a drag in one must never reshuffle the other.
    @MainActor
    private static func testProviderAndPeriodScopesAreIndependent() throws {
        // Scope names are persisted: renaming one orphans every saved order.
        try meterExpectEqual(qwenScope, "provider:qwen", "provider scope name")
        try meterExpectEqual(weeklyScope, "period:weekly", "period scope name")

        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MeterOrderStore(defaults: defaults)

        store.move(qwenSevenDay, toward: qwenMonthly, scope: qwenScope, natural: qwenMeters)
        try meterExpectEqual(
            store.ordered(weeklySection, scope: weeklyScope) { $0 },
            weeklySection,
            "a provider-layout drag must not reorder the period layout"
        )

        store.move(openaiWeekly, toward: qwenSevenDay, scope: weeklyScope, natural: weeklySection)
        try meterExpectEqual(
            store.ordered(qwenMeters, scope: qwenScope) { $0 },
            [qwenSevenDay, qwenMonthly],
            "a period-layout drag must not reorder the provider layout"
        )
        try meterExpectEqual(
            store.ordered(weeklySection, scope: weeklyScope) { $0 },
            [claudeWeekly, kimiWeekly, qwenSevenDay, openaiWeekly],
            "each layout must keep its own drag"
        )
    }

    /// `move` only ranks meters the caller is showing, so an unknown meter,
    /// or a stale key that is saved but no longer live, cannot be written
    /// back into the order.
    @MainActor
    private static func testDragWithUnknownMeterIsANoOp() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MeterOrderStore(defaults: defaults)
        // MiMo's plan meter lives in Monthly + API, never in Weekly.
        let mimoPlan = meterKey(.mimo, "Plan Quota", .monthly)

        store.move(mimoPlan, toward: claudeWeekly, scope: weeklyScope, natural: weeklySection)
        store.move(claudeWeekly, toward: mimoPlan, scope: weeklyScope, natural: weeklySection)
        try meterExpect(storedOrder(in: defaults) == nil, "a drag with an unknown meter must not write")
        try meterExpectEqual(
            store.ordered(weeklySection, scope: weeklyScope) { $0 },
            weeklySection,
            "a drag with an unknown meter must not reorder"
        )

        store.move(qwenSevenDay, toward: openaiWeekly, scope: weeklyScope, natural: weeklySection)
        let withoutClaude = [openaiWeekly, kimiWeekly, qwenSevenDay]
        let marker = plantWriteMarker(in: defaults)

        store.move(claudeWeekly, toward: openaiWeekly, scope: weeklyScope, natural: withoutClaude)
        store.move(kimiWeekly, toward: claudeWeekly, scope: weeklyScope, natural: withoutClaude)
        store.move(mimoPlan, toward: kimiWeekly, scope: weeklyScope, natural: withoutClaude)

        try meterExpectEqual(storedOrder(in: defaults), marker, "a drag with a stale or unknown meter must not write")
        try meterExpectEqual(
            store.ordered(weeklySection, scope: weeklyScope) { $0 },
            [qwenSevenDay, openaiWeekly, claudeWeekly, kimiWeekly],
            "a drag with a stale or unknown meter must not reorder"
        )
    }

    @MainActor
    private static func testDropOntoItselfIsANoOp() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MeterOrderStore(defaults: defaults)

        store.move(kimiWeekly, toward: kimiWeekly, scope: weeklyScope, natural: weeklySection)
        try meterExpect(storedOrder(in: defaults) == nil, "dropping a meter on itself must not write")

        store.move(qwenSevenDay, toward: openaiWeekly, scope: weeklyScope, natural: weeklySection)
        let marker = plantWriteMarker(in: defaults)
        store.move(kimiWeekly, toward: kimiWeekly, scope: weeklyScope, natural: weeklySection)

        try meterExpectEqual(storedOrder(in: defaults), marker, "dropping a meter on itself must not write")
        try meterExpectEqual(
            store.ordered(weeklySection, scope: weeklyScope) { $0 },
            [qwenSevenDay, openaiWeekly, claudeWeekly, kimiWeekly],
            "dropping a meter on itself must not reorder"
        )
    }

    @MainActor
    private static func testResetRestoresOnlyThatScope() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MeterOrderStore(defaults: defaults)
        store.move(qwenSevenDay, toward: openaiWeekly, scope: weeklyScope, natural: weeklySection)
        store.move(qwenSevenDay, toward: qwenMonthly, scope: qwenScope, natural: qwenMeters)

        store.reset(scope: weeklyScope)

        try meterExpectEqual(
            store.ordered(weeklySection, scope: weeklyScope) { $0 },
            weeklySection,
            "reset must restore the natural order"
        )
        try meterExpectEqual(
            store.ordered(qwenMeters, scope: qwenScope) { $0 },
            [qwenSevenDay, qwenMonthly],
            "reset must leave other scopes alone"
        )

        let restored = MeterOrderStore(defaults: defaults)
        try meterExpectEqual(
            restored.ordered(weeklySection, scope: weeklyScope) { $0 },
            weeklySection,
            "a reset must be saved, not just cleared from memory"
        )
        try meterExpectEqual(
            restored.ordered(qwenMeters, scope: qwenScope) { $0 },
            [qwenSevenDay, qwenMonthly],
            "a reset must not wipe other scopes from storage"
        )

        let marker = plantWriteMarker(in: defaults)
        restored.reset(scope: MeterOrderStore.scopeForPeriod(.daily))
        try meterExpectEqual(storedOrder(in: defaults), marker, "resetting a scope with no saved order must not write")
    }

    /// The regression that matters most: `QuotaWindow.id` is minted fresh on
    /// every fetch, so an order keyed on it would be forgotten on the very
    /// next refresh.
    @MainActor
    private static func testKeySurvivesAFreshWindowID() throws {
        let fetched = window("Weekly", .weekly)
        let refetched = window("Weekly", .weekly)
        try meterExpect(fetched.id != refetched.id, "fixture: each fetch must mint a new QuotaWindow.id")
        try meterExpectEqual(
            MeterOrderStore.key(providerID: .kimi, window: refetched),
            MeterOrderStore.key(providerID: .kimi, window: fetched),
            "a refetched meter must keep its key even though its id changed"
        )

        try meterExpect(
            meterKey(.kimi, "Weekly", .weekly) != meterKey(.kimi, "7-Day Quota", .weekly),
            "a different label must give a different key"
        )
        try meterExpect(
            meterKey(.deepseek, "Credit used", .custom, unit: "USD")
                != meterKey(.deepseek, "Credit used", .monthly, unit: "USD"),
            "a different window kind must give a different key"
        )
        try meterExpect(
            meterKey(.claude, "Weekly", .weekly) != meterKey(.claude, "Weekly", .weekly, unit: "tok"),
            "a different unit must give a different key"
        )
        try meterExpect(
            meterKey(.openai, "Weekly", .weekly) != meterKey(.kimi, "Weekly", .weekly),
            "the same window on two providers must stay two meters in the period layout"
        )

        // End to end: an order set against one fetch must apply to the next.
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MeterOrderStore(defaults: defaults)
        let scope = MeterOrderStore.scopeForProvider(.openai)
        let keyForWindow: (QuotaWindow) -> String = { MeterOrderStore.key(providerID: .openai, window: $0) }

        let firstFetch = [window("5H", .session), window("Weekly", .weekly)]
        store.move(
            keyForWindow(firstFetch[1]),
            toward: keyForWindow(firstFetch[0]),
            scope: scope,
            natural: firstFetch.map(keyForWindow)
        )

        let nextFetch = [window("5H", .session), window("Weekly", .weekly)]
        let reordered = store.ordered(nextFetch, scope: scope, key: keyForWindow)
        try meterExpectEqual(reordered.map(\.label), ["Weekly", "5H"], "the user's order must survive a refresh")
        try meterExpectEqual(
            reordered.map(\.id),
            [nextFetch[1].id, nextFetch[0].id],
            "ordered must hand back the current fetch's windows"
        )
    }

    /// A label that differs only in case or padding is the same meter. The
    /// key normalises it the way `QuotaResetDetector.WindowKey` does, so a
    /// cosmetic change in a client cannot orphan the user's order.
    @MainActor
    private static func testKeyIgnoresCaseAndSurroundingWhitespace() throws {
        try meterExpectEqual(
            meterKey(.qwen, "Monthly Usage \n", .monthly),
            meterKey(.qwen, "monthly usage", .monthly),
            "trailing whitespace and case must not split one meter into two"
        )
        try meterExpectEqual(
            meterKey(.ollama, "  Session usage", .session),
            meterKey(.ollama, "SESSION USAGE", .session),
            "leading whitespace and case must not split one meter into two"
        )
        try meterExpectEqual(
            meterKey(.deepseek, "Credit used", .custom, unit: "USD"),
            meterKey(.deepseek, "Credit used", .custom, unit: "usd"),
            "unit case must not split one meter into two"
        )

        // Keys are persisted, so their exact shape is part of the storage format.
        try meterExpectEqual(
            meterKey(.qwen, " 7-Day Quota ", .weekly),
            "qwen|7-day quota|weekly|%",
            "meter key format"
        )
    }

    /// The saved Weekly order that made both Codex accounts show the first
    /// account's meter: builds that keyed meters by provider alone saved each
    /// provider's key once per account.
    @MainActor
    private static func testRepeatedSavedKeysNeverHideOrRepeatAMeter() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(
            [weeklyScope: [legacyClaudeWeekly, legacyCodexWeekly, legacyCodexWeekly, legacyClaudeWeekly]],
            forKey: meterOrderKey
        )
        let store = MeterOrderStore(defaults: defaults)

        let rows = try twoAccountWeeklyRows()
        let shown = store.ordered(rows, scope: weeklyScope) { MeterOrderStore.key(for: $0) ?? $0.id }

        try meterExpectEqual(
            shown.map(\.id),
            [rows[2].id, rows[0].id, rows[1].id, rows[3].id],
            "saved rows lead once each, then every account's unsaved rows in natural order"
        )
        try meterExpectEqual(
            shown.first { $0.accountSlot == "umnoxf" }?.window?.used,
            0,
            "the second Codex account must show its own reading, not the first's"
        )
        try meterExpectEqual(
            shown.first { $0.accountSlot == "vtptrp" }?.window?.used,
            5,
            "the second Claude account must show its own reading, not the first's"
        )
    }

    @MainActor
    private static func testTwoAccountsOfOneProviderSurviveAPeriodDrag() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(
            [weeklyScope: [legacyClaudeWeekly, legacyCodexWeekly, legacyCodexWeekly, legacyClaudeWeekly]],
            forKey: meterOrderKey
        )
        let store = MeterOrderStore(defaults: defaults)
        let rows = try twoAccountWeeklyRows()
        let keys = rows.compactMap(MeterOrderStore.key(for:))

        // Drag the second Codex account's meter to the top.
        store.move(keys[1], toGap: 0, scope: weeklyScope, natural: keys)

        let saved = storedOrder(in: defaults)?[weeklyScope] ?? []
        try meterExpectEqual(Set(saved).count, saved.count, "a drag must save each meter once")
        try meterExpectEqual(Set(saved), Set(keys), "the saved order names every account's meter")
        let shown = store.ordered(rows, scope: weeklyScope) { MeterOrderStore.key(for: $0) ?? $0.id }
        try meterExpectEqual(shown.first?.accountSlot, "umnoxf", "the dragged account's meter leads")
        try meterExpectEqual(
            shown.filter { $0.providerID == .openai }.map { $0.window?.used },
            [0, 168],
            "each Codex account keeps its own reading after the drag"
        )
    }

    @MainActor
    private static func testMoveNeverSavesARepeatedKey() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MeterOrderStore(defaults: defaults)

        store.move(claudeWeekly, toGap: 0, scope: weeklyScope, natural: [openaiWeekly, claudeWeekly, openaiWeekly, kimiWeekly])

        try meterExpectEqual(
            storedOrder(in: defaults)?[weeklyScope],
            [claudeWeekly, openaiWeekly, kimiWeekly],
            "a repeated natural key must be saved once"
        )
    }

    @MainActor
    private static func testMoveToGapLandsExactly() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MeterOrderStore(defaults: defaults)
        let shown = { store.ordered(weeklySection, scope: weeklyScope) { $0 } }

        store.move(openaiWeekly, toGap: 2, scope: weeklyScope, natural: weeklySection)
        try meterExpectEqual(shown(), [claudeWeekly, kimiWeekly, openaiWeekly, qwenSevenDay], "gap 2 is between the second and third others")

        store.move(qwenSevenDay, toGap: 0, scope: weeklyScope, natural: weeklySection)
        try meterExpectEqual(shown(), [qwenSevenDay, claudeWeekly, kimiWeekly, openaiWeekly], "gap 0 is the top")

        store.move(claudeWeekly, toGap: 3, scope: weeklyScope, natural: weeklySection)
        try meterExpectEqual(shown(), [qwenSevenDay, kimiWeekly, openaiWeekly, claudeWeekly], "the last gap is the bottom")

        let marker = plantWriteMarker(in: defaults)
        store.move(kimiWeekly, toGap: 1, scope: weeklyScope, natural: weeklySection)
        try meterExpectEqual(storedOrder(in: defaults), marker, "dropping a meter back into its own gap must not write")
    }

    /// Keys and scopes are persisted, so their shape is storage format: the
    /// primary account's must not change, and another account's must equal
    /// the id its period row already carries.
    @MainActor
    private static func testSecondaryAccountKeyAndScopeFormat() throws {
        let weekly = QuotaWindow(label: "Weekly", windowKind: .weekly, used: 168, total: 168, unit: "hrs")
        let primary = ProviderAccountKey.primary(.openai)
        let second = ProviderAccountKey(providerID: .openai, slot: "umnoxf")

        try meterExpectEqual(MeterOrderStore.key(account: primary, window: weekly), "openai|weekly|weekly|hrs", "primary key")
        try meterExpectEqual(MeterOrderStore.scopeForProvider(primary), "provider:openai", "primary scope")
        try meterExpectEqual(
            MeterOrderStore.key(account: second, window: weekly),
            "openai#umnoxf|openai|weekly|weekly|hrs",
            "second account key"
        )
        try meterExpectEqual(MeterOrderStore.scopeForProvider(second), "provider:openai#umnoxf", "second account scope")

        let rows = try twoAccountWeeklyRows()
        for row in rows {
            try meterExpectEqual(MeterOrderStore.key(for: row), row.id, "a row's key must be its id")
        }
    }

    @MainActor
    private static func testSecondaryBlockDragLeavesPrimaryOrder() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MeterOrderStore(defaults: defaults)
        let fiveHour = window("5H", .session)
        let weekly = window("Weekly", .weekly)
        let primary = ProviderAccountKey.primary(.claude)
        let second = ProviderAccountKey(providerID: .claude, slot: "vtptrp")
        let primaryKeys = [fiveHour, weekly].map { MeterOrderStore.key(account: primary, window: $0) }
        let secondKeys = [fiveHour, weekly].map { MeterOrderStore.key(account: second, window: $0) }

        store.move(primaryKeys[1], toGap: 0, scope: MeterOrderStore.scopeForProvider(primary), natural: primaryKeys)
        let primaryOrder = storedOrder(in: defaults)?[MeterOrderStore.scopeForProvider(primary)]
        store.move(secondKeys[1], toGap: 0, scope: MeterOrderStore.scopeForProvider(second), natural: secondKeys)
        store.move(secondKeys[1], toGap: 1, scope: MeterOrderStore.scopeForProvider(second), natural: secondKeys)

        try meterExpectEqual(
            storedOrder(in: defaults)?[MeterOrderStore.scopeForProvider(primary)],
            primaryOrder,
            "a drag in one account's block must leave the other's order alone"
        )
    }

    @MainActor
    private static func testUsageCreditsReorderAmongProviderWindowsAndSurviveRefresh() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MeterOrderStore(defaults: defaults)
        let snapshot = creditSnapshot(.claude, amount: 25)
        let credits = try requireCredits(snapshot)
        let scope = MeterOrderStore.scopeForProvider(snapshot.accountKey)
        let windows = snapshot.windows.map { MeterOrderStore.key(account: snapshot.accountKey, window: $0) }
        let natural = windows + [credits.id]

        store.move(credits.id, toGap: 1, scope: scope, natural: natural)

        try meterExpectEqual(
            store.ordered(natural, scope: scope) { $0 },
            [windows[0], credits.id, windows[1]],
            "Usage Credits can sit between a provider's quota meters"
        )

        let refetched = creditSnapshot(.claude, amount: 10)
        let freshNatural = refetched.windows.map { MeterOrderStore.key(account: refetched.accountKey, window: $0) }
            + [try requireCredits(refetched).id]
        let restored = MeterOrderStore(defaults: defaults)
        try meterExpectEqual(
            restored.ordered(freshNatural, scope: scope) { $0 },
            [windows[0], credits.id, windows[1]],
            "Standard order survives a restart and newly allocated windows and balances"
        )
        try meterExpectEqual(
            restored.ordered(windows, scope: scope) { $0 },
            windows,
            "temporarily absent credits do not hide or repeat the remaining meters"
        )
        try meterExpectEqual(
            restored.ordered(freshNatural, scope: scope) { $0 },
            [windows[0], credits.id, windows[1]],
            "a credit row returning after a missing refresh retains its position"
        )
    }

    @MainActor
    private static func testUsageCreditPeriodOrderIsIndependentOfProviderAndMeterScopes() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MeterOrderStore(defaults: defaults)
        let primary = creditSnapshot(.claude, amount: 25)
        let secondary = creditSnapshot(.claude, amount: 10, slot: "work")
        let codex = creditSnapshot(.openai, amount: 500)
        let creditRows = try [primary, secondary, codex].map(requireCredits)
        let creditKeys = creditRows.map(\.id)
        let primaryScope = MeterOrderStore.scopeForProvider(primary.accountKey)
        let secondaryScope = MeterOrderStore.scopeForProvider(secondary.accountKey)
        let primaryKeys = primary.windows.map { MeterOrderStore.key(account: primary.accountKey, window: $0) } + [creditKeys[0]]
        let secondaryKeys = secondary.windows.map { MeterOrderStore.key(account: secondary.accountKey, window: $0) } + [creditKeys[1]]

        try meterExpectEqual(MeterOrderStore.scopeForUsageCredits, "usage-credits", "Period credit order has a stable scope")
        store.move(creditKeys[0], toGap: 0, scope: primaryScope, natural: primaryKeys)
        store.move(qwenSevenDay, toGap: 0, scope: weeklyScope, natural: weeklySection)
        let primaryOrder = storedOrder(in: defaults)?[primaryScope]
        let weeklyOrder = storedOrder(in: defaults)?[weeklyScope]
        store.move(creditKeys[1], toGap: 0, scope: MeterOrderStore.scopeForUsageCredits, natural: creditKeys)

        try meterExpectEqual(
            store.ordered(creditRows, scope: MeterOrderStore.scopeForUsageCredits) { $0.id }.map(\.id),
            [creditKeys[1], creditKeys[0], creditKeys[2]],
            "Period credits can be reordered across accounts and providers"
        )
        try meterExpectEqual(storedOrder(in: defaults)?[primaryScope], primaryOrder, "Period credit drag leaves Standard provider order intact")
        try meterExpectEqual(storedOrder(in: defaults)?[weeklyScope], weeklyOrder, "Period credit drag leaves Weekly meter order intact")
        try meterExpectEqual(store.ordered(secondaryKeys, scope: secondaryScope) { $0 }, secondaryKeys, "one account's credit drag does not reorder another account's block")

        store.reset(scope: MeterOrderStore.scopeForUsageCredits)
        try meterExpectEqual(store.ordered(creditKeys, scope: MeterOrderStore.scopeForUsageCredits) { $0 }, creditKeys, "credit reset restores natural credit order")
        try meterExpectEqual(storedOrder(in: defaults)?[primaryScope], primaryOrder, "credit reset preserves Standard order")
        try meterExpectEqual(storedOrder(in: defaults)?[weeklyScope], weeklyOrder, "credit reset preserves quota period order")
    }

    @MainActor
    private static func testUsageCreditAccountOrderSurvivesRestartAndMissingReading() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MeterOrderStore(defaults: defaults)
        let first = try [creditSnapshot(.claude, amount: 25), creditSnapshot(.claude, amount: 10, slot: "work")].map(requireCredits)
        let scope = MeterOrderStore.scopeForUsageCredits
        store.move(first[1].id, toGap: 0, scope: scope, natural: first.map(\.id))

        let next = try [creditSnapshot(.claude, amount: 20), creditSnapshot(.claude, amount: nil, slot: "work")].map(requireCredits)
        let restored = MeterOrderStore(defaults: defaults)
        let shown = restored.ordered(next, scope: scope) { $0.id }

        try meterExpectEqual(shown.map(\.accountSlot), ["work", ""], "accounts retain their individual ranks through restart and refresh")
        try meterExpectEqual(shown.map { $0.balance?.amount }, [nil, 20], "a missing reading stays with its own account after a drag")
        try meterExpectEqual(Set(shown.map(\.id)).count, shown.count, "neither account's credits are repeated or hidden")
        try meterExpectEqual(shown.first?.valueText, "—", "the reordered placeholder does not borrow the other account's balance")
    }

    @MainActor
    private static func testResetRowsReorderAmongCreditsAndProviderMeters() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MeterOrderStore(defaults: defaults)
        let snapshot = creditSnapshot(.openai, amount: 14_000)
            .withResetCredits(QuotaResetCreditSummary(availableCount: 2))
        let creditID = try requireCredits(snapshot).id
        let resetID = try requireAvailableResets(snapshot).id
        let scope = MeterOrderStore.scopeForProvider(snapshot.accountKey)
        let windowKeys = snapshot.windows.map { MeterOrderStore.key(account: snapshot.accountKey, window: $0) }
        let natural = windowKeys + [creditID, resetID]

        store.move(resetID, toGap: 1, scope: scope, natural: natural)
        try meterExpectEqual(
            store.ordered(natural, scope: scope) { $0 },
            [windowKeys[0], resetID, windowKeys[1], creditID],
            "Resets Available can be placed between quota meters without moving Usage Credits"
        )
        store.move(creditID, toGap: 0, scope: scope, natural: natural)
        let expected = [creditID, windowKeys[0], resetID, windowKeys[1]]

        let refreshed = creditSnapshot(.openai, amount: 13_000)
        let freshNatural = refreshed.windows.map { MeterOrderStore.key(account: refreshed.accountKey, window: $0) }
            + [try requireCredits(refreshed).id, try requireAvailableResets(refreshed).id]
        let restored = MeterOrderStore(defaults: defaults)
        try meterExpectEqual(
            restored.ordered(freshNatural, scope: scope) { $0 },
            expected,
            "all readouts keep their separate Standard positions after a refresh with an unknown reset count"
        )
        try meterExpectEqual(Set(storedOrder(in: defaults)?[scope] ?? []).count, 4, "credits, resets and quota meters persist distinct keys")
    }

    @MainActor
    private static func testAvailableResetOrderIsIndependentAndSurvivesAccountRefresh() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MeterOrderStore(defaults: defaults)
        let primary = creditSnapshot(.openai, amount: 14_000)
            .withResetCredits(QuotaResetCreditSummary(availableCount: 2))
        let secondary = creditSnapshot(.openai, amount: 500, slot: "work")
            .withResetCredits(QuotaResetCreditSummary(availableCount: 1))
        let rows = try [primary, secondary].map(requireAvailableResets)
        let creditKeys = try [primary, secondary].map(requireCredits).map(\.id)
        let scope = MeterOrderStore.scopeForAvailableResets
        let providerScope = MeterOrderStore.scopeForProvider(primary.accountKey)
        let providerKeys = primary.windows.map { MeterOrderStore.key(account: primary.accountKey, window: $0) }
            + [creditKeys[0], rows[0].id]
        store.move(rows[0].id, toGap: 0, scope: providerScope, natural: providerKeys)
        store.move(creditKeys[1], toGap: 0, scope: MeterOrderStore.scopeForUsageCredits, natural: creditKeys)
        store.move(qwenSevenDay, toGap: 0, scope: weeklyScope, natural: weeklySection)
        let otherOrders = storedOrder(in: defaults) ?? [:]

        try meterExpectEqual(scope, "resets-available", "Period reset rows have a stable independent scope")
        store.move(rows[1].id, toGap: 0, scope: scope, natural: rows.map(\.id))
        for (otherScope, order) in otherOrders {
            try meterExpectEqual(storedOrder(in: defaults)?[otherScope], order, "reset drag preserves the \(otherScope) order")
        }

        let refreshed = try [
            primary.withResetCredits(QuotaResetCreditSummary(availableCount: 0)),
            secondary.withResetCredits(nil).withAccount(slot: "work", label: "Client", fingerprint: nil)
        ].map(requireAvailableResets)
        let restored = MeterOrderStore(defaults: defaults)
        let shown = restored.ordered(refreshed, scope: scope) { $0.id }
        try meterExpectEqual(shown.map(\.accountSlot), ["work", ""], "each account retains its reset rank after restart and rename")
        try meterExpectEqual(shown.map(\.valueText), ["—", "0"], "missing and known-zero counts remain attached to the correct account")
        try meterExpectEqual(Set(shown.map(\.id)).count, 2, "neither account's reset row is duplicated or hidden")

        restored.reset(scope: scope)
        try meterExpectEqual(restored.ordered(refreshed, scope: scope) { $0.id }.map(\.id), rows.map(\.id), "resetting the reset group restores its natural order")
        for (otherScope, order) in otherOrders {
            try meterExpectEqual(storedOrder(in: defaults)?[otherScope], order, "reset-group reset preserves the \(otherScope) order")
        }
    }

    private static func requireAvailableResets(_ snapshot: QuotaSnapshot) throws -> QuotaAvailableResets {
        guard let resets = snapshot.availableResets else {
            throw MeterOrderTestFailure.failed("fixture: missing available resets for \(snapshot.accountKey.rawValue)")
        }
        return resets
    }

    private static func creditSnapshot(_ providerID: ProviderID, amount: Double?, slot: String = "") -> QuotaSnapshot {
        QuotaSnapshot(
            providerID: providerID,
            displayName: providerID.displayName,
            windows: [window("5H", .session), window("Weekly", .weekly)],
            balances: amount.map { [QuotaBalance(label: "Credits Remaining", amount: $0, unit: "credits")] } ?? [],
            fetchState: .success
        ).withAccount(slot: slot, label: slot.isEmpty ? nil : "Work", fingerprint: nil)
    }

    private static func requireCredits(_ snapshot: QuotaSnapshot) throws -> QuotaUsageCredits {
        guard let credits = snapshot.usageCredits else {
            throw MeterOrderTestFailure.failed("fixture: missing usage credits for \(snapshot.accountKey.rawValue)")
        }
        return credits
    }

    private static let legacyCodexWeekly = MeterOrderStore.key(
        providerID: .openai,
        window: QuotaWindow(label: "Weekly", windowKind: .weekly, used: 168, total: 168, unit: "hrs")
    )
    private static let legacyClaudeWeekly = meterKey(.claude, "Weekly", .weekly)

    /// Two Codex accounts on different plans and two Claude accounts, the
    /// way `QuotaPeriodSection.sections(from:)` lays out their Weekly rows.
    private static func twoAccountWeeklyRows() throws -> [QuotaPeriodRow] {
        func account(_ providerID: ProviderID, _ slot: String, _ window: QuotaWindow) -> QuotaSnapshot {
            QuotaSnapshot(
                providerID: providerID,
                displayName: providerID.displayName,
                planName: nil,
                windows: [window],
                fetchState: .success
            )
            .withAccount(slot: slot, label: slot.isEmpty ? nil : "Boggspa TW", fingerprint: nil)
        }
        let snapshots = [
            account(.openai, "", QuotaWindow(label: "Weekly", windowKind: .weekly, used: 168, total: 168, unit: "hrs")),
            account(.openai, "umnoxf", QuotaWindow(label: "Weekly", windowKind: .weekly, used: 0, total: 168, unit: "hrs")),
            account(.claude, "", QuotaWindow(label: "Weekly", windowKind: .weekly, used: 96, total: 100, unit: "%")),
            account(.claude, "vtptrp", QuotaWindow(label: "Weekly", windowKind: .weekly, used: 5, total: 100, unit: "%"))
        ]
        guard let rows = QuotaPeriodSection.sections(from: snapshots).first(where: { $0.group == .weekly })?.rows,
              rows.count == 4 else {
            throw MeterOrderTestFailure.failed("fixture: expected four Weekly rows")
        }
        return rows
    }

    private static let meterOrderKey = "dashboardMeterOrder"

    private static let weeklyScope = MeterOrderStore.scopeForPeriod(.weekly)
    private static let qwenScope = MeterOrderStore.scopeForProvider(.qwen)

    private static let openaiWeekly = meterKey(.openai, "Weekly", .weekly)
    private static let claudeWeekly = meterKey(.claude, "Weekly", .weekly)
    private static let kimiWeekly = meterKey(.kimi, "Weekly", .weekly)
    private static let qwenSevenDay = meterKey(.qwen, "7-Day Quota", .weekly)
    private static let qwenMonthly = meterKey(.qwen, "Monthly Usage", .monthly)

    /// The weekly section of the period layout in default card order, the
    /// way `QuotaPeriodSection.sections(from:)` hands it over.
    private static let weeklySection = [openaiWeekly, claudeWeekly, kimiWeekly, qwenSevenDay]

    /// Qwen's meters in the provider layout; the 7-day meter is in both.
    private static let qwenMeters = [qwenMonthly, qwenSevenDay]

    /// Every call mints a fresh `QuotaWindow.id`, exactly as a refresh does.
    private static func window(_ label: String, _ kind: QuotaWindowKind, unit: String = "%") -> QuotaWindow {
        QuotaWindow(label: label, windowKind: kind, used: 40, total: 100, unit: unit)
    }

    private static func meterKey(
        _ providerID: ProviderID,
        _ label: String,
        _ kind: QuotaWindowKind,
        unit: String = "%"
    ) -> String {
        MeterOrderStore.key(providerID: providerID, window: window(label, kind, unit: unit))
    }

    private static func storedOrder(in defaults: UserDefaults) -> [String: [String]]? {
        defaults.dictionary(forKey: meterOrderKey) as? [String: [String]]
    }

    /// Writes a value behind the store's back that it would never write
    /// itself, so "did not write" can be told apart from "wrote the same
    /// order again".
    private static func plantWriteMarker(in defaults: UserDefaults) -> [String: [String]] {
        let marker = ["marker": ["untouched"]]
        defaults.set(marker, forKey: meterOrderKey)
        return marker
    }

    private static func isolatedDefaults() throws -> (defaults: UserDefaults, suite: String) {
        let suite = "MeterOrderTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            throw MeterOrderTestFailure.failed("could not open isolated defaults suite \(suite)")
        }
        defaults.removePersistentDomain(forName: suite)
        return (defaults, suite)
    }
}
