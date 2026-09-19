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
    private let maximumConcurrentRefreshes = 3
    private let refreshStartSpacingNanoseconds: UInt64 = 175_000_000

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

    /// Fetches all registered providers with bounded, staggered concurrency.
    /// The progress callback runs on the main actor after each provider lands.
    func syncAll(
        userInitiated: Bool = false,
        onProgress: (([QuotaSnapshot], [ProviderID: String]) -> Void)? = nil
    ) async {
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        syncErrors = [:]

        let storedSnapshots = store.loadSnapshots()
        let previousSnapshots = Dictionary(uniqueKeysWithValues: storedSnapshots.map { ($0.providerID, $0) })
        var mergedSnapshots = previousSnapshots
        let scheduledProviders: [(providerID: ProviderID, client: any ProviderClient)] =
            ProviderID.allCases.compactMap { providerID in
                guard let client = clients[providerID] else { return nil }
                return (providerID, client)
            }
        let startGate = ProviderRefreshStartGate(
            spacingNanoseconds: refreshStartSpacingNanoseconds
        )

        // Keep only a small number of provider requests in flight. The start
        // gate also spaces launches within each rolling chunk so keychain and
        // network work do not arrive as a burst.
        await withTaskGroup(of: (providerID: ProviderID, outcome: ProviderSyncOutcome).self) { group in
            var nextProviderIndex = 0
            let initialCount = min(maximumConcurrentRefreshes, scheduledProviders.count)

            for _ in 0..<initialCount {
                let scheduled = scheduledProviders[nextProviderIndex]
                nextProviderIndex += 1
                group.addTask {
                    await startGate.waitForTurn()
                    let outcome = await self.syncOutcome(
                        providerID: scheduled.providerID,
                        client: scheduled.client,
                        previousSnapshot: previousSnapshots[scheduled.providerID],
                        userInitiated: userInitiated
                    )
                    return (scheduled.providerID, outcome)
                }
            }

            while let (providerID, outcome) = await group.next() {
                mergedSnapshots[providerID] = outcome.snapshot
                applySyncOutcome(outcome)

                if (providerID == .openai || providerID == .codexTelemetry),
                   let coalesced = coalescedCodexUsageSnapshot(in: mergedSnapshots) {
                    mergedSnapshots[.openai] = coalesced
                    store.upsert(coalesced)
                }

                onProgress?(
                    ProviderID.allCases.compactMap { mergedSnapshots[$0] },
                    syncErrors
                )

                if nextProviderIndex < scheduledProviders.count {
                    let scheduled = scheduledProviders[nextProviderIndex]
                    nextProviderIndex += 1
                    group.addTask {
                        await startGate.waitForTurn()
                        let outcome = await self.syncOutcome(
                            providerID: scheduled.providerID,
                            client: scheduled.client,
                            previousSnapshot: previousSnapshots[scheduled.providerID],
                            userInitiated: userInitiated
                        )
                        return (scheduled.providerID, outcome)
                    }
                }
            }
        }

        // Re-run coalescence with the final pair so the atomic final ordering
        // matches every progressive update.
        if let coalesced = coalescedCodexUsageSnapshot(in: mergedSnapshots) {
            mergedSnapshots[.openai] = coalesced
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
        case .antigravity, .mistral, .deepseek, .cerebras, .meta, .ollama, .qwen, .mimo:
            // Local probes, imported sessions, reports, and billing APIs can all miss a
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
        case .qwen, .mimo:
            return 25
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

    private func coalescedCodexUsageSnapshot(
        in snapshots: [ProviderID: QuotaSnapshot]
    ) -> QuotaSnapshot? {
        guard let usage = snapshots[.openai],
              let telemetry = snapshots[.codexTelemetry] else {
            return nil
        }

        let combinedEvents = mergedUsageEventsPreservingHistory(
            current: usage.events,
            previous: telemetry.events
        )
        return QuotaSnapshot(
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
            fetchedAt: max(usage.fetchedAt, telemetry.fetchedAt),
            resetCredits: usage.resetCredits
        )
    }
}

private actor ProviderRefreshStartGate {
    private let spacingNanoseconds: UInt64
    private var nextStartNanoseconds: UInt64 = 0

    init(spacingNanoseconds: UInt64) {
        self.spacingNanoseconds = spacingNanoseconds
    }

    func waitForTurn() async {
        let now = DispatchTime.now().uptimeNanoseconds
        let scheduledStart = max(now, nextStartNanoseconds)
        nextStartNanoseconds = scheduledStart &+ spacingNanoseconds

        guard scheduledStart > now else { return }
        try? await Task.sleep(nanoseconds: scheduledStart - now)
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

/// Runs the reset detector for one provider per sweep and keeps its recent
/// signals on screen for a while.
///
/// The detector itself is pure (`QuotaResetDetector`); this wrapper owns the
/// two pieces of storage around it: the detector state per provider, and the
/// signals it emitted in the last twelve hours, which are replayed into every
/// snapshot so a reset stays visible on the card after the sweep that found
/// it. Confirmed resets also go to the shared ledger.
private struct SnapshotSignalDetector {
    private let appGroupID = "group.com.chrisizatt.LLMUsageCounter"
    private let recentSignalsKey = "recentQuotaSignals"
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let signalRetention: TimeInterval = 12 * 60 * 60
    private let detector = QuotaResetDetector()

    private var defaults: UserDefaults {
        UserDefaults(suiteName: appGroupID) ?? .standard
    }

    init() {
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    @MainActor
    func enrichedSnapshot(from snapshot: QuotaSnapshot, previousSnapshot: QuotaSnapshot?) -> QuotaSnapshot {
        var activeSignals = loadSignals()
        pruneExpiredSignals(&activeSignals, now: snapshot.fetchedAt)

        guard snapshot.fetchState.isHealthy else {
            saveSignals(activeSignals)
            return snapshot.withSignals([])
        }

        let stateStore = QuotaResetDetectorStateStore(defaults: defaults)
        let outcome = detector.observe(snapshot, state: stateStore.state(for: snapshot.providerID))
        stateStore.save(outcome.state, for: snapshot.providerID)
        QuotaResetLedgerStore.shared.record(outcome.events)

        merge(outcome.signals, into: &activeSignals, providerID: snapshot.providerID)
        saveSignals(activeSignals)

        let detectedSignals = (activeSignals[snapshot.providerID.rawValue] ?? [])
            .sorted { $0.detectedAt > $1.detectedAt }

        // Provider clients attach signals of their own — Devin's stale-cache
        // warning, Gemini's and Claude's plan notices — describing the fetch
        // that produced this snapshot. Replacing the snapshot's signals with
        // the detector's threw all of those away before they ever reached the
        // store. They are deliberately *not* written into the persisted
        // detector store either: it replays what it holds for up to 12 hours,
        // which would keep a provider notice on screen long after the provider
        // stopped reporting it. Union them here instead, so a provider signal
        // lasts exactly as long as the provider keeps emitting it.
        return snapshot.mergingSignals(detectedSignals)
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

    /// One live signal per (kind, window, reset kind): a newer reading of the
    /// same thing replaces the older one rather than stacking beneath it.
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
                existing.kind == signal.kind
                    && existing.windowLabel == signal.windowLabel
                    && existing.resetKind == signal.resetKind
            }
            merged.append(signal)
        }

        signals[providerKey] = merged.sorted { $0.detectedAt > $1.detectedAt }
    }
}
