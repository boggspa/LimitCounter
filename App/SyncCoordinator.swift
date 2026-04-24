import Foundation
import WidgetKit

/// Orchestrates fetching from all configured providers.
/// Writes results to QuotaSnapshotStore and triggers widget reload.
/// Main app only — never compiled into widget target.
@MainActor
final class SyncCoordinator {

    private(set) var isSyncing = false
    private(set) var lastSyncDate: Date?
    private(set) var syncErrors: [ProviderID: String] = [:]

    private let store: QuotaSnapshotStore
    private let keychain: KeychainService
    private let signalDetector = SnapshotSignalDetector()
    private var clients: [ProviderID: any ProviderClient]

    init(
        store: QuotaSnapshotStore? = nil,
        keychain: KeychainService? = nil,
        clients: [ProviderID: any ProviderClient] = [:]
    ) {
        self.store = store ?? .shared
        self.keychain = keychain ?? .shared
        self.clients = clients
    }

    // MARK: - Client Registration

    func register(_ client: any ProviderClient) {
        clients[client.providerID] = client
    }

    // MARK: - Sync

    /// Fetches all registered providers in display order.
    func syncAll() async {
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        syncErrors = [:]

        let storedSnapshots = store.loadSnapshots()
        let previousSnapshots = Dictionary(uniqueKeysWithValues: storedSnapshots.map { ($0.providerID, $0) })
        var mergedSnapshots = previousSnapshots

        // 1. Fetch all providers concurrently
        await withTaskGroup(of: (providerID: ProviderID, outcome: ProviderSyncOutcome).self) { group in
            for providerID in ProviderID.allCases {
                if let client = clients[providerID] {
                    group.addTask {
                        let outcome = await self.syncOutcome(
                            providerID: providerID,
                            client: client,
                            previousSnapshot: previousSnapshots[providerID]
                        )
                        return (providerID, outcome)
                    }
                }
            }

            for await (providerID, outcome) in group {
                mergedSnapshots[providerID] = outcome.snapshot

                if let errorMessage = outcome.errorMessage {
                    syncErrors[providerID] = errorMessage
                } else {
                    syncErrors.removeValue(forKey: providerID)
                }
            }
        }

        // 2. Coalesce Codex (OpenAI) and Codex Telemetry events
        if let usage = mergedSnapshots[.openai], let telemetry = mergedSnapshots[.codexTelemetry] {
            let combinedEvents = mergedUsageEventsPreservingHistory(
                current: usage.events,
                previous: telemetry.events
            )

            mergedSnapshots[.openai] = QuotaSnapshot(
                id: usage.id,
                providerID: usage.providerID,
                displayName: usage.displayName,
                planName: usage.planName,
                windows: usage.windows,
                stats: usage.stats,
                balances: usage.balances,
                signals: usage.signals,
                events: combinedEvents,
                fetchState: usage.fetchState,
                fetchedAt: max(usage.fetchedAt, telemetry.fetchedAt)
            )
        }

        store.replaceAll(ProviderID.allCases.compactMap { mergedSnapshots[$0] })

        lastSyncDate = Date()

        // Notify WidgetKit to rebuild timelines with fresh data
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// Fetches a single provider.
    func sync(providerID: ProviderID) async {
        print("[SyncCoordinator] Starting sync for \(providerID.rawValue)")

        // Handle Codex/OpenAI coalescence special case
        if providerID == .openai || providerID == .codexTelemetry {
            await syncAll() // Simpler to re-sync both to ensure events are merged correctly
            return
        }

        guard let client = clients[providerID] else {
            print("[SyncCoordinator] No client registered for \(providerID.rawValue)")
            return
        }

        let outcome = await syncOutcome(
            providerID: providerID,
            client: client,
            previousSnapshot: store.snapshot(for: providerID)
        )
        applySyncOutcome(outcome)
        lastSyncDate = Date()

        WidgetCenter.shared.reloadAllTimelines()
        print("[SyncCoordinator] Finished sync for \(providerID.rawValue)")
    }

    // MARK: - Private

    private func syncOutcome(
        providerID: ProviderID,
        client: any ProviderClient,
        previousSnapshot: QuotaSnapshot?
    ) async -> ProviderSyncOutcome {
        let credential = keychain.credential(for: providerID)
        print("[SyncCoordinator] Credential for \(providerID.rawValue): \(credential != nil ? "present" : "nil")")

        // Allow auto-discovery clients (local logs, Windsurf, Cursor, Gemini) to proceed without stored credentials
        let canAutoDiscover =
            client is ClaudeProviderClient
            || client is CodexTelemetryProviderClient
            || client is ChatGPTLocalProviderClient
            || client is WindsurfProviderClient
            || client is CursorProviderClient
            || client is GeminiProviderClient
        guard credential != nil || client is MockProviderClient || canAutoDiscover else {
            print("[SyncCoordinator] No credentials for \(providerID.rawValue), skipping")
            if let preservedSnapshot = preservedSnapshotAfterRefreshMiss(
                providerID: providerID,
                previousSnapshot: previousSnapshot,
                reason: "missing credentials"
            ) {
                return ProviderSyncOutcome(
                    providerID: providerID,
                    snapshot: preservedSnapshot,
                    errorMessage: nil
                )
            }

            return ProviderSyncOutcome(
                providerID: providerID,
                snapshot: QuotaSnapshot(
                    providerID: providerID,
                    displayName: providerID.snapshotDisplayName,
                    planName: nil,
                    windows: [],
                    fetchState: .notConfigured
                ),
                errorMessage: nil
            )
        }

        do {
            print("[SyncCoordinator] Calling fetchSnapshot for \(providerID.rawValue)")
            let snapshot = try await fetchSnapshotWithTimeout(
                providerID: providerID,
                client: client,
                credentials: credential
            )
            print("[SyncCoordinator] Got snapshot for \(providerID.rawValue): \(snapshot.windows.count) windows")
            let historyPreservedSnapshot = snapshotPreservingCodexTelemetryHistory(
                snapshot,
                previousSnapshot: previousSnapshot
            )
            return ProviderSyncOutcome(
                providerID: providerID,
                snapshot: signalDetector.enrichedSnapshot(from: historyPreservedSnapshot, previousSnapshot: previousSnapshot),
                errorMessage: nil
            )
        } catch ProviderFetchError.notConfigured {
            print("[SyncCoordinator] Not configured error for \(providerID.rawValue)")
            if let preservedSnapshot = preservedSnapshotAfterRefreshMiss(
                providerID: providerID,
                previousSnapshot: previousSnapshot,
                reason: "not configured"
            ) {
                return ProviderSyncOutcome(
                    providerID: providerID,
                    snapshot: preservedSnapshot,
                    errorMessage: nil
                )
            }

            return ProviderSyncOutcome(
                providerID: providerID,
                snapshot: QuotaSnapshot(
                    providerID: providerID,
                    displayName: providerID.displayName,
                    planName: nil,
                    windows: [],
                    fetchState: .notConfigured
                ),
                errorMessage: nil
            )
        } catch {
            let message = (error as? ProviderFetchError)?.errorDescription
                ?? error.localizedDescription
            print("[SyncCoordinator] Error for \(providerID.rawValue): \(message)")

            if let preservedSnapshot = preservedSnapshotAfterRefreshMiss(
                providerID: providerID,
                previousSnapshot: previousSnapshot,
                reason: message
            ) {
                return ProviderSyncOutcome(
                    providerID: providerID,
                    snapshot: preservedSnapshot,
                    errorMessage: message
                )
            }

            // Write an error-state snapshot so UI reflects the failure
            let errSnap = QuotaSnapshot(
                providerID: providerID,
                displayName: providerID.snapshotDisplayName,
                planName: nil,
                windows: [],
                fetchState: .error
            )
            return ProviderSyncOutcome(
                providerID: providerID,
                snapshot: errSnap,
                errorMessage: message
            )
        }
    }

    private func preservedSnapshotAfterRefreshMiss(
        providerID: ProviderID,
        previousSnapshot: QuotaSnapshot?,
        reason: String
    ) -> QuotaSnapshot? {
        guard providerID == .codexTelemetry,
              let previousSnapshot,
              previousSnapshot.fetchState == .success,
              previousSnapshot.hasContent else {
            return nil
        }

        print("[SyncCoordinator] Preserving previous Codex telemetry snapshot after refresh miss: \(reason)")
        return previousSnapshot
    }

    private func fetchSnapshotWithTimeout(
        providerID: ProviderID,
        client: any ProviderClient,
        credentials: ProviderCredential?
    ) async throws -> QuotaSnapshot {
        let timeout = providerTimeout(for: providerID)

        return try await withCheckedThrowingContinuation { continuation in
            let state = TimeoutRaceState(continuation)
            let fetchTask = Task {
                do {
                    let snapshot = try await client.fetchSnapshot(credentials: credentials)
                    _ = state.resume(with: .success(snapshot))
                } catch {
                    _ = state.resume(with: .failure(error))
                }
            }

            Task {
                try? await Task.sleep(for: .seconds(timeout))
                let didResume = state.resume(
                    with: .failure(
                        ProviderFetchError.parsingError(
                            "\(providerID.displayName) refresh timed out after \(Int(timeout)) seconds."
                        )
                    )
                )
                if didResume {
                    fetchTask.cancel()
                }
            }
        }
    }

    private func providerTimeout(for providerID: ProviderID) -> TimeInterval {
        switch providerID {
        case .codexTelemetry:
            return 10
        case .claude, .chatgpt, .gemini:
            return 15
        case .openai, .windsurf, .cursor:
            return 20
        case .heatmap:
            return 5
        }
    }

    private func snapshotPreservingCodexTelemetryHistory(
        _ snapshot: QuotaSnapshot,
        previousSnapshot: QuotaSnapshot?
    ) -> QuotaSnapshot {
        guard snapshot.providerID == .codexTelemetry,
              snapshot.fetchState == .success,
              let previousSnapshot,
              previousSnapshot.fetchState == .success,
              !previousSnapshot.events.isEmpty else {
            return snapshot
        }

        let mergedEvents = mergedUsageEventsPreservingHistory(
            current: snapshot.events,
            previous: previousSnapshot.events
        )
        guard mergedEvents != snapshot.events else {
            return snapshot
        }

        print("[SyncCoordinator] Preserved Codex telemetry history: \(snapshot.events.count) current events, \(previousSnapshot.events.count) previous events, \(mergedEvents.count) retained")
        return snapshot.withEvents(mergedEvents)
    }

    private func mergedUsageEventsPreservingHistory(
        current: [UsageEvent],
        previous: [UsageEvent],
        now: Date = Date(),
        retention: TimeInterval = 35 * 24 * 60 * 60,
        maxEvents: Int = 5_000
    ) -> [UsageEvent] {
        let cutoff = now.addingTimeInterval(-retention)
        var seenIDs = Set<UUID>()
        var seenKeys = Set<UsageEventSemanticKey>()
        var merged: [UsageEvent] = []

        for event in current + previous {
            guard event.timestamp >= cutoff else { continue }

            let semanticKey = UsageEventSemanticKey(event: event)
            guard seenIDs.insert(event.id).inserted,
                  seenKeys.insert(semanticKey).inserted else {
                continue
            }

            merged.append(event)
        }

        return Array(merged.sorted { $0.timestamp > $1.timestamp }.prefix(maxEvents))
    }

    private func applySyncOutcome(_ outcome: ProviderSyncOutcome) {
        if let errorMessage = outcome.errorMessage {
            syncErrors[outcome.providerID] = errorMessage
        } else {
            syncErrors.removeValue(forKey: outcome.providerID)
        }

        store.upsert(outcome.snapshot)
    }
}

private final class TimeoutRaceState<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?

