import Foundation
import WidgetKit
import SwiftUI
import Combine

/// Reads and writes normalized QuotaSnapshot data to the shared App Group container.
/// Both the main app and widget extension use this class.
/// No credentials or raw API responses are ever stored here.
public final class QuotaSnapshotStore {

    public static let shared = QuotaSnapshotStore()

    private let appGroupID = "group.com.chrisizatt.LLMUsageCounter"
    private let snapshotsKey = "cachedQuotaSnapshots"
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private var defaults: UserDefaults {
        UserDefaults(suiteName: appGroupID) ?? .standard
    }

    private init() {
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    // MARK: - Read

    public func loadSnapshots() -> [QuotaSnapshot] {
        guard
            let data = defaults.data(forKey: snapshotsKey),
            let snapshots = try? decoder.decode([QuotaSnapshot].self, from: data)
        else {
            return []
        }
        return snapshots
    }

    public func snapshot(for providerID: ProviderID) -> QuotaSnapshot? {
        loadSnapshots().first { $0.providerID == providerID }
    }

    // MARK: - Write

    /// Upserts a single provider snapshot, preserving others.
    /// Call WidgetCenter.shared.reloadAllTimelines() after this from the main app.
    public func upsert(_ snapshot: QuotaSnapshot) {
        var current = loadSnapshots()
        current.removeAll { $0.providerID == snapshot.providerID }
        current.append(snapshot)
        save(current)
    }

    /// Replaces all snapshots atomically.
    public func replaceAll(_ snapshots: [QuotaSnapshot]) {
        save(snapshots)
    }

    // MARK: - Clear

    public func clear(providerID: ProviderID) {
        var current = loadSnapshots()
        current.removeAll { $0.providerID == providerID }
        save(current)
    }

    public func clearAll() {
        defaults.removeObject(forKey: snapshotsKey)
    }

    // MARK: - Staleness

    /// Returns true if the stored snapshot is older than `threshold` seconds.
    public func isStale(providerID: ProviderID, threshold: TimeInterval = 3600) -> Bool {
        guard let snap = snapshot(for: providerID) else { return true }
        return Date().timeIntervalSince(snap.fetchedAt) > threshold
    }

    // MARK: - Private

    private func save(_ snapshots: [QuotaSnapshot]) {
        if let data = try? encoder.encode(snapshots) {
            defaults.set(data, forKey: snapshotsKey)
        }
    }
}

public enum UsageRefreshCadence {
    public static let appGroupID = "group.com.chrisizatt.LLMUsageCounter"
    public static let requestedRefreshIntervalMinutesKey = "requestedRefreshIntervalMinutes"
    public static let allowedIntervalMinutes = [1, 2, 3, 5, 10, 15, 30]
    public static let defaultIntervalMinutes = 15

    private static var defaults: UserDefaults {
        UserDefaults(suiteName: appGroupID) ?? .standard
    }

    public static var requestedRefreshIntervalMinutes: Int {
        let stored = defaults.integer(forKey: requestedRefreshIntervalMinutesKey)
        guard allowedIntervalMinutes.contains(stored) else {
            return defaultIntervalMinutes
        }
        return stored
    }

    public static var requestedRefreshInterval: TimeInterval {
        TimeInterval(requestedRefreshIntervalMinutes * 60)
    }

    public static func setRequestedRefreshIntervalMinutes(_ minutes: Int) {
        let normalized = allowedIntervalMinutes.contains(minutes) ? minutes : defaultIntervalMinutes
        defaults.set(normalized, forKey: requestedRefreshIntervalMinutesKey)
    }

    public static func intervalLabel(for minutes: Int) -> String {
        minutes == 1 ? "1 minute" : "\(minutes) minutes"
    }
}

@MainActor
public final class ProviderMonthlyBudgetStore: ObservableObject {
    public static let shared = ProviderMonthlyBudgetStore()

    private let appGroupID = "group.com.chrisizatt.LLMUsageCounter"
    private let budgetsKey = "providerMonthlyBudgetsUSD"
    private let defaultsOverride: UserDefaults?

    @Published private var budgetsUSD: [ProviderID: Double]

    private var defaults: UserDefaults {
        if let defaultsOverride { return defaultsOverride }
        return UserDefaults(suiteName: appGroupID) ?? .standard
    }

    public convenience init(defaults: UserDefaults) {
        self.init(defaultsProvider: defaults)
    }

