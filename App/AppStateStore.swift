import Combine
import Foundation
import WidgetKit
#if os(macOS)
import AppKit
#endif

@MainActor
enum CloudSnapshotBackgroundRefresher {
    static func refreshFromCloudKit() async -> Bool {
        var analyticsChanged = false
        if let remote = try? await CloudKitSyncService.shared.fetchModelUsage() {
            let cached = ModelUsageArchiveStore.load()
            if remote.generatedAt > cached.generatedAt {
                do { try ModelUsageArchiveStore.save(remote); analyticsChanged = true }
                catch { /* Preserve the last successfully saved archive. */ }
            }
        }
        do {
            let remoteSnapshots = try await CloudKitSyncService.shared.fetchRemoteSnapshots()
            guard !remoteSnapshots.isEmpty else {
                return analyticsChanged
            }

            let store = QuotaSnapshotStore.shared
            let cachedSnapshots = store.loadSnapshots()
            let didChange = cachedSnapshots != remoteSnapshots

            if didChange {
                store.replaceAll(remoteSnapshots)
            }

            WidgetCenter.shared.reloadAllTimelines()
            return didChange || analyticsChanged
        } catch {
            print("[CloudSnapshotBackgroundRefresher] Cloud fetch skipped: \(error.localizedDescription)")
            return analyticsChanged
        }
    }
}

private struct UsageResetHistoryEntry: Codable, Hashable {
    let providerID: ProviderID
    let signature: String
    let occurredAt: Date

    init(alert: CloudAlertPayload) {
        providerID = alert.providerID
        signature = alert.signature
        occurredAt = alert.createdAt
    }
}

@MainActor
final class AppStateStore: ObservableObject {

    @Published private(set) var snapshots: [QuotaSnapshot]
    @Published private(set) var isSyncing = false
    @Published private(set) var lastSyncDate: Date?
    @Published private(set) var syncErrors: [ProviderID: String] = [:]
    @Published private(set) var usageAlerts: [CloudAlertPayload] = []
    @Published private(set) var modelUsage = ModelUsageArchiveStore.load()
    @Published private(set) var isIndexingModelUsage = false
    @Published private(set) var modelUsageStatus: String?
    @Published private(set) var modelUsageSyncError: String?
    @Published var pendingModelUsageNavigation = false
    @Published private var usageResetHistory: [UsageResetHistoryEntry] = []
    @Published var pendingDeepLinkProviderID: ProviderID?
    #if os(iOS)
    @Published var lastSeenAlertDate: Date?
    #endif
    @Published var isHeadlessMode: Bool {
        didSet {
            UserDefaults.standard.set(isHeadlessMode, forKey: "isHeadlessMode")
            #if os(macOS)
            updateActivationPolicy()
            #endif
        }
    }

    private let syncCoordinator: SyncCoordinator
    private let store: QuotaSnapshotStore
    private let analyticsKeychain: KeychainService
    private var modelUsageTask: Task<Void, Never>?
    private let cloudSync = CloudKitSyncService.shared
    private var hasBootstrapped = false
    private var cloudPublishTask: Task<Void, Never>?
    private var pendingCloudPublishSnapshots: [QuotaSnapshot]?
    private let usageAlertsKey = "usageAlerts.activePayloads"
    private let usageResetHistoryKey = "usageAlerts.resetHistory"
    private let dismissedUsageAlertSignaturesKey = "usageAlerts.dismissedSignatures"
    private let maxUsageAlerts = 8
    private let maxDismissedUsageAlertSignatures = 300
    private let usageAlertRetention: TimeInterval = 24 * 60 * 60
    private let usageResetHistoryRetention: TimeInterval = 7 * 24 * 60 * 60
    private let maxUsageResetHistoryEntries = 500
    private let usageAlertEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
    private let usageAlertDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    init(
        store: QuotaSnapshotStore? = nil,
        keychain: KeychainService? = nil
    ) {
        let resolvedStore = store ?? .shared
        let resolvedKeychain = keychain ?? .shared
        self.store = resolvedStore
        self.analyticsKeychain = resolvedKeychain
        let coordinator = SyncCoordinator(store: resolvedStore, keychain: resolvedKeychain)

        #if os(macOS)
        coordinator.register(CodexSessionProviderClient())
        coordinator.register(OpenAIUsageProviderClient())
        coordinator.register(ChatGPTLocalProviderClient())
        coordinator.register(CodexTelemetryProviderClient())
        coordinator.register(ClaudeProviderClient())
        coordinator.register(DevinProviderClient())
        coordinator.register(CursorProviderClient())
        coordinator.register(GeminiProviderClient())
        coordinator.register(KimiProviderClient())
        coordinator.register(GrokProviderClient())
        coordinator.register(AntigravityProviderClient())
        coordinator.register(MistralProviderClient())
        coordinator.register(DeepSeekProviderClient())
        coordinator.register(CerebrasProviderClient())
        coordinator.register(MetaProviderClient())
        coordinator.register(OllamaProviderClient())
        coordinator.register(OpenRouterProviderClient())
        coordinator.register(QwenProviderClient())
        coordinator.register(MimoProviderClient())
        #endif

        self.syncCoordinator = coordinator

        let stored = resolvedStore.loadSnapshots()
        self.snapshots = stored.isEmpty ? Self.initialSnapshots : stored
        self.lastSyncDate = stored.map(\.fetchedAt).max()
        self.isHeadlessMode = UserDefaults.standard.bool(forKey: "isHeadlessMode")
        self.usageAlerts = loadStoredUsageAlerts()
        self.usageResetHistory = loadStoredUsageResetHistory()
        recordUsageResetHistory(usageAlerts)
    }