    init(_ continuation: CheckedContinuation<Value, Error>) {
        self.continuation = continuation
    }

    func resume(with result: Result<Value, Error>) -> Bool {
        lock.lock()
        guard let continuation else {
            lock.unlock()
            return false
        }
        self.continuation = nil
        lock.unlock()

        continuation.resume(with: result)
        return true
    }
}

private struct UsageEventSemanticKey: Hashable {
    let timestampBucket: Int64
    let tokenBucket: Int64
    let model: String
    let type: UsageEvent.EventType

    init(event: UsageEvent) {
        timestampBucket = Int64((event.timestamp.timeIntervalSince1970 * 1_000).rounded())
        tokenBucket = Int64(((event.tokens ?? -1) * 1_000).rounded())
        model = (event.model ?? "").lowercased()
        type = event.type
    }
}

private struct ProviderSyncOutcome {
    let providerID: ProviderID
    let snapshot: QuotaSnapshot
    let errorMessage: String?
}

private struct SnapshotSignalDetector {
    private let appGroupID = "group.com.chrisizatt.LLMUsageCounter"
    private let recentSignalsKey = "recentQuotaSignals"
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private let minimumObservationGap: TimeInterval = 5 * 60
    private let minimumRemainingWindow: TimeInterval = 30 * 60
    private let minimumEarlyLead: TimeInterval = 20 * 60
    private let maximumElapsedShare = 0.5
    private let minimumFractionDrop = 0.35
    private let strongRecoveryFloor = 0.55
    private let signalRetention: TimeInterval = 12 * 60 * 60

