import Foundation

enum ProviderCardOrderTestFailure: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case .failed(let message):
            return message
        }
    }
}

func orderExpect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() {
        throw ProviderCardOrderTestFailure.failed(message)
    }
}

func orderExpectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) throws {
    if actual != expected {
        throw ProviderCardOrderTestFailure.failed("\(message): expected \(expected), got \(actual)")
    }
}

@main
enum ProviderCardOrderTestRunner {
    static func main() async throws {
        try await MainActor.run {
            try testEveryOrderableCardIsRanked()
            try testLegacyOrderKeepsUserChoicesAndAdoptsNewCards()
            try testDragUpwardsLandsBeforeTarget()
            try testDragDownwardsLandsAfterTarget()
            try testCardCanReachTheFinalSlot()
            try testHeatmapIsDraggable()
            try testOrderPersists()
            try testSecondaryAccountSitsAfterItsPrimary()
            try testSecondaryAccountCardMovesOnItsOwn()
            try testMoveToGapKeepsHiddenCardsInPlace()
            try testAccountEntriesSurviveAndUnreadableOnesAreDropped()
        }
        print("Provider card order tests passed")
    }

    /// Regression guard for the bug that pinned OpenRouter, Qwen, MiMo
    /// and the activity heatmap to the bottom of the dashboard: any card
    /// missing from the normalized order ranks `Int.max` and can never be
    /// moved.
    @MainActor
    private static func testEveryOrderableCardIsRanked() throws {
        let store = ProviderCardOrderStore(defaults: isolatedDefaults())

        for providerID in ProviderID.allCases where providerID.isOrderableDashboardCard {
            try orderExpect(
                store.rank(for: providerID) != Int.max,
                "\(providerID.rawValue) must have a real rank, not Int.max"
            )
        }

        for providerID in [ProviderID.openrouter, .qwen, .mimo, .heatmap] {
            try orderExpect(
                store.orderedCards.contains(providerID),
                "\(providerID.rawValue) missing from default card order"
            )
        }

        try orderExpect(
            !store.orderedCards.contains(.codexTelemetry),
            "Codex telemetry folds into the Codex card and must stay out of the order"
        )
        try orderExpectEqual(
            store.orderedCards.count,
            Set(store.orderedCards).count,
            "card order must not contain duplicates"
        )
    }

    /// A saved order written before these providers existed must keep the
    /// user's arrangement and simply gain the new cards.
    @MainActor
    private static func testLegacyOrderKeepsUserChoicesAndAdoptsNewCards() throws {
        // The exact shape a dashboard order saved before OpenRouter,
        // Qwen, MiMo and the heatmap card existed.
        let legacyOrder: [ProviderID] = [
            .openai, .claude, .grok, .kimi, .cursor, .gemini, .chatgpt, .openaiAPI,
            .devin, .antigravity, .mistral, .ollama, .meta, .deepseek, .cerebras
        ]
        let defaults = isolatedDefaults()
        defaults.set(legacyOrder.map(\.rawValue), forKey: orderedProvidersKey)

        let store = ProviderCardOrderStore(defaults: defaults)

        try orderExpectEqual(
            Array(store.orderedCards.prefix(legacyOrder.count)),
            legacyOrder,
            "saved user order must survive the migration untouched"
        )
        for providerID in [ProviderID.openrouter, .qwen, .mimo, .heatmap] {
            try orderExpect(
                store.rank(for: providerID) != Int.max,
                "\(providerID.rawValue) must be adopted into a legacy saved order"
            )
        }

        // …and the newly adopted cards must actually be movable.
        store.move(.qwen, toward: .claude)
        let order = store.orderedCards
        try orderExpectEqual(
            try index(of: .qwen, in: order) + 1,
            try index(of: .claude, in: order),
            "a newly adopted card must be draggable out of the bottom of the stack"
        )
    }

    @MainActor
    private static func testDragUpwardsLandsBeforeTarget() throws {
        let store = ProviderCardOrderStore(defaults: isolatedDefaults())

        store.move(.mimo, toward: .claude)

        let order = store.orderedCards
        let mimoIndex = try index(of: .mimo, in: order)
        let claudeIndex = try index(of: .claude, in: order)
        try orderExpectEqual(mimoIndex + 1, claudeIndex, "upward drag should land directly above the target")
    }

    @MainActor
    private static func testDragDownwardsLandsAfterTarget() throws {
        let store = ProviderCardOrderStore(defaults: isolatedDefaults())

        store.move(.openai, toward: .grok)

        let order = store.orderedCards
        let openaiIndex = try index(of: .openai, in: order)
        let grokIndex = try index(of: .grok, in: order)
        try orderExpectEqual(openaiIndex, grokIndex + 1, "downward drag should land directly below the target")
    }

    /// Insert-before-only reordering made the last slot unreachable.
    @MainActor
    private static func testCardCanReachTheFinalSlot() throws {
        let store = ProviderCardOrderStore(defaults: isolatedDefaults())
        guard let lastCard = store.orderedCards.last else {
            throw ProviderCardOrderTestFailure.failed("empty card order")
        }

        store.move(.claude, toward: lastCard)

        try orderExpectEqual(store.orderedCards.last, .claude, "a card must be able to reach the bottom slot")
    }