    private init(defaultsProvider: UserDefaults? = nil) {
        self.defaultsOverride = defaultsProvider
        let resolvedDefaults = defaultsProvider ?? (UserDefaults(suiteName: appGroupID) ?? .standard)
        self.budgetsUSD = Self.loadBudgets(from: resolvedDefaults, key: budgetsKey)
    }

    public func budgetUSD(for providerID: ProviderID) -> Double? {
        budgetsUSD[providerID]
    }

    public func setBudgetUSD(_ amount: Double?, for providerID: ProviderID) {
        if let amount, Self.isValidBudget(amount) {
            budgetsUSD[providerID] = amount
        } else {
            budgetsUSD.removeValue(forKey: providerID)
        }
        save()
    }

    public func formattedBudgetText(for providerID: ProviderID) -> String {
        guard let amount = budgetUSD(for: providerID) else { return "" }
        if amount.rounded() == amount {
            return String(format: "%.0f", amount)
        }
        return String(format: "%.2f", amount)
    }

    public static func parsedBudgetUSD(from text: String) -> Double? {
        let cleaned = text
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleaned.isEmpty, let amount = Double(cleaned), isValidBudget(amount) else {
            return nil
        }

        return amount
    }

    public nonisolated static func nonisolatedBudgetUSD(for providerID: ProviderID) -> Double? {
        let appGroupID = "group.com.chrisizatt.LLMUsageCounter"
        let budgetsKey = "providerMonthlyBudgetsUSD"
        let defaults = UserDefaults(suiteName: appGroupID) ?? .standard
        return loadBudgets(from: defaults, key: budgetsKey)[providerID]
    }

    private nonisolated static func loadBudgets(from defaults: UserDefaults, key: String) -> [ProviderID: Double] {
        let stored = defaults.dictionary(forKey: key) ?? [:]
        return stored.reduce(into: [ProviderID: Double]()) { partial, item in
            guard let providerID = ProviderID(rawValue: item.key) else { return }

            let amount: Double?
            if let double = item.value as? Double {
                amount = double
            } else if let number = item.value as? NSNumber {
                amount = number.doubleValue
            } else {
                amount = nil
            }

            guard let amount, isValidBudget(amount) else { return }
            partial[providerID] = amount
        }
    }

    private nonisolated static func isValidBudget(_ amount: Double) -> Bool {
        amount.isFinite && amount > 0
    }

    private func save() {
        let stored = budgetsUSD.reduce(into: [String: Double]()) { partial, item in
            guard Self.isValidBudget(item.value) else { return }
            partial[item.key.rawValue] = item.value
        }
        defaults.set(stored, forKey: budgetsKey)
        WidgetCenter.shared.reloadAllTimelines()
        objectWillChange.send()
    }
}

public enum PinnedPanelKind: String, Codable, CaseIterable, Hashable {
    case overview
    case provider
}

public struct PinnedPanelState: Codable, Identifiable, Equatable, Hashable {
    public var kind: PinnedPanelKind
    public var providerID: ProviderID?
    public var isVisible: Bool
    public var frameAutosaveName: String
    public var selectedOverviewProviderIDs: [ProviderID]

    public var id: String {
        switch kind {
        case .overview:
            return "overview"
        case .provider:
            return "provider.\(providerID?.rawValue ?? "unknown")"
        }
    }

    public init(
        kind: PinnedPanelKind,
        providerID: ProviderID? = nil,
        isVisible: Bool = false,
        frameAutosaveName: String? = nil,
        selectedOverviewProviderIDs: [ProviderID] = []
    ) {
        self.kind = kind
        self.providerID = providerID
        self.isVisible = isVisible
        self.frameAutosaveName = frameAutosaveName ?? Self.defaultFrameAutosaveName(kind: kind, providerID: providerID)
        self.selectedOverviewProviderIDs = selectedOverviewProviderIDs
    }

    public static func overviewDefault(visibleProviderIDs: [ProviderID] = Array(ProviderID.userFacingCases.prefix(4))) -> PinnedPanelState {
        PinnedPanelState(
            kind: .overview,
            isVisible: false,
            frameAutosaveName: defaultFrameAutosaveName(kind: .overview, providerID: nil),
            selectedOverviewProviderIDs: Array(visibleProviderIDs.prefix(4))
        )
    }

    public static func providerDefault(_ providerID: ProviderID) -> PinnedPanelState {
        PinnedPanelState(
            kind: .provider,
            providerID: providerID,
            isVisible: false,
            frameAutosaveName: defaultFrameAutosaveName(kind: .provider, providerID: providerID)
        )
    }

