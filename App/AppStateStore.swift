import Combine
import Foundation
import WidgetKit
#if os(macOS)
import AppKit
#endif

@MainActor
enum CloudSnapshotBackgroundRefresher {
    static func refreshFromCloudKit() async -> Bool {
        do {
            let remoteSnapshots = try await CloudKitSyncService.shared.fetchRemoteSnapshots()
            guard !remoteSnapshots.isEmpty else {
                return false
            }

            let store = QuotaSnapshotStore.shared
            let cachedSnapshots = store.loadSnapshots()
            let didChange = cachedSnapshots != remoteSnapshots

            if didChange {
                store.replaceAll(remoteSnapshots)
            }

            WidgetCenter.shared.reloadAllTimelines()
            return didChange
        } catch {
            print("[CloudSnapshotBackgroundRefresher] Cloud fetch skipped: \(error.localizedDescription)")
            return false
        }
    }
}

@MainActor
final class AppStateStore: ObservableObject {

    @Published private(set) var snapshots: [QuotaSnapshot]
    @Published private(set) var isSyncing = false
    @Published private(set) var lastSyncDate: Date?
    @Published private(set) var syncErrors: [ProviderID: String] = [:]
    @Published private(set) var usageAlerts: [CloudAlertPayload] = []
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
    private let cloudSync = CloudKitSyncService.shared
    private var hasBootstrapped = false
    private var cloudPublishTask: Task<Void, Never>?
    private var pendingCloudPublishSnapshots: [QuotaSnapshot]?
    private let usageAlertsKey = "usageAlerts.activePayloads"
    private let dismissedUsageAlertSignaturesKey = "usageAlerts.dismissedSignatures"
    private let maxUsageAlerts = 8
    private let maxDismissedUsageAlertSignatures = 300
    private let usageAlertRetention: TimeInterval = 24 * 60 * 60
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
        let coordinator = SyncCoordinator(store: resolvedStore, keychain: resolvedKeychain)

        #if os(macOS)
        coordinator.register(CodexSessionProviderClient())
        coordinator.register(OpenAIUsageProviderClient())
        coordinator.register(ChatGPTLocalProviderClient())
        coordinator.register(CodexTelemetryProviderClient())
        coordinator.register(ClaudeProviderClient())
        coordinator.register(WindsurfProviderClient())
        coordinator.register(CursorProviderClient())
        coordinator.register(GeminiProviderClient())
        coordinator.register(KimiProviderClient())
        #endif

        self.syncCoordinator = coordinator

        let stored = resolvedStore.loadSnapshots()
        self.snapshots = stored.isEmpty ? Self.initialSnapshots : stored
        self.lastSyncDate = stored.map(\.fetchedAt).max()
        self.isHeadlessMode = UserDefaults.standard.bool(forKey: "isHeadlessMode")
        self.usageAlerts = loadStoredUsageAlerts()
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
                providerID: .windsurf,
                displayName: ProviderID.windsurf.snapshotDisplayName,
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
            )
        ]
        #endif
    }

    var visibleSnapshots: [QuotaSnapshot] {
        let visibility = ProviderVisibilityStore.shared
        return snapshots.filter { visibility.isVisible($0.providerID) }
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
    }

    func refresh() async {
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }

        #if os(macOS)
        await syncCoordinator.syncAll()
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
        guard !alerts.isEmpty else {
            pruneStoredUsageAlerts()
            return
        }

        let dismissed = Set(loadDismissedUsageAlertSignatures())
        let now = Date()
        var merged = usageAlerts.filter {
            $0.kind.isUsageReset
                && !dismissed.contains($0.signature)
                && now.timeIntervalSince($0.createdAt) <= usageAlertRetention
        }
        var seen = Set(merged.map(\.signature))

        let freshAlerts = alerts
            .filter {
                $0.kind.isUsageReset
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
                $0.kind.isUsageReset
                    && !dismissed.contains($0.signature)
                    && now.timeIntervalSince($0.createdAt) <= usageAlertRetention
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    private func saveUsageAlerts() {
        guard let data = try? usageAlertEncoder.encode(usageAlerts) else { return }
        UserDefaults.standard.set(data, forKey: usageAlertsKey)
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
