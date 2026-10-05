import SwiftUI
import UserNotifications
#if os(iOS)
import BackgroundTasks
import UIKit
#endif

@main
struct AIUsageTrackerApp: App {

    @Environment(\.scenePhase) private var scenePhase

    #if os(iOS)
    @UIApplicationDelegateAdaptor private var appDelegate: IOSAppDelegate
    #endif
    @StateObject private var appState = AppStateStore()
    #if os(macOS)
    @State private var menuBarController: MenuBarController?
    @State private var notificationCoordinator: MacNotificationCoordinator?
    #endif

    var body: some Scene {
        WindowGroup(id: "dashboard") {
            DashboardView()
                .environmentObject(appState)
                .preferredColorScheme(.dark)
                .task {
                    #if os(iOS)
                    appDelegate.appState = appState
                    appDelegate.scheduleBackgroundRefresh()
                    #endif
                    await appState.bootstrap()
                    #if os(macOS)
                    appState.bootstrapHeadless()
                    if menuBarController == nil {
                        menuBarController = MenuBarController(appState: appState)
                    }
                    if notificationCoordinator == nil {
                        notificationCoordinator = MacNotificationCoordinator(appState: appState)
                        await notificationCoordinator?.bootstrap()
                    }
                    #endif
                }
                .onChange(of: appState.snapshots) { _ in
                    #if os(macOS)
                    menuBarController?.updateMenu()
                    #endif
                }
                .onChange(of: appState.isHeadlessMode) { _ in
                    #if os(macOS)
                    menuBarController?.updateMenu()
                    #endif
                }
                .onChange(of: scenePhase) { phase in
                    #if os(iOS)
                    if phase == .active {
                        Task { await appState.refresh() }
                    }
                    #endif
                }
        }
        #if os(macOS)
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 920, height: 640)
        #endif
    }
}

#if os(iOS)
final class IOSAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    private let backgroundTaskIdentifier = "com.chrisizatt.LLMUsageCounter.refresh"
    private var pendingNotificationAccount: ProviderAccountKey?
    weak var appState: AppStateStore? {
        didSet {
            if let appState, let account = pendingNotificationAccount {
                appState.pendingDeepLinkAccountKey = account
                pendingNotificationAccount = nil
            }
        }
    }

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().setNotificationCategories([AlertNotificationContent.makeCategory()])
        application.registerForRemoteNotifications()
        registerBackgroundTasks()
        scheduleBackgroundRefresh()

        Task {
            do {
                try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            } catch {
                print("[IOSAppDelegate] Notification authorization skipped: \(error.localizedDescription)")
            }
        }

        return true
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        scheduleBackgroundRefresh()
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        guard let appState else {
            Task { @MainActor in
                guard CloudKitSyncService.shared.isCloudKitNotification(userInfo) else {
                    completionHandler(.noData)
                    return
                }

                CloudKitSyncService.shared.markRemoteNotificationReceived()

                var alerts = CloudKitSyncService.shared.extractAlertPayloads(from: userInfo)
                if alerts.isEmpty {
                    alerts = (try? await CloudKitSyncService.shared.fetchRecentAlerts(since: nil, limit: 5)) ?? []
                }
                if !CloudKitSyncService.shared.hasVisibleAlertPayload(userInfo) {
                    await LocalNotificationPublisher.shared.processIncomingAlerts(alerts)
                }

                let didUpdate = await CloudSnapshotBackgroundRefresher.refreshFromCloudKit()
                self.scheduleBackgroundRefresh()
                completionHandler(didUpdate ? .newData : .noData)
            }
            return
        }

        Task { @MainActor in
            let handled = await appState.handleRemoteNotification(userInfo: userInfo)
            self.scheduleBackgroundRefresh()
            completionHandler(handled ? .newData : .noData)
        }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        print("[IOSAppDelegate] Remote notifications unavailable: \(error.localizedDescription)")
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        print("[IOSAppDelegate] Remote notifications registered")
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound, .badge]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let info = response.notification.request.content.userInfo
        guard let account = CloudKitSyncService.shared.accountKey(fromNotificationUserInfo: info) else { return }

        switch response.actionIdentifier {
        case AlertNotificationContent.openActionIdentifier, UNNotificationDefaultActionIdentifier:
            await MainActor.run {
                if let appState = self.appState {
                    appState.pendingDeepLinkAccountKey = account
                } else {
                    self.pendingNotificationAccount = account
                }
            }
        default:
            break
        }
    }

    func scheduleBackgroundRefresh() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: backgroundTaskIdentifier)

        let request = BGAppRefreshTaskRequest(identifier: backgroundTaskIdentifier)
        request.earliestBeginDate = Date().addingTimeInterval(UsageRefreshCadence.requestedRefreshInterval)

        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            print("[IOSAppDelegate] Failed to schedule background refresh: \(error.localizedDescription)")
        }
    }

    private func registerBackgroundTasks() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: backgroundTaskIdentifier, using: nil) { [weak self] task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }

            self?.handleBackgroundRefresh(task: refreshTask)
        }
    }

    private func handleBackgroundRefresh(task: BGAppRefreshTask) {
        scheduleBackgroundRefresh()

        let work = Task { @MainActor in
            if let appState {
                await appState.refresh()
            } else {
                _ = await CloudSnapshotBackgroundRefresher.refreshFromCloudKit()
            }
            task.setTaskCompleted(success: true)
        }

        task.expirationHandler = {
            work.cancel()
            task.setTaskCompleted(success: false)
        }
    }
}
#endif

#if os(macOS)
@MainActor
final class MacNotificationCoordinator: NSObject, UNUserNotificationCenterDelegate {
    weak var appState: AppStateStore?

    init(appState: AppStateStore) {
        self.appState = appState
        super.init()
    }

    func bootstrap() async {
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().setNotificationCategories([AlertNotificationContent.makeCategory()])
        await MacLocalNotificationPublisher.shared.requestAuthorizationIfNeeded()
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound, .badge])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        let actionIdentifier = response.actionIdentifier
        defer { completionHandler() }

        guard let raw = info["providerID"] as? String,
              let providerID = ProviderID(rawValue: raw) else { return }

        switch actionIdentifier {
        case AlertNotificationContent.openActionIdentifier, UNNotificationDefaultActionIdentifier:
            Task { @MainActor in
                self.appState?.pendingDeepLinkAccountKey = ProviderAccountKey(
                    providerID: providerID, slot: info["accountSlot"] as? String ?? ""
                )
                NSApp.activate(ignoringOtherApps: true)
            }
        default:
            break
        }
    }
}
#endif
