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
        .claude,
        .chatgpt,
        .windsurf,
        .cursor,
        .gemini
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
