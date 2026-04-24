import SwiftUI
#if os(iOS)
import BackgroundTasks
import UIKit
import UserNotifications
#endif

@main
struct AIUsageTrackerApp: App {

    #if os(iOS)
    @UIApplicationDelegateAdaptor private var appDelegate: IOSAppDelegate
    #endif
    @StateObject private var appState = AppStateStore()
    #if os(macOS)
    @State private var menuBarController: MenuBarController?
    #endif

    var body: some Scene {
        WindowGroup {
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
        }
        #if os(macOS)
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 280, height: 380)
        #endif
    }
}

#if os(iOS)
final class IOSAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    private let backgroundTaskIdentifier = "com.chrisizatt.LLMUsageCounter.refresh"
    weak var appState: AppStateStore?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        application.registerForRemoteNotifications()
        registerBackgroundTasks()

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
            completionHandler(.noData)
            return
        }

        Task {
            let handled = await appState.handleRemoteNotification(userInfo: userInfo)
            completionHandler(handled ? .newData : .noData)
        }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        print("[IOSAppDelegate] Remote notifications unavailable: \(error.localizedDescription)")
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    func scheduleBackgroundRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: backgroundTaskIdentifier)
        request.earliestBeginDate = Date().addingTimeInterval(30 * 60)

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

        guard let appState else {
            task.setTaskCompleted(success: false)
            return
        }

        let work = Task { @MainActor in
            await appState.refresh()
            task.setTaskCompleted(success: true)
        }

        task.expirationHandler = {
            work.cancel()
            task.setTaskCompleted(success: false)
        }
    }
}
#endif
