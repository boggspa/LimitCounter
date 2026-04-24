import Combine
import Foundation
import WidgetKit
#if os(macOS)
import AppKit
#endif

@MainActor
final class AppStateStore: ObservableObject {

    @Published private(set) var snapshots: [QuotaSnapshot]
    @Published private(set) var isSyncing = false
    @Published private(set) var lastSyncDate: Date?
    @Published private(set) var syncErrors: [ProviderID: String] = [:]
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
        coordinator.register(ChatGPTLocalProviderClient())
        coordinator.register(CodexTelemetryProviderClient())
        coordinator.register(ClaudeProviderClient())
        coordinator.register(WindsurfProviderClient())
        coordinator.register(CursorProviderClient())
        coordinator.register(GeminiProviderClient())
        #endif

        self.syncCoordinator = coordinator

        let stored = resolvedStore.loadSnapshots()
        self.snapshots = stored.isEmpty ? Self.initialSnapshots : stored
        self.lastSyncDate = stored.map(\.fetchedAt).max()
        self.isHeadlessMode = UserDefaults.standard.bool(forKey: "isHeadlessMode")
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

        #if os(iOS)
        do {
            try await cloudSync.ensureViewerSubscriptions()
        } catch {
            print("[AppStateStore] CloudKit subscription setup skipped: \(error.localizedDescription)")
        }
        #endif
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
            scheduleCloudPublish(loaded)
        }
        #else
        do {
            let remoteSnapshots = try await cloudSync.fetchRemoteSnapshots()
            if !remoteSnapshots.isEmpty {
                store.replaceAll(remoteSnapshots)
                WidgetCenter.shared.reloadAllTimelines()
            }

            let loaded = store.loadSnapshots()
            snapshots = loaded.isEmpty ? Self.initialSnapshots : loaded
            lastSyncDate = loaded.map(\.fetchedAt).max()
            syncErrors = [:]
        } catch {
            print("[AppStateStore] Cloud fetch skipped: \(error.localizedDescription)")
            let loaded = store.loadSnapshots()
            snapshots = loaded.isEmpty ? Self.initialSnapshots : loaded
            lastSyncDate = loaded.map(\.fetchedAt).max()
            syncErrors = [:]
        }
        #endif
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
                    try await self.cloudSync.publishSnapshots(snapshotsToPublish)
                } catch {
                    print("[AppStateStore] Cloud publish skipped: \(error.localizedDescription)")
                }
            }
        }
    }
    #endif
}