    @MainActor
    private static func testHeatmapIsDraggable() throws {
        let store = ProviderCardOrderStore(defaults: isolatedDefaults())
        guard let firstCard = store.orderedCards.first else {
            throw ProviderCardOrderTestFailure.failed("empty card order")
        }

        store.move(.heatmap, toward: firstCard)

        try orderExpectEqual(store.orderedCards.first, .heatmap, "the heatmap card must be reorderable too")
    }

    @MainActor
    private static func testOrderPersists() throws {
        let defaults = isolatedDefaults()
        let store = ProviderCardOrderStore(defaults: defaults)
        store.move(.qwen, toward: .openai)
        let expected = store.orderedCards

        let restored = ProviderCardOrderStore(defaults: defaults)
        try orderExpectEqual(restored.orderedCards, expected, "card order must round-trip through storage")
    }

    private static let claudeWork = ProviderAccountKey(providerID: .claude, slot: "vtptrp")

    @MainActor
    private static func testSecondaryAccountSitsAfterItsPrimary() throws {
        let store = ProviderCardOrderStore(defaults: isolatedDefaults())

        try orderExpectEqual(
            store.sortedCards([claudeWork, .primary(.gemini), .primary(.claude), .primary(.openai)]),
            [.primary(.openai), .primary(.claude), claudeWork, .primary(.gemini)],
            "an account that was never dragged follows its provider's primary"
        )
    }

    @MainActor
    private static func testSecondaryAccountCardMovesOnItsOwn() throws {
        let defaults = isolatedDefaults()
        let store = ProviderCardOrderStore(defaults: defaults)
        let visible: [ProviderAccountKey] = [.primary(.openai), .primary(.claude), claudeWork, .primary(.gemini)]

        store.move(claudeWork, toGap: 0, among: visible)
        try orderExpectEqual(
            store.sortedCards(visible),
            [claudeWork, .primary(.openai), .primary(.claude), .primary(.gemini)],
            "a second account's card moves without its primary"
        )

        store.move(.primary(.openai), toGap: 3, among: visible)
        try orderExpectEqual(
            store.sortedCards(visible),
            [claudeWork, .primary(.claude), .primary(.gemini), .primary(.openai)],
            "the last gap is the bottom"
        )

        let restored = ProviderCardOrderStore(defaults: defaults)
        try orderExpectEqual(restored.sortedCards(visible), store.sortedCards(visible), "account order must round-trip")
        try orderExpect(
            (defaults.array(forKey: orderedProvidersKey) as? [String])?.contains(claudeWork.rawValue) == true,
            "the dragged account is saved by its account key"
        )
    }

    @MainActor
    private static func testMoveToGapKeepsHiddenCardsInPlace() throws {
        let store = ProviderCardOrderStore(defaults: isolatedDefaults())
        let visible: [ProviderAccountKey] = [.primary(.openai), .primary(.claude), .primary(.gemini)]
        let hiddenIndex = try index(of: .openaiAPI, in: store.orderedCards)

        store.move(.primary(.gemini), toGap: 0, among: visible)

        try orderExpectEqual(
            store.sortedCards(visible),
            [.primary(.gemini), .primary(.openai), .primary(.claude)],
            "gap 0 is the top of what is on screen"
        )
        try orderExpectEqual(
            try index(of: .openaiAPI, in: store.orderedCards),
            hiddenIndex,
            "a card that is not on screen keeps its place"
        )
    }

    @MainActor
    private static func testAccountEntriesSurviveAndUnreadableOnesAreDropped() throws {
        let defaults = isolatedDefaults()
        defaults.set(
            ["claude", claudeWork.rawValue, "claude#", "nonsense#x", "codexTelemetry#abc", "openai"],
            forKey: orderedProvidersKey
        )
        let store = ProviderCardOrderStore(defaults: defaults)

        try orderExpectEqual(
            Array(store.orderedCards.prefix(2)),
            [.claude, .openai],
            "providers keep their saved order around account entries"
        )
        try orderExpectEqual(
            store.sortedCards([.primary(.openai), claudeWork, .primary(.claude)]),
            [.primary(.claude), claudeWork, .primary(.openai)],
            "a saved account entry keeps its place"
        )

        store.move(.primary(.openai), toGap: 0, among: [.primary(.openai), claudeWork, .primary(.claude)])
        let saved = defaults.array(forKey: orderedProvidersKey) as? [String] ?? []
        try orderExpect(saved.contains(claudeWork.rawValue), "account entries survive a save")
        for unreadable in ["claude#", "nonsense#x", "codexTelemetry#abc"] {
            try orderExpect(!saved.contains(unreadable), "\(unreadable) must be dropped")
        }
        try orderExpectEqual(saved.count, Set(saved).count, "saved order must not repeat an entry")
    }

    private static func index(of providerID: ProviderID, in order: [ProviderID]) throws -> Int {
        guard let index = order.firstIndex(of: providerID) else {
            throw ProviderCardOrderTestFailure.failed("\(providerID.rawValue) missing from card order")
        }
        return index
    }

    private static let orderedProvidersKey = "dashboardCardProviderOrder"

    private static func isolatedDefaults() -> UserDefaults {
        let name = "ProviderCardOrderTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: name) else {
            return .standard
        }
        defaults.removePersistentDomain(forName: name)
        return defaults
    }
}