    public static func defaultFrameAutosaveName(kind: PinnedPanelKind, providerID: ProviderID?) -> String {
        switch kind {
        case .overview:
            return "PinnedPanel.overview"
        case .provider:
            return "PinnedPanel.provider.\(providerID?.rawValue ?? "unknown")"
        }
    }
}

@MainActor
public final class PinnedPanelStore: ObservableObject {
    public static let shared = PinnedPanelStore()

    private let appGroupID = "group.com.chrisizatt.LLMUsageCounter"
    private let panelsKey = "pinnedPanelStates"
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let defaultsOverride: UserDefaults?

    @Published private var states: [PinnedPanelState]

    private var defaults: UserDefaults {
        if let defaultsOverride { return defaultsOverride }
        return UserDefaults(suiteName: appGroupID) ?? .standard
    }

    public convenience init(defaults: UserDefaults) {
        self.init(defaultsProvider: defaults)
    }

    private init(defaultsProvider: UserDefaults? = nil) {
        self.defaultsOverride = defaultsProvider
        let resolvedDefaults = defaultsProvider ?? (UserDefaults(suiteName: appGroupID) ?? .standard)
        if let data = resolvedDefaults.data(forKey: panelsKey),
           let decoded = try? decoder.decode([PinnedPanelState].self, from: data) {
            self.states = Self.normalizedStates(decoded)
        } else {
            self.states = Self.defaultStates()
        }
    }

    public var allStates: [PinnedPanelState] {
        states
    }

    public var visibleStates: [PinnedPanelState] {
        states.filter(\.isVisible)
    }

    public func state(kind: PinnedPanelKind, providerID: ProviderID? = nil) -> PinnedPanelState {
        let id = PinnedPanelState(kind: kind, providerID: providerID).id
        return states.first(where: { $0.id == id }) ?? Self.defaultState(kind: kind, providerID: providerID)
    }

    public func isVisible(kind: PinnedPanelKind, providerID: ProviderID? = nil) -> Bool {
        state(kind: kind, providerID: providerID).isVisible
    }

    @discardableResult
    public func setVisible(_ visible: Bool, kind: PinnedPanelKind, providerID: ProviderID? = nil) -> PinnedPanelState {
        var updated = state(kind: kind, providerID: providerID)
        updated.isVisible = visible
        upsert(updated)
        return updated
    }

    @discardableResult
    public func toggle(kind: PinnedPanelKind, providerID: ProviderID? = nil) -> PinnedPanelState {
        let current = state(kind: kind, providerID: providerID)
        return setVisible(!current.isVisible, kind: kind, providerID: providerID)
    }

    public func updateOverviewProviders(_ providerIDs: [ProviderID]) {
        var overview = state(kind: .overview)
        overview.selectedOverviewProviderIDs = Array(providerIDs.filter(\.isUserFacingInProviderLists).prefix(4))
        upsert(overview)
    }

    public func reset() {
        states = Self.defaultStates()
        save()
    }

    public static func normalizedStates(_ decoded: [PinnedPanelState]) -> [PinnedPanelState] {
        var output = defaultStates()

        for state in decoded {
            guard state.kind == .overview || state.providerID?.isUserFacingInProviderLists == true else {
                continue
            }

            let normalized = PinnedPanelState(
                kind: state.kind,
                providerID: state.providerID,
                isVisible: state.isVisible,
                frameAutosaveName: state.frameAutosaveName.isEmpty
                    ? PinnedPanelState.defaultFrameAutosaveName(kind: state.kind, providerID: state.providerID)
                    : state.frameAutosaveName,
                selectedOverviewProviderIDs: state.selectedOverviewProviderIDs.filter(\.isUserFacingInProviderLists)
            )

            output.removeAll { $0.id == normalized.id }
            output.append(normalized)
        }

        return output.sorted { lhs, rhs in
            let lhsRank = lhs.kind == .overview ? -1 : ProviderCardOrderStore.nonisolatedRank(for: lhs.providerID ?? .openai)
            let rhsRank = rhs.kind == .overview ? -1 : ProviderCardOrderStore.nonisolatedRank(for: rhs.providerID ?? .openai)
            return lhsRank < rhsRank
        }
    }

    private static func defaultStates() -> [PinnedPanelState] {
        [PinnedPanelState.overviewDefault()] + ProviderID.userFacingCases.map(PinnedPanelState.providerDefault)
    }