    private static var initialSnapshots: [QuotaSnapshot] {
        #if os(iOS)
        []
        #else
        [
            QuotaSnapshot(
                providerID: .claude,
                displayName: ProviderID.claude.snapshotDisplayName,
                planName: nil,
                windows: [],
                fetchState: .notConfigured
            ),
            QuotaSnapshot(
                providerID: .openai,
                displayName: ProviderID.openai.snapshotDisplayName,
                planName: nil,
                windows: [],
                fetchState: .notConfigured
            ),
            QuotaSnapshot(
                providerID: .openaiAPI,
                displayName: ProviderID.openaiAPI.snapshotDisplayName,
                planName: nil,
                windows: [],
                fetchState: .notConfigured
            ),
            QuotaSnapshot(
                providerID: .chatgpt,
                displayName: ProviderID.chatgpt.snapshotDisplayName,
                planName: nil,
                windows: [],
                fetchState: .notConfigured
            ),
            QuotaSnapshot(
                providerID: .codexTelemetry,
                displayName: ProviderID.codexTelemetry.snapshotDisplayName,
                planName: nil,
                windows: [],
                fetchState: .notConfigured
            ),
            QuotaSnapshot(
                providerID: .devin,
                displayName: ProviderID.devin.snapshotDisplayName,
                planName: nil,
                windows: [],
                fetchState: .notConfigured
            ),
            QuotaSnapshot(
                providerID: .cursor,
                displayName: ProviderID.cursor.snapshotDisplayName,
                planName: nil,
                windows: [],
                fetchState: .notConfigured
            ),
            QuotaSnapshot(
                providerID: .gemini,
                displayName: ProviderID.gemini.snapshotDisplayName,
                planName: nil,
                windows: [],
                fetchState: .notConfigured
            ),
            QuotaSnapshot(
                providerID: .kimi,
                displayName: ProviderID.kimi.snapshotDisplayName,
                planName: nil,
                windows: [],
                fetchState: .notConfigured
            ),
            QuotaSnapshot(
                providerID: .openrouter,
                displayName: ProviderID.openrouter.snapshotDisplayName,
                planName: nil,
                windows: [],
                fetchState: .notConfigured
            )
        ]
        #endif
    }

    var visibleSnapshots: [QuotaSnapshot] {
        let visibility = ProviderVisibilityStore.shared
        return snapshots.filter { visibility.isVisible($0.providerID) }
    }

    var sevenDayResetCounts: [ProviderID: Int] {
        let cutoff = Date().addingTimeInterval(-usageResetHistoryRetention)
        return Dictionary(
            grouping: usageResetHistory.filter { $0.occurredAt >= cutoff },
            by: \.providerID
        )
        .mapValues { $0.count }
    }

    func suggestedRefreshDelay(defaultIntervalSeconds: Int) -> TimeInterval {
        let baseDelay = TimeInterval(max(15, defaultIntervalSeconds))
        let now = Date()
        let resetDates = visibleSnapshots
            .flatMap { snapshot in snapshot.windows.compactMap(\.resetDate) }
            .filter { $0 > .distantPast }

        guard let nearestReset = resetDates.min() else {
            return baseDelay
        }

        let timeUntilReset = nearestReset.timeIntervalSince(now)

        if timeUntilReset <= 0 {
            return min(baseDelay, 60)
        }

        if timeUntilReset <= 30 * 60 {
            return min(baseDelay, max(30, timeUntilReset + 45))
        }

        return baseDelay
    }

