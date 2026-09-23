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