    private static func defaultState(kind: PinnedPanelKind, providerID: ProviderID?) -> PinnedPanelState {
        switch kind {
        case .overview:
            return .overviewDefault()
        case .provider:
            return .providerDefault(providerID ?? .openai)
        }
    }

    private func upsert(_ state: PinnedPanelState) {
        states.removeAll { $0.id == state.id }
        states.append(state)
        states = Self.normalizedStates(states)
        save()
        objectWillChange.send()
    }

    private func save() {
        guard let data = try? encoder.encode(states) else { return }
        defaults.set(data, forKey: panelsKey)
    }
}

@MainActor
public final class ProviderVisibilityStore: ObservableObject {
    public static let shared = ProviderVisibilityStore()

    private let appGroupID = "group.com.chrisizatt.LLMUsageCounter"
    private let hiddenProvidersKey = "hiddenProviderIDs"

    @Published private var hiddenProviderIDs: Set<ProviderID>

    private var defaults: UserDefaults {
        UserDefaults(suiteName: appGroupID) ?? .standard
    }

    private init() {
        let appGroupID = "group.com.chrisizatt.LLMUsageCounter"
        let defaults = UserDefaults(suiteName: appGroupID) ?? .standard
        let stored = defaults.array(forKey: hiddenProvidersKey) as? [String] ?? []
        self.hiddenProviderIDs = Set(stored.compactMap(ProviderID.init(rawValue:)))
    }

    public func isVisible(_ providerID: ProviderID) -> Bool {
        !hiddenProviderIDs.contains(providerID)
    }

    public func setVisible(_ providerID: ProviderID, _ visible: Bool) {
        if visible {
            hiddenProviderIDs.remove(providerID)
        } else {
            hiddenProviderIDs.insert(providerID)
        }
        save()
        WidgetCenter.shared.reloadAllTimelines()
    }

    public func toggle(_ providerID: ProviderID) {
        setVisible(providerID, !isVisible(providerID))
    }

    public var allVisibleProviderIDs: [ProviderID] {
        ProviderID.userFacingCases.filter { !hiddenProviderIDs.contains($0) }
    }

    public func binding(for providerID: ProviderID) -> Binding<Bool> {
        Binding(
            get: { [weak self] in self?.isVisible(providerID) ?? true },
            set: { [weak self] visible in self?.setVisible(providerID, visible) }
        )
    }

    private func save() {
        let values = ProviderID.allCases.filter { hiddenProviderIDs.contains($0) }.map(\.rawValue)
        defaults.set(values, forKey: hiddenProvidersKey)
        objectWillChange.send()
    }
}

/// Persists the user's preferred dashboard layout — the standard
/// per-provider card list, or the compact stacked-meters view.
/// Mirrors `ProviderVisibilityStore`'s storage pattern so the setting
/// flows through the App Group container and is visible to widgets if
/// they ever need to react to it.
public enum DashboardLayoutMode: String, Codable, CaseIterable {
    case standard
    case compact
}

public final class DashboardLayoutModeStore: ObservableObject {
    public static let shared = DashboardLayoutModeStore()

    private let appGroupID = "group.com.chrisizatt.LLMUsageCounter"
    private let modeKey = "dashboardLayoutMode"

    @Published public private(set) var mode: DashboardLayoutMode

    private var defaults: UserDefaults {
        UserDefaults(suiteName: appGroupID) ?? .standard
    }

    private init() {
        let stored = (UserDefaults(suiteName: appGroupID) ?? .standard).string(forKey: modeKey)
        self.mode = stored.flatMap(DashboardLayoutMode.init(rawValue:)) ?? .standard
    }

    public func setMode(_ newMode: DashboardLayoutMode) {
        guard newMode != mode else { return }
        mode = newMode
        defaults.set(newMode.rawValue, forKey: modeKey)
    }

    public func toggle() {
        setMode(mode == .standard ? .compact : .standard)
    }
}

@MainActor
public final class ProviderCardOrderStore: ObservableObject {
    public static let shared = ProviderCardOrderStore()

    private let appGroupID = "group.com.chrisizatt.LLMUsageCounter"
    private let orderedProvidersKey = "dashboardCardProviderOrder"

    @Published private var orderedProviderIDs: [ProviderID]

    private var defaults: UserDefaults {
        UserDefaults(suiteName: appGroupID) ?? .standard
    }