    func bootstrap() async {
        guard !hasBootstrapped else { return }
        hasBootstrapped = true

        do {
            try await cloudSync.ensureViewerSubscriptions()
        } catch {
            print("[AppStateStore] CloudKit subscription setup skipped: \(error.localizedDescription)")
        }

        do {
            let recentAlerts = try await cloudSync.fetchRecentAlerts(
                since: Date().addingTimeInterval(-usageResetHistoryRetention),
                limit: 200
            )
            ingestUsageAlerts(recentAlerts)
            #if os(iOS)
            lastSeenAlertDate = recentAlerts.map(\.createdAt).max()
            #endif
        } catch {
            print("[AppStateStore] Reset history backfill skipped: \(error.localizedDescription)")
        }

        #if os(iOS)
        _ = await CloudSnapshotBackgroundRefresher.refreshFromCloudKit()
        let loaded = store.loadSnapshots()
        snapshots = loaded.isEmpty ? Self.initialSnapshots : loaded
        lastSyncDate = loaded.map(\.fetchedAt).max()
        syncErrors = [:]
        #endif
    }

    func refresh(userInitiated: Bool = false) async {
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        refreshModelUsage()

        #if os(macOS)
        await syncCoordinator.syncAll(userInitiated: userInitiated) { [weak self] progressiveSnapshots, progressiveErrors in
            guard let self else { return }
            snapshots = progressiveSnapshots.isEmpty ? Self.initialSnapshots : progressiveSnapshots
            syncErrors = progressiveErrors
        }
        let loaded = store.loadSnapshots()
        snapshots = loaded.isEmpty ? Self.initialSnapshots : loaded
        lastSyncDate = syncCoordinator.lastSyncDate
        syncErrors = syncCoordinator.syncErrors

        if !loaded.isEmpty {
            let noticedAt = lastSyncDate ?? Date()
            let resetAlerts = UsageResetAlertBuilder.resetAlerts(from: loaded, noticedAt: noticedAt)
            ingestUsageAlerts(resetAlerts)
            await MacLocalNotificationPublisher.shared.processEmittedAlerts(resetAlerts)
            scheduleCloudPublish(loaded)
        }
        #else
        _ = await CloudSnapshotBackgroundRefresher.refreshFromCloudKit()
        let loaded = store.loadSnapshots()
        snapshots = loaded.isEmpty ? Self.initialSnapshots : loaded
        lastSyncDate = loaded.map(\.fetchedAt).max()
        syncErrors = [:]
        if !loaded.isEmpty {
            ingestUsageAlerts(
                UsageResetAlertBuilder.resetAlerts(
                    from: loaded,
                    noticedAt: lastSyncDate ?? Date()
                )
            )
        }
        #endif
    }

    func openUsageAlert(_ alert: CloudAlertPayload) {
        pendingDeepLinkProviderID = alert.providerID
        dismissUsageAlert(alert)
    }

    /// The provider credential whose existing folder grant a history source reads.
    /// Nil for TaskWraith, whose data folder has its own shared grant.
    private static func modelUsageGrantProvider(_ source: LocalModelUsageSource) -> ProviderID? {
        switch source {
        case .codex: return .codexTelemetry
        case .claude: return .claude
        case .taskwraith: return nil
        }
    }