    private var defaults: UserDefaults {
        UserDefaults(suiteName: appGroupID) ?? .standard
    }

    init() {
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    func enrichedSnapshot(from snapshot: QuotaSnapshot, previousSnapshot: QuotaSnapshot?) -> QuotaSnapshot {
        var activeSignals = loadSignals()
        pruneExpiredSignals(&activeSignals, now: snapshot.fetchedAt)

        let newSignals = detectSignals(current: snapshot, previous: previousSnapshot)
        merge(newSignals, into: &activeSignals, providerID: snapshot.providerID)
        saveSignals(activeSignals)

        guard snapshot.fetchState.isHealthy else {
            return snapshot.withSignals([])
        }

        let providerSignals = (activeSignals[snapshot.providerID.rawValue] ?? [])
            .sorted { $0.detectedAt > $1.detectedAt }

        return snapshot.withSignals(providerSignals)
    }

    private func detectSignals(current: QuotaSnapshot, previous: QuotaSnapshot?) -> [QuotaSignal] {
        guard current.fetchState.isHealthy,
              let previous,
              previous.fetchState.isHealthy,
              current.providerID == previous.providerID else {
            return []
        }

        let elapsed = current.fetchedAt.timeIntervalSince(previous.fetchedAt)
        guard elapsed >= minimumObservationGap else {
            return []
        }

        let previousWindows: [WindowComparisonKey: QuotaWindow] = Dictionary(
            uniqueKeysWithValues: previous.windows.compactMap { window -> (WindowComparisonKey, QuotaWindow)? in
            guard window.hasExplicitLimit, let total = window.total, total > 0 else { return nil }
            return (WindowComparisonKey(window: window), window)
        })

        return current.windows.compactMap { currentWindow in
            let key = WindowComparisonKey(window: currentWindow)
            guard let previousWindow = previousWindows[key] else { return nil }
            return unexpectedRecoverySignal(
                currentWindow: currentWindow,
                previousWindow: previousWindow,
                currentDate: current.fetchedAt,
                previousDate: previous.fetchedAt
            )
        }
    }

    private func unexpectedRecoverySignal(
        currentWindow: QuotaWindow,
        previousWindow: QuotaWindow,
        currentDate: Date,
        previousDate: Date
    ) -> QuotaSignal? {
        guard currentWindow.hasExplicitLimit,
              previousWindow.hasExplicitLimit,
              let currentTotal = currentWindow.total,
              let previousTotal = previousWindow.total,
              currentTotal > 0,
              previousTotal > 0 else {
            return nil
        }

        let totalDelta = abs(currentTotal - previousTotal)
        guard totalDelta <= max(1, previousTotal * 0.05) else {
            return nil
        }

        guard let previousResetDate = previousWindow.resetDate else {
            return nil
        }

        let elapsed = currentDate.timeIntervalSince(previousDate)
        let previousRemaining = previousResetDate.timeIntervalSince(previousDate)

        guard previousRemaining >= minimumRemainingWindow else {
            return nil
        }

        let elapsedShare = elapsed / previousRemaining
        guard elapsedShare < maximumElapsedShare else {
            return nil
        }

        let fractionDrop = previousWindow.fractionUsed - currentWindow.fractionUsed
        let strongRecovery = currentWindow.fractionUsed <= 0.20
            || fractionDrop >= strongRecoveryFloor
            || currentWindow.used <= previousWindow.used * 0.4

        guard previousWindow.fractionUsed >= 0.50,
              fractionDrop >= minimumFractionDrop,
              strongRecovery else {
            return nil
        }

        let earlyLead = previousRemaining - elapsed
        guard earlyLead >= minimumEarlyLead else {
            return nil
        }

        let confidence = signalConfidence(
            fractionDrop: fractionDrop,
            elapsedShare: elapsedShare,
            currentWindow: currentWindow
        )

        let recoveryTitle: String = currentWindow.fractionUsed <= 0.10
            ? "Usage window appears refreshed early"
            : "Unexpected quota recovery detected"

        var message = "\(currentWindow.label) fell from \(previousWindow.percentageUsed)% to \(currentWindow.percentageUsed)% about \(durationDescription(earlyLead)) earlier than the prior reset estimate."

        if let currentResetDate = currentWindow.resetDate {
            let resetShift = currentResetDate.timeIntervalSince(previousResetDate)
            if abs(resetShift) >= 30 * 60 {
                if resetShift < 0 {
                    message += " The reset estimate also moved earlier."
                } else {
                    message += " The reset estimate also restarted from a later point."
                }
            }
        }

        return QuotaSignal(
            kind: .unexpectedRecovery,
            title: recoveryTitle,
            message: message,
            severity: confidence >= 0.8 ? .warning : .info,
            confidence: confidence,
            windowLabel: currentWindow.label,
            detectedAt: currentDate
        )
    }

    private func signalConfidence(
        fractionDrop: Double,
        elapsedShare: Double,
        currentWindow: QuotaWindow
    ) -> Double {
        let recoveryScore = min(max(fractionDrop / 0.75, 0), 1)
        let earlinessScore = min(max(1 - elapsedShare, 0), 1)
        let freshnessScore = currentWindow.fractionUsed <= 0.10 ? 1.0 : 0.7

        return min(0.95, max(0.55, 0.30 + recoveryScore * 0.35 + earlinessScore * 0.25 + freshnessScore * 0.10))
    }

    private func durationDescription(_ interval: TimeInterval) -> String {
        let totalMinutes = max(Int(interval / 60), 1)
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60

        if hours > 0 && minutes > 0 {
            return "\(hours)h \(minutes)m"
        }
        if hours > 0 {
            return "\(hours)h"
        }
        return "\(minutes)m"
    }

    private func loadSignals() -> [String: [QuotaSignal]] {
        guard let data = defaults.data(forKey: recentSignalsKey),
              let decoded = try? decoder.decode([String: [QuotaSignal]].self, from: data) else {
            return [:]
        }

        return decoded
    }

    private func saveSignals(_ signals: [String: [QuotaSignal]]) {
        guard let data = try? encoder.encode(signals) else { return }
        defaults.set(data, forKey: recentSignalsKey)
    }

    private func pruneExpiredSignals(_ signals: inout [String: [QuotaSignal]], now: Date) {
        for key in signals.keys {
            let filtered = (signals[key] ?? []).filter { now.timeIntervalSince($0.detectedAt) <= signalRetention }
            if filtered.isEmpty {
                signals.removeValue(forKey: key)
            } else {
                signals[key] = filtered
            }
        }
    }

    private func merge(
        _ newSignals: [QuotaSignal],
        into signals: inout [String: [QuotaSignal]],
        providerID: ProviderID
    ) {
        guard !newSignals.isEmpty else { return }

        let providerKey = providerID.rawValue
        var merged = signals[providerKey] ?? []

        for signal in newSignals {
            merged.removeAll { existing in
                existing.kind == signal.kind && existing.windowLabel == signal.windowLabel
            }
            merged.append(signal)
        }

        signals[providerKey] = merged.sorted { $0.detectedAt > $1.detectedAt }
    }
}

private struct WindowComparisonKey: Hashable, Equatable {
    let label: String
    let windowKind: QuotaWindowKind
    let unit: String

    init(window: QuotaWindow) {
        self.label = window.label
        self.windowKind = window.windowKind
        self.unit = window.unit
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(label)
        hasher.combine(windowKind)
        hasher.combine(unit)
    }

    static func == (lhs: WindowComparisonKey, rhs: WindowComparisonKey) -> Bool {
        lhs.label == rhs.label && lhs.windowKind == rhs.windowKind && lhs.unit == rhs.unit
    }
}