    private init() {
        let stored = (UserDefaults(suiteName: appGroupID) ?? .standard)
            .array(forKey: orderedProvidersKey) as? [String] ?? []
        self.orderedProviderIDs = Self.normalizedOrder(
            from: stored.compactMap(ProviderID.init(rawValue:))
        )
    }

    public func rank(for providerID: ProviderID) -> Int {
        orderedProviderIDs.firstIndex(of: providerID) ?? Int.max
    }

    /// Provides a way to check rank from non-isolated contexts (like widgets)
    /// without hopping to the MainActor. Reads directly from UserDefaults.
    public nonisolated static func nonisolatedRank(for providerID: ProviderID) -> Int {
        let appGroupID = "group.com.chrisizatt.LLMUsageCounter"
        let orderedProvidersKey = "dashboardCardProviderOrder"
        let stored = (UserDefaults(suiteName: appGroupID) ?? .standard)
            .array(forKey: orderedProvidersKey) as? [String] ?? []

        let currentOrder = ProviderCardOrderStore.normalizedOrder(
            from: stored.compactMap(ProviderID.init(rawValue:))
        )
        return currentOrder.firstIndex(of: providerID) ?? Int.max
    }

    public func move(_ providerID: ProviderID, before targetProviderID: ProviderID) {
        guard providerID != targetProviderID else { return }

        var updatedOrder = Self.normalizedOrder(from: orderedProviderIDs)
        guard
            let sourceIndex = updatedOrder.firstIndex(of: providerID),
            updatedOrder.contains(targetProviderID)
        else {
            return
        }

        updatedOrder.remove(at: sourceIndex)
        let targetIndex = updatedOrder.firstIndex(of: targetProviderID) ?? updatedOrder.endIndex
        updatedOrder.insert(providerID, at: targetIndex)
        orderedProviderIDs = updatedOrder
        save()
    }

    public func syncKnownProviders(_ providerIDs: [ProviderID]) {
        let mergedOrder = Self.normalizedOrder(from: orderedProviderIDs + providerIDs)
        guard mergedOrder != orderedProviderIDs else { return }
        orderedProviderIDs = mergedOrder
        save()
    }

    private func save() {
        defaults.set(orderedProviderIDs.map(\.rawValue), forKey: orderedProvidersKey)
    }

    private nonisolated static func normalizedOrder(from providerIDs: [ProviderID]) -> [ProviderID] {
        var ordered: [ProviderID] = []

        for providerID in providerIDs where providerID.isUserFacingInProviderLists {
            if !ordered.contains(providerID) {
                ordered.append(providerID)
            }
        }

        for providerID in defaultOrder where !ordered.contains(providerID) {
            ordered.append(providerID)
        }

        return ordered
    }

    private nonisolated static let defaultOrder: [ProviderID] = [
        .openai,
        .openaiAPI,
        .claude,
        .chatgpt,
        .windsurf,
        .cursor,
        .gemini,
        .kimi,
        .antigravity,
        .grok,
        .mistral,
        .deepseek,
        .cerebras,
        .meta
    ]
}

@MainActor
public final class ProviderCardDisclosureStore: ObservableObject {
    public static let shared = ProviderCardDisclosureStore()

    private let appGroupID = "group.com.chrisizatt.LLMUsageCounter"
    private let expandedStatePrefix = "providerCardTelemetryExpanded."

    private var defaults: UserDefaults {
        UserDefaults(suiteName: appGroupID) ?? .standard
    }

    private init() {}

    public func isExpanded(for providerID: ProviderID) -> Bool {
        let key = expandedStateKey(for: providerID)
        if defaults.object(forKey: key) == nil {
            return true
        }
        return defaults.bool(forKey: key)
    }

    public func setExpanded(_ expanded: Bool, for providerID: ProviderID) {
        defaults.set(expanded, forKey: expandedStateKey(for: providerID))
        objectWillChange.send()
    }

    public func toggle(_ providerID: ProviderID) {
        setExpanded(!isExpanded(for: providerID), for: providerID)
    }

    public func binding(for providerID: ProviderID) -> Binding<Bool> {
        Binding(
            get: { [weak self] in self?.isExpanded(for: providerID) ?? true },
            set: { [weak self] expanded in self?.setExpanded(expanded, for: providerID) }
        )
    }

    private func expandedStateKey(for providerID: ProviderID) -> String {
        "\(expandedStatePrefix)\(providerID.rawValue)"
    }
}
