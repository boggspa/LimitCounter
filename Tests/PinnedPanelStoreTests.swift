import Foundation

enum PinnedPanelTestFailure: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case .failed(let message):
            return message
        }
    }
}

func panelExpect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() {
        throw PinnedPanelTestFailure.failed(message)
    }
}

func panelExpectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) throws {
    if actual != expected {
        throw PinnedPanelTestFailure.failed("\(message): expected \(expected), got \(actual)")
    }
}

@main
enum PinnedPanelStoreTestRunner {
    static func main() async throws {
        testDefaultStates()
        try testPersistenceRoundTrip()
        try testNormalizationDropsInvalidProviderState()
        print("Pinned panel store tests passed")
    }

    @MainActor
    private static func testDefaultStates() {
        let store = PinnedPanelStore(defaults: isolatedDefaults())
        let states = store.allStates

        try? panelExpect(states.contains { $0.kind == .overview }, "default overview panel")
        try? panelExpect(states.contains { $0.kind == .provider && $0.providerID == .openai }, "default provider panel")
        try? panelExpect(states.allSatisfy { !$0.isVisible }, "defaults hidden")
    }

    @MainActor
    private static func testPersistenceRoundTrip() throws {
        let defaults = isolatedDefaults()
        let first = PinnedPanelStore(defaults: defaults)

        let overview = first.setVisible(true, kind: .overview)
        first.updateOverviewProviders([.openai, .claude, .kimi, .codexTelemetry])
        let kimi = first.setVisible(true, kind: .provider, providerID: .kimi)

        let restored = PinnedPanelStore(defaults: defaults)
        let restoredOverview = restored.state(kind: .overview)
        let restoredKimi = restored.state(kind: .provider, providerID: .kimi)

        try panelExpectEqual(restoredOverview.isVisible, true, "overview visibility")
        try panelExpectEqual(restoredOverview.frameAutosaveName, overview.frameAutosaveName, "overview autosave")
        try panelExpectEqual(restoredOverview.selectedOverviewProviderIDs, [.openai, .claude, .kimi], "overview provider filtering")
        try panelExpectEqual(restoredKimi.isVisible, true, "provider visibility")
        try panelExpectEqual(restoredKimi.frameAutosaveName, kimi.frameAutosaveName, "provider autosave")
    }

    @MainActor
    private static func testNormalizationDropsInvalidProviderState() throws {
        let normalized = PinnedPanelStore.normalizedStates([
            PinnedPanelState(kind: .provider, providerID: .codexTelemetry, isVisible: true),
            PinnedPanelState(kind: .provider, providerID: .claude, isVisible: true, frameAutosaveName: "")
        ])

        try panelExpect(!normalized.contains { $0.providerID == .codexTelemetry }, "hidden telemetry provider panel dropped")
        let claude = try normalized.first { $0.providerID == .claude }.orThrow("missing claude state")
        try panelExpectEqual(claude.frameAutosaveName, "PinnedPanel.provider.claude", "empty autosave repaired")
    }

    private static func isolatedDefaults() -> UserDefaults {
        let name = "PinnedPanelStoreTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: name) else {
            return .standard
        }
        defaults.removePersistentDomain(forName: name)
        return defaults
    }
}

private extension Optional {
    func orThrow(_ message: String) throws -> Wrapped {
        guard let value = self else {
            throw PinnedPanelTestFailure.failed(message)
        }
        return value
    }
}
