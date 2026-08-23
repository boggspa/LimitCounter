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
    func syncAll(userInitiated: Bool = false) async {
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
                            previousSnapshot: previousSnapshots[providerID],
                            userInitiated: userInitiated
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
    func sync(providerID: ProviderID, userInitiated: Bool = true) async {
        print("[SyncCoordinator] Starting sync for \(providerID.rawValue)")

        // Handle Codex/OpenAI coalescence special case
        if providerID == .openai || providerID == .codexTelemetry {
            await syncAll(userInitiated: userInitiated) // Simpler to re-sync both to ensure events are merged correctly
            return
        }

        guard let client = clients[providerID] else {
            print("[SyncCoordinator] No client registered for \(providerID.rawValue)")
            return
        }

        let outcome = await syncOutcome(
            providerID: providerID,
            client: client,
            previousSnapshot: store.snapshot(for: providerID),
            userInitiated: userInitiated
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
        previousSnapshot: QuotaSnapshot?,
        userInitiated: Bool
    ) async -> ProviderSyncOutcome {
        let credential = keychain.credential(for: providerID)
        print("[SyncCoordinator] Credential for \(providerID.rawValue): \(credential != nil ? "present" : "nil")")

        // Allow auto-discovery clients (local logs, Devin, Cursor,
        // Gemini, Grok) to proceed without stored credentials. Grok can
        // run from the local ~/.grok CLI folder in development builds or
        // fall back to TaskWraith activity data when that bookmark exists.
        let canAutoDiscover =
            client is ClaudeProviderClient
            || client is CodexTelemetryProviderClient
            || client is ChatGPTLocalProviderClient
            || client is DevinProviderClient
            || client is CursorProviderClient
            || client is GeminiProviderClient
            || client is GrokProviderClient
            || client is AntigravityProviderClient
            || client is MistralProviderClient
            || client is CerebrasProviderClient
            || client is MetaProviderClient
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
                credentials: credential,
                userInitiated: userInitiated
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
        } catch ProviderFetchError.credentialExpired(let message) {
            print("[SyncCoordinator] Expired credential for \(providerID.rawValue): \(message)")
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

            return ProviderSyncOutcome(
                providerID: providerID,
                snapshot: QuotaSnapshot(
                    providerID: providerID,
                    displayName: providerID.snapshotDisplayName,
                    planName: nil,
                    windows: [],
                    fetchState: .notConfigured
                ),
                errorMessage: message
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
        guard let previousSnapshot,
              previousSnapshot.fetchState == .success,
              previousSnapshot.hasContent else {
            return nil
        }

        let shouldPreserve: Bool
        switch providerID {
        case .codexTelemetry:
            shouldPreserve = true
        case .claude:
            shouldPreserve = true
        case .openai:
            // A transient Codex usage decode/network miss should keep the last
            // good card rather than blanking every meter to "Update failed".
            shouldPreserve = true
        case .kimi:
            // Kimi OAuth tokens rotate every 15 minutes. Permission, network,
            // refresh, and token-race failures must not erase the last good
            // quota snapshot while the user repairs or retries the session.
            shouldPreserve = true
        case .antigravity, .mistral, .deepseek, .cerebras, .meta, .ollama:
            // Local probes, imported reports, and billing APIs can all miss a
            // refresh transiently. Keep the last truthful reading visible.
            shouldPreserve = true
        default:
            shouldPreserve = false
        }

        guard shouldPreserve else { return nil }

        print("[SyncCoordinator] Preserving previous \(providerID.rawValue) snapshot after refresh miss: \(reason)")
        return previousSnapshot
    }

    private func fetchSnapshotWithTimeout(
        providerID: ProviderID,
        client: any ProviderClient,
        credentials: ProviderCredential?,
        userInitiated: Bool
    ) async throws -> QuotaSnapshot {
        let timeout = providerTimeout(for: providerID)

        return try await withCheckedThrowingContinuation { continuation in
            let state = TimeoutRaceState(continuation)
            let fetchTask = Task {
                do {
                    let snapshot: QuotaSnapshot
                    if let interactiveClient = client as? any UserInitiatedProviderClient {
                        snapshot = try await interactiveClient.fetchSnapshot(
                            credentials: credentials,
                            userInitiated: userInitiated
                        )
                    } else {
                        snapshot = try await client.fetchSnapshot(credentials: credentials)
                    }
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
            return 30
        case .claude, .chatgpt, .gemini, .ollama:
            return 15
        case .openai, .openaiAPI, .devin, .cursor, .kimi, .grok,
             .mistral, .deepseek, .cerebras, .meta, .openrouter:
            return 20
        case .antigravity:
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
        maxEvents: Int = 5_000,
        maxPerHeatmapBucket: Int = 8
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

        // Re-apply the provider's per-2h-bucket cap to the merged set.
        // Without this, each fetch picks a slightly different "newest 8"
        // for dense recent buckets — stable IDs + unique semantic keys
        // mean those distinct events all survive deduplication and
        // accumulate over time. Heavy recent days balloon past 8 events
        // per bucket, monopolize the global `maxEvents` quota via the
        // newest-first `prefix`, and shove older days off the heatmap.
        // Capping per bucket here bounds total events at
        // 8 × 12 × 35 = 3360 and guarantees the full retention window
        // gets to be represented regardless of how dense recent activity
        // is.
        let sorted = merged.sorted { $0.timestamp > $1.timestamp }
        let calendar = Calendar.current
        var bucketCounts: [HeatmapBucketKey: Int] = [:]
        var capped: [UsageEvent] = []
        capped.reserveCapacity(min(sorted.count, maxEvents))

        for event in sorted {
            let key = HeatmapBucketKey(timestamp: event.timestamp, calendar: calendar)
            guard bucketCounts[key, default: 0] < maxPerHeatmapBucket else {
                continue
            }
            bucketCounts[key, default: 0] += 1
            capped.append(event)
            if capped.count >= maxEvents { break }
        }

        return capped
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

/// 2-hour-row × day bucket used to apply the heatmap's per-cell cap when
/// merging Codex telemetry history. Matches `CodexTelemetryBucketKey` in
/// CodexTelemetryProviderClient — kept as a separate private struct here
/// rather than imported, so SyncCoordinator stays self-contained.
private struct HeatmapBucketKey: Hashable {
    let dayStart: Date
    let row: Int

    init(timestamp: Date, calendar: Calendar) {
        dayStart = calendar.startOfDay(for: timestamp)
        row = calendar.component(.hour, from: timestamp) / 2
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
        discardUnreliableKimiRecoverySignals(&activeSignals, current: snapshot)

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

    private func discardUnreliableKimiRecoverySignals(
        _ signals: inout [String: [QuotaSignal]],
        current: QuotaSnapshot
    ) {
        guard current.providerID == .kimi, current.fetchState.isHealthy else { return }

        let providerKey = ProviderID.kimi.rawValue
        let filtered = (signals[providerKey] ?? []).filter { $0.kind != .unexpectedRecovery }
        if filtered.isEmpty {
            signals.removeValue(forKey: providerKey)
        } else {
            signals[providerKey] = filtered
        }
    }

    private func detectSignals(current: QuotaSnapshot, previous: QuotaSnapshot?) -> [QuotaSignal] {
        guard current.fetchState.isHealthy,
              let previous,
              previous.fetchState.isHealthy,
              current.providerID == previous.providerID else {
            return []
        }

        let elapsed = current.fetchedAt.timeIntervalSince(previous.fetchedAt)
        guard elapsed > 0 else {
            return []
        }
        if current.providerID != .openai, elapsed < minimumObservationGap {
            return []
        }

        let previousWindows: [WindowComparisonKey: QuotaWindow] = Dictionary(
            uniqueKeysWithValues: previous.windows.compactMap { window -> (WindowComparisonKey, QuotaWindow)? in
            guard window.hasExplicitLimit, let total = window.total, total > 0 else { return nil }
            return (WindowComparisonKey(window: window), window)
        })

        return current.windows.flatMap { currentWindow -> [QuotaSignal] in
            let key = WindowComparisonKey(window: currentWindow)
            guard let previousWindow = previousWindows[key] else { return [] }
            if let signal = scheduledResetSignal(
                currentWindow: currentWindow,
                previousWindow: previousWindow,
                currentDate: current.fetchedAt,
                previousDate: previous.fetchedAt
            ) {
                return [signal]
            }
            // Kimi overloads a full `remaining` value to represent an active
            // lockout, so only its scheduled reset transition is trustworthy.
            if current.providerID != .kimi, let signal = unexpectedRecoverySignal(
                currentWindow: currentWindow,
                previousWindow: previousWindow,
                currentDate: current.fetchedAt,
                previousDate: previous.fetchedAt,
                allowResetWindowRestart: current.providerID == .openai
            ) {
                return [signal]
            }
            return []
        }
    }

    private func scheduledResetSignal(
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

        guard let previousResetDate = previousWindow.resetDate,
              previousResetDate <= currentDate else {
            return nil
        }

        let elapsed = currentDate.timeIntervalSince(previousDate)
        guard elapsed <= 6 * 60 * 60 else {
            return nil
        }

        let previousFraction = recordedFractionUsed(previousWindow)
        let currentFraction = recordedFractionUsed(currentWindow)

        guard previousFraction >= 0.40 else {
            return nil
        }

        guard currentFraction <= 0.10 else {
            return nil
        }

        let previousPercentage = percentageUsed(previousFraction)
        let currentPercentage = percentageUsed(currentFraction)
        let message: String
        if let newReset = currentWindow.resetDate {
            let resetIn = durationDescription(newReset.timeIntervalSince(currentDate))
            message = "Quota refreshed from \(previousPercentage)% to \(currentPercentage)%. Next reset in \(resetIn)."
        } else {
            message = "Quota refreshed from \(previousPercentage)% to \(currentPercentage)%."
        }

        return QuotaSignal(
            kind: .scheduledReset,
            title: "\(currentWindow.label) reset",
            message: message,
            severity: .info,
            confidence: 0.95,
            windowLabel: currentWindow.label,
            detectedAt: currentDate
        )
    }

    private func unexpectedRecoverySignal(
        currentWindow: QuotaWindow,
        previousWindow: QuotaWindow,
        currentDate: Date,
        previousDate: Date,
        allowResetWindowRestart: Bool
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

        let previousFraction = recordedFractionUsed(previousWindow)
        let currentFraction = recordedFractionUsed(currentWindow)
        let fractionDrop = previousFraction - currentFraction
        let resetToZeroEarly = currentFraction <= 0.01
            && currentWindow.used <= max(1, currentTotal * 0.01)
            && previousFraction >= 0.08
            && fractionDrop >= 0.08
        let strongRecovery = currentFraction <= 0.20
            || fractionDrop >= strongRecoveryFloor
            || currentWindow.used <= previousWindow.used * 0.4

        let strongDropRecovery = previousFraction >= 0.50
            && fractionDrop >= minimumFractionDrop
            && strongRecovery

        let resetWindowRestarted: Bool
        if allowResetWindowRestart,
           let currentResetDate = currentWindow.resetDate {
            resetWindowRestarted = currentFraction <= 0.10
                && currentResetDate.timeIntervalSince(previousResetDate) >= minimumEarlyLead
                && currentResetDate > currentDate
        } else {
            resetWindowRestarted = false
        }

        guard resetToZeroEarly || strongDropRecovery || resetWindowRestarted else {
            return nil
        }

        let earlyLead = previousRemaining - elapsed
        guard earlyLead >= minimumEarlyLead else {
            return nil
        }

        let confidence = signalConfidence(
            fractionDrop: fractionDrop,
            elapsedShare: elapsedShare,
            currentFraction: currentFraction,
            resetWindowRestarted: resetWindowRestarted
        )

        let recoveryTitle: String
        var message: String
        if resetWindowRestarted {
            recoveryTitle = "Usage window reset early"
            message = "\(currentWindow.label) reset window restarted at \(percentageUsed(currentFraction))% used about \(durationDescription(earlyLead)) earlier than the prior reset estimate."
        } else if resetToZeroEarly {
            recoveryTitle = "Usage window reset early"
            message = "\(currentWindow.label) reset from \(percentageUsed(previousFraction))% to 0% about \(durationDescription(earlyLead)) earlier than the prior reset estimate."
        } else {
            recoveryTitle = currentFraction <= 0.10
                ? "Usage window appears refreshed early"
                : "Unexpected quota recovery detected"
            message = "\(currentWindow.label) fell from \(percentageUsed(previousFraction))% to \(percentageUsed(currentFraction))% about \(durationDescription(earlyLead)) earlier than the prior reset estimate."
        }

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
        currentFraction: Double,
        resetWindowRestarted: Bool
    ) -> Double {
        if resetWindowRestarted {
            return 0.95
        }

        let recoveryScore = min(max(fractionDrop / 0.75, 0), 1)
        let earlinessScore = min(max(1 - elapsedShare, 0), 1)
        let freshnessScore = currentFraction <= 0.10 ? 1.0 : 0.7

        return min(0.95, max(0.55, 0.30 + recoveryScore * 0.35 + earlinessScore * 0.25 + freshnessScore * 0.10))
    }

    private func recordedFractionUsed(_ window: QuotaWindow) -> Double {
        guard let total = window.total, total > 0 else { return 0 }
        return min(max(window.used / total, 0), 1)
    }

    private func percentageUsed(_ fraction: Double) -> Int {
        Int((min(max(fraction, 0), 1) * 100).rounded())
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