    /// Runs independently of quota refresh, so a first historical backfill cannot
    /// block the menu bar or short-window meters. A second refresh reuses the task.
    func refreshModelUsage() {
        guard modelUsageTask == nil else { return }
        modelUsageTask = Task { @MainActor in
            defer { modelUsageTask = nil; isIndexingModelUsage = false }
            isIndexingModelUsage = true
            modelUsageSyncError = nil
            #if os(macOS)
            var roots: [LocalModelUsageSource: URL] = [:]
            var opened: [URL] = []
            var releases: [() -> Void] = []
            defer {
                for url in opened { url.stopAccessingSecurityScopedResource() }
                for release in releases { release() }
            }
            for source in LocalModelUsageSource.allCases {
                guard let provider = Self.modelUsageGrantProvider(source) else {
                    // TaskWraith's data folder has one shared grant rather than a provider credential.
                    if source == .taskwraith, let scoped = AGBenchBookmarkStore.startAccess() {
                        releases.append(scoped.stop)
                        roots[source] = scoped.url
                    }
                    continue
                }
                guard let credential = analyticsKeychain.credential(for: provider) else { continue }
                let bookmark = credential.bookmarkData ?? credential.extraFields?["bookmarkData"].flatMap { Data(base64Encoded: $0) }
                if let bookmark {
                    var stale = false
                    if let url = try? URL(resolvingBookmarkData: bookmark, options: .withSecurityScope,
                        relativeTo: nil, bookmarkDataIsStale: &stale) {
                        if url.startAccessingSecurityScopedResource() { opened.append(url) }
                        roots[source] = url
                    }
                } else if let path = credential.customEndpoint, path.hasPrefix("/") {
                    // This path was explicitly saved in provider setup. No home-directory search.
                    roots[source] = URL(fileURLWithPath: path)
                }
            }
            guard !roots.isEmpty else {
                modelUsageStatus = "Connect local Codex, Claude or TaskWraith folders in provider setup to index model usage."
                return
            }
            do {
                let archive = try await ModelUsageLogScanner.shared.scan(roots: roots) { [weak self] message in
                    await MainActor.run { self?.modelUsageStatus = message }
                }
                modelUsage = archive
                modelUsageStatus = nil
                do { try await cloudSync.publishModelUsage(archive) }
                catch { modelUsageSyncError = "History is saved on this Mac. iCloud analytics sync is unavailable; refresh to retry." }
            } catch {
                modelUsageStatus = "History indexing could not finish. Cached history is still available; refresh to retry."
            }
            #else
            do {
                // The analytics subscription is independent of existing quota alerts.
                try? await cloudSync.ensureModelUsageSubscription()
                if let remote = try await cloudSync.fetchModelUsage() {
                    if remote.generatedAt >= modelUsage.generatedAt {
                        try ModelUsageArchiveStore.save(remote)
                        modelUsage = remote
                    }
                    modelUsageStatus = nil
                } else { modelUsageStatus = "Open Limit Counter on your Mac to collect and sync model history." }
            } catch {
                modelUsageSyncError = "iCloud analytics is unavailable. Showing the last saved history."
            }
            #endif
        }
    }

    func dismissUsageAlert(_ alert: CloudAlertPayload) {
        var dismissed = loadDismissedUsageAlertSignatures()
        dismissed.removeAll { $0 == alert.signature }
        dismissed.append(alert.signature)
        if dismissed.count > maxDismissedUsageAlertSignatures {
            dismissed.removeFirst(dismissed.count - maxDismissedUsageAlertSignatures)
        }
        UserDefaults.standard.set(dismissed, forKey: dismissedUsageAlertSignaturesKey)

        usageAlerts.removeAll { $0.signature == alert.signature }
        saveUsageAlerts()
    }

    func dismissAllUsageAlerts() {
        guard !usageAlerts.isEmpty else { return }

        var dismissed = loadDismissedUsageAlertSignatures()
        for signature in usageAlerts.map(\.signature) where !dismissed.contains(signature) {
            dismissed.append(signature)
        }
        if dismissed.count > maxDismissedUsageAlertSignatures {
            dismissed.removeFirst(dismissed.count - maxDismissedUsageAlertSignatures)
        }
        UserDefaults.standard.set(dismissed, forKey: dismissedUsageAlertSignaturesKey)

        usageAlerts = []
        saveUsageAlerts()
    }

    private func ingestUsageAlerts(_ alerts: [CloudAlertPayload]) {
        recordUsageResetHistory(alerts)

        guard !alerts.isEmpty else {
            pruneStoredUsageAlerts()
            return
        }

        let dismissed = Set(loadDismissedUsageAlertSignatures())
        let now = Date()
        var merged = usageAlerts.filter {
            $0.isAnnounceable
                && !dismissed.contains($0.signature)
                && now.timeIntervalSince($0.createdAt) <= usageAlertRetention
        }
        var seen = Set(merged.map(\.signature))

        let freshAlerts = alerts
            .filter {
                $0.isAnnounceable
                    && !dismissed.contains($0.signature)
                    && now.timeIntervalSince($0.createdAt) <= usageAlertRetention
            }
            .sorted { $0.createdAt < $1.createdAt }

        for alert in freshAlerts where seen.insert(alert.signature).inserted {
            merged.insert(alert, at: 0)
        }

        usageAlerts = Array(
            merged
                .sorted { $0.createdAt > $1.createdAt }
                .prefix(maxUsageAlerts)
        )
        saveUsageAlerts()
    }

    private func pruneStoredUsageAlerts() {
        recordUsageResetHistory([])

        let dismissed = Set(loadDismissedUsageAlertSignatures())
        let now = Date()
        let pruned = usageAlerts.filter {
            !dismissed.contains($0.signature)
                && now.timeIntervalSince($0.createdAt) <= usageAlertRetention
        }
        guard pruned != usageAlerts else { return }
        usageAlerts = pruned
        saveUsageAlerts()
    }

