#if os(macOS)
import Foundation
import UserNotifications

@MainActor
final class MacLocalNotificationPublisher {
    static let shared = MacLocalNotificationPublisher()

    private let defaults = UserDefaults.standard
    private let postedSignaturesKey = "mac.postedAlertSignatures"
    private let maxRetention = 200

    private init() {}

    func requestAuthorizationIfNeeded() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .notDetermined else { return }
        do {
            _ = try await center.requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            print("[MacLocalNotificationPublisher] authorization skipped: \(error.localizedDescription)")
        }
    }

    func processEmittedAlerts(_ alerts: [CloudAlertPayload]) async {
        guard !alerts.isEmpty else { return }
        for alert in alerts {
            await post(alert)
        }
    }

    private func post(_ alert: CloudAlertPayload) async {
        guard alert.providerID != .heatmap, alert.providerID != .codexTelemetry else { return }

        var posted = (defaults.array(forKey: postedSignaturesKey) as? [String]) ?? []
        guard !posted.contains(alert.signature) else { return }

        let content = AlertNotificationContent.makeContent(for: alert)
        let request = UNNotificationRequest(
            identifier: alert.signature,
            content: content,
            trigger: nil
        )

        do {
            try await UNUserNotificationCenter.current().add(request)
            posted.append(alert.signature)
            if posted.count > maxRetention {
                posted.removeFirst(posted.count - maxRetention)
            }
            defaults.set(posted, forKey: postedSignaturesKey)
        } catch {
            print("[MacLocalNotificationPublisher] post failed: \(error.localizedDescription)")
        }
    }
}
#endif
