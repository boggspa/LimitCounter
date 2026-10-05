import Foundation
import OSLog
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
    /// Provider refresh failures, which `print` loses once the app is
    /// launched from Finder.
    private static let logger = Logger(subsystem: "com.chrisizatt.LLMUsageCounter", category: "sync")

    /// Kimi's messages are written by `KimiProviderClient` and never carry
    /// request or token material, so they are logged readable. Other
    /// providers' messages can quote response bodies and stay redacted.
    private static func logRefreshFailure(_ providerID: ProviderID, _ message: String) {
        if providerID == .kimi {
            logger.error("kimi refresh failed: \(message, privacy: .public)")
        } else {
            logger.error("\(providerID.rawValue, privacy: .public) refresh failed: \(message, privacy: .private)")
        }
    }
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
        let previousSnapshots = Dictionary(
            storedSnapshots.map { ($0.accountKey, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var mergedSnapshots = previousSnapshots
        let scheduledAccounts = scheduledAccounts()
        let startGate = ProviderRefreshStartGate(
            spacingNanoseconds: refreshStartSpacingNanoseconds
        )

        // Keep only a small number of account requests in flight. The start
        // gate also spaces launches within each rolling chunk so keychain and
        // network work do not arrive as a burst.
        await withTaskGroup(of: (account: ProviderAccountKey, outcome: ProviderSyncOutcome).self) { group in
            var nextAccountIndex = 0
            let initialCount = min(maximumConcurrentRefreshes, scheduledAccounts.count)

            for _ in 0..<initialCount {
                let scheduled = scheduledAccounts[nextAccountIndex]
                nextAccountIndex += 1
                group.addTask {
                    await startGate.waitForTurn()
                    let outcome = await self.syncOutcome(
                        account: scheduled.account,
                        client: scheduled.client,
                        previousSnapshot: previousSnapshots[scheduled.account],
                        userInitiated: userInitiated
                    )
                    return (scheduled.account, outcome)
                }
            }

            while let (account, outcome) = await group.next() {
                mergedSnapshots[account] = outcome.snapshot
                applySyncOutcome(outcome)

                if account.isPrimary,
                   (account.providerID == .openai || account.providerID == .codexTelemetry),
                   let coalesced = coalescedCodexUsageSnapshot(in: mergedSnapshots) {
                    mergedSnapshots[.primary(.openai)] = coalesced
                    store.upsert(coalesced)
                }

                onProgress?(orderedSnapshots(mergedSnapshots), syncErrors)

                if nextAccountIndex < scheduledAccounts.count {
                    let scheduled = scheduledAccounts[nextAccountIndex]
                    nextAccountIndex += 1
                    group.addTask {
                        await startGate.waitForTurn()
                        let outcome = await self.syncOutcome(
                            account: scheduled.account,
                            client: scheduled.client,
                            previousSnapshot: previousSnapshots[scheduled.account],
                            userInitiated: userInitiated
                        )
                        return (scheduled.account, outcome)
                    }
                }
            }
        }

        // Re-run coalescence with the final pair so the atomic final ordering
        // matches every progressive update.
        if let coalesced = coalescedCodexUsageSnapshot(in: mergedSnapshots) {
            mergedSnapshots[.primary(.openai)] = coalesced
        }

        store.replaceAll(orderedSnapshots(mergedSnapshots))

        lastSyncDate = Date()

        // Notify WidgetKit to rebuild timelines with fresh data
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// Fetches every account of a single provider.
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

        // This provider's errors are about to be re-derived from scratch.
        syncErrors.removeValue(forKey: providerID)
        for account in accountKeys(for: providerID) {
            let outcome = await syncOutcome(
                account: account,
                client: client,
                previousSnapshot: store.snapshot(for: account),
                userInitiated: userInitiated
            )
            applySyncOutcome(outcome)
        }
        lastSyncDate = Date()

        WidgetCenter.shared.reloadAllTimelines()
        print("[SyncCoordinator] Finished sync for \(providerID.rawValue)")
    }

    // MARK: - Accounts

    /// Every account the sweep refreshes, in dashboard order: each registered
    /// provider's primary account, then the secondary accounts the user added
    /// under it. A provider that cannot hold extra accounts contributes only
    /// its primary, whatever the registry says.
    private func scheduledAccounts() -> [(account: ProviderAccountKey, client: any ProviderClient)] {
        ProviderID.allCases.flatMap { providerID -> [(account: ProviderAccountKey, client: any ProviderClient)] in
            guard let client = clients[providerID] else { return [] }
            return accountKeys(for: providerID).map { ($0, client) }
        }
    }

    private func accountKeys(for providerID: ProviderID) -> [ProviderAccountKey] {
        guard providerID.supportsAdditionalAccounts else { return [.primary(providerID)] }
        return ProviderAccountRegistry.shared.keys(for: providerID)
    }

    /// Provider order first, then primary before secondaries in the order they
    /// were added. Snapshots for accounts no longer in the registry (removed
    /// while a sweep was in flight) drop out here rather than lingering.
    private func orderedSnapshots(_ merged: [ProviderAccountKey: QuotaSnapshot]) -> [QuotaSnapshot] {
        ProviderID.allCases.flatMap { providerID -> [QuotaSnapshot] in
            accountKeys(for: providerID).compactMap { merged[$0] }
        }
    }

    /// Files the outcome under the account the sweep scheduled. Provider
    /// clients know nothing about slots, so every snapshot they return — and
    /// every placeholder written on their behalf — is stamped here.
    private func stamped(_ outcome: ProviderSyncOutcome, credential: ProviderCredential?) -> ProviderSyncOutcome {
        let account = outcome.account
        let label = account.isPrimary ? nil : ProviderAccountRegistry.shared.label(for: account)
        let fingerprint = outcome.snapshot.accountFingerprint
            ?? Self.derivedFingerprint(for: account.providerID, credential: credential)
        return ProviderSyncOutcome(
            account: account,
            snapshot: outcome.snapshot.withAccount(slot: account.slot, label: label, fingerprint: fingerprint),
            errorMessage: outcome.errorMessage
        )
    }

    /// Providers that report no identity of their own get one from the account
    /// identifier the credential carries (Codex's ChatGPT account id, an OpenAI
    /// project id, a Cursor team id). Claude's `accountIdentifier` field holds a
    /// pasted token, never an identity, so it is excluded.
    static func derivedFingerprint(for providerID: ProviderID, credential: ProviderCredential?) -> String? {
        guard providerID != .claude,
              let identifier = credential?.normalizedAccountIdentifier,
              !identifier.isEmpty else {
            return nil
        }
        return ProviderAccountFingerprint.make(providerID: providerID, components: [identifier])
    }

    // MARK: - Private

    private func syncOutcome(
        account: ProviderAccountKey,
        client: any ProviderClient,
        previousSnapshot: QuotaSnapshot?,
        userInitiated: Bool
    ) async -> ProviderSyncOutcome {
        let credential = keychain.credential(for: account)
        return stamped(
            await rawSyncOutcome(
                account: account,
                client: client,
                credential: credential,
                previousSnapshot: previousSnapshot,
                userInitiated: userInitiated
            ),
            credential: credential
        )
    }

    private func rawSyncOutcome(
        account: ProviderAccountKey,
        client: any ProviderClient,
        credential: ProviderCredential?,
        previousSnapshot: QuotaSnapshot?,
        userInitiated: Bool
    ) async -> ProviderSyncOutcome {
        let providerID = account.providerID
        print("[SyncCoordinator] Credential for \(account.rawValue): \(credential != nil ? "present" : "nil")")

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
        // A secondary account has no ambient source: it exists only through
        // the credential (folder grant, session, token) the user gave it.
        guard credential != nil || (account.isPrimary && (client is MockProviderClient || canAutoDiscover)) else {
            print("[SyncCoordinator] No credentials for \(providerID.rawValue), skipping")
            if let preservedSnapshot = preservedSnapshotAfterRefreshMiss(
                providerID: providerID,
                previousSnapshot: previousSnapshot,
                reason: "missing credentials"
            ) {
                return ProviderSyncOutcome(
                    account: account,
                    snapshot: preservedSnapshot,
                    errorMessage: nil
                )
            }

            return ProviderSyncOutcome(
                account: account,
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
                account: account,
                client: client,
                credentials: credential,
                userInitiated: userInitiated
            )
            print("[SyncCoordinator] Got snapshot for \(providerID.rawValue): \(snapshot.windows.count) windows")
            let historyPreservedSnapshot = snapshotPreservingCodexTelemetryHistory(
                snapshot,
                previousSnapshot: previousSnapshot
            )
            // A snapshot written without one of the provider's sources still
            // says why, beside the fresh card.
            let partialWarning = await (client as? any ProviderPartialRefreshReporting)?
                .takePartialRefreshWarning()
            return ProviderSyncOutcome(
                account: account,
                snapshot: signalDetector.enrichedSnapshot(from: historyPreservedSnapshot, previousSnapshot: previousSnapshot),
                errorMessage: partialWarning
            )
        } catch ProviderFetchError.notConfigured {
            print("[SyncCoordinator] Not configured error for \(providerID.rawValue)")
            if let preservedSnapshot = preservedSnapshotAfterRefreshMiss(
                providerID: providerID,
                previousSnapshot: previousSnapshot,
                reason: "not configured"
            ) {
                return ProviderSyncOutcome(
                    account: account,
                    snapshot: preservedSnapshot,
                    errorMessage: nil
                )
            }

            return ProviderSyncOutcome(
                account: account,
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
            Self.logRefreshFailure(providerID, message)
            if let preservedSnapshot = preservedSnapshotAfterRefreshMiss(
                providerID: providerID,
                previousSnapshot: previousSnapshot,
                reason: message
            ) {
                return ProviderSyncOutcome(
                    account: account,
                    snapshot: preservedSnapshot,
                    errorMessage: message
                )
            }

            return ProviderSyncOutcome(
                account: account,
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
            Self.logRefreshFailure(providerID, message)

            // A Codex folder now signed in to another account: the previous
            // snapshot may already be that account's, so it is not kept.
            if !(error is CodexAccountSwitchedError),
               let preservedSnapshot = preservedSnapshotAfterRefreshMiss(
                providerID: providerID,
                previousSnapshot: previousSnapshot,
                reason: message
            ) {
                return ProviderSyncOutcome(
                    account: account,
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
                account: account,
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
        case .antigravity, .mistral, .deepseek, .cerebras, .meta, .ollama, .qwen, .mimo, .minimax:
            // Local probes, imported sessions, reports, and billing APIs can all miss a
            // refresh transiently. Keep the last truthful reading visible.
            shouldPreserve = true
        default:
            shouldPreserve = false
        }

        guard shouldPreserve else { return nil }

        print("[SyncCoordinator] Preserving previous \(providerID.rawValue) snapshot after refresh miss: \(reason)")
        Self.logger.notice("keeping the previous \(providerID.rawValue, privacy: .public) snapshot after a refresh miss")
        return previousSnapshot
    }

    private func fetchSnapshotWithTimeout(
        account: ProviderAccountKey,
        client: any ProviderClient,
        credentials: ProviderCredential?,
        userInitiated: Bool
    ) async throws -> QuotaSnapshot {
        let providerID = account.providerID
        let timeout = providerTimeout(for: providerID)

        return try await withCheckedThrowingContinuation { continuation in
            let state = TimeoutRaceState(continuation)
            let fetchTask = Task {
                do {
                    let snapshot: QuotaSnapshot
                    if let accountClient = client as? any AccountScopedProviderClient {
                        // Clients with per-account caches or keychain items
                        // (Claude) need to know which account this is.
                        snapshot = try await accountClient.fetchSnapshot(
                            credentials: credentials,
                            account: account,
                            userInitiated: userInitiated
                        )
                    } else if let interactiveClient = client as? any UserInitiatedProviderClient {
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
               .mistral, .deepseek, .cerebras, .meta, .openrouter, .minimax:
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

    /// Errors stay keyed by provider so the setup rail and dashboard need no
    /// second key. A secondary account's message is prefixed with its label,
    /// and a provider's errors accumulate within a sweep: one account
    /// succeeding must not erase another account's failure.
    private func applySyncOutcome(_ outcome: ProviderSyncOutcome) {
        let providerID = outcome.account.providerID
        if let errorMessage = outcome.errorMessage {
            let labelled: String
            if outcome.account.isPrimary {
                labelled = errorMessage
            } else {
                let label = outcome.snapshot.accountBadgeText ?? "Account"
                labelled = "\(label): \(errorMessage)"
            }
            if let existing = syncErrors[providerID], !existing.isEmpty, existing != labelled,
               !existing.components(separatedBy: "\n").contains(labelled) {
                syncErrors[providerID] = existing + "\n" + labelled
            } else {
                syncErrors[providerID] = labelled
            }
        }

        store.upsert(outcome.snapshot)
    }

    private func coalescedCodexUsageSnapshot(
        in snapshots: [ProviderAccountKey: QuotaSnapshot]
    ) -> QuotaSnapshot? {
        guard let usage = snapshots[.primary(.openai)],
              let telemetry = snapshots[.primary(.codexTelemetry)] else {
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
            resetCredits: usage.resetCredits,
            accountSlot: usage.accountSlot,
            accountLabel: usage.accountLabel,
            accountFingerprint: usage.accountFingerprint
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

    // Releasing this lock-protected state requires no actor hop. Explicit
    // isolation also avoids Swift 6.2's iOS Release optimizer crash in deinit.
    nonisolated deinit {}

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
    let account: ProviderAccountKey
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

        let account = snapshot.accountKey
        let stateStore = QuotaResetDetectorStateStore(defaults: defaults)

        // The same slot now holds a different account: a Work meter at 12%
        // replacing a Personal meter at 90% is not a reset, it is a different
        // meter. Start the trail again and drop anything still pending.
        if ProviderAccountFingerprint.indicatesAccountChange(
            previous: previousSnapshot?.accountFingerprint,
            current: snapshot.accountFingerprint
        ) {
            print("[SyncCoordinator] \(account.rawValue) is now a different account; resetting its reset-detector trail")
            stateStore.clear(account: account)
            activeSignals.removeValue(forKey: account.rawValue)
        }

        let outcome = detector.observe(snapshot, state: stateStore.state(for: account))
        stateStore.save(outcome.state, for: account)
        QuotaResetLedgerStore.shared.record(outcome.events)

        merge(outcome.signals, into: &activeSignals, account: account)
        saveSignals(activeSignals)

        let detectedSignals = (activeSignals[account.rawValue] ?? [])
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

    /// Keep historical events, but require current evidence for banked reset
    /// availability. An empty detector result must retire a spent reset too.
    private func merge(
        _ newSignals: [QuotaSignal],
        into signals: inout [String: [QuotaSignal]],
        account: ProviderAccountKey
    ) {
        let providerKey = account.rawValue
        signals[providerKey] = QuotaResetSignalRetention.merging(
            newSignals,
            with: signals[providerKey] ?? []
        )
    }
}