    private func loadStoredUsageAlerts() -> [CloudAlertPayload] {
        guard let data = UserDefaults.standard.data(forKey: usageAlertsKey),
              let decoded = try? usageAlertDecoder.decode([CloudAlertPayload].self, from: data) else {
            return []
        }

        let dismissed = Set(loadDismissedUsageAlertSignatures())
        let now = Date()
        return decoded
            .filter {
                $0.isAnnounceable
                    && !dismissed.contains($0.signature)
                    && now.timeIntervalSince($0.createdAt) <= usageAlertRetention
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    private func saveUsageAlerts() {
        guard let data = try? usageAlertEncoder.encode(usageAlerts) else { return }
        UserDefaults.standard.set(data, forKey: usageAlertsKey)
    }

    private func loadStoredUsageResetHistory() -> [UsageResetHistoryEntry] {
        guard let data = UserDefaults.standard.data(forKey: usageResetHistoryKey),
              let decoded = try? usageAlertDecoder.decode([UsageResetHistoryEntry].self, from: data) else {
            return []
        }

        let cutoff = Date().addingTimeInterval(-usageResetHistoryRetention)
        return decoded
            .filter { $0.occurredAt >= cutoff }
            .sorted { $0.occurredAt > $1.occurredAt }
    }

    private func recordUsageResetHistory(_ alerts: [CloudAlertPayload]) {
        let now = Date()
        let cutoff = now.addingTimeInterval(-usageResetHistoryRetention)
        var history = usageResetHistory.filter { $0.occurredAt >= cutoff && $0.occurredAt <= now }
        var signatures = Set(history.map(\.signature))

        for alert in alerts where alert.kind.isUsageReset && alert.createdAt >= cutoff && alert.createdAt <= now {
            guard signatures.insert(alert.signature).inserted else { continue }
            history.append(UsageResetHistoryEntry(alert: alert))
        }

        history = Array(
            history
                .sorted { $0.occurredAt > $1.occurredAt }
                .prefix(maxUsageResetHistoryEntries)
        )

        guard history != usageResetHistory else { return }
        usageResetHistory = history

        if let data = try? usageAlertEncoder.encode(history) {
            UserDefaults.standard.set(data, forKey: usageResetHistoryKey)
        }
    }

    private func loadDismissedUsageAlertSignatures() -> [String] {
        UserDefaults.standard.array(forKey: dismissedUsageAlertSignaturesKey) as? [String] ?? []
    }

    #if os(macOS)
    private func updateActivationPolicy() {
        if isHeadlessMode {
            NSApplication.shared.setActivationPolicy(.accessory)
        } else {
            NSApplication.shared.setActivationPolicy(.regular)
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }

    func bootstrapHeadless() {
        if isHeadlessMode {
            NSApplication.shared.setActivationPolicy(.accessory)
        }
    }
    #endif

    #if os(iOS)
    func handleRemoteNotification(userInfo: [AnyHashable: Any]) async -> Bool {
        guard cloudSync.isCloudKitNotification(userInfo) else {
            return false
        }

        cloudSync.markRemoteNotificationReceived()

        var alerts = cloudSync.extractAlertPayloads(from: userInfo)
        if alerts.isEmpty {
            alerts = (try? await cloudSync.fetchRecentAlerts(since: lastSeenAlertDate)) ?? []
        }
        if let newest = alerts.map(\.createdAt).max() {
            lastSeenAlertDate = newest
        }
        ingestUsageAlerts(alerts)
        if !cloudSync.hasVisibleAlertPayload(userInfo) {
            await LocalNotificationPublisher.shared.processIncomingAlerts(alerts)
        }

        await refresh()
        return true
    }
    #endif

    #if os(macOS)
    private func scheduleCloudPublish(_ snapshots: [QuotaSnapshot]) {
        pendingCloudPublishSnapshots = snapshots

        guard cloudPublishTask == nil else { return }

        cloudPublishTask = Task { @MainActor in
            defer { self.cloudPublishTask = nil }

            while let snapshotsToPublish = self.pendingCloudPublishSnapshots {
                self.pendingCloudPublishSnapshots = nil

                do {
                    let emitted = try await self.cloudSync.publishSnapshots(snapshotsToPublish)
                    await MacLocalNotificationPublisher.shared.processEmittedAlerts(emitted)
                } catch {
                    print("[AppStateStore] Cloud publish skipped: \(error.localizedDescription)")
                }
            }
        }
    }
    #endif
}
